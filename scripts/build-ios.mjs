#!/usr/bin/env node
/**
 * iOS 构建流水线：web 构建 → cap sync → vendor 还原 → xcodebuild → 导出 IPA。
 *
 * 为什么需要它：这条链有五个步骤，其中两步**极易忘**且忘掉后的报错都很难懂 ——
 *   1. `cap sync ios` 会把 CapApp-SPM/Package.swift 改回远程依赖
 *      （直连 GitHub Releases 常超时 → `Missing package product 'CapApp-SPM'`）；
 *   2. IPA 必须叫 `SuenMusic-v<版本>-release.ipa`，服务端才会认它。
 *
 * 用法（在 **suenmusic-mobile** 仓库根执行；web 在**同级**的 suenmusic-server 仓库里）：
 *   npm run ios:sync              # 只做 web 构建 + cap sync + vendor 还原（进 Xcode 前跑）
 *   npm run ios:ipa               # 完整链路，产出 app/SuenMusic-v<版本>-release.ipa
 *   npm run ios:ipa:unsigned      # 同上，但**不签名**，产出 app/unsigned/ 下的同名 IPA
 *
 * 两种导出怎么选：
 *   - **开发签名**（默认）：内嵌一份描述文件，可直接装到描述文件覆盖的设备上；
 *     代价是免费账号 7 天过期。
 *   - **未签名**（`--unsigned`）：AltStore / SideStore 这类重签工具最"干净"的输入
 *     —— 它们本来就要剥离原签名再用你自己的证书重签，给一份没签名的省去所有意外。
 *     两者文件名相同，靠目录区分；上传时按需要挑一份。
 *
 * 版本号来源与安卓**严格对齐**（见 .github/workflows/build-android.yml 的 Determine Version）：
 *   versionName ← 仓库根 `VERSION` 文件（如 1.4）
 *   versionCode ← 10000 + git 提交数（与安卓同一个单调递增基数）
 * 两者都以 xcodebuild **命令行覆盖**的方式注入（MARKETING_VERSION /
 * CURRENT_PROJECT_VERSION），不写 project.pbxproj —— 那是 Xcode 自己管理的文件，
 * 手工改会被它重写回去。
 *
 * ⚠️ 服务端 iOS 分支的 versionCode 取 0，更新判定走的是**版本名比较**
 *    （见 server/src/services/ugreen-update.ts）。所以 `MARKETING_VERSION` 必须
 *    跟 `VERSION` 一致 —— 这是 iOS 更新通道能生效的前提。
 *
 * 环境变量：
 *   IOS_ALLOW_PROVISIONING_UPDATES=0  关闭 -allowProvisioningUpdates（默认开启）。
 *     开启时 xcodebuild 会联网找 Apple 刷新描述文件 —— 免费个人团队的描述文件
 *     7 天就过期，不刷新会直接签名失败。
 *   IOS_APP_TARGET    Xcode target 名，默认 App
 */

import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, readFile, rm, stat } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const VENDOR = join(ROOT, 'ios/Vendor/capacitor-swift-pm');
const IOS_PROJECT = join(ROOT, 'ios/App/App.xcodeproj');
const PBXPROJ = join(IOS_PROJECT, 'project.pbxproj');
/**
 * ⚠️ 2026-09-26 仓库已拆分：web 在**同级**的 suenmusic-server 仓库里。
 * 所以这里必须往上跳一层 —— 前提是两个仓库检出在同一级目录
 * （本地 ~/Documents/github/{suenmusic-server,suenmusic-mobile}，
 *  CI 里 $GITHUB_WORKSPACE/{suenmusic-server,suenmusic-mobile}）。
 * 与 web/capacitor.config.ts 里那两条 `../../suenmusic-mobile/...` 是同一份约定的两面。
 */
const WEB_DIR = join(ROOT, '../suenmusic-server/web');
/** 统一产物目录（安卓 APK 与 iOS IPA 都归口到这里） */
const OUTPUT_DIR = join(ROOT, 'app');

const TARGET = process.env.IOS_APP_TARGET || 'App';
const ALLOW_PROVISIONING_UPDATES = process.env.IOS_ALLOW_PROVISIONING_UPDATES !== '0';
const SYNC_ONLY = process.argv.includes('--sync-only');
const UNSIGNED = process.argv.includes('--unsigned');

/** 构建输出单独放 app/（统一产物目录），源码树里不留中间产物。签名与未签名分开存放，免得互相覆盖 */
const SYMROOT = join(OUTPUT_DIR, UNSIGNED ? 'build-unsigned' : 'build');
/**
 * 未签名的包放子目录。
 *
 * 刻意**保留规范文件名**（不给它加 `-unsigned` 后缀）：服务端是按
 * `^SuenMusic-v(\d+)-release\.ipa$` 挑包的，改名字它就认不出来了。
 * 用目录区分两种产物，名字留给上传。
 */
const IPA_DIR = UNSIGNED ? join(OUTPUT_DIR, 'unsigned') : OUTPUT_DIR;

function fail(message) {
  console.error(`\n✖ ${message}`);
  process.exit(1);
}

function run(command, args, options = {}) {
  console.log(`\n$ ${command} ${args.join(' ')}`);
  execFileSync(command, args, { stdio: 'inherit', ...options });
}

function output(command, args, options = {}) {
  return execFileSync(command, args, { encoding: 'utf8', ...options }).trim();
}

// ---------------------------------------------------------------------------
// 前置检查：宁可开头报清楚，也不要跑到一半死在 Xcode 里
// ---------------------------------------------------------------------------

if (process.platform !== 'darwin') {
  fail(`iOS 构建只能在 macOS 上跑（当前 ${process.platform}）`);
}

if (!existsSync(join(WEB_DIR, 'node_modules'))) {
  fail(
    `web/node_modules 不存在（${WEB_DIR}）\n` +
      `  web 在同级的 suenmusic-server 仓库里，先跑：cd ../suenmusic-server/web && npm ci`
  );
}

/**
 * vendor 里的 xcframework 是否就位。
 *
 * ⚠️ **必须在 `syncWeb()` 之后调用，不能放在文件顶部**：`*.xcframework` 被
 * .gitignore 排除、不随仓库分发，全新克隆的仓库里一开始就是缺的 —— 而
 * `syncWeb()` 的第 3 步（`scripts/fix-ios-vendor.sh`）正是负责把它们下载补上。
 * 放在顶部会让 CI / 新机器直接死在这一步，永远走不到下载。
 */
function assertVendor() {
  for (const name of ['Capacitor', 'Cordova']) {
    if (!existsSync(join(VENDOR, `${name}.xcframework`))) {
      fail(
        `缺少 ${name}.xcframework —— 先跑 bash scripts/fix-ios-vendor.sh 把它补上\n` +
          `  （*.xcframework 被 .gitignore 排除，不会随仓库分发）`
      );
    }
  }
}

/**
 * 版本号与安卓同源。两个都校验，避免把 "1.4 " 这种带空白的内容悄悄带进产物。
 */
async function readVersionName() {
  const raw = (await readFile(join(ROOT, 'VERSION'), 'utf8')).trim();
  if (!/^\d+(?:\.\d+)*$/.test(raw)) {
    fail(`VERSION 文件内容不是版本号：${JSON.stringify(raw)}`);
  }
  return raw;
}

/**
 * 与安卓 CI 的 `VERSION_CODE=$((20000 + COMMIT_COUNT))` 严格相同；拿不到 git 时回退。
 *
 * ⚠️ 基数从 10000 抬到 **20000**（2026-09-26 拆分仓库时）：
 *   旧仓库 suenmusic 的 versionCode 已经发到 `10000 + 115 = 10115`，而本仓库是
 *   **全新的 git 历史**（提交数从 1 起）—— 沿用 10000 会算出 10001，**低于已装机版本**，
 *   Android 会以 `INSTALL_FAILED_VERSION_DOWNGRADE` 拒绝安装。抬高基数留足余量。
 *
 * 为什么要回退：源码可能是**导出的副本**（没有 .git 目录），这时 `git rev-list` 直接
 * 非零退出。iOS 的 code 只写进 CFBundleVersion —— 服务端 iOS 分支的 versionCode
 * 取 0、更新判定走版本名比较（见 server/src/services/ugreen-update.ts），
 * 所以两端 code 数值不一致没有影响，单调性够用就行。
 */
function readVersionCode(versionName) {
  try {
    const count = Number(output('git', ['rev-list', '--count', 'HEAD'], { cwd: ROOT }));
    if (Number.isInteger(count) && count > 0) {
      return { code: 20000 + count, source: `20000 + 提交数 ${count}` };
    }
  } catch {
    /* 不是 git 工作树 → 走下面的回退 */
  }
  const [major = 0, minor = 0, patch = 0] = versionName.split('.').map(Number);
  return {
    code: 20000 + major * 100 + minor * 10 + patch,
    source: `按版本号推导（当前目录不是 git 工作树）`,
  };
}

/**
 * 从工程里读 team id。
 *
 * 不硬编码：这是**用户自己**在 Xcode 里选的（Signing & Capabilities → Team），
 * 换账号、换机器都会变，写死只会让脚本在别人机器上莫名签名失败。
 */
async function readTeamId() {
  const pbx = await readFile(PBXPROJ, 'utf8');
  return /DEVELOPMENT_TEAM = ([A-Za-z0-9]+);/.exec(pbx)?.[1] ?? null;
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

async function syncWeb() {
  console.log('\n── 1/3 构建 Web 产物 ──');
  run('npm', ['run', 'build'], { cwd: WEB_DIR });

  console.log('\n── 2/3 同步进 iOS 工程 ──');
  run('npx', ['cap', 'sync', 'ios'], { cwd: WEB_DIR });

  console.log('\n── 3/3 还原本地 vendor 依赖 ──');
  // cap sync 刚把 Package.swift 改回远程依赖，这里必须还原，否则 SPM 解析失败
  run('bash', [join(ROOT, 'scripts/fix-ios-vendor.sh')], { cwd: ROOT });
}

async function buildIpa(versionName, versionCode) {
  await mkdir(IPA_DIR, { recursive: true });

  const args = [
    '-project', IOS_PROJECT,
    '-target', TARGET,
    '-configuration', 'Release',
    '-sdk', 'iphoneos',
    // 显式指定输出根目录：默认会落进 ios/App/build（也在 gitignore 里，但源码树里
    // 混着构建产物总归不好找）
    `SYMROOT=${SYMROOT}`,
    `MARKETING_VERSION=${versionName}`,
    `CURRENT_PROJECT_VERSION=${versionCode}`,
  ];
  if (UNSIGNED) {
    /**
     * 完全跳过签名。产出的 .app 不带 _CodeSignature 也不带 embedded.mobileprovision
     * —— 正是 AltStore / SideStore 这类重签工具最"干净"的输入：
     * 它们本来就要剥离原签名再签，给一份没签名的省去所有剥离的意外。
     */
    args.push('CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=""');
  } else if (ALLOW_PROVISIONING_UPDATES) {
    args.push('-allowProvisioningUpdates');
  }
  args.push('build');

  console.log(
    `\n── 编译 Release（版本 ${versionName} / code ${versionCode}，${UNSIGNED ? '未签名' : '开发签名'}）──`
  );
  run('xcodebuild', args, { cwd: join(ROOT, 'ios/App') });

  const appPath = join(SYMROOT, 'Release-iphoneos', `${TARGET}.app`);
  if (!existsSync(appPath)) fail(`没找到构建产物：${appPath}`);

  // 自证版本注入生效：xcodebuild 的命令行覆盖如果写错名字，产物里会静默保持工程旧值
  const builtName = output('/usr/libexec/PlistBuddy', [
    '-c', 'Print :CFBundleShortVersionString', join(appPath, 'Info.plist'),
  ]);
  const builtCode = output('/usr/libexec/PlistBuddy', [
    '-c', 'Print :CFBundleVersion', join(appPath, 'Info.plist'),
  ]);
  console.log(`\n产物版本：CFBundleShortVersionString=${builtName} CFBundleVersion=${builtCode}`);
  if (builtName !== versionName) {
    fail(`版本注入失败：产物是 ${builtName}，期望 ${versionName}（检查 MARKETING_VERSION 覆盖是否被工程设置顶掉）`);
  }

  console.log('\n── 打包 IPA ──');
  // 用 Payload/ 目录直接 zip，而不是 xcodebuild -exportArchive：
  // 后者要 exportOptions.plist + 共享 scheme，而本工程的 scheme 只在 Xcode 本地
  // （未共享），免费个人团队下还要额外处理导出方式。这种 IPA 交给
  // AltStore / SideStore 重签，与导出方式无关。
  const payloadDir = join(IPA_DIR, 'Payload');
  await rm(payloadDir, { recursive: true, force: true });
  await mkdir(payloadDir, { recursive: true });
  // 用 `cp -R` 而不是 fs.cp：bundle 内的 Frameworks 靠相对符号链接组织，
  // shell 的 -R 逐个原样搬运，不用去猜 fs.cp 对符号链接的处理是否够保守。
  run('cp', ['-R', appPath, payloadDir]);

  const ipaName = `SuenMusic-v${versionName}-release.ipa`;
  const ipaPath = join(IPA_DIR, ipaName);
  await rm(ipaPath, { force: true });
  run('zip', ['-qry', ipaName, 'Payload'], { cwd: IPA_DIR });
  await rm(payloadDir, { recursive: true, force: true });

  const { size } = await stat(ipaPath);
  console.log(`\n✔ ${ipaPath}`);
  console.log(`  大小 ${(size / 1024 / 1024).toFixed(1)} MB${UNSIGNED ? '（未签名，交给重签工具）' : ''}`);
  console.log('\n下一步：**手动**把这个 IPA 放到 NAS 的 release/ 目录，App 的更新检查才看得到');
  console.log('  目标路径：/home/suenqi/应用/SuenMusic/release/');
  console.log('  （UGREEN 的收集链接已失效，自动上传通道不再可用，只能手动传）');
}

const versionName = await readVersionName();
const teamId = await readTeamId();
if (!UNSIGNED && !teamId) {
  fail(
    '工程里没有 DEVELOPMENT_TEAM —— 先在 Xcode 里给 target App 选一个 Team\n' +
      '  （Signing & Capabilities → Automatically manage signing → Team）\n' +
      '  只想产出交给重签工具的包：改用 npm run ios:ipa:unsigned'
  );
}
console.log(
  `平台 macOS ✔　版本 ${versionName}　${teamId ? `Team ${teamId}` : '未签名导出（不需要 Team）'}`
);

await syncWeb();
assertVendor();

if (SYNC_ONLY) {
  console.log('\n✔ Web 产物已同步进 iOS 工程，现在可以在 Xcode 里直接 Build');
} else {
  const { code: versionCode, source } = readVersionCode(versionName);
  console.log(`versionCode ${versionCode}（${source}）`);
  await buildIpa(versionName, versionCode);
}
