#!/usr/bin/env node
/**
 * 鸿蒙 NEXT HAP 构建脚本：Web 编译 → 同步至 rawfile → hvigorw 构建未签名 HAP。
 *
 * 用法：
 *   node scripts/build-hw.mjs --sync-only      # 仅执行 web build 并同步到 hw rawfile
 *   node scripts/build-hw.mjs                  # 编译未签名 HAP，产出 app/SuenMusic-v<版本>-unsigned.hap
 */

import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import { copyFile, mkdir, readFile, writeFile, stat } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const HW_DIR = join(ROOT, 'hw');
const OUTPUT_DIR = join(ROOT, 'app');
const SYNC_ONLY = process.argv.includes('--sync-only');

function log(msg) {
  console.log(`[build-hw] ${msg}`);
}

function fail(message) {
  console.error(`\n✖ [build-hw] ${message}`);
  process.exit(1);
}

function run(command, args, options = {}) {
  console.log(`\n$ ${command} ${args.join(' ')}`);
  execFileSync(command, args, { stdio: 'inherit', ...options });
}

function output(command, args, options = {}) {
  return execFileSync(command, args, { encoding: 'utf8', ...options }).trim();
}

async function readVersionName() {
  const raw = (await readFile(join(ROOT, 'VERSION'), 'utf8')).trim();
  if (!/^\d+(?:\.\d+)*$/.test(raw)) {
    fail(`VERSION 文件内容不是合法版本号：${JSON.stringify(raw)}`);
  }
  return raw;
}

function readVersionCode(versionName) {
  try {
    const count = Number(output('git', ['rev-list', '--count', 'HEAD'], { cwd: ROOT }));
    if (Number.isInteger(count) && count > 0) {
      return { code: 20000 + count, source: `20000 + git 提交数 ${count}` };
    }
  } catch {
    /* 无法执行 git 时回退到版本号推导 */
  }
  const [major = 0, minor = 0, patch = 0] = versionName.split('.').map(Number);
  return {
    code: 20000 + major * 100 + minor * 10 + patch,
    source: `按版本号推导`,
  };
}

async function syncWeb() {
  log('1/3 同步 Web 静态资源至鸿蒙 rawfile 目录...');
  run('node', [join(ROOT, 'scripts/sync-hw.mjs')]);
}

async function injectVersion(versionName, versionCode) {
  log(`2/3 注入版本号至鸿蒙工程: ${versionName} (${versionCode})...`);
  const appJsonPath = join(HW_DIR, 'AppScope/app.json5');
  if (existsSync(appJsonPath)) {
    let content = await readFile(appJsonPath, 'utf8');
    content = content.replace(/"versionName":\s*"[^"]*"/, `"versionName": "${versionName}"`);
    content = content.replace(/"versionCode":\s*\d+/, `"versionCode": ${versionCode}`);
    await writeFile(appJsonPath, content, 'utf8');
  }
}

async function assembleHap(versionName, versionCode) {
  log('3/3 执行 Hvigor 编译未签名 HAP...');
  const hvigorw = join(HW_DIR, 'hvigorw');

  // `hvigorw` 是 bash 脚本（#!/usr/bin/env bash），Windows 不能直接 spawn，
  // 只会报一个看不懂的 ENOEXEC/EACCES。CI 跑在 ubuntu 所以一直没暴露。
  // 本地 Windows 请用 DevEco Studio 构建，或在 Git Bash / WSL 里跑本脚本。
  if (process.platform === 'win32') {
    fail('hvigorw 是 bash 脚本，Windows 上无法直接执行；请用 DevEco Studio 构建，或在 Git Bash / WSL 里运行本脚本。');
  }

  const args = [
    'assembleHap',
    '--mode', 'module',
    '-p', 'module=entry@default',
    '-p', 'product=default',
    '-p', `versionName=${versionName}`,
    '-p', `versionCode=${versionCode}`,
    '--no-daemon',
    '--accept-license',
  ];

  run(hvigorw, args, { cwd: HW_DIR });

  // 检索产物目录
  const candidateDirs = [
    join(HW_DIR, 'entry/build/default/outputs/default'),
    join(HW_DIR, 'build/outputs/default'),
  ];

  let foundHap = null;
  for (const dir of candidateDirs) {
    if (existsSync(dir)) {
      const files = readdirSync(dir).filter((f) => f.endsWith('.hap'));
      if (files.length > 0) {
        foundHap = join(dir, files[0]);
        break;
      }
    }
  }

  if (!foundHap) {
    fail('Hvigor 编译完成，但未在 outputs 目录找到 .hap 产物！');
  }

  await mkdir(OUTPUT_DIR, { recursive: true });
  const targetHap = join(OUTPUT_DIR, `SuenMusic-v${versionName}-unsigned.hap`);

  await copyFile(foundHap, targetHap);

  const { size } = await stat(targetHap);
  log(`✔ HAP 打包成功！产物：${targetHap}`);
  log(`  大小 ${(size / 1024 / 1024).toFixed(2)} MB（未签名，供测试与自签使用）`);
}

const versionName = process.env.CUSTOM_VERSION || (await readVersionName());
const { code: versionCode, source } = readVersionCode(versionName);
log(`当前目标版本: v${versionName} / versionCode: ${versionCode} (${source})`);

await syncWeb();

if (SYNC_ONLY) {
  log('✔ 已完成静态资源同步（--sync-only）。');
} else {
  await injectVersion(versionName, versionCode);
  await assembleHap(versionName, versionCode);
}
