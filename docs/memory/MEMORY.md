# SuenMusic 移动端长期记忆（Android + iOS）

> 本文件只收**移动端**的不可动摇约束与踩过的坑。
> 服务端 / Web 的长期记忆在**同级** suenmusic-server 仓库的
> [`docs/memory/MEMORY.md`](https://github.com/sunriseqis/suenmusic-server/blob/main/docs/memory/MEMORY.md)。
>
> **2026-09-26 按平台从那份里切分而来**，编号沿用原编号，所以下面会有跳跃
> （22 → 30 → 31 → 34~40）。原处保留了带指针的同名标题，便于从旧文档跳过来。

---

### 22. Android 永久官方签名一致性
- **根除签名冲突**：GitHub Actions 临时虚拟机每次构建会自动生成随机密钥导致各次 APK 签名互斥。解决方案是生成并内置专用官方密钥库 `android/app/suenmusic.keystore`（有效至 2054 年，RSA 2048 位），并在 `build.gradle` 的 `signingConfigs.release` 默认加载，确保本地与 CI 构建签名永久一致。
- **统一构建 `assembleRelease`**：正式分发生产包（`debuggable="false"`），避免定制系统拦截测试包覆盖安装；配置 `lint { checkReleaseBuilds false; abortOnError false }` 消除冗长耗时的静态分析。

---

### 30. Android 原生代码无法本地验证，必须过 CI 才算编译通过（2026-09-21 实测）
- **沙箱没有 JDK / Android SDK**，`javac` 与 Gradle 都跑不了 → Android 的 Java 改动**只能靠 GitHub Actions 验证**。
  攒着不提交 = 攒着未验证的错误：本次的编译错误就来自一段积压多日、从未被编译过的改动，一提交就炸。
- **Capacitor 的 JSON 类型陷阱**：`JSObject extends org.json.JSONObject`（**子类**），而 `JSArray.getJSONObject()`
  继承自 `JSONArray`、返回的是**父类** `org.json.JSONObject`。所以 `JSObject x = lines.getJSONObject(i)` **编译不过**，
  报 `incompatible types: JSONObject cannot be converted to JSObject`。正确写法是声明成 `org.json.JSONObject`。
- **随之而来的 API 差异**：`getString(key, defaultValue)` 是 `JSObject` **独有**的；换成 `org.json.JSONObject` 后
  必须改用 `optString(key, fallback)`（Android org.json 没有二参 `getString`）。
- **放宽参数类型的技巧**：要同时接受两者的辅助方法，入参直接写 `org.json.JSONObject` —— 子类 `JSObject` 照样能传入，
  既有调用点不用改。
- 参照实现：`SuenAudioPlugin.java` 的 `setQueue()`（父类写法）与 `setLyricTimeline()`（修复后）。

### 31. APK 内置了一份 web 快照 —— 前端改动必须重新构建安卓端才进 App
- **结构**：`web/capacitor.config.ts` 里 `webDir: 'dist'` 且**没有配 `server.url`**，
  `MainActivity` 也没有自定义 `loadUrl`；构建 APK 时 `npx cap sync android` 会把 `web/dist`
  打进 `android/app/src/main/assets/public/`（该目录被 `.gitignore`，是构建产物）。
  **所以安卓 WebView 加载的是 APK 内的静态快照**，服务端只提供数据（API / 音频流），**不提供页面**。
- **后果**：任何 `web/**` 改动（组件、样式、页面逻辑）**光部署 web 容器是不够的** ——
  浏览器/PWA 立刻生效，但**已安装的 App 必须重新构建并安装 APK** 才生效。
- **没有 OTA**：项目没有引入 capgo / ionic-webview 之类的前端热更新插件，所以「不重新构建就更新前端」做不到。
- **发版口径**：要让 App 拿到前端修复，把 `VERSION` 递增（如 1.1 → 1.2）触发 `build-android`。
  只推代码不改 `VERSION` 会生成同名 APK（`SuenMusic-v1.1-release.apk`）覆盖旧资产、版本名不变，
  只能靠 `versionCode`（= `10000 + 提交数`）区分，容易混淆。
- **别忘最后一步**：CI 只发布到 GitHub Release（NAS 直传已因 runner 连不上中转而移除），
  还要**手动**把包放进 NAS 的 `/home/suenqi/应用/SuenMusic/release/`，App 的更新检查才看得到。
  （收集链接失效后自动投递脚本已删除，见上方 2026-09-25 的更新。）

---

## iOS 端与免费自签路线（2026-09-25 沉淀）

iOS 端首轮已完成。**架构与完整方案见 [`https://github.com/sunriseqis/suenmusic-mobile/blob/main/docs/architecture/ios-plan.md`](https://github.com/sunriseqis/suenmusic-mobile/blob/main/docs/architecture/ios-plan.md)**，
这里只记不可动摇的约束与踩过的坑。

### 34. iOS 工程接入：三处配置缺一就构建不了

- **`web/capacitor.config.ts` 必须显式配 `ios.path: '../ios'`**（安卓侧早已配 `android.path: '../android'`）。
  不配时 CLI 按默认值去找 `web/ios` —— 那是**不存在**的目录，`cap sync ios` 直接失败。
- **`web/package.json` 要有 `@capacitor/ios`**（`^8.5.2`）。只装 `@capacitor/android` 时，
  iOS 平台算"尚未添加"。
- **构建前必须先把 web 产物同步进 `ios/App/App/public`**。该目录与 `capacitor.config.json`、
  `config.xml` 都在 gitignore 里，缺任何一个 Xcode 会在**资源阶段**就失败
  （`The file "public" couldn't be opened because there is no such file`），Swift 根本编不到。

### 35. `cap sync ios` 会重写 SPM 依赖 —— 每次都要跑 `fix-ios-vendor.sh`

- `cap sync ios` 会把 `ios/App/CapApp-SPM/Package.swift` 改回
  `.package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", …)`。该地址的二进制
  托管在 GitHub Releases，**直连经常超时**，表现是 `Failed to resolve package dependencies`
  或 `Missing package product 'CapApp-SPM'`。
- 所以仓库把依赖 vendor 到 `ios/Vendor/capacitor-swift-pm/`（path 引用、离线可构建），
  并配了恢复脚本。**每次 `cap sync ios` 之后跑 `bash scripts/fix-ios-vendor.sh`**；
  `npm run ios:sync` 已内建这三步（web 构建 → cap sync → 修 vendor）。
- **`*.xcframework` 被 `.gitignore` 排除，不随仓库分发**。新环境或清过目录后由该脚本下载
  （当前对应 Capacitor 8.5.2；需要代理时用 `https_proxy` 环境变量）。
  > 同一类坑（任何从 GitHub Release 拉资产的地方都会遇到）：**资产下载链接是临时签名 URL，
  > 约 1 小时就过期**，且国内直连 `release-assets.githubusercontent.com` 极慢
  > （实测 26.4 MB 走代理要 3 分 17 秒 ≈ 137 KB/s）。
  > 于是「让工具内部下载 + 失败重试」经常报 `error decoding response body` —— 要么用到了过期链接，
  > 要么流被截断。可靠做法：**重新取一次 release 元数据拿新链接**，且确保走代理。
- ⚠️ 那个脚本**必须存在**：`Package.swift` 的注释里一直引用 `scripts/fix-ios-vendor.sh`，
  但 2026-09-25 之前它并不存在 —— 结果就是每次 sync 后只能手工改回去。

### 36. iOS 版本号只有一个来源：仓库根 `VERSION`

- `MARKETING_VERSION` ← `VERSION` 文件；`CURRENT_PROJECT_VERSION` ← `10000 + git 提交数`
  （与安卓 CI 同一算法；非 git 工作树时回退为 `major*10000 + minor*100 + patch`）。
  两者都由 `scripts/build-ios.mjs` 以 **xcodebuild 命令行覆盖**注入；
  **不要手工改 `project.pbxproj`** —— 它由 Xcode 管理，改了会被重写回去。
- **为什么这是硬约束**：服务端 iOS 分支的 `versionCode` 固定取 0，更新判定
  **回退到版本名比较**。`MARKETING_VERSION` 与 `VERSION` 不一致时，
  App 会永远提示"有新版本"（或永远提示"已是最新"）。

### 37. iOS 的四条 Info.plist 声明，一条都不能少

| key | 作用 | 缺了会怎样 |
|---|---|---|
| `UIBackgroundModes = audio` | 熄屏 / 切后台继续播 | 锁屏即停 |
| `NSAllowsArbitraryLoads`（ATS 例外） | 服务端是明文 http | 请求被 ATS 全拦 |
| `NSLocalNetworkUsageDescription` | 局域网访问授权（iOS 14+） | 系统**不弹询问框**；日志表现为 `unsatisfied (Local network prohibited)` + `NSURLErrorDomain -1009`，Wi-Fi 正常却连不上 |
| `LSApplicationQueriesSchemes = [altstore, sidestore]` | 更新时探测重签工具 | `canOpenURL` **恒 false**，更新被静默降级成"用 Safari 打开" |

### 38. 免费签名（不付费自用）的硬限制

- 描述文件 **7 天**过期（实测产物 IPA 内 `embedded.mobileprovision` 的 `ExpirationDate` 正好 7 天）；
  **同时最多 3 个**自签 App；**每 7 天最多注册 10 个** App ID —— 所以 bundle id 定下就别改。
- **「续签」和「更新」是同一件事**：每 7 天必须重新签名安装一次，无论有没有新版本。
  别把"App 内点一次立即更新"当成长期免维护 —— 真正的固定动作是每 7 天在
  SideStore / AltStore 里 Refresh。
- 选定 **SideStore**（免电脑续签）而非 AltStore + AltServer（要求 Mac 常开）。
  首次配置需一台电脑生成 pairing file + 装 VPN 组件 + anisette 服务器，之后全在手机上完成。
  ⚠️ VPN 组件的名字换过三代：`StosVPN`（已废弃，App Store 搜不到）→ `StikDebug` →
  **`LocalDevVPN`（当前）**，而 LocalDevVPN **只在非中国区上架**，需要外区 Apple ID 才能下载
  （下载用的外区号与签名用的号可以不是同一个）。**这是 SideStore 路线在国内的实际门槛。**
- **iOS 沙箱不允许应用安装/替换自己**，没有安卓 `PackageInstaller` 的等价物；
  免费签名下也没有可用的 OTA（`itms-services` 只认企业证书或付费账号的 ad-hoc）。
  所以 App 内的「立即更新」只能把 IPA 地址交给外部工具 —— **这是设计边界，不是未完成项**。

### 39. 蓝牙歌词在 iOS 上不可复刻 —— 不要为了"对齐两端"去编实现

- iOS 的 Now Playing 不支持实时改字段（AVRCP 转发机制与安卓不同），
  `setLyricTimeline` / `setLyricLine` 在 iOS 插件里是**空操作**，
  设置页的「车机蓝牙歌词」开关对 iOS 隐藏。
- 平台差异清单见 [`https://github.com/sunriseqis/suenmusic-mobile/blob/main/docs/architecture/ios-plan.md`](https://github.com/sunriseqis/suenmusic-mobile/blob/main/docs/architecture/ios-plan.md) §八。

### 40. iOS：跨线程访问 `bridge.webView` 会搞坏 WebKit（2026-09-25 实锤，我引入的回归）

- **规则**：`bridge?.webView` 只能在**主线程**访问。要跨线程用（例如在后台队列里拼本地
  URL），必须**先把值取好再传进去** —— 与 `SuenAudioPlugin.onMain` 注释里记的是同一类故障：
  WebKit 的进程间通信卡死，表现为**界面还在、但页面失去响应**（点什么都没反应 / 一直转圈）。
- **实例**：`cacheImages` 原先在 `DispatchQueue.global(qos: .utility)` 里调
  `localFileURL(path:)`，而它要读 `bridge?.webView?.url`。
- **为什么长期没暴露**：`web/src/offline/covers.ts` 里写死了 `getPlatform() === 'android'`，
  且 `prefetchCovers()` **全项目无人调用** → 本方法在 iOS 上是**死代码**。
  安卓侧一直在跑，但 Capacitor 的 Java 桥线程安全，所以踩不到。
- **怎么爆的**：把那个 android 判断去掉后，`coverSrc()`（经 `utils/format.ts` 的 `coverUrl()`
  分发，10 个调用点）每渲染一张封面都进队列 → 一开 App 就是几十张批量触发。
- **修法**：`webViewOrigin()`（**主线程取值**）+ 纯静态 `fileURL(path:origin:)`（任意线程可调）。
- **⚠️ 推论（最该记住的一条）**：**"这段代码在 iOS 上从没被调用过" ≠ "它是对的"。**
  给某一端"启用"一段既有代码之前，先确认它在该端**真的被跑通过** ——
  否则等于把一个从未验证过的分支接上了电。

---

## 附：跨端交织、仍留在服务端仓库的相关节

下面这些与移动端有关，但它们本身是**服务端 / Web / 移动端交织写**的 ——
拆一半会让两边都读不通，所以**整节保留在原处**，需要时回 server 仓库查：

| 原编号 | 标题 | 与移动端的关系 |
|---|---|---|
| §19 | 音源锚定（Anchor）防御性设计 | 内含一条「Android Media3 故障态必须 `prepare()`」 |
| §21 | CI/CD 按需构建与版本控制体系 | 三端共用同一套版本号口径与发版规则 |
| §32 | `undici` 默认 300 秒出站超时 | 会伪装成 `fetch failed`，移动端表现为「连不上服务端」 |
| §33 | 画像的「证据」边界 | 端上展示画像时的口径约束 |

日更记录里的移动端内容见同目录的 `2026-09-*.md`。
