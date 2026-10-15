import CryptoKit
import Foundation
import Network

/**
 * SuenAudioCache —— iOS 离线缓存（P2）：本地回环 HTTP 代理 + 磁盘 LRU。
 *
 * 对标 Android 的 `SuenAudioCache`（Media3 SimpleCache + CacheDataSource）。
 * iOS 的 AVFoundation 没有可插拔的 DataSource 抽象，等价物的做法是**在进程内
 * 起一个只监听回环地址的 HTTP 服务**，把 `AVPlayerItem` 的 URL 指向它：
 *
 *   AVPlayer ──HTTP──▶ 127.0.0.1:<动态端口> ──▶ 磁盘缓存（命中）
 *                                          └──▶ 上游 /api/stream（未命中，边下边存）
 *
 * 四条硬约束（全部来自 Android 侧踩坑结论，移植时必须保持）：
 *
 * 1. **缓存键是曲目 id，不是流 URL。** 流地址带签名时效（`?t=...`），签名一换
 *    URL 就变；按 URL 做键会让缓存在签名轮换后集体失效。id 稳定，换路径
 *    （内网/反代）、换令牌都不影响。
 *
 * 2. **下载必须整首、从 0 顺序落盘。** 不做按需分片 —— 音频文件只有几 MB，
 *    顺序下完最省事也最不容易错。客户端要读的区间还没下到就**阻塞等待**，
 *    而不是立刻返回短响应：后者会让播放器把这条流判成"播完了"。
 *
 * 3. **上游断流要能续拉。** 服务端 `/api/stream` 声明了 `Content-Length`，
 *    实测上游 CDN 会只发 93.5% 就断（AVPlayer 报 -1005，比 ExoPlayer 严格）。
 *    这里拿到"已落盘字节数"后用 `Range: bytes=<n>-` 续拉，把服务端那条
 *    不能改（去掉它 Chromium 会把 seekable 判成空区间）的 `Content-Length`
 *    语义问题在客户端消化掉。
 *
 * 4. **容量 4GB，LRU 淘汰，用户不需要手动清理。** 磁盘不可用（满/无权限）
 *    时降级为内存缓冲；最坏情况退化为"有缓存语义但没留下文件"，绝不因此
 *    播不出来。
 *
 * 与 Android 的行为差异（有意为之）：
 *   - 缓存目录用 `Caches/`（Android 用的是 external-files）：iOS 上 `Caches`
 *     不进 iCloud 备份、空间紧张时系统可回收，语义和"可再生的音频缓存"最匹配。
 *   - `isCached` 只认**完整**文件（对齐 Android `isFullyCached` 的整段连续判定），
 *     部分缓存对"断网能不能听"这个判断没有意义。
 */

// MARK: - 缓存条目

/**
 * 一首曲目的缓存条目：字节仓库 + "等字节"屏障。
 *
 * 读（本地代理连接）与写（上游下载任务）分属不同线程，用 `NSCondition` 协调：
 * 代理侧要读的区间还没到时**阻塞等待**，下载器每落盘一块就 `broadcast` 唤醒。
 *
 * ⚠️ `lock` 是**不可重入**的 `NSCondition`：所有对外方法都在方法体内一次性
 * `lock()/unlock()`，内部不允许再调用另一个会加锁的方法。
 */
final class AudioCacheEntry {

    enum State {
        /// 正在下载（含"失败后等待重试"——重试由新的下载任务触发）
        case downloading
        /// 已完整落盘
        case complete
        /// 下载失败且不再自动重试（客户端下次请求时由 `reopen()` 重新武装）
        case failed
    }

    let id: String
    /// nil = 磁盘不可用，降级为内存缓冲
    let fileURL: URL?

    private let lock = NSCondition()
    private var stored: Int64 = 0
    private var knownTotal: Int64 = 0
    private var state: State = .downloading
    private var headersSeen = false
    private var mimeType: String?
    private var durationMs: Int = 0
    private var memory = Data()
    private var writeHandle: FileHandle?
    private var accessAt = Date()
    private var readers = 0

    init(id: String, fileURL: URL?, existingBytes: Int64,
         mimeType: String?, durationMs: Int, complete: Bool) {
        self.id = id
        self.fileURL = fileURL
        self.stored = max(0, existingBytes)
        self.mimeType = mimeType
        self.durationMs = durationMs
        self.state = complete ? .complete : .downloading
        if let fileURL = fileURL, !complete {
            // 续传：接着已有文件的末尾写
            self.writeHandle = try? FileHandle(forWritingTo: fileURL)
            if self.writeHandle == nil {
                self.state = .failed
            } else {
                _ = try? self.writeHandle?.seekToEnd()
            }
        }
    }

    deinit {
        try? writeHandle?.close()
    }

    // MARK: 只读快照

    var storedBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    var isComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return state == .complete
    }

    /// LRU 淘汰候选：没有活动读者、且不在下载中
    var isEvictable: Bool {
        lock.lock(); defer { lock.unlock() }
        return readers == 0 && state != .downloading
    }

    var lastAccessAt: Date {
        lock.lock(); defer { lock.unlock() }
        return accessAt
    }

    var contentType: String? {
        lock.lock(); defer { lock.unlock() }
        return mimeType
    }

    var declaredDurationMs: Int {
        lock.lock(); defer { lock.unlock() }
        return durationMs
    }

    /**
     * 代理回给客户端时可以承诺的总长度。**0 = 未知**（调用方改走 chunked）。
     *
     * - 下载中 + 已知上游总长 → 以上游为准（客户端据此拿到正确的
     *   `Content-Length`，进度条与 seek 才正常）
     * - 下载中 + 总长未知 → 0（上游按 chunked 传，我们也不知道有多少）
     * - 已完整 → 实际落盘字节数
     * - 已失败（上游截断）→ **实际落盘字节数**：把已缓存的前缀当成整首交给
     *   播放器，让它把已缓存部分正常放完，而不是看到一条永不满足的流
     */
    var serveTotal: Int64 {
        lock.lock(); defer { lock.unlock() }
        if state == .downloading { return knownTotal }
        return knownTotal > 0 ? min(knownTotal, stored) : stored
    }

    // MARK: 写入（下载器调用）

    /// 追加下载到的字节。返回 false = 落盘失败（磁盘满等），下载器据此降级。
    @discardableResult
    func append(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        lock.lock()
        defer { lock.unlock() }
        guard state != .complete else { return false }
        if let handle = writeHandle {
            do {
                try handle.write(contentsOf: data)
            } catch {
                return false
            }
        } else if fileURL == nil {
            memory.append(data)
        } else {
            return false
        }
        stored += Int64(data.count)
        lock.broadcast()
        return true
    }

    func setTotal(_ total: Int64) {
        guard total > 0 else { return }
        lock.lock()
        if total > knownTotal { knownTotal = total }
        lock.broadcast()
        lock.unlock()
    }

    /// 上游响应头已处理完（无论拿没拿到总长）。代理据此不再傻等。
    func noteHeaders(mimeType newMime: String?, durationMs newDuration: Int) {
        lock.lock()
        if let newMime = newMime, !newMime.isEmpty { mimeType = newMime }
        if newDuration > 0 { durationMs = newDuration }
        headersSeen = true
        lock.broadcast()
        lock.unlock()
    }

    /// 进入终态。`complete=false` 表示这次没能拿全 —— 客户端下次请求时由
    /// `reopen()` 重新武装，从已落盘位置续拉。
    func finish(complete: Bool) {
        lock.lock()
        state = complete ? .complete : .failed
        lock.broadcast()
        lock.unlock()
    }

    /// 上游无视 Range 从头返回时调用：丢掉已有前缀，避免文件里出现错位字节。
    func reset() {
        lock.lock()
        if let handle = writeHandle {
            try? handle.truncate(atOffset: 0)
            _ = try? handle.seek(toOffset: 0)
        }
        if fileURL == nil { memory.removeAll() }
        stored = 0
        lock.broadcast()
        lock.unlock()
    }

    /// 重新武装下载（清掉 failed 终态），使阻塞中的读者继续等待新字节。
    func reopen() {
        lock.lock()
        if state == .failed { state = .downloading }
        lock.broadcast()
        lock.unlock()
    }

    /// 被驱逐：唤醒所有等待者并标记失败，让它们干净收尾（不泄漏连接）。
    func abandon() {
        lock.lock()
        state = .failed
        headersSeen = true
        lock.broadcast()
        lock.unlock()
    }

    // MARK: 读取（本地代理调用）

    func beginRead() {
        lock.lock()
        readers += 1
        accessAt = Date()
        lock.unlock()
    }

    func endRead() {
        lock.lock()
        readers = max(0, readers - 1)
        lock.unlock()
    }

    /// 等到上游响应头处理完（或条目进入终态）。返回 false = 超时且上游没回话。
    func waitForHeaders(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        defer { lock.unlock() }
        while !headersSeen && state == .downloading {
            if !lock.wait(until: deadline) { break }
        }
        return headersSeen
    }

    /**
     * 等到 `[offset, offset + length)` 全部就绪。
     *
     * 返回 false 表示**进入终态后仍然不够**（下载失败，或已完整但请求越界）——
     * 调用方据此收尾，而不是无限等下去。
     */
    func waitForBytes(offset: Int64, length: Int64, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        defer { lock.unlock() }
        while stored < offset + length {
            if state != .downloading { return false }
            if !lock.wait(until: deadline) { return false }
        }
        return true
    }

    /// 从缓存里读一段字节。文件读**不持锁**：写入方用的是独立文件描述符，
    /// POSIX 语义下能保证读到的是已经 `write(2)` 落进页缓存的完整字节。
    func read(offset: Int64, length: Int) -> Data? {
        lock.lock()
        guard offset >= 0, offset < stored else { lock.unlock(); return nil }
        let want = Int(min(Int64(length), stored - offset))
        guard want > 0 else { lock.unlock(); return nil }
        let inMemory = fileURL == nil
        let snapshot: Data? = inMemory
            ? memory.subdata(in: Int(offset)..<Int(offset + Int64(want)))
            : nil
        lock.unlock()

        if let snapshot = snapshot { return snapshot }
        guard let fileURL = fileURL else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: want) ?? Data()
        } catch {
            return nil
        }
    }
}

// MARK: - 上游下载器

/**
 * 单首曲目的上游下载任务：把 `/api/stream/:id` 的字节顺序拉到缓存里。
 *
 * 断流续拉（本文件头第 3 条）：每次只请求 `bytes=<已落盘>-`，中断后带着新的
 * 偏移重来，最多 `maxAttempts` 次。服务端那条"声明了 Content-Length 却可能
 * 只发 93.5%"的流，在这里被拼成完整文件。
 */
final class StreamCacheDownloader: NSObject, URLSessionDataDelegate {

    private static let maxAttempts = 4

    private weak var store: AudioCacheStore?
    private let entry: AudioCacheEntry
    private let requestBuilder: (Int64) -> URLRequest?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var offset: Int64
    private var upstreamTotal: Int64 = 0
    private var attempts = 0
    private var cancelled = false
    /// 落盘失败的降级标志：停止缓存下载，让客户端下次请求重新决策
    private var diskBroken = false
    /// 网络环境变化（回前台 / 断网恢复 / 切网）触发的手动重启标记：
    /// `didCompleteWithError` 优先识别它，续拉**不消耗** attempts 预算
    private var manualRestart = false
    /// 最近一次收到上游数据的时刻：`retryNow` 只中止真正卡住的请求
    private var lastDataAt = Date()
    private static let stallThreshold: TimeInterval = 1.5

    init(entry: AudioCacheEntry, store: AudioCacheStore,
         requestBuilder: @escaping (Int64) -> URLRequest?) {
        self.entry = entry
        self.store = store
        self.requestBuilder = requestBuilder
        self.offset = entry.storedBytes
        super.init()
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 0   // 不设总超时：音频要读几分钟
        configuration.httpMaximumConnectionsPerHost = 2
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        startTask(on: session)
    }

    /// 下载已结束：只断开会话，不再 cancel（避免在委托回调里打断自己）。
    func detach() {
        session?.finishTasksAndInvalidate()
        session = nil
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        session?.invalidateAndCancel()
        session = nil
    }

    /// 回前台 / 网络环境变化时调用：卡住的在途请求立即中止并从已落盘位置续拉，
    /// 不等 `timeoutIntervalForRequest` 的 30 秒空闲超时 —— 切网后旧请求
    /// 大概率停在死路径上，等满 30 秒就是用户感知的"热启动卡顿"。
    /// 数据仍在正常流入的请求不动：中止它只会白白多一次 Range 请求。
    func retryNow() {
        guard !cancelled, !diskBroken, session != nil,
              let task = task, task.state == .running else { return }
        guard Date().timeIntervalSince(lastDataAt) > Self.stallThreshold else { return }
        manualRestart = true
        // 防抖：触发事件可能连发（NWPathMonitor 切网抖动），新请求必须再
        // 积攒 stallThreshold 的"无数据"证据才会被下一次 retryNow 打断
        lastDataAt = Date()
        task.cancel()
    }

    private func startTask(on session: URLSession) {
        guard !cancelled, !diskBroken else { return }
        guard let request = requestBuilder(offset) else {
            entry.noteHeaders(mimeType: nil, durationMs: 0)
            entry.finish(complete: false)
            session.finishTasksAndInvalidate()
            self.session = nil
            store?.downloadFinished(id: entry.id)
            return
        }
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    private func retry(from newOffset: Int64) {
        offset = max(0, newOffset)
        guard let session = session else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self, !self.cancelled else { return }
            self.startTask(on: session)
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let status = http.statusCode
        if status == 200 && offset > 0 {
            // 上游无视了 Range → 只能从头重来，否则文件里会留下错位字节
            cacheLog("download", "\(entry.id) 上游忽略 Range，重置缓存从头下载")
            entry.reset()
            offset = 0
        }
        if status == 416 {
            // 请求位置已在文件末尾之后：本地落盘字节数已经很可能是全量
            if let total = Self.totalFromContentRange(http.value(forHTTPHeaderField: "Content-Range")) {
                entry.setTotal(total)
            }
            entry.noteHeaders(mimeType: nil, durationMs: 0)
            completionHandler(.cancel)
            return
        }
        guard status == 206 || status == 200 else {
            cacheLog("download", "\(entry.id) 上游 HTTP \(status)，放弃本次下载")
            completionHandler(.cancel)
            return
        }

        if let total = Self.totalLength(from: http) {
            upstreamTotal = total
            entry.setTotal(total)
        }
        let rawType = http.value(forHTTPHeaderField: "Content-Type")
        if offset == 0 {
            // 上游响应头一次性记全。`ctype` 是排查「B 站音源被当视频流」这类问题的
            // 第一现场 —— 服务端会把 CDN 的头原样透传下来，所以这里看到的就是 CDN 的。
            cacheLog("download", "\(entry.id) 上游 \(status) ctype=\(rawType ?? "-") "
                + "len=\(http.value(forHTTPHeaderField: "Content-Length") ?? "-") "
                + "crange=\(http.value(forHTTPHeaderField: "Content-Range") ?? "-")")
        }
        let duration = Int(http.value(forHTTPHeaderField: "X-Audio-Duration-Ms") ?? "") ?? 0
        entry.noteHeaders(mimeType: rawType, durationMs: duration)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        lastDataAt = Date()
        if !entry.append(data) {
            cacheLog("download", "\(entry.id) 落盘失败，停止缓存下载")
            diskBroken = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !cancelled else { return }
        let stored = entry.storedBytes
        let reachedTotal = upstreamTotal > 0 && stored >= upstreamTotal
        let truncated = error != nil || (upstreamTotal > 0 && stored < upstreamTotal)

        if manualRestart {
            manualRestart = false
            if reachedTotal {
                // cancel 恰好落在收尾瞬间：直接按完成收尾，不进下面的续拉分支
                entry.finish(complete: true)
                session.finishTasksAndInvalidate()
                self.session = nil
                store?.downloadFinished(id: entry.id)
                return
            }
            cacheLog("download",
                     "\(entry.id) 网络环境变化，中止在途请求并立即续拉（已落盘 \(stored) 字节）")
            retry(from: stored)
            return
        }

        if truncated && attempts < Self.maxAttempts && !diskBroken {
            attempts += 1
            cacheLog("download",
                     "\(entry.id) 中断（\(error?.localizedDescription ?? "上游提前结束")），"
                     + "已落盘 \(stored)/\(upstreamTotal) 字节，第 \(attempts) 次续拉")
            retry(from: stored)
            return
        }

        let complete: Bool
        if reachedTotal {
            complete = true
        } else if error == nil && upstreamTotal == 0 {
            // 上游走 chunked（无长度可校验）：正常结束即视为完整
            complete = stored > 0
        } else {
            complete = false
        }

        cacheLog("download", "\(entry.id) 结束 stored=\(stored) total=\(upstreamTotal) "
            + "complete=\(complete) attempts=\(attempts)")
        entry.finish(complete: complete)
        session.finishTasksAndInvalidate()
        self.session = nil
        store?.downloadFinished(id: entry.id)
    }

    // MARK: 头部解析

    /// `Content-Range: bytes 0-3167081/3167082` 里的总数
    static func totalFromContentRange(_ value: String?) -> Int64? {
        guard let value = value, let slash = value.lastIndex(of: "/") else { return nil }
        let tail = value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        guard let total = Int64(tail), total > 0 else { return nil }
        return total
    }

    /// `Content-Range` 优先（206 时 `Content-Length` 只是本次区间的大小），
    /// 否则退到 `Content-Length`（200 时它才是总长）。
    static func totalLength(from http: HTTPURLResponse) -> Int64? {
        if let total = totalFromContentRange(http.value(forHTTPHeaderField: "Content-Range")) {
            return total
        }
        if let raw = http.value(forHTTPHeaderField: "Content-Length"), let n = Int64(raw), n > 0 {
            return n
        }
        return nil
    }
}

// MARK: - 缓存仓库

/**
 * 磁盘 LRU 仓库：`Caches/suen-audio-cache/<safe-id>.bin` + 同名 `.json` 侧车。
 *
 * 为什么用**每首一个侧车**而不是一份全局索引：索引文件一旦写坏，整库缓存
 * 一起作废；侧车坏掉只影响那一首（重新下载即可）。Android 侧也踩过
 * "SQLite 索引损坏导致 SimpleCache 起不来"的坑（见 `SuenAudioCache` 注释）。
 */
final class AudioCacheStore {

    static let shared = AudioCacheStore()

    /// 上限 4GB（与 Android 一致，用户拍板）
    static let maxBytes: Int64 = 4 * 1024 * 1024 * 1024

    private struct Sidecar: Codable {
        var total: Int64
        var complete: Bool
        var contentType: String?
        var durationMs: Int
        var lastAccess: Date
    }

    private let root: URL
    /// 只保护 `entries` / `downloaders` / `debugLog`，**不**用于包裹磁盘 IO
    private let dictLock = NSLock()
    private var entries: [String: AudioCacheEntry] = [:]
    private var downloaders: [String: StreamCacheDownloader] = [:]
    private var debugLog = true

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("suen-audio-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: 条目

    func entry(for id: String) -> AudioCacheEntry {
        dictLock.lock()
        defer { dictLock.unlock() }
        if let existing = entries[id] { return existing }
        let created = makeEntry(id)
        entries[id] = created
        return created
    }

    private func makeEntry(_ id: String) -> AudioCacheEntry {
        let sidecar = loadSidecar(id)
        var dataURL: URL? = fileURL(id)
        var existing: Int64 = 0
        if let url = dataURL {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber {
                existing = size.int64Value
            } else if !FileManager.default.createFile(atPath: url.path, contents: nil) {
                // 磁盘写入不可用（磁盘满 / 目录被清）→ 降级为内存缓冲
                dataURL = nil
            }
        }
        let complete = (sidecar?.complete == true) && existing > 0
            && (sidecar?.total ?? 0) <= existing
        return AudioCacheEntry(id: id, fileURL: dataURL, existingBytes: existing,
                               mimeType: sidecar?.contentType,
                               durationMs: sidecar?.durationMs ?? 0,
                               complete: complete)
    }

    private func allEntries() -> [AudioCacheEntry] {
        dictLock.lock()
        defer { dictLock.unlock() }
        return Array(entries.values)
    }

    // MARK: 下载生命周期

    /// 确保这首歌的下载在跑（没有就起一个，从已落盘位置续拉）。
    func ensureDownload(for id: String, requestBuilder: @escaping (Int64) -> URLRequest?) {
        let target = entry(for: id)
        if target.isComplete { return }

        dictLock.lock()
        if downloaders[id] != nil {
            dictLock.unlock()
            return
        }
        target.reopen()
        let downloader = StreamCacheDownloader(entry: target, store: self,
                                               requestBuilder: requestBuilder)
        downloaders[id] = downloader
        dictLock.unlock()
        downloader.start()
    }

    fileprivate func downloadFinished(id: String) {
        dictLock.lock()
        let downloader = downloaders.removeValue(forKey: id)
        let entry = entries[id]
        dictLock.unlock()
        downloader?.detach()
        if let entry = entry { saveSidecar(entry) }
        enforceLimit(protecting: id)
    }

    /// 回前台 / 网络环境变化：在途下载里真正卡住的请求立即换轨续拉。
    /// 原本它们要等 `timeoutIntervalForRequest` 的 30 秒空闲超时才会自愈，
    /// 切网后旧请求停在死路径上，等满 30 秒就是用户感知的"热启动卡顿"。
    func retryStalledDownloads() {
        dictLock.lock()
        let list = Array(downloaders.values)
        dictLock.unlock()
        for downloader in list { downloader.retryNow() }
    }

    // MARK: 对外查询

    /// 是否**完整**落在磁盘上（断网可听的判定依据）。
    /// 刻意不经过 `entry(for:)` —— 那会给每首查询过的曲子建一个空文件。
    func isComplete(_ id: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL(id).path),
              let size = attrs[.size] as? NSNumber, size.int64Value > 0 else { return false }
        guard let sidecar = loadSidecar(id), sidecar.complete else { return false }
        return sidecar.total <= size.int64Value
    }

    func usedBytes() -> Int64 {
        guard let list = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var sum: Int64 = 0
        for url in list where url.pathExtension == "bin" {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            sum += Int64(size)
        }
        return sum
    }

    // MARK: 驱逐

    func evict(id: String) {
        dictLock.lock()
        let entry = entries.removeValue(forKey: id)
        let downloader = downloaders.removeValue(forKey: id)
        dictLock.unlock()
        downloader?.cancel()
        entry?.abandon()
        try? FileManager.default.removeItem(at: fileURL(id))
        try? FileManager.default.removeItem(at: sidecarURL(id))
        cacheLog("evict", "\(id) 已驱逐")
    }

    func clear() {
        dictLock.lock()
        let running = Array(downloaders.values)
        let live = Array(entries.values)
        downloaders.removeAll()
        entries.removeAll()
        dictLock.unlock()
        running.forEach { $0.cancel() }
        live.forEach { $0.abandon() }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cacheLog("clear", "缓存已清空")
    }

    /// 超出 4GB 上限时按 LRU 淘汰（跳过有活动读者和正在下载的条目）
    private func enforceLimit(protecting id: String) {
        var used = usedBytes()
        guard used > Self.maxBytes else { return }
        let candidates = allEntries()
            .filter { $0.isEvictable && $0.id != id }
            .sorted { $0.lastAccessAt < $1.lastAccessAt }
        for candidate in candidates {
            evict(id: candidate.id)
            used = usedBytes()
            if used <= Self.maxBytes { return }
        }
    }

    // MARK: 路径与侧车

    private func fileURL(_ id: String) -> URL {
        root.appendingPathComponent(Self.fileName(for: id) + ".bin")
    }

    private func sidecarURL(_ id: String) -> URL {
        root.appendingPathComponent(Self.fileName(for: id) + ".json")
    }

    /// 文件名 = 净化后的 id 前缀 + id 哈希后缀。
    /// 后者保证"不同 id 一定不同文件"，前者让缓存目录肉眼可读（排查用）。
    static func fileName(for id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        var safe = ""
        for scalar in id.unicodeScalars {
            safe.unicodeScalars.append(allowed.contains(scalar) ? scalar : "_")
            if safe.count >= 48 { break }
        }
        let digest = Insecure.SHA1.hash(data: Data(id.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(10)
        return "\(safe)-\(digest)"
    }

    private func loadSidecar(_ id: String) -> Sidecar? {
        guard let data = try? Data(contentsOf: sidecarURL(id)) else { return nil }
        return try? JSONDecoder().decode(Sidecar.self, from: data)
    }

    private func saveSidecar(_ entry: AudioCacheEntry) {
        let sidecar = Sidecar(total: entry.storedBytes,
                              complete: entry.isComplete,
                              contentType: entry.contentType,
                              durationMs: entry.declaredDurationMs,
                              lastAccess: Date())
        guard let data = try? JSONEncoder().encode(sidecar) else { return }
        try? data.write(to: sidecarURL(entry.id), options: .atomic)
    }

    func setDebugLog(_ enabled: Bool) {
        dictLock.lock()
        debugLog = enabled
        dictLock.unlock()
    }

    fileprivate var isDebugLogEnabled: Bool {
        dictLock.lock()
        defer { dictLock.unlock() }
        return debugLog
    }
}

// MARK: - 回环 HTTP 代理

/**
 * 只监听 `127.0.0.1` 的最小 HTTP/1.1 服务：把 `AVPlayerItem` 的 URL 落到
 * 磁盘缓存上。
 *
 * 只跑回环的意义：这个端口能读到本机磁盘上的缓存字节，把它暴露到局域网上
 * 没有任何理由。回环连接同时不受 iOS 本地网络权限弹窗影响。
 *
 * 请求面刻意做到最小 —— 只有 `GET/HEAD /stream/<trackId>`：客户端是我们
 * 自己的 `AVPlayer`，不需要一个通用 HTTP 服务器。
 */
final class LocalStreamProxy {

    static let shared = LocalStreamProxy()

    private let store = AudioCacheStore.shared
    private let configLock = NSLock()
    private let connectionLock = NSLock()
    private var liveConnections: [ObjectIdentifier: ProxyConnection] = [:]

    private let listenerQueue = DispatchQueue(label: "com.suenmusic.proxy.listener")
    /// 并发队列：AVPlayer 可能同时开着多条连接（当前曲 + 预取下一首）
    let connectionQueue = DispatchQueue(label: "com.suenmusic.proxy.connection",
                                        attributes: .concurrent)

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var upstreamBase = ""
    private var upstreamToken = ""
    private var starting = false
    private var debugLog = true

    private init() {}

    // MARK: 配置与启动

    /// `setQueue` 每次都会带着最新的 base/token 过来（反代地址可能变、令牌会轮换）
    func configure(base: String, token: String) {
        var normalized = base
        while normalized.hasSuffix("/") { normalized.removeLast() }
        configLock.lock()
        upstreamBase = normalized
        upstreamToken = token
        configLock.unlock()
    }

    /// 非阻塞启动。端口没就绪时 `localURL` 返回 nil，播放自动回退到直连 ——
    /// 缓存是增强项，**任何情况下都不能因为它没准备好而播不出来**。
    func startIfNeeded() {
        configLock.lock()
        if listener != nil || starting {
            configLock.unlock()
            return
        }
        starting = true
        configLock.unlock()

        listenerQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
                parameters.requiredInterfaceType = .loopback
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self = self else { connection.cancel(); return }
                    let proxyConnection = ProxyConnection(connection: connection, proxy: self)
                    self.retain(proxyConnection)
                    proxyConnection.start()
                }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        self.configLock.lock()
                        self.port = listener?.port?.rawValue ?? 0
                        let ready = self.port
                        self.configLock.unlock()
                        proxyLog("listener", "本地流代理已就绪 127.0.0.1:\(ready)")
                    case .failed(let error):
                        proxyLog("listener", "本地流代理监听失败: \(error)")
                        self.configLock.lock()
                        self.resetListenerState()
                        self.configLock.unlock()
                    case .cancelled:
                        self.configLock.lock()
                        self.resetListenerState()
                        self.configLock.unlock()
                    default:
                        break
                    }
                }
                self.configLock.lock()
                self.listener = listener
                self.configLock.unlock()
                listener.start(queue: self.listenerQueue)
            } catch {
                proxyLog("listener", "本地流代理启动异常: \(error)")
                self.configLock.lock()
                self.resetListenerState()
                self.configLock.unlock()
            }
        }
    }

    /// 调用方须持有 `configLock`
    private func resetListenerState() {
        listener = nil
        port = 0
        starting = false
    }

    func stop() {
        configLock.lock()
        let listener = self.listener
        self.resetListenerState()
        configLock.unlock()
        listener?.cancel()
        connectionLock.lock()
        let live = Array(liveConnections.values)
        liveConnections.removeAll()
        connectionLock.unlock()
        live.forEach { $0.close() }
    }

    func setDebugLog(_ enabled: Bool) {
        configLock.lock()
        debugLog = enabled
        configLock.unlock()
    }

    var isDebugLogEnabled: Bool {
        configLock.lock()
        defer { configLock.unlock() }
        return debugLog
    }

    // MARK: 对外地址

    /// 本地代理地址。nil = 端口未就绪 / 上游未配置 → 调用方应回退直连。
    func localURL(trackId: String) -> String? {
        configLock.lock()
        let ready = port
        let hasUpstream = !upstreamBase.isEmpty
        configLock.unlock()
        guard ready > 0, hasUpstream else { return nil }
        let encoded = trackId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trackId
        return "http://127.0.0.1:\(ready)/stream/\(encoded)"
    }

    /// 上游流地址（带会话令牌）。`startOffset > 0` 时带 Range 续拉。
    func upstreamRequest(trackId: String, startOffset: Int64) -> URLRequest? {
        configLock.lock()
        let base = upstreamBase
        let token = upstreamToken
        configLock.unlock()
        guard !base.isEmpty else { return nil }
        let encoded = trackId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trackId
        var components = URLComponents(string: "\(base)/api/stream/\(encoded)")
        if !token.isEmpty {
            components?.queryItems = [URLQueryItem(name: "t", value: token)]
        }
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("SuenMusic/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        if startOffset > 0 {
            /**
             ⚠️ **只有续拉才带 `Range`，首次整首下载绝不能带**（2026-09-26 实测教训）。

             服务端 `streamRate()` 对「带 Range 的请求」按码率限速
             （`Math.max(码率 * 1.3, 40_000)`，即下限 40KB/s）。而 AVFoundation
             在 40KB/s 下**打不开 B 站的 fMP4**：一直停在
             `AVPlayerWaitingWhileEvaluatingBufferingRateReason`，20 秒内从未就绪，
             并不断从 64KB 对齐的偏移重发请求。同一份字节用 390KB/s、1MB/s 投喂立刻正常。

             为什么只有 B 站音源中招：网易云是 MP3，40KB/s 下照样边收边解码；
             B 站是 fMP4（`ftyp iso5` + `moov` + `sidx` + `moof/mdat` 分片），
             AVFoundation 要攒够数据才肯就绪 —— 它不像浏览器/ExoPlayer 能边到边解。
             于是「只有 iOS + 只有 B 站音源」这条极窄现象的真正根因是**下行速率**，
             与容器格式、`Content-Type`、权限都无关。

             不带 `Range` 走的正是服务端明确定义的「全量拉取／离线下载」分支
             （`streamRate` 里 `if (!hasRange) return undefined`）—— 我们干的本来就是
             全量下载，以前只是多发了一个 `bytes=0-`。
             */
            request.setValue("bytes=\(startOffset)-", forHTTPHeaderField: "Range")
        }
        return request
    }

    /// 客户端要读一首曲子：把下载任务开起来，并把条目交给连接去伺服
    func entry(trackId: String) -> AudioCacheEntry {
        let target = store.entry(for: trackId)
        store.ensureDownload(for: trackId) { [weak self] offset in
            self?.upstreamRequest(trackId: trackId, startOffset: offset)
        }
        return target
    }

    // MARK: 连接登记

    fileprivate func retain(_ connection: ProxyConnection) {
        connectionLock.lock()
        liveConnections[ObjectIdentifier(connection)] = connection
        connectionLock.unlock()
    }

    fileprivate func release(_ connection: ProxyConnection) {
        connectionLock.lock()
        liveConnections.removeValue(forKey: ObjectIdentifier(connection))
        connectionLock.unlock()
    }
}

// MARK: - 单条客户端连接

/**
 * 一条 `AVPlayer` 连接：解析请求头 → 计算响应区间 → **从缓存里**喂字节。
 *
 * 关键取舍：写响应头之前先等上游响应头处理完。
 * `Content-Length` 必须一次报准 —— 它是 AVPlayer 判断"这条流是否完整"的依据，
 * 报错了就会在流结束时得到 -1005；报小了则会只播开头一小段。
 * 唯一例外是上游按 chunked 传（拿不到总长），此时改用 chunked 回给客户端。
 */
final class ProxyConnection {

    private static let chunkSize = 256 * 1024
    /// 等一个新字节的最长时间。超过它说明下载真的卡住了（下载器自己会重试），
    /// 此时干净收尾让播放器重发请求，好过挂死在这里。
    private static let waitTimeout: TimeInterval = 25
    /// 等上游响应头的最长时间
    private static let metadataTimeout: TimeInterval = 12

    private let connection: NWConnection
    private weak var proxy: LocalStreamProxy?

    private var buffer = Data()
    private var headParsed = false
    private var closing = false

    private var entry: AudioCacheEntry?
    private var sent: Int64 = 0
    private var end: Int64 = 0
    /// 上游无总长（chunked）时的模式：忽略客户端 Range，从头按 chunked 伺服
    private var chunked = false

    init(connection: NWConnection, proxy: LocalStreamProxy) {
        self.connection = connection
        self.proxy = proxy
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: proxy?.connectionQueue ?? .global(qos: .utility))
        receive()
    }

    // MARK: 收请求头

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self = self, !self.closing else { return }
            if let data = data, !data.isEmpty { self.buffer.append(data) }
            if error != nil || (isComplete && self.buffer.isEmpty) {
                self.close()
                return
            }
            if let separator = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = self.buffer.subdata(in: 0..<separator.lowerBound)
                self.buffer.removeAll()
                self.handleHead(head)
                return
            }
            if self.buffer.count > 16 * 1024 {
                self.respond(status: 431, reason: "Request Header Fields Too Large", extra: [:])
                return
            }
            self.receive()
        }
    }

    private func handleHead(_ head: Data) {
        guard !headParsed, let text = String(data: head, encoding: .utf8) else {
            respond(status: 400, reason: "Bad Request", extra: [:])
            return
        }
        headParsed = true

        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            respond(status: 400, reason: "Bad Request", extra: [:])
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            respond(status: 400, reason: "Bad Request", extra: [:])
            return
        }
        let method = String(parts[0]).uppercased()
        let targetPath = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        guard method == "GET" || method == "HEAD" else {
            respond(status: 405, reason: "Method Not Allowed", extra: [:])
            return
        }

        let path = targetPath.split(separator: "?").first.map { String($0) } ?? targetPath
        let prefix = "/stream/"
        guard path.hasPrefix(prefix) else {
            respond(status: 404, reason: "Not Found", extra: [:])
            return
        }
        let rawId = String(path.dropFirst(prefix.count))
        let trackId = rawId.removingPercentEncoding ?? rawId
        guard !trackId.isEmpty, let proxy = proxy else {
            respond(status: 400, reason: "Bad Request", extra: [:])
            return
        }

        let target = proxy.entry(trackId: trackId)
        target.beginRead()
        entry = target

        let ready = target.waitForHeaders(timeout: Self.metadataTimeout)
        let total = target.serveTotal

        // Content-Type 必须按**真实字节**判，不能信上游声明（见 playableContentType）。
        // 文件头通常随第一包就到；已完整缓存的条目更是立刻可读。
        var head = Data()
        if let first = target.read(offset: 0, length: 16) {
            head = first
        } else if target.waitForBytes(offset: 0, length: 1, timeout: 3),
                  let first = target.read(offset: 0, length: 16) {
            head = first
        }

        var extra: [String: String] = [
            "Content-Type": Self.playableContentType(declared: target.contentType, head: head),
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
        ]
        if target.declaredDurationMs > 0 {
            extra["X-Audio-Duration-Ms"] = String(target.declaredDurationMs)
        }

        if total <= 0 && !ready {
            proxyLog("serve", "\(trackId) 上游 \(Int(Self.metadataTimeout))s 未回响应头，回 504")
            respond(status: 504, reason: "Gateway Timeout",
                    extra: ["Content-Type": "text/plain; charset=utf-8"],
                    body: Data("upstream headers timeout".utf8))
            return
        }

        if total <= 0 {
            // 上游按 chunked 传（没有总长可报）→ 忽略 Range，从头 chunked 伺服。
            // 对客户端而言这就是一条合法的 200 全量响应。
            chunked = true
            sent = 0
            end = 0
            extra["Transfer-Encoding"] = "chunked"
            proxyLog("serve", "\(trackId) 200 chunked（上游未给总长）")
            respond(status: 200, reason: "OK", extra: extra, thenPump: method != "HEAD")
            return
        }

        let (start, finish) = Self.resolveRange(headers["range"], total: total)
        if start < 0 {
            respond(status: 416, reason: "Range Not Satisfiable",
                    extra: ["Content-Range": "bytes */\(total)"])
            return
        }

        let length = finish - start + 1
        let isRange = headers["range"] != nil
        extra["Content-Length"] = String(length)
        if isRange {
            extra["Content-Range"] = "bytes \(start)-\(finish)/\(total)"
        }

        proxyLog("serve", "\(trackId) \(isRange ? 206 : 200) \(start)-\(finish)/\(total) "
            + "mime=\(extra["Content-Type"] ?? "-")")

        sent = start
        end = finish
        respond(status: isRange ? 206 : 200,
                reason: isRange ? "Partial Content" : "OK",
                extra: extra, thenPump: method != "HEAD")
    }

    /// 解析 `Range: bytes=s-e` / `bytes=s-` / `bytes=-N`。
    /// 返回 (-1, -1) 表示越界。无 Range 或格式不认识 → 整个文件。
    static func resolveRange(_ header: String?, total: Int64) -> (Int64, Int64) {
        let whole: (Int64, Int64) = (0, max(0, total - 1))
        guard let header = header, header.lowercased().hasPrefix("bytes=") else { return whole }
        let spec = header.dropFirst("bytes=".count).split(separator: ",").first.map { String($0) } ?? ""
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return whole }
        let startText = String(bounds[0]).trimmingCharacters(in: .whitespaces)
        let endText = String(bounds[1]).trimmingCharacters(in: .whitespaces)

        if startText.isEmpty {
            guard let suffix = Int64(endText) else { return whole }
            return (max(0, total - suffix), max(0, total - 1))
        }
        guard let start = Int64(startText) else { return whole }
        if start >= total { return (-1, -1) }
        guard let requestedEnd = Int64(endText) else { return (start, max(0, total - 1)) }
        return (start, min(requestedEnd, max(0, total - 1)))
    }

    /**
     交给 AVPlayer 的 `Content-Type`：**按缓存文件头字节认容器，认出来就覆盖上游声明**。

     ⚠️ 2026-09-26 实测（同一份 B 站 fMP4 字节，只改这一个响应头）：

         video/mp4                 → AVPlayer 正常播放
         audio/mp4                 → AVPlayer 正常播放
         application/octet-stream  → -11828 Cannot Open（媒体格式不受支持）

     与 WebKit / ExoPlayer 不同，AVFoundation **不靠字节嗅探容器**：它就认这个响应头，
     头里没有可用的容器信息就直接拒播。而服务端 `PASSTHROUGH_HEADERS` 会把 CDN 的类型
     原样透传下去，B 站/QQ 侧**大量音频就是 `application/octet-stream`** ——
     现象即「很多歌在 iOS 上播不出来，而 web 与安卓正常」。

     所以这里不看上游说什么，只信字节：认出来就用认出来的，认不出来才退回声明。
     */
    static func playableContentType(declared: String?, head: Data) -> String {
        if let sniffed = sniffContentType(head) { return sniffed }
        let value = declared?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? "audio/mpeg" : value
    }

    /// 从文件头字节认容器。认不出返回 nil（调用方退回上游声明）。
    static func sniffContentType(_ head: Data) -> String? {
        let bytes = [UInt8](head)
        guard bytes.count >= 12 else { return nil }
        func match(_ offset: Int, _ tag: String) -> Bool {
            let tagBytes = [UInt8](tag.utf8)
            guard offset >= 0, bytes.count >= offset + tagBytes.count else { return false }
            return Array(bytes[offset ..< offset + tagBytes.count]) == tagBytes
        }
        // MP4 家族：B 站 .m4s（CMAF 分片，`ftyp iso5` + moov + sidx + moof/mdat）走这里。
        // 混合流（带视频轨）也落 audio/mp4 —— 本应用只出声，取音轨正是想要的。
        if match(4, "ftyp") { return "audio/mp4" }
        if match(0, "ID3") { return "audio/mpeg" }
        if match(0, "fLaC") { return "audio/flac" }
        if match(0, "OggS") { return "audio/ogg" }
        if match(0, "RIFF") && match(8, "WAVE") { return "audio/wav" }
        // MPEG 音频帧同步（无 ID3 标签的裸 MP3）
        if bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 { return "audio/mpeg" }
        return nil
    }

    // MARK: 写响应与喂数据

    private func respond(status: Int, reason: String, extra: [String: String],
                         body: Data? = nil, thenPump: Bool = false) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in extra.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        if let body = body { payload.append(body) }

        connection.send(content: payload, contentContext: .defaultMessage,
                        isComplete: false,
                        completion: .contentProcessed { [weak self] error in
            guard let self = self, !self.closing else { return }
            if error != nil { self.close(); return }
            if let body = body, !body.isEmpty {
                self.finish()
            } else if thenPump {
                self.pump()
            } else {
                self.finish()
            }
        })
    }

    /// 从缓存按 256KB 分块喂给播放器。分块既避免一次性把整首读进内存，
    /// 也让"还没下到的区间"能一块一块等出来。
    private func pump() {
        guard !closing, let entry = entry else { return }
        guard chunked || sent <= end else { finish(); return }

        let want = chunked
            ? Self.chunkSize
            : Int(min(Int64(Self.chunkSize), end - sent + 1))

        if !entry.waitForBytes(offset: sent, length: 1, timeout: Self.waitTimeout) {
            // 终态且等不到新字节：把已就绪的部分发完就收尾
            let available = entry.storedBytes - sent
            guard available > 0,
                  let tail = entry.read(offset: sent, length: Int(min(Int64(want), available))),
                  !tail.isEmpty else {
                finish()
                return
            }
            sent += Int64(tail.count)
            send(tail)
            return
        }

        let available = entry.storedBytes - sent
        guard let data = entry.read(offset: sent, length: Int(min(Int64(want), max(1, available)))),
              !data.isEmpty else {
            finish()
            return
        }
        sent += Int64(data.count)
        send(data)
    }

    private func send(_ data: Data) {
        let payload = chunked ? Self.chunkFrame(data) : data
        connection.send(content: payload, contentContext: .defaultMessage,
                        isComplete: false,
                        completion: .contentProcessed { [weak self] error in
            guard let self = self, !self.closing else { return }
            if error != nil { self.close(); return }
            self.pump()
        })
    }

    private func finish() {
        guard !closing else { return }
        guard chunked else {
            closeFinished()
            return
        }
        // chunked 收尾帧
        connection.send(content: Data("0\r\n\r\n".utf8), contentContext: .defaultMessage,
                        isComplete: false,
                        completion: .contentProcessed { [weak self] _ in
            self?.closeFinished()
        })
    }

    private func closeFinished() {
        guard !closing else { return }
        connection.send(content: nil, contentContext: .defaultMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private static func chunkFrame(_ data: Data) -> Data {
        var frame = Data(String(data.count, radix: 16).utf8)
        frame.append(Data("\r\n".utf8))
        frame.append(data)
        frame.append(Data("\r\n".utf8))
        return frame
    }

    func close() {
        guard !closing else { return }
        closing = true
        entry?.endRead()
        entry = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        proxy?.release(self)
    }
}

// MARK: - 日志

private func cacheLog(_ tag: String, _ message: String) {
    guard AudioCacheStore.shared.isDebugLogEnabled else { return }
    print("[AudioCache/\(tag)] \(message)")
}

private func proxyLog(_ tag: String, _ message: String) {
    guard LocalStreamProxy.shared.isDebugLogEnabled else { return }
    print("[StreamProxy/\(tag)] \(message)")
}
