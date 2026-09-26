# iOS 免费自签安装指南（不付费自用）

> 面向「**不想买 $99/年 开发者账号，只自己用**」的安装与续签流程。
> 业内也常把这件事叫「**免签**」，本文统一写作「免费自签」。
>
> 方案选型与实现细节见 [`../architecture/ios-plan.md`](../architecture/ios-plan.md)；
> 本文只讲**手上怎么操作**。
>
> ⚠️ **2026-09-26 仓库已拆分**：本文件属于 **suenmusic-mobile** 仓库，
> 构建产物在 `app/`（原 `output_ios/`）。前端 `web/` 在同级的 `suenmusic-server` 仓库，
> 跑 `npm run ios:ipa:unsigned` 前它必须和本仓库检出在同一级目录。

---

## 一、先认清三条硬限制

这些是 Apple 对**免费（个人）Apple ID** 的规定，任何工具都绕不过：

| 限制 | 对你的影响 |
|---|---|
| 描述文件 **7 天**过期 | 第 8 天 App 会**直接打不开**（不是闪退，是提示无法验证），必须重新签名安装 |
| 同时最多 **3 个**自签 App | SuenMusic 占 1 个，还剩 2 个 |
| 每 7 天最多注册 **10 个** App ID | `com.suenmusic.app` 定下就**别改**；反复换 bundle id 会耗尽配额，7 天内装不上新的 |

不受限的部分：`UIBackgroundModes = audio`（后台播放）正常可用；
Push / iCloud / App Groups 免费账号用不了，但本项目一个都没用。

> ⚠️ **最重要的一句话：「续签」和「更新」是同一件事。**
> 每 7 天你都要重新签名安装一次，**不管有没有新版本**。
> 不要指望"点一次立即更新就长期不用管"。

---

## 二、IPA 产物在哪，怎么生成

命令行生成（在仓库根目录）：

```bash
npm --prefix web install     # 首次需要，或 node_modules 被清过之后
npm run ios:ipa              # 开发签名版
npm run ios:ipa:unsigned     # 未签名版（给 SideStore 更干净的输入）
```

产物路径（`app/` 在 `.gitignore` 里，**git 视图里看不到，要用文件管理器或终端看**）：

| 产物 | 路径 | 用途 |
|---|---|---|
| 开发签名 | `app/SuenMusic-v1.4-release.ipa` | 装到本人设备；**7 天过期** |
| 未签名 | `app/unsigned/SuenMusic-v1.4-release.ipa` | 交给 SideStore / AltStore 重签 |

两份**文件名故意相同**（服务端按 `SuenMusic-v<版本>-release.ipa` 挑更新包），靠目录区分。

终端确认：

```bash
ls -lh app/*.ipa app/unsigned/*.ipa
```

**版本号改了才会出新文件名**：`VERSION` 文件（当前 `1.4`）是唯一来源，
改成 `1.5` 再跑一次 `npm run ios:ipa`，产物就是 `SuenMusic-v1.5-release.ipa`。

---

## 三、路线选择

| | 续签怎么做 | 需要电脑 | 适合谁 |
|---|---|---|---|
| **A. Xcode 直装** | 每 7 天插线 ⌘R | **每次都要** | 只想先跑起来看看 / 手边一直有 Mac |
| **B. AltStore + AltServer** | Mac 上的 AltServer 后台无线刷新 | Mac 常开 + 同 Wi-Fi | Mac 长期开机的人 |
| **C. SideStore** ⭐ | 手机上自签（本地 VPN 让设备与自己通信） | **仅首次配置** | Mac 不常开的人 —— **本项目选这条** |

下面 A 讲三行，B/C 详述。

### A. Xcode 直装（最简，先跑起来用）

1. iPhone 插上 Mac（或配好无线调试）
2. `npm run ios:sync`
3. Xcode 打开 `ios/App/App.xcodeproj` → 顶部设备选你的 iPhone → **⌘R**
4. 首次运行会要求信任：手机 **设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID**

7 天后再插线 ⌘R 一次即可。**注意**：这条路装出来的 App，
点设置页的「立即更新」只会跳到 Safari 下载 IPA，**装不了** —— 安装只能回到 Xcode。
所以 A 只适合验证功能，不适合长期自用。

---

## 四、SideStore 从零到装上 SuenMusic

> SideStore 的界面各版本会变，**精确路径以官方为准**：
> [`docs.sidestore.io`](https://docs.sidestore.io/) 右上角可切**中文** → Docs → Introduction。
> 下面给的是**步骤骨架和每步的意图**，照着走不会迷路。

### 4.0 一次性准备清单

| 项 | 说明 |
|---|---|
| 一台电脑 | Windows / macOS / Linux 都行，仅首次需要 |
| iPhone 数据线 | 生成配对文件时要连电脑 |
| 电脑端工具 | **iLoader**（开源图形界面，推荐）—— 见 4.2 |
| 免费 Apple ID | 用于**签名**，就是平时登录 App Store 那个 |
| **外区 Apple ID** | ⚠️ **用于下载 VPN 组件**，国区 App Store 下不到 —— 见 4.3。可以和上面那个不是同一个号 |
| 手机系统 | iOS 16+ 需手动开**开发者模式**（见 4.1） |
| 网络 | 生成配对文件时手机与电脑建议在同一 Wi-Fi |

### 4.1 手机：打开开发者模式

**设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启手机**。
（iOS 16 起必须，不打开侧载的 App 起不来。）

### 4.2 电脑：装 SideStore + 准备配对文件

配对文件是什么：一份「这台电脑 ↔ 这台 iPhone 已配对互信」的记录。
SideStore 在手机上要**假装自己就是那台配过对的电脑**，系统才允许它走安装流程。

#### 推荐：用 iLoader（一步到位）

**iLoader** 是开源的图形界面工具（仓库 [`nab138/iloader`](https://github.com/nab138/iloader)，
Windows / macOS / Linux 都有）：

1. 手机 USB 连电脑 → 手机上点「**信任此电脑**」
2. 打开 iLoader → 登录你的 Apple ID
3. 选「**安装 SideStore**」

它会一次做完三件事：把 SideStore 装进手机、生成配对文件、**并自动放进 SideStore 的沙盒**
（省掉手机上手动导入那一步）。它也能给其他已装好的侧载 App 投放配对文件。

> **为什么不再用 JitterbugPair**：该工具**已很久没有更新**。新版 SideStore（Nightly）会直接报错
> `SideStore could not determine this device's UDID. Please replace your pairing using iloader.`
> —— 官方给的解法就是「改用 iLoader 重新生成配对文件」。
> 所以下面那条**只在 iLoader 跑不起来时才用**。

#### 备用：手动生成（仅在 iLoader 不可用时）

只有当 iLoader 在你的平台上跑不起来（或本身报错）时才走这条：

1. 手机 USB 连电脑 → 手机上点「**信任此电脑**」
2. 用 **JitterbugPair** 生成 `<设备UDID>.mobiledevicepairing`
   > ⚠️ 长期未更新。若 SideStore 报 `could not determine this device's UDID`，
   > 说明这条路已经不通 —— 回到 iLoader。
3. 把文件传到手机（AirDrop / 文件 App / iCloud），待会儿在 SideStore 里**手动导入**
4. SideStore 的 IPA 得另想办法装进手机：用 **AltServer**，或先用电脑端工具代装

### 4.3 手机：装 VPN 组件（最容易卡住的一步）

**这是「免电脑续签」的关键部件。** 它只在本机内部转发，让 SideStore 能在没有电脑的情况下
通过 localhost 访问自己的 usbmuxd/lockdown 服务 —— 本质是**伪造一台"配过对的电脑"**。
**签名 / 安装 / 续签时必须保持连接**，否则会失败。

#### ⚠️ 这个名字换过三代，别照着老教程搜

| 组件 | 状态 | 获取方式 |
|---|---|---|
| **StosVPN** | ❌ 已过时。SideStore 团队早期自研的专用 VPN，实测**后台容易被系统杀掉、经常自动断开** | 已不推荐，**App Store 上搜不到** |
| **StikDebug** | 过渡期替代品 | 外区（美区）App Store |
| **LocalDevVPN** | ✅ **当前推荐** | ⚠️ **国区 App Store 没有，需要外区 Apple ID** |
| Clash Mi 等支持回环的代理 | 进阶替代，可常驻后台 | 国区可下，见下方 |

**所以搜不到是正常的**，不是操作问题 —— 两个原因叠在一起：
`StosVPN` 这名字已经不用了；而当前的 `LocalDevVPN` **只在中国区之外上架**。

#### 外区 Apple ID 和"签名用的 Apple ID"可以是同一个，也可以分开

别把这两件事混了：

- **下载 VPN 组件** → 用**外区** Apple ID。
  切换方式：**App Store → 右上角头像 → 退出登录 → 换号**；
  或 **设置 → 你的名字 → 媒体与购买项目 → 切换账号**（**不影响 iCloud 登录**，照片通讯录都还在原账号上）
- **SideStore 里登录的那个** → 用**你自己的号**，它只负责签名

#### 不想搞外区账号？两个替代思路

1. **用 Clash Mi 之类的代理顶替**：社区方案 [`tom-snow/Sidestore-ClashMi`](https://github.com/tom-snow/Sidestore-ClashMi)
   就是把 StosVPN 换成 Clash Mi（**国区 App Store 就能下**），顺带解决了 StosVPN 爱断连、无法常驻后台的问题。
2. **回到 Xcode 直装**：不需要外区账号、不需要 VPN、不需要任何第三方工具 ——
   代价是每 7 天插一次 Mac（见 §三 路线 A）。**门槛最低，只是要动手。**

### 4.4 手机：SideStore 初始化

手机 **设置 → 通用 → VPN 与设备管理** → 先信任对应的开发者证书。

然后打开 SideStore：

- **走 iLoader 的**：配对文件已经自动放好了，**直接做第 2 步**，不用手动导入。
- **走手动路线的**：先在 SideStore 里**导入** 4.2 生成的 `pairing file`。

2. SideStore → **Settings** → **登录你的 Apple ID**
   （需要 **anisette 服务器**提供设备验证数据；用默认的，登录不上就在设置里换一个）

### 4.5 手机：装 SuenMusic

⚠️ **鸡生蛋问题**：此刻 App 还没装，所以**用不了 App 内的「立即更新」**。

1. 把 IPA 传到手机 —— **推荐未签名版**：`app/unsigned/SuenMusic-v1.4-release.ipa`
   （AirDrop 最省事）
2. SideStore 主界面右上角 **`+`** → 选择这个 IPA 文件
3. 等它重签 + 安装完成

> 也可以从 URL 装，但需要 IPA 已经放在可访问的地址上（我们的服务端下载接口要带一次性令牌，
> 手工填不方便）。首次就 AirDrop 传文件最省事。

### 4.6 首次打开必做：允许「本地网络」

App 连的是你局域网里的 SuenMusic 服务器，iOS 14 起必须授权：

- 第一次打开 App 会弹「**允许访问本地网络**」→ **必须点允许**
- 手滑点了不允许：**设置 → 隐私与安全性 → 本地网络 → 打开 SuenMusic**

不授权的话表现是：界面能开、但一直转圈 / 播不出声（日志里是
`unsatisfied (Local network prohibited)`）。

### 4.7 配好之后：日常只需一件事

**每 7 天**（建议第 5～6 天就做，别等过期）：

> 打开 SideStore → **Refresh All**

想更省事：在 SideStore 里开启**后台刷新**，并保持 **VPN 组件常开**（见 4.3）+ 手机有网，
它就会在后台自动重签。但**别完全依赖自动**，到点了手动点一下最稳。

---

## 五、更新到新版本

SideStore 只负责"重签同一份 IPA"。要装**新版本**得先有新 IPA：

1. 递增 `VERSION`（如 `1.4` → `1.5`）
2. `npm run ios:ipa:unsigned` 生成 `SuenMusic-v1.5-release.ipa`
3. **手动**把它放进 NAS 的 `/home/suenqi/应用/SuenMusic/release/`
   （UGREEN 收集链接已失效，自动投递脚本已删除，只能手动传）
4. App 内（旧版本）→ 设置页 →「检查更新」→「立即更新」
   → 会唤起 `sidestore://install?url=<带一次性令牌的地址>` → SideStore 重签安装

同 bundle id 覆盖安装，**本地数据保留**。

> 如果第 4 步唤起失败（例如 SideStore 不接受明文 http 的局域网地址），
> 就退回 4.5 的老办法：AirDrop 新 IPA 到手机，SideStore 里选文件装。
> 这条路径**永远可用**，不依赖任何网络回调。

---

## 六、排错

### App 装完打不开 / 提示无法验证

**7 天到了。** 去 SideStore → Refresh All。数据不会丢。

### 下载 SideStore.ipa 报 `error decoding response body` / 卡很久

两个原因，通常一起出现：

1. **GitHub 的下载链接是临时签名 URL，只有约 1 小时有效期。**
   报错里那串地址的 `se=...` 就是到期时间 —— 如果工具缓存了旧链接再重试，
   必然失败（服务端会返回一个 XML 错误页，而不是 IPA）。
2. **国内直连 `release-assets.githubusercontent.com` 很慢。** 实测 26.4 MB 走代理要
   **3 分 17 秒（约 137 KB/s）**，慢线路上极易中途断流 —— 而 reqwest 的
   `error decoding response body` 最常见成因就是**响应流被截断**。

**解法：别让工具自己下，手动下好再用本地 IPA 安装。**

```bash
export https_proxy=http://<你的代理>:<端口>          # 国内必需
URL=$(curl -s https://api.github.com/repos/SideStore/SideStore/releases/latest \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print([a['browser_download_url'] for a in d['assets'] if a['name']=='SideStore.ipa'][0])")
curl -fL --retry 3 -o ~/Downloads/SideStore.ipa "$URL"
```

> ⚠️ **别装 0.6.4**：那个 release 的名字就叫 **`0.6.4 (DO NOT USE)`**，正文第一行是
> `❌ DO NOT USE — SIGN-IN IS BROKEN ON 0.6.4 AND BEFORE`。Apple 侧的改动让 0.6.4 及更早
> 版本登录 SideStore 必报 503。**当前要装的是 `0.7.0-alpha`**（名字带 alpha，但它是修了这个问题的版本）。
> 上面的命令用 `releases/latest` 拿的就是它。

### App Store 里搜不到 StosVPN / LocalDevVPN

**不是你的问题，是名字和上架区变了**（详见 4.3）：

- `StosVPN` 是早期名称，已经废弃，App Store 上搜不到
- 当前要装的是 `LocalDevVPN`，**只在非中国区上架** → 需要一个外区 Apple ID
- 不想搞外区账号：用 `tom-snow/Sidestore-ClashMi` 那套换成 Clash Mi（国区可下），
  或者干脆回到 Xcode 直装（§三 路线 A）

### SideStore 报 `could not determine this device's UDID`

配对文件是**旧工具（JitterbugPair）**生成的，新版 SideStore（Nightly）已经不认识它。
官方给的解法写在报错里：**改用 iLoader 重新生成配对文件**（见 4.2 的推荐路径）。
用 iLoader 装 SideStore 时会自动放好，不用手动导入。

### SideStore 提示「已达到 App ID 上限」

免费账号每 7 天只能注册 10 个 App ID。**别反复改 bundle id** ——
改一次就消耗一个配额。等 7 天窗口过去，或换一个 Apple ID。

### 手机能装但连不上服务器（一直转圈 / 不出声）

1. **设置 → 隐私与安全性 → 本地网络** → 确认 SuenMusic 是打开的
2. 确认手机和服务器在**同一个网络**（同一 Wi-Fi，或同一个 Tailscale 网络）
3. 换个手机浏览器直接打开服务端地址，看能不能通

### 构建侧报 `Missing package product 'CapApp-SPM'`

`cap sync ios` 把本地的 SPM 依赖改回远程了（直连 GitHub Releases 常超时）。修：

```bash
bash scripts/fix-ios-vendor.sh
```

（`npm run ios:sync` 已内建这一步；想省心就直接用它。）

### 构建侧报 `The file "public" couldn't be opened`

web 产物还没同步进 iOS 工程。先跑：

```bash
npm run ios:sync
```

### 想让 SideStore 拿到"最干净"的输入

用未签名版：

```bash
npm run ios:ipa:unsigned
# → app/unsigned/SuenMusic-v<版本>-release.ipa
```

它不含 `_CodeSignature` 也不含 `embedded.mobileprovision`，
重签工具不用先剥离原签名。

---

## 七、命令速查

```bash
# 生成 IPA（在仓库根执行）
npm --prefix web install          # 首次 / node_modules 被清后
npm run ios:sync                  # 只同步（进 Xcode 前跑）
npm run ios:ipa                   # 开发签名 IPA
npm run ios:ipa:unsigned          # 未签名 IPA

# 产物位置
open app                   # 开发签名版
open app/unsigned          # 未签名版

# 修 SPM 依赖（cap sync 之后如果构建报错）
bash scripts/fix-ios-vendor.sh

# 查看当前版本号
cat VERSION
```
