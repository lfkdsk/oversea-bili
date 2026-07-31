import Foundation

struct EngineStats {
    var hosts: [HostStatus] = []
    var currentHost: String?
    var currentLabel: String?
    var cacheAheadBytes: Int64 = 0
    var deliveredBytes: Int64 = 0
    var failovers: Int = 0
    var inflightCount: Int = 0
}

func withTimeout<T>(seconds: Double, _ op: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw URLError(.timedOut)
        }
        guard let result = try await group.next() else { throw URLError(.cancelled) }
        group.cancelAll()
        return result
    }
}

/// 分块下载引擎:把媒体文件按 2MB 分块,每块独立走"当前最优线路"下载,
/// 失败自动冷却换路;在播放头前方保持预取窗口。
/// 数据消费方是 LocalStreamServer(本地回环 HTTP),换线路对播放器完全透明。
final class ChunkEngine {
    static let chunkSize: Int64 = 2 * 1024 * 1024

    let loaderQueue: DispatchQueue
    let contentLength: Int64
    private let selector: CDNSelector

    private var cache: [Int64: Data] = [:]
    private var cacheBytes: Int64 = 0
    private let maxCacheBytes: Int64 = 96 * 1024 * 1024
    private var waiters: [Int64: [CheckedContinuation<Data, Error>]] = [:]
    private var inflight: Set<Int64> = []
    private var fetchTasks: [Int64: Task<Void, Never>] = [:]
    private var frontierOffset: Int64 = 0
    private var failoverCount = 0
    private var deliveredTotal: Int64 = 0
    private var stopped = false
    private var lastStatsPush = Date.distantPast

    private let prefetchAheadChunks: Int64 = 12  // 24MB 预取窗口
    private let maxConcurrentFetch = 2

    /// 主线程回调
    var onStats: ((EngineStats) -> Void)?
    var onFailover: ((Int) -> Void)?

    private let cdnSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 40
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    init(selector: CDNSelector, contentLength: Int64, queue: DispatchQueue? = nil) {
        self.selector = selector
        self.contentLength = contentLength
        self.loaderQueue = queue ?? DispatchQueue(label: "obili.engine")
    }

    var lastChunkIndex: Int64 { max(0, (contentLength - 1) / Self.chunkSize) }

    // MARK: - 消费入口

    /// 取一个分块(缓存命中直接返回;否则触发紧急下载并等待)。
    func chunk(at idx: Int64) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            loaderQueue.async {
                guard !self.stopped else {
                    continuation.resume(throwing: URLError(.cancelled))
                    return
                }
                guard idx >= 0, idx <= self.lastChunkIndex else {
                    continuation.resume(throwing: URLError(.badURL))
                    return
                }
                if let data = self.cache[idx] {
                    self.deliveredTotal += Int64(data.count)
                    continuation.resume(returning: data)
                    self.schedulePrefetch()
                    self.publishStats()
                    return
                }
                self.waiters[idx, default: []].append(continuation)
                self.ensureFetch(idx, urgent: true)
                self.schedulePrefetch()
            }
        }
    }

    /// 播放头(最近一次请求的字节位置),预取窗口跟随它。
    func noteFrontier(_ offset: Int64) {
        loaderQueue.async {
            self.frontierOffset = min(max(0, offset), self.contentLength)
            self.schedulePrefetch()
        }
    }

    func shutdown() {
        loaderQueue.async {
            self.stopped = true
            for task in self.fetchTasks.values { task.cancel() }
            self.fetchTasks.removeAll()
            for list in self.waiters.values {
                for waiter in list { waiter.resume(throwing: URLError(.cancelled)) }
            }
            self.waiters.removeAll()
            self.cache.removeAll()
            self.cacheBytes = 0
        }
    }

    func requestStats() {
        loaderQueue.async { self.publishStats(force: true) }
    }

    // MARK: - 预取

    private func schedulePrefetch() {
        guard !stopped, contentLength > 0 else { return }
        let startIdx = frontierOffset / Self.chunkSize
        let endIdx = min(lastChunkIndex, startIdx + prefetchAheadChunks)
        var idx = startIdx
        while idx <= endIdx {
            if cache[idx] == nil, !inflight.contains(idx) {
                if inflight.count >= maxConcurrentFetch { break }
                ensureFetch(idx, urgent: false)
            }
            idx += 1
        }
    }

    private func ensureFetch(_ idx: Int64, urgent: Bool) {
        guard !stopped, cache[idx] == nil, !inflight.contains(idx) else { return }
        if !urgent, inflight.count >= maxConcurrentFetch { return }
        inflight.insert(idx)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.fetchChunk(idx, urgent: urgent)
        }
        fetchTasks[idx] = task
    }

    // MARK: - 分块下载(任意线程,结果回到 loaderQueue)

    private func fetchChunk(_ idx: Int64, urgent: Bool) async {
        let start = idx * Self.chunkSize
        let end = min(contentLength - 1, (idx + 1) * Self.chunkSize - 1)
        let expected = Int(end - start + 1)

        var round = 0
        let maxRounds = urgent ? 4 : 1
        while round < maxRounds, !Task.isCancelled {
            round += 1
            var tried = Set<String>()
            var attemptInRound = 0
            while let candidate = selector.pick(excluding: tried), !Task.isCancelled {
                tried.insert(candidate.host)
                attemptInRound += 1
                let began = Date()
                do {
                    let data = try await withTimeout(seconds: urgent ? 10 : 16) {
                        try await self.download(url: candidate.url, start: start, end: end)
                    }
                    guard data.count >= expected else { throw URLError(.badServerResponse) }
                    let elapsed = Date().timeIntervalSince(began)
                    self.selector.recordSuccess(host: candidate.host, bytes: data.count, seconds: elapsed)
                    if attemptInRound > 1 || round > 1 {
                        self.noteFailover()
                    }
                    self.storeChunk(idx, data: data.prefix(expected).withUnsafeBytes { Data($0) })
                    return
                } catch {
                    let message = (error as? URLError)?.code == .timedOut ? "超时" : error.localizedDescription
                    self.selector.recordFailure(host: candidate.host, error: message)
                }
            }
            if round < maxRounds {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        finishChunkFailed(idx)
    }

    private func download(url: URL, start: Int64, end: Int64) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue(BiliClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(BiliClient.referer, forHTTPHeaderField: "Referer")
        req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        req.timeoutInterval = 8
        let (data, response) = try await cdnSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 || http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func storeChunk(_ idx: Int64, data: Data) {
        loaderQueue.async {
            self.inflight.remove(idx)
            self.fetchTasks[idx] = nil
            guard !self.stopped else { return }
            if self.cache[idx] == nil {
                self.cache[idx] = data
                self.cacheBytes += Int64(data.count)
            }
            if let list = self.waiters.removeValue(forKey: idx) {
                self.deliveredTotal += Int64(data.count)
                for waiter in list { waiter.resume(returning: data) }
            }
            self.trimCache()
            self.schedulePrefetch()
            self.publishStats()
        }
    }

    private func finishChunkFailed(_ idx: Int64) {
        loaderQueue.async {
            self.inflight.remove(idx)
            self.fetchTasks[idx] = nil
            if let list = self.waiters.removeValue(forKey: idx) {
                for waiter in list { waiter.resume(throwing: URLError(.networkConnectionLost)) }
            }
            self.publishStats(force: true)
        }
    }

    private func noteFailover() {
        loaderQueue.async {
            self.failoverCount += 1
            let count = self.failoverCount
            DispatchQueue.main.async { self.onFailover?(count) }
        }
    }

    private func trimCache() {
        guard cacheBytes > maxCacheBytes else { return }
        let currentIdx = frontierOffset / Self.chunkSize
        let evictable = cache.keys.sorted { abs($0 - currentIdx) > abs($1 - currentIdx) }
        for idx in evictable {
            guard cacheBytes > maxCacheBytes else { break }
            if idx >= currentIdx, idx <= currentIdx + prefetchAheadChunks { continue }
            if let data = cache.removeValue(forKey: idx) {
                cacheBytes -= Int64(data.count)
            }
        }
    }

    private func publishStats(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastStatsPush) > 0.5 else { return }
        lastStatsPush = Date()
        var stats = EngineStats()
        stats.hosts = selector.snapshot()
        stats.currentHost = selector.currentHost
        stats.currentLabel = selector.currentHost.flatMap { host in
            selector.candidate(for: host)?.label
        }
        stats.deliveredBytes = deliveredTotal
        stats.failovers = failoverCount
        stats.inflightCount = inflight.count
        var idx = frontierOffset / Self.chunkSize
        var ahead: Int64 = 0
        while let chunk = cache[idx] {
            ahead += Int64(chunk.count)
            idx += 1
        }
        stats.cacheAheadBytes = ahead
        DispatchQueue.main.async { self.onStats?(stats) }
    }
}
