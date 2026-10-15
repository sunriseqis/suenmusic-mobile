import AVFoundation
import Capacitor
import CryptoKit
import MediaPlayer
import Network
import UIKit

/**
 * SuenAudio —— iOS 原生音频桥（对齐 Android 端 SuenAudioPlugin 的完整契约）。
 *
 * 职责边界（与 Android 侧一致）：
 *   - 原生只负责"播放 Web 端排好的队列"：setQueue 收到曲目列表后交给 AVQueuePlayer 出声
 *   - 队列顺序、播放模式、解析重试全部还在 Web 端 player store 里
 *   - 原生往回推五类事件：progress（进度心跳）、trackChange（曲目切换）、
 *     state（播放/暂停）、error（播放错误）、networkChanged（网络变化）
 *
 * 与 Android 的对应关系：
 *   Media3 MediaSessionService  → AVQueuePlayer（actionAtItemEnd = .none + 手动 advance）
 *   MediaController             → 本插件的直接方法调用
 *   音频焦点                     → AVAudioSession interruption 通知
 *   耳机插拔                    → AVAudioSession routeChange 通知
 *   通知栏/锁屏                  → MPNowPlayingInfoCenter + MPRemoteCommandCenter
 *   熄屏保活                    → Info.plist UIBackgroundModes = audio
 *   SuenAudioCache（4GB LRU）   → SuenAudioCache.swift：回环 HTTP 代理 + 磁盘 LRU
 *   AVRCP 蓝牙歌词              → iOS 不支持实时改 NowPlaying 字段，setLyric* 为空操作
 *
 * 关键行为决策（对齐 Android 实测踩坑结论）：
 *   - 队列由**原生自动接续**（Android 是 setPauseAtEndOfMediaItems(false)）：
 *     熄屏后 WKWebView 的 JS 会被系统节流，Web 端曲终判定不可靠，
 *     "下一首放谁"必须由原生完成（单曲/列表循环经 setRepeatMode 下发）。
 *   - trackChange 的 reason 与 Media3 编号一致：1=AUTO（播完接续）2=SEEK。
 *     不发 3（PLAYLIST_CHANGED 回声）——Web 端本来就会丢掉它。
 *   - seekToIndex 语义："选中这一首"而非"从头播这一首"：目标是当前条目且非
 *     故障态时**不动位置**（Android 真机报障："一点播放就从头开始"）。
 *   - reloadCurrent：换音源后必须重建条目（丢内存缓冲 + 重新组流 URL），
 *     否则播放器继续放旧音源（Android 真机报障："换了源时长和内容都没变"）。
 */

// MARK: - 队列模型

struct SuenTrack {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let coverUrl: String?
    let durationMs: Int
}

// MARK: - 插件

@objc(SuenAudioPlugin)
public class SuenAudioPlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "SuenAudioPlugin"
    public let jsName = "SuenAudio"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "setQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pause", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "seek", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "seekToIndex", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "reloadCurrent", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setRepeatMode", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setLyricTimeline", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setLyricLine", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestNotificationPermission", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getCacheInfo", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isCached", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cacheImages", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "evictCache", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearCache", returnType: CAPPluginReturnPromise),
    ]

    // MARK: 状态

    /**
     * 离线缓存 / 本地流代理的诊断日志开关。
     *
     * 缓存命不命中、续拉了几次、代理回了 200 还是 206 —— 这些在 Xcode 控制台
     * 各打印一行（`[AudioCache/...]` / `[StreamProxy/...]`）。只有模拟器、没有
     * 真机的阶段，这是唯一能自证缓存链路真的跑起来的手段。真机验收后可关。
     */
    private static let cacheDebugLog = true

    private var engine: AudioEngine?
    private let networkMonitor = NetworkMonitor()
    private var networkObserver: ((String) -> Void)?

    // MARK: 生命周期

    override public func load() {
        super.load()

        /**
         * 本地流代理**提前**启动（非阻塞）。
         *
         * 它监听端口需要一点时间，而 `AudioEngine.makeItem` 组装 URL 时必须
         * 立刻拿到地址。提前起的意义是：等用户登录、点播放时端口早就绪，
         * 第一首就走缓存；万一还没就绪，`streamUrl` 会回退直连（照样能播，
         * 只是这首不落缓存）。
         */
        LocalStreamProxy.shared.startIfNeeded()
        AudioCacheStore.shared.setDebugLog(SuenAudioPlugin.cacheDebugLog)
        LocalStreamProxy.shared.setDebugLog(SuenAudioPlugin.cacheDebugLog)

        networkMonitor.onChange = { [weak self] type in
            // NWPathMonitor 的回调在 utility 队列上（见 NetworkMonitor.start），
            // 这里必须走统一出口切回主线程，否则会卡死 WebKit（白屏）
            self?.emit("networkChanged", ["type": type])
            if type == "available" {
                // 断网恢复 / 切网（WiFi↔蜂窝）：缓存下载里卡住的请求
                // 立即换轨续拉，不等 30 秒空闲超时
                AudioCacheStore.shared.retryStalledDownloads()
            }
        }
        networkMonitor.start()

        // 回前台：断网 / 切网期间停在死路径上的缓存下载立即续拉
        //（弱网热启动卡顿修复，与上面的 networkChanged 触发互补）
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// 回前台触发点：只负责唤醒卡住的缓存下载；Web 端的重探测由
    /// visibilitychange/pageshow 钩子自己完成（P0-1），两边互不依赖。
    @objc private func appDidBecomeActive(_ notification: Notification) {
        AudioCacheStore.shared.retryStalledDownloads()
    }

    /// Web 端排好队的整条队列：条目（id+元数据）+ 起始位置 + 流会话凭据。
    /// 语义逐字段对齐 Android SuenAudioPlugin.setQueue：
    ///   - autoplay=false：只装载不出声（恢复会话场景，出声一律由 play() 触发）
    ///   - tailOnly=true：items 只覆盖 [startIndex, 队尾)，正在播的那首不动
    ///     （切播放模式重排未播部分时不再"卡一下"）
    @objc func setQueue(_ call: CAPPluginCall) {
        guard let baseUrl = call.getString("baseUrl"),
              let token = call.getString("token"),
              let rawItems = call.getArray("items") else {
            call.reject("缺少 baseUrl / token / items")
            return
        }
        let startIndex = intArg(call, "startIndex") ?? 0
        let startPositionMs = intArg(call, "startPositionMs") ?? 0
        let autoplay = call.getBool("autoplay") ?? true
        let tailOnly = call.getBool("tailOnly") ?? false

        var tracks: [SuenTrack] = []
        for raw in rawItems {
            guard let o = raw as? [String: Any] else { continue }
            guard let id = o["id"] as? String, !id.isEmpty else { continue }
            tracks.append(SuenTrack(
                id: id,
                title: o["title"] as? String ?? "未知曲目",
                artist: o["artist"] as? String ?? "未知歌手",
                album: o["album"] as? String,
                coverUrl: o["coverUrl"] as? String,
                durationMs: intOf(o["durationMs"])
            ))
        }
        if tracks.isEmpty {
            call.reject("播放队列为空")
            return
        }

        // 本地流代理要拿上游地址与令牌才能代播；每次 setQueue 都刷新一遍
        // （反代地址可能变、会话令牌会轮换）
        LocalStreamProxy.shared.configure(base: baseUrl, token: token)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            do {
                if self.engine == nil {
                    self.engine = try AudioEngine(plugin: self)
                }
                try self.engine?.setQueue(
                    baseUrl: baseUrl, token: token, tracks: tracks,
                    startIndex: startIndex, startPositionMs: startPositionMs,
                    autoplay: autoplay, tailOnly: tailOnly)
                call.resolve()
            } catch {
                call.reject("队列装载失败: \(error.localizedDescription)")
            }
        }
    }

    @objc func play(_ call: CAPPluginCall) {
        withEngine(call) { engine in
            if engine.tracks.isEmpty {
                call.reject("播放队列为空")
                return
            }
            engine.play()
            call.resolve()
        }
    }

    @objc func pause(_ call: CAPPluginCall) {
        withEngine(call) { engine in
            engine.pause()
            call.resolve()
        }
    }

    @objc func seek(_ call: CAPPluginCall) {
        guard let positionMs = intArg(call, "positionMs") else {
            call.reject("缺少 positionMs")
            return
        }
        withEngine(call) { engine in
            engine.seek(to: positionMs)
            call.resolve()
        }
    }

    /// 定位到指定条目。autoplay=false 时只就位不出声（Web 端"装载"路径）。
    /// force=true 时即使目标就是当前条目也强制从头重载（故障态恢复用）。
    @objc func seekToIndex(_ call: CAPPluginCall) {
        guard let index = intArg(call, "index") else {
            call.reject("缺少 index")
            return
        }
        let autoplay = call.getBool("autoplay") ?? true
        let force = call.getBool("force") ?? false
        withEngine(call) { engine in
            guard engine.tracks.indices.contains(index) else {
                // 越界直接拒绝，让 Web 端自己修正（对齐 Android 行为）
                call.reject("曲目索引越界: \(index) / \(engine.tracks.count)")
                return
            }
            engine.seekToIndex(index, autoplay: autoplay, force: force)
            call.resolve()
        }
    }

    /// 硬重载当前（或指定）条目：换了音源之后必须走这里。
    /// 重建条目 = 丢掉内存缓冲 + 按当前流会话重新组流 URL。
    @objc func reloadCurrent(_ call: CAPPluginCall) {
        let positionMs = intArg(call, "positionMs") ?? 0
        let autoplay = call.getBool("autoplay") ?? true
        withEngine(call) { engine in
            guard !engine.tracks.isEmpty else {
                call.reject("原生队列为空，无法重载")
                return
            }
            let index = self.intArg(call, "index") ?? engine.currentIndex
            guard engine.tracks.indices.contains(index) else {
                call.reject("曲目索引越界: \(index) / \(engine.tracks.count)")
                return
            }
            engine.reloadCurrent(index: index, positionMs: positionMs, autoplay: autoplay)
            call.resolve()
        }
    }

    /// 播放模式：让原生队列自己接续时也遵守单曲/列表循环（off/one/all）
    @objc func setRepeatMode(_ call: CAPPluginCall) {
        let mode = call.getString("mode") ?? "off"
        withEngine(call) { engine in
            engine.setRepeatMode(mode)
            call.resolve()
        }
    }

    /// 蓝牙歌词：iOS 的 Now Playing 不支持实时改 artist 字段（AVRCP 转发机制不同），
    /// 此功能在 iOS 上不可复刻 —— 空操作保持 JS 契约兼容，设置页开关由 Web 端按平台隐藏。
    @objc func setLyricTimeline(_ call: CAPPluginCall) {
        call.resolve()
    }

    @objc func setLyricLine(_ call: CAPPluginCall) {
        call.resolve()
    }

    /// iOS 无通知渠道权限概念（Now Playing 由系统管理），直接成功
    @objc func requestNotificationPermission(_ call: CAPPluginCall) {
        call.resolve()
    }

    @objc func getStatus(_ call: CAPPluginCall) {
        withEngine(call) { engine in
            call.resolve(engine.statusSnapshot())
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        withEngine(call) { engine in
            engine.stop()
            call.resolve()
        }
    }

    // MARK: 离线缓存（本地回环代理 + 磁盘 LRU，见 SuenAudioCache.swift）

    /**
     * 缓存类方法都要碰磁盘目录，统一放到 utility 队列执行，结果回主线程
     * 再 resolve —— 与事件出口同一条铁律（见 `onMain` 的注释）。
     */
    @objc func getCacheInfo(_ call: CAPPluginCall) {
        DispatchQueue.global(qos: .utility).async {
            let used = AudioCacheStore.shared.usedBytes()
            SuenAudioPlugin.onMain {
                call.resolve([
                    "usedBytes": Double(used),
                    "maxBytes": Double(AudioCacheStore.maxBytes),
                ])
            }
        }
    }

    @objc func isCached(_ call: CAPPluginCall) {
        guard let id = call.getString("id"), !id.isEmpty else {
            call.reject("缺少 id")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let cached = AudioCacheStore.shared.isComplete(id)
            SuenAudioPlugin.onMain { call.resolve(["cached": cached]) }
        }
    }

    /// 重新锚定音源前必须驱逐该曲缓存：缓存键是曲目 id，内容却已换音源 ——
    /// 不驱逐就会继续放旧音源的字节（"锚定了却没变化"）。
    @objc func evictCache(_ call: CAPPluginCall) {
        guard let id = call.getString("id"), !id.isEmpty else {
            call.reject("缺少 id")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            AudioCacheStore.shared.evict(id: id)
            SuenAudioPlugin.onMain { call.resolve() }
        }
    }

    @objc func clearCache(_ call: CAPPluginCall) {
        DispatchQueue.global(qos: .utility).async {
            AudioCacheStore.shared.clear()
            // 同时清封面缓存（对齐 Android clearCache 的行为）
            CoverCache.clear()
            SuenAudioPlugin.onMain { call.resolve() }
        }
    }

    /// 封面本地缓存：远程 URL → 可直接给 `<img src>` 用的本地 URL。
    /// 返回 URL 形如 `capacitor://localhost/_capacitor_file_/...`，
    /// 由 Capacitor iOS 的 WebViewAssetHandler 落到本地文件（离线不裂图）。
    @objc func cacheImages(_ call: CAPPluginCall) {
        guard let urls = call.getArray("urls") as? [String] else {
            call.reject("缺少 urls")
            return
        }
        /**
         * ⚠️ 先在**主线程**取 WebView 的 scheme/host，再进后台队列下载。
         *
         * 拼本地 URL 要读 `bridge?.webView?.url`，而 WKWebView 是**主线程独占**的。
         * 这个取值原先写在下面的 utility 队列里 —— 等于从后台线程碰 WKWebView，
         * 与 `onMain` 注释里那类故障同源：WebKit 的进程间通信会卡死，
         * 表现为界面还在但页面失去响应（点什么都没反应 / 一直转圈）。
         *
         * 为什么长期没暴露：`web/src/offline/covers.ts` 里原先写死了
         * `getPlatform() === 'android'`，而 `prefetchCovers()` 全项目无人调用 ——
         * 于是本方法在 iOS 上是**死代码**；安卓侧虽然一直在跑，但 Capacitor 的 Java 桥
         * 线程安全，所以也踩不到。iOS 一旦启用封面缓存，这条路就会每次渲染都触发。
         */
        let origin = webViewOrigin()
        DispatchQueue.global(qos: .utility).async {
            var out: [String: String] = [:]
            for url in urls where !url.isEmpty {
                if let local = CoverCache.cacheImage(url) {
                    out[url] = SuenAudioPlugin.fileURL(path: local, origin: origin)
                }
            }
            DispatchQueue.main.async { call.resolve(out) }
        }
    }

    // MARK: 内部工具

    private func withEngine(_ call: CAPPluginCall, _ body: @escaping (AudioEngine) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let engine = self?.engine else {
                call.reject("播放引擎未初始化，请先装载队列")
                return
            }
            body(engine)
        }
    }

    private func intArg(_ call: CAPPluginCall, _ name: String) -> Int? {
        if let d = call.getDouble(name) { return Int(d) }
        if let i = call.getInt(name) { return i }
        return nil
    }

    private func intOf(_ raw: Any?) -> Int {
        if let n = raw as? NSNumber { return n.intValue }
        if let d = raw as? Double { return Int(d) }
        if let i = raw as? Int { return i }
        return 0
    }

    /// WebView 的源（scheme + host）。
    ///
    /// ⚠️ **必须在主线程调用** —— 它读 `bridge.webView`。
    /// 需要跨线程使用时，先在主线程取好再传出去（见 `cacheImages`）。
    private func webViewOrigin() -> (scheme: String, host: String) {
        if let url = bridge?.webView?.url, let s = url.scheme, let h = url.host {
            return (s, h)
        }
        return ("capacitor", "localhost")
    }

    /// 把本地绝对路径包装成 WebView 可访问的 URL（对齐 Android 的 CAPACITOR_FILE_START 方案）。
    ///
    /// 纯函数：**不碰 WebView**，因此可以在任意线程安全调用。
    private static func fileURL(path: String, origin: (scheme: String, host: String)) -> String {
        "\(origin.scheme)://\(origin.host)/_capacitor_file_\(path)"
    }

    // MARK: 引擎 → Web 的事件出口

    /// 把闭包切到主线程执行。
    ///
    /// ⚠️ 这是**正确性要求**，不是优化：
    /// `notifyListeners` 最终会走到 `WKWebView.evaluateJavaScript`，而 WKWebView
    /// 是主线程独占的。从后台线程调用它会卡死 WebKit 的进程间通信 ——
    /// 实测表现就是 WebContent / GPU 进程"无响应"被系统反复杀掉，页面纯白。
    /// （安卓侧没这个问题：Capacitor 的 Java 桥会自动切主线程。）
    ///
    /// 已在主线程时直接执行，避免多绕一次队列打乱事件顺序。
    static func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    /// 统一事件出口。**所有 `notifyListeners` 必须经此**，
    /// 否则又会出现"后台线程碰 WKWebView"的白屏故障。
    private func emit(_ event: String, _ data: [String: Any]) {
        SuenAudioPlugin.onMain { [weak self] in
            self?.notifyListeners(event, data: data)
        }
    }

    func emitProgress(index: Int, positionMs: Int, durationMs: Int, playing: Bool) {
        emit("progress", [
            "index": index,
            "positionMs": positionMs,
            "durationMs": durationMs,
            "playing": playing,
        ])
    }

    func emitTrackChange(index: Int, id: String, reason: Int) {
        emit("trackChange", [
            "index": index,
            "id": id,
            "reason": reason,
        ])
    }

    func emitState(playing: Bool) {
        emit("state", ["playing": playing])
    }

    func emitError(message: String) {
        emit("error", ["message": message])
    }
}

// MARK: - 播放引擎

/// AVQueuePlayer 队列驱动。AVQueuePlayer 播完的条目会自动出队，
/// 所以用 `ObjectIdentifier(item) → 逻辑索引` 映射来追踪当前位置；
/// `actionAtItemEnd = .none` + 手动 advance，换得单曲循环 / 列表循环 /
/// 队列终止三种语义的精确控制（全部在原生完成，熄屏不依赖 JS）。
final class AudioEngine: NSObject {

    enum RepeatMode: String { case off, one, all }

    private weak var plugin: SuenAudioPlugin?
    private let player = AVQueuePlayer()
    private var timeObserver: Any?

    /// KVO token **必须持有**。
    ///
    /// `observe(_:options:changeHandler:)` 返回的 `NSKeyValueObservation` 一旦
    /// 释放就立刻 `invalidate()` —— 观察者静默失效：不报错、不崩溃、不打印，
    /// 只有编译器那句 "result of call ... is unused" 在提示。
    /// 之前漏了这一步，直接后果是 `state` 事件从头到尾一次都没发出，而 Web 端的
    /// `playing` 状态与播放上报开关**全部**挂在这一个事件上。
    private var observations: [NSKeyValueObservation] = []

    /// `state` 去重：只在有效播放状态**变化**时上报，避免缓冲抖动把 UI 刷成闪烁。
    private var lastReportedPlaying: Bool?

    private(set) var tracks: [SuenTrack] = []
    private var itemIndex: [ObjectIdentifier: Int] = [:]
    private var repeatMode: RepeatMode = .off

    private var baseUrl = ""
    private var sessionToken = ""

    /// 程序化换条目期间抑制 KVO 自动发 trackChange（手动发的带 reason=SEEK）
    private var suppressTransitionEvent = false
    private var lastCurrentItem: AVPlayerItem?
    private var reportedFailures: Set<ObjectIdentifier> = []
    private var isActivated = false

    private let nowPlaying = MPNowPlayingInfoCenter.default()
    private var remoteCommandsInstalled = false
    /// `addTarget` 的返回 token。持有它既是为了将来能干净卸载，
    /// 也是因为"注册了但没拿到句柄"和"没注册"在现象上无法区分。
    private var remoteCommandTargets: [Any] = []
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    private var lastNowPlayingUpdate = Date.distantPast

    /// 播放**意图** —— 锁屏 / 控制中心 / 灵动岛的按钮与进度条只看这一个值。
    ///
    /// 绝不能用 `player.rate` 代替：`automaticallyWaitsToMinimizeStalling` 打开后，
    /// 缓冲等待期间 rate 会掉到 0（日志里 index 11 那段 `MEDIA_PLAYBACK_STALL`
    /// 就是活例）—— 用 rate 判定会把"正在缓冲"错报成"已暂停"，锁屏按钮随即来回跳。
    private var playingIntent = false

    /// Now Playing 自检日志开关。
    ///
    /// 锁屏 / 灵动岛是**系统渲染**的界面，代码到底有没有生效无法从屏幕直接读出来。
    /// 只有 Xcode、没有真机的阶段，这行日志是唯一能自证"数据源已就绪"的手段。
    /// 真机验收通过后可以关掉。
    private var nowPlayingDebugLog = true

    init(plugin: SuenAudioPlugin) throws {
        self.plugin = plugin
        super.init()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
        isActivated = true

        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = true

        // 进度心跳：500ms，对齐 Android TICK_MS
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.onProgressTick(time)
        }
        // KVO 回调的线程 = 改属性的那个线程。AVFoundation 会在自己的内部队列上
        // 改 currentItem（自动接续）和 timeControlStatus（起播/缓冲/暂停），所以
        // 不能假定是主线程 —— 先把值取出来，再切主线程处理。
        //
        // ⚠️ 返回值必须 append 进 `observations`，否则观察者立刻失效（见属性注释）。
        observations.append(player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            let item = player.currentItem
            SuenAudioPlugin.onMain { [weak self] in
                self?.onCurrentItemChanged(item)
            }
        })
        // 这个 KVO 只做两件事：① 真正进入 .playing 时补一次状态；② 跌回 .paused 时
        // 检查"条目是不是真的挂了"。普通暂停**不由它上报**（理由见 .paused 分支）。
        // 不用 rate 是因为缓冲等待时 rate 也会掉到 0，那会造成卡顿瞬间的假暂停。
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            switch player.timeControlStatus {
            case .playing:
                SuenAudioPlugin.onMain { [weak self] in self?.reportPlaying(true) }
            case .paused:
                SuenAudioPlugin.onMain { [weak self] in
                    // 这里**不报**"暂停"：队列重建期间 AVFoundation 会短暂跌回 paused，
                    // 而该回调是异步切回主线程的，可能在 startPlayback() 之后才到 ——
                    // 那样会把刚起播的状态又刷成暂停（UI 闪一下）。
                    // 暂停一律由 play/pause/stop/中断/曲末这些**意图明确**的路径上报。
                    // 只有"条目真的挂了"这种意外停止，才必须在这里补一次状态纠正。
                    self?.reportCurrentItemFailureIfNeeded(andStop: true)
                }
            case .waitingToPlayAtSpecifiedRate:
                // 播放意图仍在（只是在等缓冲）→ 不上报，保持 UI 的"播放中"
                break
            @unknown default:
                break
            }
        })
        NotificationCenter.default.addObserver(
            self, selector: #selector(itemDidEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(itemFailed(_:)),
            name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)

        installRemoteCommands()

        // 让本 App 成为系统的 "Now Playing 宿主"。
        //
        // 只注册 `MPRemoteCommandCenter` 的 target **不够** —— 系统还要靠这个调用
        // 建立"远程控制事件路由到本 App"的关系。缺了它，锁屏 / 控制中心 / 灵动岛
        // 压根不会把"正在播放"面板挂到我们头上，target 也永远收不到回调
        // （按钮不出现、或出现但点了没反应）。
        //
        // 必须在主线程调用；`AudioEngine` 只在 `setQueue` 的 main.async 里创建，
        // 这里天然在主线程，但仍显式断言一次，避免以后被人挪到后台队列。
        precondition(Thread.isMainThread, "beginReceivingRemoteControlEvents 必须在主线程调用")
        UIApplication.shared.beginReceivingRemoteControlEvents()

        logNowPlayingDiagnostics(reason: "engine-init")
    }

    deinit {
        if let timeObserver = timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        player.pause()
    }

    // MARK: 队列操作

    func setQueue(baseUrl: String, token: String, tracks: [SuenTrack],
                  startIndex: Int, startPositionMs: Int,
                  autoplay: Bool, tailOnly: Bool) throws {
        self.baseUrl = normalizedBase(baseUrl)
        self.sessionToken = token

        suppressTransitionEvent = true
        defer { suppressTransitionEvent = false }

        if tailOnly, !self.tracks.isEmpty, let current = player.currentItem,
           let currentLogical = itemIndex[ObjectIdentifier(current)],
           currentLogical < startIndex {
            // 只重排 [startIndex, 队尾)：此路径下 tracks 参数只含尾段，
            // 全量逻辑队列（self.tracks）保持不变。把 player 队列里当前条目
            // 之后的全部替换掉 —— 正在播的那首不在替换范围内 → 不重新装载
            // → 切播放模式不再"卡一下"（对齐 Android replaceMediaItems 行为）。
            let queue = player.items()
            if let pos = queue.firstIndex(of: current) {
                for stale in queue[(pos + 1)...] {
                    itemIndex.removeValue(forKey: ObjectIdentifier(stale))
                    player.remove(stale)
                }
            }
            for (offset, track) in tracks.enumerated() {
                let item = makeItem(for: track)
                itemIndex[ObjectIdentifier(item)] = startIndex + offset
                player.insert(item, after: current)
            }
            // 对齐 Android：tailOnly 路径不动播放状态（不 seek、不 play）
            lastCurrentItem = player.currentItem
            return
        }

        // 整队列重发：全量重建。player 队列只需要 [startIndex, 队尾)
        // （i 前面的条目永远不会被"接续"到，回退切歌走 rebuildQueue）。
        self.tracks = tracks
        player.removeAllItems()
        itemIndex.removeAll()
        let start = min(max(0, startIndex), max(0, tracks.count - 1))
        var previous: AVPlayerItem?
        for i in start..<tracks.count {
            let item = makeItem(for: tracks[i])
            itemIndex[ObjectIdentifier(item)] = i
            player.insert(item, after: previous)
            previous = item
        }
        if startPositionMs > 0 {
            player.seek(to: CMTime(seconds: Double(startPositionMs) / 1000.0, preferredTimescale: 600))
        }
        if autoplay {
            startPlayback()
        }
        lastCurrentItem = player.currentItem
        updateNowPlaying()
    }

    /// 起播 / 暂停 / 停止都只调 `reportPlaying`，由它统一负责
    /// ① 写播放意图 ② 发 state 事件 ③ 刷新 Now Playing。
    /// 三条出口各写一遍是之前 Now Playing 状态不同步的根因，不要再拆散。
    func play() {
        activateIfNeeded()
        if player.rate == 0 {
            // 条目处于末尾（播放自然结束后的重播）则先归零
            if let item = player.currentItem, item.currentTime() >= item.duration, item.duration > CMTime.zero {
                player.seek(to: .zero)
            }
            player.play()
        }
        // 无论走没走进上面的分支都表一次"要播"。去重后不会重复发事件，
        // 但能保证"用户按了播放"这件事一定被 Web 端听到。
        reportPlaying(true)
    }

    func pause() {
        player.pause()
        reportPlaying(false)
    }

    func stop() {
        player.pause()
        reportPlaying(false)
    }

    func seek(to positionMs: Int) {
        let seconds = max(0, Double(positionMs) / 1000.0)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        updateNowPlaying()
    }

    /// 语义对齐 Android：目标就是当前条目且非故障态 → **不动位置**（选中 ≠ 从头播）；
    /// force 或越界态才从头重载。其余情况重建 player 队列（等价 Media3 的 seekTo+prepare）。
    func seekToIndex(_ index: Int, autoplay: Bool, force: Bool) {
        let sameItem = player.currentItem.flatMap { itemIndex[ObjectIdentifier($0)] } == index
        let atEnd: Bool = {
            guard let item = player.currentItem else { return true }
            return item.duration > CMTime.zero && item.currentTime() >= item.duration
        }()
        if sameItem && !force && !atEnd {
            if autoplay { play() }
            return
        }
        rebuildQueue(from: index, positionMs: 0, autoplay: autoplay, reason: 2)
    }

    /// 换音源硬重载：停掉 → 重建条目（新 URL + 丢缓冲）→ 定位 → 出声
    func reloadCurrent(index: Int, positionMs: Int, autoplay: Bool) {
        guard tracks.indices.contains(index) else { return }
        suppressTransitionEvent = true

        let track = tracks[index]
        let fresh = makeItem(for: track)
        let queue = player.items()
        if let current = player.currentItem, let pos = queue.firstIndex(of: current) {
            itemIndex.removeValue(forKey: ObjectIdentifier(current))
            player.remove(current)
            itemIndex[ObjectIdentifier(fresh)] = index
            player.insert(fresh, after: pos > 0 ? queue[pos - 1] : nil)
        } else {
            itemIndex[ObjectIdentifier(fresh)] = index
            player.insert(fresh, after: nil)
        }
        suppressTransitionEvent = false
        lastCurrentItem = fresh

        if positionMs > 0 {
            player.seek(to: CMTime(seconds: Double(positionMs) / 1000.0, preferredTimescale: 600))
        }
        if autoplay { startPlayback() }
        updateNowPlaying()
        // 通知 Web 端索引与元数据已就位（reason=SEEK，与 Android 行为一致）
        plugin?.emitTrackChange(index: index, id: track.id, reason: 2)
    }

    func setRepeatMode(_ mode: String) {
        repeatMode = RepeatMode(rawValue: mode) ?? .off
        // 模式决定"队尾还有没有下一首"：off→all 会让锁屏的"下一首"从灰变亮
        refreshRemoteCommandAvailability()
    }

    func statusSnapshot() -> [String: Any] {
        let positionMs = Int(player.currentTime().seconds * 1000)
        let duration = currentItemDurationMs()
        return [
            "index": currentIndex,
            "positionMs": max(0, positionMs),
            "durationMs": max(0, duration),
            "playing": player.rate > 0,
            "queueLength": tracks.count,
        ]
    }

    // MARK: 私有：队列构建

    /// 重建 player 队列使其从 index 开始（等价 Media3 的 seekTo(index) + prepare）。
    /// reason: 1=AUTO（repeat all 环绕接续） 2=SEEK
    private func rebuildQueue(from index: Int, positionMs: Int, autoplay: Bool, reason: Int) {
        guard tracks.indices.contains(index) else { return }
        if reason == 2 {
            consecutiveErrors = 0
        }
        suppressTransitionEvent = true

        player.removeAllItems()
        var newItems: [AVPlayerItem] = []
        for i in index..<tracks.count {
            let item = makeItem(for: tracks[i])
            itemIndex[ObjectIdentifier(item)] = i
            newItems.append(item)
            player.insert(item, after: newItems.dropLast().last)
        }
        if positionMs > 0 {
            player.seek(to: CMTime(seconds: Double(positionMs) / 1000.0, preferredTimescale: 600))
        }
        if autoplay { startPlayback() }

        suppressTransitionEvent = false
        lastCurrentItem = player.currentItem
        updateNowPlaying()
        plugin?.emitTrackChange(index: index, id: tracks[index].id, reason: reason)
    }

    /// 曲末接续决策（原生侧，熄屏可靠）：
    ///   - repeat one：原地归零重播（不发 trackChange，不是切歌）
    ///   - 队列中：advanceToNextItem，KVO 检测后发 trackChange(reason=1)
    ///   - repeat all + 队尾：整队列环绕重建
    ///   - repeat off + 队尾：停在末尾（等价 Media3 STATE_ENDED）
    @objc private func itemDidEnd(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let item = note.object as? AVPlayerItem else { return }
            guard ObjectIdentifier(item) == self.currentItemKey() else {
                // 旧条目的迟到通知，忽略
                return
            }
            guard let idx = self.itemIndex[ObjectIdentifier(item)] else { return }

            if self.repeatMode == .one {
                // 原地重播：不是切歌，不发 trackChange；但"仍在播放"要报给 Web
                self.player.seek(to: .zero)
                self.startPlayback()
                return
            }

            let isLast = idx >= self.tracks.count - 1
            if isLast {
                if self.repeatMode == .all {
                    self.rebuildQueue(from: 0, positionMs: 0, autoplay: true, reason: 1)
                } else {
                    // repeat off 到队尾：停在末尾（等价 Media3 STATE_ENDED）
                    self.player.pause()
                    self.reportPlaying(false)
                }
            } else {
                self.player.advanceToNextItem()
                // 正常靠上面的 currentItem KVO 发 trackChange(reason=1)；这里主动补一次
                // 兜底 —— AVQueuePlayer 的 currentItem KVO 在部分场景下会迟到甚至不触发，
                // 而熄屏自动接续全靠它同步 Web 端。
                // 重复调用是安全的：onCurrentItemChanged 内部有 lastCurrentItem 去重。
                self.onCurrentItemChanged(self.player.currentItem)
            }
        }
    }

    private var consecutiveErrors = 0
    private static let maxConsecutiveErrors = 5

    private func handlePlaybackFailure() {
        consecutiveErrors += 1
        guard consecutiveErrors < Self.maxConsecutiveErrors else {
            consecutiveErrors = 0
            reportPlaying(false)
            return
        }
        guard !tracks.isEmpty else { return }
        let idx = currentIndex
        if idx + 1 < tracks.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                self.rebuildQueue(from: idx + 1, positionMs: 0, autoplay: true, reason: 1)
            }
        } else if repeatMode == .all {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                self.rebuildQueue(from: 0, positionMs: 0, autoplay: true, reason: 1)
            }
        } else {
            reportPlaying(false)
        }
    }

    @objc private func itemFailed(_ note: Notification) {
        let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?
            .localizedDescription ?? "播放错误"
        plugin?.emitError(message: message)
        handlePlaybackFailure()
    }

    // MARK: 私有：播放状态上报

    /// `state` 事件的唯一出口。
    ///
    /// Web 端把 `state` 当 DOM 的 `play`/`pause`/`playing` 用（bridge.ts），
    /// 而 store 的 `playing` 与"播放上报开关"**只**由这三个事件驱动 ——
    /// 这个事件一断，界面就会永远停在错的播放态。
    ///
    /// 语义是**播放意图**，不是瞬时播放状态：起播 / 暂停 / 中断 / 曲末各自显式上报，
    /// 不靠 `rate`、`timeControlStatus` 去反推。瞬时状态会在缓冲与队列重建时抖动，
    /// 拿它驱动 UI 就是闪烁的来源。
    private func reportPlaying(_ playing: Bool) {
        // 这里同时是**播放意图**的唯一写入点。放在去重之前：即使 Web 端已经知道
        // 这个状态（事件被去重吃掉），Now Playing 的 rate 也必须落在正确值上。
        playingIntent = playing
        if playing {
            consecutiveErrors = 0
        }

        guard lastReportedPlaying != playing else { return }
        lastReportedPlaying = playing
        plugin?.emitState(playing: playing)

        // 意图变了 → 锁屏 / 控制中心 / 灵动岛必须同步。
        // 之前漏了这一步：暂停后 `addPeriodicTimeObserver` 不再回调，
        // `MPNowPlayingInfoPropertyPlaybackRate` 就永远停在最后一次写的 1.0，
        // 系统据此认为"还在播"，锁屏进度条会自顾自地继续往前走。
        updateNowPlaying()
    }

    /// 起播的唯一入口：出声 + 立刻上报播放态。
    ///
    /// 不等 `timeControlStatus` 走完 waiting → playing 再报 —— 否则从用户按下播放
    /// 到按钮变样之间会有一段空窗（网络慢时尤其明显）。
    private func startPlayback() {
        player.play()
        reportPlaying(true)
    }

    /// 当前条目确实挂了就上报（每个条目只报一次，Web 端负责解析重试）。
    ///
    /// 两个触发点复用：进度心跳（只报错误）+ 播放状态跌回 paused（错误 + 状态纠正）。
    /// 后者是必要的 —— 条目失败时时间轴会停住，`addPeriodicTimeObserver` 不再回调，
    /// 只靠心跳会漏报。
    ///
    /// - Parameter andStop: true 表示同时纠正播放状态（用于"意外停止"场景）。
    private func reportCurrentItemFailureIfNeeded(andStop: Bool = false) {
        guard let item = player.currentItem else { return }
        guard item.status == .failed || item.error != nil else { return }
        let key = ObjectIdentifier(item)
        guard !reportedFailures.contains(key) else { return }
        reportedFailures.insert(key)
        if andStop { reportPlaying(false) }
        plugin?.emitError(message: item.error?.localizedDescription ?? "播放错误")
        handlePlaybackFailure()
    }

    // MARK: 私有：状态跟踪

    private func onProgressTick(_ time: CMTime) {
        guard player.rate > 0 || player.currentItem != nil else { return }
        reportCurrentItemFailureIfNeeded()
        let posMs = max(0, Int(time.seconds * 1000))
        let durMs = currentItemDurationMs()
        plugin?.emitProgress(index: currentIndex, positionMs: posMs, durationMs: max(0, durMs), playing: player.rate > 0)
        resyncNowPlayingIfStale()
    }

    private func onCurrentItemChanged(_ newItem: AVPlayerItem?) {
        guard !suppressTransitionEvent else { return }
        guard let item = newItem, item !== lastCurrentItem else {
            lastCurrentItem = newItem
            return
        }
        lastCurrentItem = item
        guard let idx = itemIndex[ObjectIdentifier(item)] else { return }
        updateNowPlaying()
        // KVO 触发的换条目只有"自然接续"一种来源（切歌的显式路径都手动发 reason=2）
        plugin?.emitTrackChange(index: idx, id: tracks[idx].id, reason: 1)
    }

    var currentIndex: Int {
        guard let item = player.currentItem, let idx = itemIndex[ObjectIdentifier(item)] else {
            return 0
        }
        return idx
    }

    private func currentItemKey() -> ObjectIdentifier? {
        player.currentItem.map { ObjectIdentifier($0) }
    }

    private func currentItemDurationMs() -> Int {
        if let item = player.currentItem {
            let sec = item.duration.seconds
            if sec.isFinite && sec > 0 { return Int(sec * 1000) }
        }
        // 流尚未探测到时长时退回元数据（Web 端还会用已知真实时长覆盖）
        let idx = currentIndex
        return tracks.indices.contains(idx) ? tracks[idx].durationMs : 0
    }

    private func makeItem(for track: SuenTrack) -> AVPlayerItem {
        let url = URL(string: streamUrl(track.id))!
        let asset = AVURLAsset(url: url)
        return AVPlayerItem(asset: asset)
    }

    /// 组装流地址：**优先走本地回环代理**（P2 离线缓存）。
    ///
    /// 代理不可用时回退直连 —— 缓存是增强项，任何情况下都不能因为它
    /// 没准备好而播不出来。回退代价只是这首不落缓存。
    private func streamUrl(_ trackId: String) -> String {
        if let local = LocalStreamProxy.shared.localURL(trackId: trackId) {
            return local
        }
        return directStreamUrl(trackId)
    }

    /// 直连上游（对齐 Android SuenAudio.streamUrlFor，防御双斜杠）
    private func directStreamUrl(_ trackId: String) -> String {
        var base = baseUrl
        while base.hasSuffix("/") { base.removeLast() }
        let encId = trackId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trackId
        if !sessionToken.isEmpty {
            let encToken = sessionToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sessionToken
            return "\(base)/api/stream/\(encId)?t=\(encToken)"
        }
        return "\(base)/api/stream/\(encId)"
    }

    private func normalizedBase(_ raw: String) -> String {
        var base = raw
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    private func activateIfNeeded() {
        guard !isActivated else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        isActivated = true
    }

    // MARK: 私有：系统事件

    /// 音频焦点（对齐 Android：来电暂停、让路导航）
    ///
    /// AVAudioSession 的通知由系统从内部队列投递，线程不确定 —— 先切回主线程
    /// 再动 player，理由同 `SuenAudioPlugin.onMain` 的注释。
    @objc private func handleInterruption(_ note: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handleInterruption(note) }
            return
        }
        guard let info = note.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            player.pause()
            reportPlaying(false)
        case .ended:
            // 不自动恢复：让用户手动按播放（对齐 Android 的保守策略）
            break
        @unknown default:
            break
        }
    }

    /// 耳机插拔：拔出即暂停（对齐 Android 行为）
    @objc private func handleRouteChange(_ note: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handleRouteChange(note) }
            return
        }
        guard let info = note.userInfo,
              let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
        if reason == .oldDeviceUnavailable {
            player.pause()
            reportPlaying(false)
        }
    }

    // MARK: 私有：锁屏 / 控制中心

    /// 注册锁屏 / 控制中心 / 灵动岛的远程控制命令。
    ///
    /// ⚠️ 「addTarget 就够了」是错的：`isEnabled` 才是系统决定这颗按钮
    /// 显不显示、点不点得动的依据。两者必须成对处理。
    private func installRemoteCommands() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let center = MPRemoteCommandCenter.shared()

        // 重复安装会叠加 target（同一次按键被处理多次）→ 先清空再注册
        [
            center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
            center.nextTrackCommand, center.previousTrackCommand,
            center.changePlaybackPositionCommand,
        ].forEach { $0.removeTarget(nil) }

        let playTarget = center.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.play()
            return .success
        }
        let pauseTarget = center.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.pause()
            return .success
        }
        let toggleTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            // 看**意图**而不是 rate：缓冲时 rate 为 0，按 rate 判断会把"暂停"
            // 误当成"播放"，用户按一下反而又起播一次。
            self.playingIntent ? self.pause() : self.play()
            return .success
        }
        let nextTarget = center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self, !self.tracks.isEmpty else { return .commandFailed }
            let idx = self.currentIndex
            if idx + 1 < self.tracks.count {
                self.rebuildQueue(from: idx + 1, positionMs: 0, autoplay: true, reason: 2)
                return .success
            }
            if self.repeatMode == .all {
                self.rebuildQueue(from: 0, positionMs: 0, autoplay: true, reason: 2)
                return .success
            }
            return .commandFailed
        }
        let prevTarget = center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self, !self.tracks.isEmpty else { return .commandFailed }
            let idx = self.currentIndex
            guard idx > 0 || self.repeatMode == .all else { return .commandFailed }
            self.rebuildQueue(from: idx > 0 ? idx - 1 : self.tracks.count - 1,
                              positionMs: 0, autoplay: true, reason: 2)
            return .success
        }
        let positionTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.seek(to: Int(posEvent.positionTime * 1000))
            return .success
        }
        remoteCommandTargets = [
            playTarget, pauseTarget, toggleTarget, nextTarget, prevTarget, positionTarget,
        ]

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true

        // 对齐 Android 通知栏的按钮集合（上一首 / 暂停 / 下一首 + 进度条）。
        // 不注册 ±15s 快进快退，并显式关掉 —— 否则系统会在锁屏多塞两颗按钮，
        // 与安卓端、与 Web 端播放器都不一致。
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false

        refreshRemoteCommandAvailability()
    }

    /// 锁屏 / 控制中心按钮的可用性。
    ///
    /// 系统不会替我们判断"还有没有下一首"，它只看 `isEnabled`。
    /// 不刷这个，队尾的"下一首"也会亮着，用户点了没反应 —— 比直接灰掉更糟。
    private func refreshRemoteCommandAvailability() {
        let center = MPRemoteCommandCenter.shared()
        let hasTracks = !tracks.isEmpty
        let canGoNext = hasTracks && (currentIndex + 1 < tracks.count || repeatMode == .all)
        let canGoPrev = hasTracks && (currentIndex > 0 || repeatMode == .all)
        center.nextTrackCommand.isEnabled = canGoNext
        center.previousTrackCommand.isEnabled = canGoPrev
        center.changePlaybackPositionCommand.isEnabled = hasTracks
    }

    /// 写 Now Playing 元数据 —— 锁屏、控制中心、灵动岛、CarPlay 面板的**唯一数据源**。
    ///
    /// 刷新策略是**事件驱动**，不在进度心跳里逐帧覆写：
    /// 系统会拿 `MPNowPlayingInfoPropertyPlaybackRate` 自己推算进度条位置，
    /// 我们再每 500ms 覆写一次 `ElapsedPlaybackTime` 反而会让进度条抖动 / 回跳
    /// （Apple 的 Now Playing 指南把"每秒刷新 elapsed"明确列为反模式）。
    /// 所以在 play / pause / seek / 换曲 / 队列重建 时各写一次即可，
    /// 另外用 `resyncNowPlayingIfStale()` 做低频校准兜底。
    private func updateNowPlaying() {
        lastNowPlayingUpdate = Date()

        guard tracks.indices.contains(currentIndex) else {
            nowPlaying.nowPlayingInfo = nil
            refreshRemoteCommandAvailability()
            return
        }
        let track = tracks[currentIndex]
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: Double(max(1, currentItemDurationMs())) / 1000.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, player.currentTime().seconds),
            // 意图，不是瞬时 rate（理由见 `playingIntent` 注释）
            MPNowPlayingInfoPropertyPlaybackRate: playingIntent ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = track.album, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        nowPlaying.nowPlayingInfo = info

        if let coverUrl = track.coverUrl, !coverUrl.isEmpty {
            loadArtwork(for: track.id, url: coverUrl)
        }
        refreshRemoteCommandAvailability()
        logNowPlayingDiagnostics(reason: "update")
    }

    /// 低频校准：流被服务端掐断时（日志里的 `MEDIA_PLAYBACK_STALL`），
    /// 系统按 rate 推算的进度会跑在实际音频前面，久了会漂。
    /// 每 10s 拿真实播放位置正面覆盖一次即可，不需要更密。
    private func resyncNowPlayingIfStale() {
        guard Date().timeIntervalSince(lastNowPlayingUpdate) >= 10 else { return }
        updateNowPlaying()
    }

    /// Now Playing 自检：把系统侧真正生效的状态打到 Xcode 控制台。
    ///
    /// 存在意义：锁屏 / 灵动岛由系统渲染，而**模拟器不渲染**它们，
    /// 所以"代码跑没跑对"没法从屏幕上看出来。有了这行日志，
    /// 只要在 Xcode 里跑一次、按一下播放，就能判断数据源是否已就绪。
    private func logNowPlayingDiagnostics(reason: String) {
        guard nowPlayingDebugLog else { return }
        let session = AVAudioSession.sharedInstance()
        let center = MPRemoteCommandCenter.shared()
        let info = nowPlaying.nowPlayingInfo
        let title = (info?[MPMediaItemPropertyTitle] as? String) ?? "-"
        let elapsed = (info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double) ?? -1
        let duration = (info?[MPMediaItemPropertyPlaybackDuration] as? Double) ?? -1
        let rate = (info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double) ?? -1
        let hasArtwork = info?[MPMediaItemPropertyArtwork] != nil
        let num = { (v: Double) in String(format: "%.1f", v) }
        print("[NowPlaying/\(reason)] cat=\(session.category.rawValue) mode=\(session.mode.rawValue) "
              + "opts=\(session.categoryOptions.rawValue) ioSampleRate=\(session.sampleRate) "
              + "intent=\(playingIntent ? "play" : "pause")")
        print("[NowPlaying/\(reason)] title=\(title) rate=\(num(rate)) elapsed=\(num(elapsed)) "
              + "dur=\(num(duration)) artwork=\(hasArtwork ? "Y" : "N") "
              + "| cmds play=\(center.playCommand.isEnabled) pause=\(center.pauseCommand.isEnabled) "
              + "toggle=\(center.togglePlayPauseCommand.isEnabled) next=\(center.nextTrackCommand.isEnabled) "
              + "prev=\(center.previousTrackCommand.isEnabled) "
              + "seek=\(center.changePlaybackPositionCommand.isEnabled)")
    }

    private func loadArtwork(for trackId: String, url: String) {
        if let cached = artworkCache[trackId] {
            var info = nowPlaying.nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = cached
            nowPlaying.nowPlayingInfo = info
            return
        }
        guard let remote = URL(string: url) else { return }
        URLSession.shared.dataTask(with: remote) { [weak self] data, _, _ in
                guard let self = self, let data = data,
                      let image = UIImage(data: data) else { return }
            // boundsSize 为 .zero 会让封面在锁屏上直接不显示（系统按这个尺寸索取图像）
            let bounds = image.size
            guard bounds.width > 0, bounds.height > 0 else { return }
            let artwork = MPMediaItemArtwork(boundsSize: bounds) { _ in image }
            DispatchQueue.main.async {
                // artworkCache 只在主线程读写。之前写在工作线程、读在主线程，
                // 是一次真实（虽然大概率不炸）的字典数据竞争。
                self.artworkCache[trackId] = artwork
                guard self.tracks.indices.contains(self.currentIndex),
                      self.tracks[self.currentIndex].id == trackId else { return }
                var info = self.nowPlaying.nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = artwork
                self.nowPlaying.nowPlayingInfo = info
            }
        }.resume()
    }
}

// MARK: - 封面缓存

enum CoverCache {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("covers", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 已存在的不重复下载；单个失败返回 nil（尽力而为，对齐 Android）
    static func cacheImage(_ urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let digest = Insecure.SHA1.hash(data: Data(urlString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let dest = directory.appendingPathComponent("\(hex).img")

        if FileManager.default.fileExists(atPath: dest.path) {
            return dest.path
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("SuenMusic/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        // cacheImages 跑在 utility 队列上，用信号量把异步下载转同步（逐张尽力而为）
        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            payload = data
            semaphore.signal()
        }.resume()
        semaphore.wait()
        guard let data = payload, !data.isEmpty else {
            return nil
        }
        try? data.write(to: dest, options: .atomic)
        return dest.path
    }
}

// MARK: - 网络监听（对齐 Android ConnectivityManager.NetworkCallback）

final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private var lastSatisfied: Bool?
    private var lastInterfaceType: NWInterface.InterfaceType?
    var onChange: ((String) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let satisfied = path.status == .satisfied
            let interfaceType = path.availableInterfaces.first?.type
            guard let lastSatisfied = self.lastSatisfied else {
                // 首次回调只记录基线，不发事件（对齐 Android：只报"变化"）
                self.lastSatisfied = satisfied
                self.lastInterfaceType = interfaceType
                return
            }
            // WiFi↔蜂窝切换时 satisfied 始终为 true，只靠连通性翻转报不出
            // "切网"事件；接口类型变化也要报 —— 停在旧路径上的请求
            //（缓存下载、Web 端探测）等的就是这个信号
            guard satisfied != lastSatisfied || interfaceType != self.lastInterfaceType else { return }
            self.lastSatisfied = satisfied
            self.lastInterfaceType = interfaceType
            self.onChange?(satisfied ? "available" : "lost")
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }
}

// MARK: - 桥接容器
//
// Capacitor 8 的 App 内本地 Swift 插件没有自动发现机制，必须挂到
// CAPBridgeViewController 子类的 capacitorDidLoad() 里注册。
// SceneDelegate 与 Main.storyboard 两处根视图控制器都已指向本类。

class SuenBridgeViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        bridge?.registerPluginInstance(SuenAudioPlugin())
        // 应用更新（iOS 侧只会"把安装包地址交给重签工具 / Safari"，见 SuenUpdatePlugin）
        bridge?.registerPluginInstance(SuenUpdatePlugin())
    }
}
