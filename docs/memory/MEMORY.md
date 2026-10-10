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

### 30. Android 可以本地编译 —— 别为了"验证一下"去烧 CI 额度（2026-10-10 更正）
- **⚠️ 本条 2026-09-21 的原结论「沙箱没有 JDK / Android SDK，只能靠 CI 验证」是错的**，
  2026-10-10 实测证伪：`/usr/bin/javac`（OpenJDK 21）、`/opt/android-sdk`
  （`platforms/android-36`、`build-tools/35.0.0` + `36.0.0`）、`/opt/gradle-8.14.3`、
  `~/.gradle/init.gradle`（阿里云镜像）都在，`adb` 在 `/usr/bin/adb`。
  结论错、代价是真付了：当时据此把改动攒着不提交，反而让一个从未编译过的改动一提交就炸。
- **不要用 `./gradlew`**：`android/gradle/wrapper/gradle-wrapper.properties` 的 `distributionUrl`
  指向 `services.gradle.org`，这台机器连不上 → wrapper 会**静默**去下 224MB，卡在
  `gradle-8.14.3-all.zip.part` 约 105MB 就再也不动。实测症状：挂 23 分钟、CPU 只烧 13 秒、
  `android/app/build/` 零写入、`ss -tnp` 能看到连着 `185.199.108.133:443`（GitHub 回源）。
  **直接用已装好的 `/opt/gradle-8.14.3/bin/gradle`。**
  另：长构建**重定向到日志文件再 tail**，别用 `| tail` —— 就是它把进度全吞了，白等了 23 分钟。
- **出 debug 包**（冷启约 40s，增量约 4s）：
  ```
  cd web && npm run build && npx cap sync android
  cd ../android && ANDROID_HOME=/opt/android-sdk /opt/gradle-8.14.3/bin/gradle assembleDebug
  ```
  产物 `android/app/build/outputs/apk/debug/app-debug.apk`。
  ⚠️ **debug 变体的 `versionName` 恒为 `1.0`**，别拿它判断版本；正式版本号由 CI 注入。
- **怎么证明"包里有新代码"**（别只看时间戳）：用 `python3` 的 `zipfile` 读 APK 里的
  `assets/public/index.html` 取出入口 hash，与 `web/dist/index.html` 比对；
  sourcemap（`*.js.map`）也打进包了，可以直接 grep 新增的标识符名。
- **分工**：本地 debug 包用来**验证行为**；`VERSION` 递增推 CI 只用来出**正式 release 包**。
  顺序应该是先本地验证、再决定动不动 CI。
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

## 鸿蒙 NEXT 端（2026-10-10 沉淀）

首个鸿蒙原生客户端（`hw/`，ArkWeb + ArkTS）接入 AVSession 后，系统播控中心/锁屏
出现「显示上一首 / 未知曲目 / 歌词时有时无」。排查后沉淀如下 5 条。
工作日志见 [`2026-10-10.md`](2026-10-10.md)。

### 41. 鸿蒙端**不走 Capacitor** —— `isHarmony` 只能靠"注入对象在不在"判断
- 鸿蒙客户端是原生 ArkWeb + `javaScriptProxy`（注入 `window.SuenHarmony`），**没有 Capacitor**。
  所以 web 里 `isAndroid` / `isIOS` / `isNativeAudio`（都来自 `Capacitor.getPlatform()` /
  `isNativePlatform()`）在鸿蒙端**全是 false**。
- 判平台用 `web/src/native/update.ts` 的 `isHarmony = !!window.SuenHarmony`；
  ArkTS 侧另外还会注入 `window.__HARMONY_NEXT__ = true`（`onPageEnd` 时）。
- **后果**：任何 `v-if="isAndroid"` / `isNativeAudio` 门控的功能，鸿蒙端默认**不显示**；
  要开口子必须显式 `|| isHarmony`。设置页的 `quick-toggles` 容器两个方向都踩过 ——
  漏加会在鸿蒙端整块隐藏，多加会在 PC 端留一个空凹槽（它带 `neu-inset` 凹陷底）。
- 鸿蒙的 web 快照由 `scripts/sync-hw.mjs` 从 `web/dist` 拷进
  `hw/entry/src/main/resources/rawfile/`（gitignore，只留 `.gitkeep`）—— 与安卓的
  `cap sync` 同构：**前端改动同样必须重新构建 HAP 才进客户端**。

### 42. AVSession 元数据链路的四条铁律（三个症状的同一个病根）
一次切歌会**并发触发多次上报**（`web/src/stores/player.ts` 加载时 + `loadedmetadata`；
JS 侧 `window.SuenHarmony.updateMediaMetadata(...)` 发完不管、不 await），所以：

1. **绝不等网络**：封面下载（`http.request`，超时预算 5s + 5s）**不能** await 在
   `setAVMetadata` 之前。旧写法把标题堵在慢网络后面，上一首那次晚回来就盖住新歌
   → **「切歌后仍显示上一首」**。现在先推纯文本元数据，封面由 `attachCover()` 异步补。
2. **必须有单调序号守卫**：类里存 `metaSeq`，每次上报 `++`；异步结果回来时
   `seq !== this.metaSeq` 就**丢弃并 `release()` 那张 PixelMap**。没有它，谁最后 resolve 谁就赢。
3. **绝不伪造元数据**：`updateLyric` 曾在 `currentMetadata` 为空时凭空造一条
   `{ assetId: 'suen_current', title: '未知曲目' }` 推给系统 —— 而 web 在 App 启动、
   队列为空、切歌时都会先推一条空歌词（`stores/lyrics.ts`），于是播控中心一上来就是
   **「未知曲目」**。现在歌词只存 `currentLyric`，元数据没到就先存着，**不碰系统 UI**。
4. **不能用"口令式"判断**：放行条件里曾写 `assetId.startsWith('suen_')`，而伪造出来的
   `suen_current` 恰好满足它 → 等于"任何曲目的歌词都收"，这是**「歌词时有时无」**的根源。
   正确做法：`assetId` 必须等于当前曲目；`assetId` 为空只清歌词、不动标题封面；
   换曲（assetId 变化）时同时作废旧歌词与旧封面。

5. **不要依赖"另一条消息先到过"**：web 有两条上报（元数据 / 歌词）。曾把"建立控件"
   的责任只压在元数据那条上，结果**那条在鸿蒙端从未真正生效** —— 控件此前一直是靠
   歌词路径里那条**伪造的元数据**撑着的；去掉伪造后控件就**整条消失**。
   现在两条路**各自都能独立建立播控中心**：歌词消息也带完整元数据
   （`assetId/title/artist/album/coverUrl/durationMs/lyric`）。
   推论：**一条消息必须自足**，不能要求"另一条必须先到过" —— 这是第 4 条的延伸：
   去掉一根拐杖之前，先确认另一条腿真的能承重。

附：`!this.session` 的静默 `return` 一律改成 `hilog.error` —— **"元数据被丢掉却毫无痕迹"
是最难查的一类故障**（见第 44 条同类问题）。

### 43. ArkTS 编译约束清单（每条都真实拦过 CI）
- **`arkts-no-obj-literals-as-types`**：形参/属性**不能写匿名对象类型**
  （`f(meta: { a?: string })` 直接报错）→ 必须提成 `interface`。
- **`arkts-no-untyped-obj-literals`**：它会**连带**报在调用点 —— 形参类型是匿名字面量类型时，
  传进去的字面量也算"找不到声明类型"。①修好后②自动消失。
  稳妥做法：字面量一律先赋给**显式定类型的局部变量**再传。
- **`wantAgent.WantAgent` 不存在**：`@kit.AbilityKit` 的 `wantAgent` 命名空间**没有导出
  `WantAgent` 这个名字**（只有 `getWantAgent`）。
  ⚠️ **不能退化成 `Object`** —— `backgroundTaskManager.startBackgroundRunning()` 的第三个参数
  正是那个未导出的类型，`Object` 是它的**父类型**、传不进去，只会把"名字找不到"换成"类型不匹配"。
  **正确做法：去掉显式返回类型，交给类型推断**（`getWantAgent()` 的返回类型恰好就是 API 期望的那个）。
- **`void expr` 非法**：`void this.stopContinuousTask()` 编译不过，直接写调用即可
  （`4d23276` 修的就是这个；注意别和 Android 那边 `void promise` 的写法混）。
- **本地编译不了**：`build-hw.yml` 在容器 `ghcr.io/dalongzhuazi/harmonyos-ci:api26r` 里跑
  `hvigorw assembleHap`，而沙箱**没有 docker、也没有鸿蒙 SDK** → 只能靠 CI 或本地 DevEco。
  本地能做到的极限是**语法检查**：把 `struct` 换成 `class` 后用 TypeScript 解析器解析
  （`build()` 里的 `Column() { ... }` 是 ArkUI DSL、不是合法 TS，会有 **2 条预期假阳性**）。
- 另外 `avSession` 的 `AVMetadata.lyric` 是存在的（能编译过），歌词那条路是通的。
- **就算能编译，构建脚本本身也有 Windows 坑**（用户在 Windows 本地构建时踩到）：
  - `scripts/sync-hw.mjs` 里 `execFileSync('npm', …)` 在 Windows 上直接
    `spawnSync npm ENOENT` —— npm 实际是 `npm.cmd`，而 `execFileSync` 不经过 shell。
    已改为按平台选 `npm.cmd` / `npm`。**CI 跑在 ubuntu，这类坑只会在本地暴露。**
  - `scripts/build-hw.mjs` 里 `run(hvigorw, …)`：hvigorw 是 **bash 脚本**
    （`#!/usr/bin/env bash`），Windows 不能直接 spawn，原来只报一个看不懂的
    ENOEXEC/EACCES；已改成明确提示用 **DevEco Studio** 构建，或在 Git Bash / WSL 里跑。
- **`hw/entry/src/main/resources/rawfile/` 是 gitignore 的构建产物**，仓库里只跟踪了
  `.gitkeep`。新 clone / 另一台机器上它是**空的** → 页面加载不了 → 播控中心必然没有元数据，
  表现为"控件完全消失"。CI 会自动跑 `node scripts/sync-hw.mjs`；
  **本地用 DevEco 编之前必须先手动跑一次**（或 `npm run hw:sync`）。

### 44. 鸿蒙封面必须显式要二进制，且失败必须打日志
- `httpRequest.request(url, {...})` **不指定 `expectDataType` 时拿到的可能是 `string`**，
  于是 `response.result instanceof ArrayBuffer` 永远 false → **封面永远拉不到**。
  必须显式 `expectDataType: http.HttpDataType.ARRAY_BUFFER`。
- 更要命的是旧代码在这条分支上**一行日志都不打**（`if (200 && instanceof ArrayBuffer)` 不成立就
  `return undefined`）→ 表现为"封面就是没有，日志也什么都没有"。现在三种失败分开打：
  **非 200 / 拿到非二进制 / 解码异常**，成功也打一行。
- 排除掉一个假嫌疑：`coverSrc()` 的原生缓存门控**只认安卓**
  （`web/src/offline/covers.ts` 里写死 `getPlatform() === 'android'`），所以鸿蒙端拿到的
  是原始 `http(s)` URL —— ArkTS 那道 `startsWith('http')` 检查是过得去的。

### 45. 鸿蒙「系统歌词」开关：默认**开**，关掉要主动收回
- web 侧 `isHarmonyLyricsEnabled` / `setHarmonyLyricsEnabled`（key `suenmusic.harmonyLyrics`，
  `web/src/native/audio.ts`）**默认开** —— 存的是"关闭标记"（`'0'`），与「车机蓝牙歌词」
  （存 `'1'`、默认关）**相反**：那个是车机 opt-in，这个是既有能力的总闸。
- 设置页开关只在鸿蒙端显示；关掉时必须走 **force 路径**
  （`lyrics.setEnabled(false)` → `syncHarmonyLyric(id, '', true)`）把**已经推出去的歌词收回** ——
  否则关了开关，锁屏上还挂着歌词。

### 46. 给系统 API 的结构体**不要塞 `undefined` 的键** —— 会被静默拒绝（2026-10-10 最贵的一课）
- **现象**：`AVMetadata` 里写 `mediaImage: … || undefined`、`lyric: … || undefined`，
  `setAVMetadata()` **每次都被拒**。而 catch 里有 `hilog.error` —— 但没人看到日志，
  所以对外表现是"改了没反应"，不是"报错"。
- **代价**（这一条同时解释了四个报障，它们**不是**四个 bug）：
  | 报障 | 真实原因 |
  |---|---|
  | 歌名显示「未知曲目」 | 真元数据全被拒，播控中心里只剩另一条兜底数据 |
  | 封面拉不到 | 封面逻辑在同一行之后，压根没跑到 |
  | 切歌后仍显示上一首 | 元数据从未被更新过 |
  | 去掉兜底后控件**完全消失** | 兜底一没，每次调用都带 `undefined` → 全部被拒 |
- **修法**：**有值才赋键**。
  ```ts
  const metadata: avSession.AVMetadata = { assetId, title, artist, album, duration };
  if (this.currentLyric) { metadata.lyric = this.currentLyric; }
  if (this.currentPixelMap) { metadata.mediaImage = this.currentPixelMap; }
  ```
  清空歌词用**空字符串**，不要用 `undefined`。
- **诊断法（下次直接照做）**：**回溯"唯一被证实成功过的那次调用"长什么样**。
  本轮那条伪造数据 `{assetId, title, lyric}` 之所以能成功，正因为它**一个 undefined 字段都没有** ——
  整个问题是被这个"唯一的幸存者"反推出来的。用户还提供了两条决定性描述：
  「界面完全正常」（排除"页面没加载"）、「往上拉能看到正确时间轴、松开又弹回」
  （说明**歌词数据是对的，错的是系统推算的播放位置**）。
- 推广：ArkTS 里凡是**交给系统 API 的结构体**都适用；`try/catch` 里打了日志但没人能看时，
  等价于没有日志 —— **让失败可观测**要在"调用之前"留痕（入口 + 关键参数），不是只在 catch 里。

### 47. 播放位置必须**周期上报**，别让系统按锚点外推
- 锁屏/播控中心的歌词滚动位置，是系统用 `AVPlaybackState.position`（`elapsedTime` +
  `updateTime`）**自己外推**出来的。所以只在状态变化时上报，误差会随时间累积。
- web 侧原来的 `timeupdate` 只更新了 store 里的 `positionMs`，**不上报**；上报只发生在
  `play / pause / ended / loadedmetadata / canplay / durationchange / seek()`。
  而 **`applyPendingSeek()`（续播跳转，`web/src/stores/player.ts:274`）直接改
  `el.currentTime`、不经过 `seek()`**，于是锚点 stale。
- 实测症状：控件里歌词比实际播放快 20 秒，而 App 内进度条是对的。
- **修法**：`timeupdate` 里按 **1 秒节流**补一次上报（仅播放中）。锁屏时 `timeupdate`
  依然触发（**媒体事件不受 JS 定时器节流影响**），所以后台/锁屏也能保持锚定。
  这样无论 stale 锚点是被谁造成的，1 秒内都会重新锚定，误差 ≤1 秒。
- `updateTime` 的**单位**至今没确认（SDK 约定查不到，暂按毫秒）。**这是刻意的取舍**：
  用"1 秒重新锚定"把不确定性变得无关紧要 —— 单位就算错，误差也只在两次上报之间累积。
  **架构上的选择可以消掉信息缺失**，这比先去查文档更划算。
- 判断这类问题的关键问句：**"这个数据是我们在推，还是让对方猜？"** 凡是让系统猜的，
  迟早会漂。

### 48. 去掉一层兜底之前，先确认另一条路真的能承重
- 本轮我按"不能伪造数据"的原则把 `updateLyric` 里那段兜底删掉了 —— 原则没错，
  但**当时并没有确认 `updateMediaMetadata` 那条路是通的**（它其实一次都没成功过）。
  结果：控件整条消失，用户只能回退重编一次。
- **规则**：动"兜底 / 降级 / fallback"之前，先问一句
  **"被我拿掉的这根拐杖，底下那条腿真的能承重吗？"**
  要么先验证它（哪怕用日志证明它从没成功过），要么**两条路改成互不依赖**，
  再删兜底 —— 后者的做法见第 42 条第 5 点（歌词消息也带完整元数据）。
- 配套：**兜底数据本身也是数据**。它一旦被系统 UI 展示过，就会变成"用户看到的既有行为"，
  删掉它是一次**行为变更**，不能算"清理"。

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
