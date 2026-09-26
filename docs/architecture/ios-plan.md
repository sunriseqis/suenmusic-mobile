# iOS 客户端 实施方案

> 决策依据见 [`roadmap.md`](roadmap.md)。
> 本文件是 **R7（iOS 端）的执行方案**：原生播放桥、离线缓存、应用更新通道，
> 以及「**不付费、自己用**」前提下的签名与安装路线。
>
> ⚠️ **2026-09-26 仓库已拆分**：本文件属于 **suenmusic-mobile**（Android + iOS）。
> 文中的 `web/`、`server/` 现在都在**同级**的 `suenmusic-server` 仓库里 ——
> 例如 `web/capacitor.config.ts` 的实际位置是 `../suenmusic-server/web/capacitor.config.ts`。
> 两个仓库必须检出在**同一级目录**下（本地 `~/Documents/github/{suenmusic-server,suenmusic-mobile}`，
> CI 里 `$GITHUB_WORKSPACE/{suenmusic-server,suenmusic-mobile}`），构建才成立。
> 另外产物目录已从 `output_ios/` 改为统一的 `app/`。

---

## 一、定位与边界

iOS 与安卓是**同一个 Web 前端**的两个原生壳（Capacitor 8）。原生只做 Web 做不了的事，
边界与安卓严格对齐：

| 归属 | 内容 |
|---|---|
| **原生负责** | 出声（AVQueuePlayer）、队列自动接续、锁屏/控制中心/灵动岛、耳机插拔与来电中断、离线缓存落盘、应用更新投递 |
| **Web 负责** | 队列顺序、播放模式、音源解析与重试、进度上报、歌词、全部 UI 状态 |

**为什么队列接续必须在原生**：熄屏后 WKWebView 的 JS 会被系统节流，Web 端的
「曲终判定」不可靠 —— 实测表现是「锁屏不自动续播、解锁后才跳曲」。
所以「下一首放谁」由原生完成（单曲/列表循环经 `setRepeatMode` 下发），
Web 只负责把索引同步回来。

---

## 二、工程结构

```
ios/
├── App/
│   ├── App.xcodeproj                    # 唯一 target：App（PRODUCT_BUNDLE_IDENTIFIER = com.suenmusic.app）
│   ├── CapApp-SPM/                      # Capacitor CLI 托管，承载 capacitor-swift-pm 依赖
│   │   └── Package.swift                # ⚠️ cap sync 会重写它，见 §九-1
│   └── App/
│       ├── SuenAudioPlugin.swift        # 原生播放桥（17 个方法）+ 封面缓存
│       ├── SuenAudioCache.swift         # 回环 HTTP 代理 + 磁盘 LRU + 断流续拉
│       ├── SuenUpdatePlugin.swift       # 应用更新：读版本 + 把安装包交给外部重签工具
│       ├── AppDelegate.swift            # Capacitor 模板
│       ├── SceneDelegate.swift          # 根视图 = SuenBridgeViewController
│       ├── Info.plist                   # 后台音频 / ATS 例外 / 本地网络 / 重签工具 scheme
│       └── Base.lproj/Main.storyboard   # 根控制器指向 SuenBridgeViewController
└── Vendor/capacitor-swift-pm/           # 本地 vendored 的 Capacitor/Cordova 二进制（见 §九-2）
```

`SuenBridgeViewController`（定义在 `SuenAudioPlugin.swift` 末尾）是
`CAPBridgeViewController` 的子类，在 `capacitorDidLoad()` 里注册两个本地插件。
Capacitor 8 对 App 内的本地 Swift 插件没有自动发现机制，**必须手工注册**。

---

## 三、原生播放桥（`SuenAudioPlugin.swift`）

### 3.1 方法契约（17 个，与安卓同名同参）

| 类别 | 方法 |
|---|---|
| 队列 | `setQueue`、`seekToIndex`、`reloadCurrent`、`stop` |
| 播放 | `play`、`pause`、`seek`、`setRepeatMode` |
| 状态 | `getStatus` |
| 系统 | `requestNotificationPermission`、`setLyricTimeline`、`setLyricLine` |
| 缓存 | `getCacheInfo`、`isCached`、`cacheImages`、`evictCache`、`clearCache` |

事件出口 5 类：`progress`（500ms 心跳）、`trackChange`、`state`、`error`、`networkChanged`。

### 3.2 与安卓的对应关系

| 安卓 | iOS |
|---|---|
| Media3 `MediaSessionService` | `AVQueuePlayer`（`actionAtItemEnd = .none` + 手动 advance） |
| `MediaController` | 插件直接方法调用 |
| 音频焦点 | `AVAudioSession.interruption` 通知 |
| 耳机插拔 | `AVAudioSession.routeChange` 通知 |
| 通知栏 / 锁屏 | `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` |
| 熄屏保活 | `Info.plist` → `UIBackgroundModes = audio` |
| `SuenAudioCache`（4GB LRU） | `SuenAudioCache.swift`（回环 HTTP 代理 + 磁盘 LRU） |
| AVRCP 蓝牙歌词 | **iOS 不支持** → `setLyric*` 空操作（见 §八） |

### 3.3 三条关键行为决策

1. **`trackChange.reason` 与 Media3 编号一致**：`1=AUTO`（播完接续）、`2=SEEK`。
   **不发 3**（`PLAYLIST_CHANGED` 回声）—— 那是我们自己重发队列的回声，不是切歌，
   Web 端本来就会丢掉它。
2. **`seekToIndex` 语义是「选中这一首」而非「从头播这一首」**：目标就是当前条目
   且非故障态时**不动位置**。安卓真机报障过「一点播放就从头开始」，就是这个语义没对齐。
3. **`reloadCurrent` 换音源必须重建条目**（丢内存缓冲 + 重新组流 URL）。
   只改 src / 只 seek 都会继续放旧音源 —— 表现是「换了源但时长和内容都没变」。

### 3.4 两个必须记住的实现细节

- **Now Playing 的播放状态用「意图」而不是 `player.rate`**：开了
  `automaticallyWaitsToMinimizeStalling` 后，缓冲期间 `rate` 会掉到 0，
  用它判定会把「正在缓冲」错报成「已暂停」，锁屏按钮来回跳。
- **所有 `notifyListeners` 必须切回主线程**：它最终走 `WKWebView.evaluateJavaScript`，
  而 WKWebView 主线程独占。从后台线程调用会卡死 WebKit 的进程间通信 ——
  实测表现是 WebContent/GPU 进程被系统反复杀掉、**页面纯白**。
  统一出口是 `SuenAudioPlugin.onMain`，不要绕过它。

---

## 四、离线缓存（`SuenAudioCache.swift`）

### 4.1 为什么是自己实现

AVFoundation 没有可插拔的 DataSource 抽象（对比安卓的 Media3 `SimpleCache` +
`CacheDataSource`），等价做法是**在进程内起一个只监听回环的 HTTP 服务**：

```
AVPlayer ──HTTP──▶ 127.0.0.1:<动态端口> ──▶ 磁盘缓存（命中）
                                        └──▶ 上游 /api/stream（未命中，边下边存）
```

只监听回环的理由：这个端口能读到本机磁盘上的缓存字节，暴露到局域网没有任何理由；
回环连接也不受 iOS 本地网络权限弹窗影响（见 §九-5）。

### 4.2 四条硬约束（移植自安卓踩坑结论，不得修改）

1. **缓存键是曲目 id，不是流 URL。** 流地址带签名时效（`?t=...`），签名一换 URL 就变，
   按 URL 做键会让缓存在签名轮换后集体失效。id 稳定。
2. **下载必须整首、从 0 顺序落盘。** 不做按需分片。客户端要读的区间还没下到就
   **阻塞等待**，而不是立刻返回短响应 —— 后者会让播放器把这条流判成「播完了」。
3. **上游断流要能续拉。** 服务端声明了 `Content-Length`，实测上游 CDN 会只发约 93.5%
   就断（AVPlayer 报 `-1005`）。拿到「已落盘字节数」后用 `Range: bytes=<n>-` 续拉，
   最多 4 次。
4. **容量 4GB、LRU 淘汰，用户不需要手动清理。** 磁盘不可用时降级为内存缓冲；
   最坏情况退化为「有缓存语义但没留下文件」，绝不因此播不出来。

### 4.3 与安卓的有意差异

- 缓存目录用 `Caches/`（安卓用 external-files）：`Caches` 不进 iCloud 备份、
  空间紧张时系统可回收，语义与「可再生的音频缓存」最匹配。
- `isCached` **只认完整文件**：部分缓存对「断网能不能听」这个判断没有意义。
- 元数据用**每首一个侧车 JSON**，不用全局索引：索引写坏会让整库缓存一起作废，
  侧车坏掉只影响那一首。

---

## 五、应用更新通道

### 5.1 两端形态完全不同（这是 iOS 的硬约束，不是未完成）

| | 安卓 | iOS |
|---|---|---|
| 安装 | 应用内下载 APK → 拉起系统安装界面 | **应用内装不了自己**：把 IPA 地址交给外部重签工具 / Safari |
| 强制要求 | `REQUEST_INSTALL_PACKAGES` | 无等价能力；免费签名下 OTA（`itms-services`）也不可用 |

### 5.2 服务端按平台分流

- `/api/update/check?platform=android|ios` —— 缺省 `android`（老客户端行为不变）。
  产物名各认各的：`SuenMusic-v<版本>-release.apk` / `.ipa`。
- `/api/update/download?platform=…&token=…` —— 两条鉴权入口满足其一即可：
  - `?token=`：`check` 顺带签发的**短期令牌**（30 分钟，HMAC 覆盖平台，见
    `server/src/utils/update-token.ts`）。给**发不出 Authorization 头**的调用方用
    （iOS 的重签工具、Safari）。
  - `Authorization: Bearer`：安卓原生侧自己下载时走这条。

### 5.3 iOS 侧的投递顺序

`SuenUpdatePlugin.openUpdate(url)` 依次尝试：

1. `altstore://install?url=<百分号编码后的地址>`
2. `sidestore://install?url=<…>`
3. 都不在 → `UIApplication.open(url)`，交给 Safari 下载

前两步依赖 `Info.plist` 的 `LSApplicationQueriesSchemes` 白名单（`altstore`、`sidestore`）——
**没有这个白名单，`canOpenURL` 恒返回 false**，会被静默降级成 Safari。

返回值语义：`opened` = 已唤起重签工具；`external` = 已交给系统。
**`external` 不是失败**，是免费签名下的正常路径。

### 5.4 ⚠️ iOS 的版本比较只看版本名

服务端 iOS 分支的 `versionCode` 固定取 0（`CFBundleVersion` 与版本名同源），
于是更新判定回退到**版本名比较**。因此 **`MARKETING_VERSION` 必须与仓库根 `VERSION` 一致** ——
这是 iOS 更新通道能生效的前提。

---

## 六、签名与安装（不付费、自己用）

### 6.1 免费（个人）Apple ID 的硬限制

| 限制 | 影响 |
|---|---|
| 描述文件 **7 天**过期 | 到期 App 直接打不开，必须重新签名安装 |
| 同时最多 **3 个**自签 App | 占用一个额度 |
| 每 7 天最多注册 **10 个** App ID | `com.suenmusic.app` 定下就别改，反复换会耗尽配额 |
| 无 Push / iCloud / App Groups 等 entitlement | 本项目一个都没用，**无影响** |
| `UIBackgroundModes = audio` | **不受限**，后台播放正常 |

**关键认知：「续签」和「更新」在免费签名下是同一件事。**
每 7 天必须重新签名安装一次，无论有没有新版本。

### 6.2 三条路

| | 续签方式 | 需要电脑 | 能走 App 内「立即更新」 |
|---|---|---|---|
| **Xcode 直装** | 每 7 天插线 ⌘R | 每次都要 | ❌ 只会跳到 Safari 下载 |
| **AltStore + AltServer** | Mac 上的 AltServer 后台无线刷新 | Mac 常开 + 同 Wi-Fi | ✅ |
| **SideStore** | 手机上自签（本地 VPN 让设备与自己通信） | **仅首次配置** | ✅ |

**本项目选定的路线：SideStore**（理由：Mac 不常开）。

### 6.3 SideStore 一次性配置

> **逐步操作版见 [`../guides/ios-自签安装指南.md`](../guides/ios-自签安装指南.md)**
> （含 IPA 产物位置、首次安装的鸡生蛋问题、每 7 天续签、排错与命令速查）。
> 下面是同一件事的方案侧记录。

手机侧先做：iOS 16+ 必须开**开发者模式**（设置 → 隐私与安全性 → 开发者模式 → 打开并重启）。

电脑侧（一次性）：
1. 手机 USB 连电脑 → 手机上点「信任此电脑」
2. 用 **iLoader**（开源 GUI，`nab138/iloader`）登录 Apple ID → 选「安装 SideStore」。
   它一次做完三件事：把 SideStore 装进手机、生成 pairing file、**自动放进 SideStore 沙盒**。
   > 不用 **JitterbugPair**：该工具长期未更新，新版 SideStore 会直接报
   > `SideStore could not determine this device's UDID. Please replace your pairing using iloader.`
   > —— 官方解法就是改用 iLoader 重新生成。

手机侧：
3. 装 **VPN 组件** —— SideStore 的配套「假 VPN / 回环」，让手机在**没有电脑**的情况下
   通过 localhost 访问自己的 usbmuxd。**必须保持连接**，否则续签失败。只在本机内部转发。
   ⚠️ 名字换过三代：`StosVPN`（已废弃，App Store 搜不到）→ `StikDebug` → **`LocalDevVPN`（当前）**；
   而 LocalDevVPN **只在非中国区 App Store 上架**，需要一个**外区 Apple ID** 才能下载。
   注意「下载用的外区号」与「SideStore 里签名用的号」**可以不是同一个账号**。
   不想搞外区账号：可用 [`tom-snow/Sidestore-ClashMi`](https://github.com/tom-snow/Sidestore-ClashMi)
   那套换成 Clash Mi，或退回 Xcode 直装。
4. SideStore → Settings → 登录 Apple ID（需要 **anisette 服务器**提供设备验证数据）

> 备用路线（iLoader 跑不起来时）：**JitterbugPair** 生成 `.mobiledevicepairing` → AirDrop 到手机 →
> 在 SideStore 里手动导入；SideStore 本身另用 **AltServer** 安装。见指南 §4.2。

**第一版 App**：此时 App 还没装，用不了 App 内的更新入口 —— 用 AirDrop 把 IPA 传到手机，
SideStore → `+` → 选文件。

### 6.4 日常

- **每 7 天**（建议第 5～6 天就做）：打开 SideStore → **Refresh All**。
  开后台刷新 + 保持 VPN 组件常开可基本自动完成。
- **有新版时**：App 内设置页「立即更新」→ 唤起 `sidestore://install?url=<带一次性令牌的地址>`
  → SideStore 重签安装、数据保留。

---

## 七、构建流程

### 7.1 命令

| 命令 | 作用 |
|---|---|
| `npm run ios:sync` | web 构建 → `cap sync ios` → 还原本地 vendor 依赖（**进 Xcode 前跑**） |
| `npm run ios:ipa` | 完整链路，产出**开发签名**的 IPA |
| `npm run ios:ipa:unsigned` | 同上但**不签名**，产出给重签工具用的干净包 |

实现见 `scripts/build-ios.mjs`。

### 7.2 版本号只有一个来源

与安卓 CI（`.github/workflows/build-android.yml` 的 Determine Version）严格对齐：

| 项 | 来源 |
|---|---|
| `versionName` / `MARKETING_VERSION` | 仓库根 `VERSION` 文件（如 `1.4`） |
| `versionCode` / `CURRENT_PROJECT_VERSION` | `10000 + git 提交数`；非 git 工作树时回退为 `major*10000 + minor*100 + patch` |

两者都以 **xcodebuild 命令行覆盖**注入，**不写 `project.pbxproj`** ——
那是 Xcode 自己管理的文件，手工改会被它重写回去。
脚本会读回产物里的 `CFBundleShortVersionString` 自证注入生效。

### 7.3 产物

```
app/SuenMusic-v<版本>-release.ipa            # 开发签名
app/unsigned/SuenMusic-v<版本>-release.ipa   # 未签名（重签工具的干净输入）
```

两份**文件名故意相同**：服务端按 `^SuenMusic-v(\d+(?:\.\d+)*)-release\.ipa$` 挑包，
加 `-unsigned` 后缀它就认不出来。用目录区分，名字留给上传。

**投递是手动的**：UGREEN 收集链接已失效（见 §九-9），把 IPA 拖进 NAS 的
`/home/suenqi/应用/SuenMusic/release/`。

---

## 八、平台差异（有意为之，不是缺陷）

| 功能 | 安卓 | iOS | 原因 |
|---|---|---|---|
| 车机蓝牙歌词（AVRCP） | ✅ 支持 | ❌ `setLyric*` 空操作，设置页开关对 iOS 隐藏 | iOS 的 Now Playing 不支持实时改字段，AVRCP 转发机制不同 |
| 通知渠道权限 | ✅ 需要 | ✅ 恒成功 | iOS 无通知渠道概念，Now Playing 由系统管理 |
| 应用更新安装 | 应用内一键 | 交给外部重签工具 | 沙箱不允许应用安装自己 |
| 抖动/下拉刷新 | ✅ | ✅ | 已统一为「原生端」判断 |

---

## 九、硬约束与踩坑（改代码前必读）

1. **`cap sync ios` 会重写 `ios/App/CapApp-SPM/Package.swift`**，把本地 vendor 依赖改回
   远程 `.package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", …)`。
   直连 GitHub Releases 常超时，表现是 `Missing package product 'CapApp-SPM'`。
   **每次 sync 之后跑一次 `bash scripts/fix-ios-vendor.sh`**（`ios:sync` 已内建）。
2. **`*.xcframework` 被 gitignore**，不随仓库分发。新环境或清过目录后，
   `fix-ios-vendor.sh` 会从 GitHub Releases 下载对应版本（当前 Capacitor 8.5.2；
   需要代理时用 `https_proxy` 环境变量）。
3. **`web/capacitor.config.ts` 必须显式配 `ios.path: '../ios'`**。
   不配时 CLI 按默认值去找 `web/ios`（不存在），`cap sync ios` 直接报找不到工程。
   同理安卓侧早就配了 `android.path: '../android'`。
4. **构建前必须先把 web 产物同步进 `ios/App/App/public`**。该目录与
   `capacitor.config.json`、`config.xml` 都在 gitignore 里，缺任何一个，Xcode 会在
   资源阶段直接失败：`The file "public" couldn't be opened because there is no such file`。
   （`build-ios.mjs` 的 sync 步骤就是干这个的。）
5. **`NSLocalNetworkUsageDescription` 是必需的**（`Info.plist`）。服务端是局域网地址，
   iOS 14 起访问本地网络要用户授权；缺这个 key 时系统**不弹询问框**。
   它与 `NSAllowsArbitraryLoads`（明文 http 的 ATS 例外）解决的是两件事，都要有。
6. **`LSApplicationQueriesSchemes` 必须登记 `altstore` / `sidestore`**，
   否则 `canOpenURL` 恒 false，更新会被静默降级成「用 Safari 打开」。
7. **版本号不要手工改 `project.pbxproj`**，走 §7.2 的命令行注入；
   并且 `VERSION` 与 iOS 的版本名必须一致，否则更新通道永远提示有新版。
8. **宿主环境的 node 版本**：`web/package.json` 的 engines 要求 `>=22.18`。
   低于它 npm 会报 `EBADENGINE`（仅警告，构建仍可通过）。
9. **NAS 只读不写**：UGREEN 的**收集链接（上传侧）已失效**
   （只读预检返回 `{"code":1303,"msg":"Data does not exist"}`），
   原先的 `scripts/upload-apk.mjs` 与 `npm run upload:apk` / `upload:ipa` 已删除。
   **下载分享（服务端读包用的那个）仍正常**，更新通道不受影响 —— 失效的只是投递方式，
   现在是手动把 IPA 放进 `release/`。
10. **iOS 代理的上游下载请求不能带 `Range`，否则被服务端限速到 40KB/s，
    AVFoundation 打不开 B 站的 fMP4。**
    服务端 `streamRate()` 对「带 Range 的请求」按码率限速
    （`Math.max(码率 * 1.3, 40_000)`，下限 40KB/s），对不带 Range 的
    「全量拉取／离线下载」则明确不节流。我们用真实 AVPlayer + 本地 HTTP
    复刻投喂节奏，实测（2026-09-26）：

    | 投喂速率 | AVPlayer |
    |---|---|
    | **40 KB/s**（限速后的实际值） | ❌ 停在 `AVPlayerWaitingWhileEvaluatingBufferingRateReason`，20s 从未就绪，请求不断从 64KB 对齐偏移重发 |
    | 390 KB/s / 1 MB/s | ✅ 立刻 `readyToPlay`，正常播放 |

    网易云是 MP3，40KB/s 下照样边收边解码；B 站是 fMP4
    （`ftyp iso5` + `moov` + `sidx` + `moof/mdat` 分片），AVFoundation 要攒够
    数据才肯就绪 —— 这就是「**只有 iOS + 只有 B 站音源**」的完整解释。
    **不要给首次整首下载加回 `Range: bytes=0-`**（`LocalStreamProxy.upstreamRequest`）。

    排查中已被实验排除：`Content-Type` 取 `video/mp4` 还是 `audio/mp4`（都能播）、
    容器本身（同一份字节本地改名 `.mp4` 即正常）、签名/本地网络权限（与现象无关）。
11. **`Content-Type` 不能信上游，必须按字节判 —— `application/octet-stream` 会让
    AVFoundation 直接拒播。** 实测（同一份 B 站 fMP4 字节，只改这一个响应头）：

    | 响应头 | AVPlayer |
    |---|---|
    | `video/mp4` | ✅ 正常 |
    | `audio/mp4` | ✅ 正常 |
    | **`application/octet-stream`** | ❌ `-11828 Cannot Open`（媒体格式不受支持） |

    AVFoundation **不靠字节嗅探容器**（WebKit / ExoPlayer 会），它就认这个响应头。
    而服务端 `PASSTHROUGH_HEADERS` 把 CDN 的类型原样透传，B 站/QQ 侧**大量音频正是
    `application/octet-stream`** —— 现象是「很多歌在 iOS 上播不出来，web 与安卓正常」。

    因此 `ProxyConnection` 用 `playableContentType(declared:head:)` 按缓存文件头的
    字节（`ftyp` / `ID3` / `fLaC` / `OggS` / `RIFF…WAVE` / MPEG 帧同步）自己认容器，
    **认出来就覆盖上游声明**。**不要改回「原样透传上游 Content-Type」。**

---

## 十、待验证（代码在，但没端到端跑过）

1. **AltStore / SideStore 是否接受明文 http 的局域网 IPA 源** —— 我们的服务端是
   `http://192.168.x.x`，重签工具能否接受未实测。
2. **30 分钟令牌**够不够走完一次安装流程。
3. **开发签名的 IPA 能否被 SideStore 重签安装** —— 常规做法是剥离原签名再签，
   理论上可行；未实测。真遇到拒绝就用 `npm run ios:ipa:unsigned` 出未签名包。
4. **`NSLocalNetworkUsageDescription` 缺失是否必然阻塞局域网** ——
   日志里出现过 `unsatisfied (Local network prohibited)` + `NSURLErrorDomain -1009`
   的连发失败（伴随上游 94% 截断），但同一时期用 **Xcode 直装**时播放正常，
   未复现稳态阻塞。该 key 已按 Apple 要求补上，留待自签安装时对照验证。
