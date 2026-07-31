import AVFoundation
import Combine
import Foundation
import SwiftUI

/// CDN / 播放相关的用户偏好。
final class CDNSettings: ObservableObject {
    static let shared = CDNSettings()

    @Published var extraMirrors: Bool {
        didSet { UserDefaults.standard.set(extraMirrors, forKey: "cdn.extraMirrors") }
    }
    /// 空字符串 = 自动选路
    @Published var manualPin: String {
        didSet { UserDefaults.standard.set(manualPin, forKey: "cdn.manualPin") }
    }
    /// 0 = 自动最高
    @Published var preferredQN: Int {
        didSet { UserDefaults.standard.set(preferredQN, forKey: "play.preferredQN") }
    }
    @Published var danmakuOn: Bool {
        didSet { UserDefaults.standard.set(danmakuOn, forKey: "play.danmakuOn") }
    }

    private init() {
        extraMirrors = UserDefaults.standard.object(forKey: "cdn.extraMirrors") as? Bool ?? true
        manualPin = UserDefaults.standard.string(forKey: "cdn.manualPin") ?? ""
        preferredQN = UserDefaults.standard.object(forKey: "play.preferredQN") as? Int ?? 0
        danmakuOn = UserDefaults.standard.object(forKey: "play.danmakuOn") as? Bool ?? true
    }
}

struct QualityOption: Identifiable, Equatable {
    let qn: Int
    let label: String
    var id: Int { qn }
}

/// 本地播放进度(未登录/服务端进度缺失时的兜底)。
enum ProgressStore {
    private static let key = "play.progress.v1"

    static func save(bvid: String, seconds: Double) {
        guard seconds > 5 else { return }
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Double]] ?? [:]
        map[bvid] = ["s": seconds, "t": Date().timeIntervalSince1970]
        if map.count > 200 {
            let oldest = map.sorted { ($0.value["t"] ?? 0) < ($1.value["t"] ?? 0) }
            for (bvid, _) in oldest.prefix(map.count - 200) {
                map[bvid] = nil
            }
        }
        UserDefaults.standard.set(map, forKey: key)
    }

    static func load(bvid: String) -> Double? {
        let map = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Double]]
        return map?[bvid]?["s"]
    }
}

@MainActor
final class PlayerViewModel: ObservableObject {
    enum PlayState: Equatable {
        case loading(String)
        case playing
        case failed(String)
    }

    @Published var state: PlayState = .loading("正在解析视频…")
    @Published var stats = EngineStats()
    @Published var qualityName = ""
    @Published var videoTitle = ""
    @Published var availableQualities: [QualityOption] = []
    @Published var currentQN = 0
    @Published var danmakuEnabled = true
    @Published var currentSeconds: Double = 0
    /// 弹幕分段加载完成时 +1,驱动高能面板刷新
    @Published var heatVersion = 0
    /// 暂停 / 缓冲状态(驱动网速悬浮窗)
    @Published var timeControl: AVPlayer.TimeControlStatus = .waitingToPlayAtSpecifiedRate
    /// "已从 xx:xx 续播" 提示
    @Published var resumeNotice: String?

    let player = AVPlayer()
    let danmaku = DanmakuManager()
    weak var danmakuOverlay: DanmakuOverlayView?

    private var bvid = ""
    private var detail: ViewData?
    private var candidates: [CDNCandidate] = []
    private var videoSelector: CDNSelector?
    private var server: LocalStreamServer?
    private var videoEngine: ChunkEngine?
    private var audioEngine: ChunkEngine?
    private var mp4Engine: ChunkEngine?

    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var lastTickSeconds: Double = -1
    private var lastLocalSave: Double = 0
    private var lastReportAt = Date.distantPast
    private var stallObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var probeTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var pendingQN: Int?
    private var recoveryAttempt = 0
    private var lastRecoveryAt = Date.distantPast

    var totalSeconds: Double { Double(detail?.duration ?? 0) }

    func heat(_ buckets: Int) -> [Int] { danmaku.heatBuckets(buckets) }

    // MARK: - 加载

    func load(bvid: String) async {
        self.bvid = bvid
        danmakuEnabled = CDNSettings.shared.danmakuOn
        do {
            state = .loading("正在解析视频…")
            let detail = try await VideoAPI.detail(bvid: bvid)
            self.detail = detail
            videoTitle = detail.title
            danmaku.configure(cid: detail.cid, aid: detail.aid, duration: Double(detail.duration ?? 0))
            danmaku.onDanmaku = { [weak self] danmus in
                self?.danmakuOverlay?.add(danmus)
            }
            danmaku.onLoaded = { [weak self] in
                self?.heatVersion += 1
            }
            setupObservers()

            // 调试:-directPlay YES / -directURL 直连播放,绕过 SmartLoader
            let overrideURL = UserDefaults.standard.string(forKey: "directURL")
            if UserDefaults.standard.bool(forKey: "directPlay") || overrideURL != nil {
                let play = try await VideoAPI.playURL(bvid: bvid, cid: detail.cid)
                guard let direct = URL(string: overrideURL ?? play.durl?.first?.url ?? "") else {
                    throw BiliError.badURL
                }
                let asset = AVURLAsset(url: direct, options: [
                    "AVURLAssetHTTPHeaderFieldsKey": [
                        "User-Agent": BiliClient.userAgent,
                        "Referer": BiliClient.referer,
                    ],
                ])
                attachItem(asset: asset, seekTo: nil)
                return
            }

            try await buildPipeline(seekTo: await resumeTime(for: detail))
        } catch {
            fail(error)
        }
    }

    /// 续播位置:服务端进度(跨设备)优先,本地记录兜底;开头/结尾不续播。
    private func resumeTime(for detail: ViewData) async -> CMTime? {
        var resume = 0.0
        if BiliClient.shared.csrf != nil,
           let v2: PlayerV2Data = try? await VideoAPI.playerV2(aid: detail.aid, cid: detail.cid),
           let ms = v2.lastPlayTime, ms > 0 {
            resume = Double(ms) / 1000
        }
        if resume <= 0 {
            resume = ProgressStore.load(bvid: bvid) ?? 0
        }
        let duration = Double(detail.duration ?? 0)
        guard resume > 10, duration > 30, resume < duration * 0.95 else { return nil }
        resumeNotice = "已从 \(formatDuration(Int(resume))) 续播"
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.resumeNotice = nil
        }
        return CMTime(seconds: resume, preferredTimescale: 600)
    }

    private var targetQN: Int {
        if let pendingQN { return pendingQN }
        let preferred = CDNSettings.shared.preferredQN
        return preferred == 0 ? 127 : preferred
    }

    private func buildPipeline(seekTo: CMTime?) async throws {
        guard let detail else { return }
        teardownPipeline()
        state = .loading("正在获取播放地址…")
        let play = try await VideoAPI.playURLDash(bvid: bvid, cid: detail.cid)
        let labels = play.qualityLabels
        if let dash = play.dash, let video = Self.pickVideo(dash.video ?? [], targetQN: targetQN) {
            try await buildDash(dash: dash, video: video, labels: labels, seekTo: seekTo)
        } else if let durl = play.durl?.first {
            try await buildDurl(play: play, durl: durl, labels: labels, seekTo: seekTo)
        } else {
            throw BiliError.notPlayable("接口未返回可用播放地址")
        }
    }

    // MARK: - 轨道选择

    static func pickVideo(_ tracks: [DashTrack], targetQN: Int) -> DashTrack? {
        let usable = tracks.filter { track in
            guard track.id <= 120,
                  track.baseUrl != nil,
                  Sidx.parseRange(track.segmentBase?.indexRange) != nil else { return false }
            let codec = (track.codecs ?? "").lowercased()
            // Apple TV 无 AV1 硬解;杜比视界暂不做
            return !codec.hasPrefix("av01") && !codec.hasPrefix("dvh")
        }
        let ids = Set(usable.map(\.id))
        guard !ids.isEmpty else { return nil }
        let chosen = ids.filter { $0 <= targetQN }.max() ?? ids.min()!
        let same = usable.filter { $0.id == chosen }
        return same.first {
            let codec = ($0.codecs ?? "").lowercased()
            return codec.hasPrefix("hvc") || codec.hasPrefix("hev")
        } ?? same.first
    }

    static func pickAudio(_ tracks: [DashTrack]) -> DashTrack? {
        tracks
            .filter {
                (30200...30299).contains($0.id) && $0.baseUrl != nil
                    && Sidx.parseRange($0.segmentBase?.indexRange) != nil
            }
            .max { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) }
    }

    // MARK: - DASH → 本地 HLS

    private func buildDash(dash: DashData, video: DashTrack, labels: [Int: String], seekTo: CMTime?) async throws {
        let extra = CDNSettings.shared.extraMirrors
        let pin = CDNSettings.shared.manualPin

        guard let vRange = Sidx.parseRange(video.segmentBase?.indexRange) else {
            throw BiliError.notPlayable("视频轨缺少分段索引")
        }
        let vCandidates = CandidateBuilder.build(from: video, includeExtraMirrors: extra)
        state = .loading("正在验证线路与分段索引…")
        let vIndex = try await Self.fetchIndex(candidates: vCandidates, indexRange: vRange)

        let queue = DispatchQueue(label: "obili.hls")
        let server = LocalStreamServer()
        let port = try await server.start()
        let base = HLSBuilder.base(port: port)
        self.server = server

        let vSelector = CDNSelector(candidates: vCandidates, pinnedHost: pin.isEmpty ? nil : pin)
        vSelector.recordSuccess(host: vIndex.winner.host, bytes: vIndex.bytes, seconds: vIndex.elapsed)
        videoSelector = vSelector
        candidates = vCandidates

        let vTotal = vIndex.segments.last!.end + 1
        let vEngine = ChunkEngine(selector: vSelector, contentLength: vTotal, queue: queue)
        vEngine.onStats = { [weak self] stats in self?.stats = stats }
        vEngine.onFailover = { [weak self] _ in self?.scheduleRecoveryProbe() }
        videoEngine = vEngine
        server.setRoute(HLSBuilder.videoDataPath, .media(engine: vEngine, length: vTotal, mime: "video/mp4"))
        server.setRoute(
            HLSBuilder.videoPlaylistPath,
            .playlist(HLSBuilder.media(base: base, dataPath: HLSBuilder.videoDataPath,
                                       initEnd: vRange.end, segments: vIndex.segments))
        )

        var audioTrack: DashTrack?
        if let audio = Self.pickAudio(dash.audio ?? []),
           let aRange = Sidx.parseRange(audio.segmentBase?.indexRange) {
            let aCandidates = CandidateBuilder.build(from: audio, includeExtraMirrors: extra)
            if let aIndex = try? await Self.fetchIndex(candidates: aCandidates, indexRange: aRange) {
                let aSelector = CDNSelector(candidates: aCandidates, pinnedHost: pin.isEmpty ? nil : pin)
                aSelector.recordSuccess(host: aIndex.winner.host, bytes: aIndex.bytes, seconds: aIndex.elapsed)
                let aTotal = aIndex.segments.last!.end + 1
                let aEngine = ChunkEngine(selector: aSelector, contentLength: aTotal, queue: queue)
                aEngine.onFailover = { [weak self] _ in self?.scheduleRecoveryProbe() }
                audioEngine = aEngine
                server.setRoute(HLSBuilder.audioDataPath, .media(engine: aEngine, length: aTotal, mime: "audio/mp4"))
                server.setRoute(
                    HLSBuilder.audioPlaylistPath,
                    .playlist(HLSBuilder.media(base: base, dataPath: HLSBuilder.audioDataPath,
                                               initEnd: aRange.end, segments: aIndex.segments))
                )
                audioTrack = audio
            }
        }

        server.setRoute(HLSBuilder.masterPath, .playlist(HLSBuilder.master(base: base, video: video, audio: audioTrack)))

        guard let url = URL(string: base + HLSBuilder.masterPath) else {
            throw BiliError.badURL
        }
        attachItem(asset: AVURLAsset(url: url), seekTo: seekTo)

        currentQN = video.id
        qualityName = labels[video.id] ?? QualityLabel.name(video.id)
        let switchable = Set(
            (dash.video ?? [])
                .filter { track in
                    let codec = (track.codecs ?? "").lowercased()
                    return track.id <= 120 && !codec.hasPrefix("av01") && !codec.hasPrefix("dvh")
                        && Sidx.parseRange(track.segmentBase?.indexRange) != nil
                }
                .map(\.id)
        )
        availableQualities = switchable.sorted(by: >).map {
            QualityOption(qn: $0, label: labels[$0] ?? QualityLabel.name($0))
        }
        startBackgroundProbe()
        startPeriodicProbe()
    }

    struct IndexResult {
        let winner: CDNCandidate
        let segments: [SidxSegment]
        let bytes: Int
        let elapsed: Double
    }

    /// 下载 0...indexEnd(init + sidx)并解析分段;按候选优先序尝试(API 下发的在前)。
    static func fetchIndex(candidates: [CDNCandidate], indexRange: (start: Int64, end: Int64)) async throws -> IndexResult {
        let ordered = candidates.filter { !$0.isExtra } + candidates.filter { $0.isExtra }
        for candidate in ordered {
            let began = Date()
            do {
                let data = try await withTimeout(seconds: 8) {
                    try await downloadRange(url: candidate.url, start: 0, end: indexRange.end)
                }
                guard data.count == Int(indexRange.end) + 1 else { continue }
                let sidxSlice = data.subdata(in: Int(indexRange.start)..<data.count)
                guard let segments = Sidx.parse(data: sidxSlice, absoluteStart: indexRange.start),
                      !segments.isEmpty else { continue }
                return IndexResult(
                    winner: candidate,
                    segments: segments,
                    bytes: data.count,
                    elapsed: max(0.05, Date().timeIntervalSince(began))
                )
            } catch {
                continue
            }
        }
        throw BiliError.notPlayable("所有线路的分段索引都获取失败")
    }

    private static func downloadRange(url: URL, start: Int64, end: Int64) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.setValue(BiliClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(BiliClient.referer, forHTTPHeaderField: "Referer")
        req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        let (data, response) = try await CDNProber.probeSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 || http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - durl mp4 兜底

    private func buildDurl(play: PlayURLData, durl: Durl, labels: [Int: String], seekTo: CMTime?) async throws {
        let candidates = CandidateBuilder.build(from: durl, includeExtraMirrors: CDNSettings.shared.extraMirrors)
        self.candidates = candidates
        state = .loading("正在验证线路…")
        let apiProvided = candidates.filter { !$0.isExtra }
        guard let (healthy, sample) = await CDNProber.firstHealthy(apiProvided.isEmpty ? candidates : apiProvided) else {
            throw BiliError.notPlayable("所有线路均连接失败,请检查网络")
        }
        let totalBytes = sample.totalBytes > 0 ? sample.totalBytes : Int64(durl.size ?? 0)
        guard totalBytes > 0 else { throw BiliError.notPlayable("无法确定视频文件大小") }

        let pin = CDNSettings.shared.manualPin
        let selector = CDNSelector(candidates: candidates, pinnedHost: pin.isEmpty ? nil : pin)
        selector.recordSuccess(host: healthy.host, bytes: sample.bytes, seconds: max(sample.totalMs / 1000, 0.001))
        videoSelector = selector

        let engine = ChunkEngine(selector: selector, contentLength: totalBytes)
        engine.onStats = { [weak self] stats in self?.stats = stats }
        engine.onFailover = { [weak self] _ in self?.scheduleRecoveryProbe() }
        mp4Engine = engine

        let server = LocalStreamServer()
        let port = try await server.start()
        server.setRoute(HLSBuilder.mp4Path, .media(engine: engine, length: totalBytes, mime: "video/mp4"))
        self.server = server

        guard let assetURL = URL(string: HLSBuilder.base(port: port) + HLSBuilder.mp4Path) else {
            throw BiliError.badURL
        }
        attachItem(asset: AVURLAsset(url: assetURL), seekTo: seekTo)

        currentQN = play.quality ?? 0
        qualityName = labels[currentQN] ?? QualityLabel.name(currentQN)
        availableQualities = (play.acceptQuality ?? [])
            .filter { $0 <= 80 }
            .map { QualityOption(qn: $0, label: labels[$0] ?? QualityLabel.name($0)) }
        startBackgroundProbe()
        startPeriodicProbe()
    }

    // MARK: - AVPlayer 装配

    private func attachItem(asset: AVURLAsset, seekTo: CMTime?) {
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 30
        item.externalMetadata = Self.metadata(title: detail?.title ?? videoTitle, author: detail?.owner?.name)

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor [weak self] in
                switch observed.status {
                case .readyToPlay:
                    self?.state = .playing
                case .failed:
                    self?.state = .failed(observed.error?.localizedDescription ?? "播放失败")
                default:
                    break
                }
            }
        }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        stallObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleStall() }
        }

        player.replaceCurrentItem(with: item)
        if let seekTo, seekTo.seconds.isFinite, seekTo.seconds > 1 {
            player.seek(to: seekTo)
        }
        player.play()
    }

    private func setupObservers() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                // seek:清掉屏上残留的旧位置弹幕,游标由 DanmakuManager 自行重定位
                if self.lastTickSeconds >= 0, abs(seconds - self.lastTickSeconds) > 2 {
                    self.danmakuOverlay?.clear()
                }
                self.lastTickSeconds = seconds
                self.currentSeconds = seconds
                self.danmaku.tick(seconds, emit: self.danmakuEnabled && self.player.rate > 0)
                self.recordProgress(seconds)
            }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let paused = player.rate == 0
            Task { @MainActor [weak self] in
                self?.danmakuOverlay?.setPaused(paused)
            }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                self?.timeControl = status
            }
        }
    }

    /// 本地每 5 秒落盘;登录态每 15 秒上报 B 站(历史进度 / 跨设备续播)。
    private func recordProgress(_ seconds: Double) {
        guard seconds > 5, player.rate > 0 else { return }
        if abs(seconds - lastLocalSave) > 5 {
            lastLocalSave = seconds
            ProgressStore.save(bvid: bvid, seconds: seconds)
        }
        if BiliClient.shared.csrf != nil,
           Date().timeIntervalSince(lastReportAt) > 15,
           let detail {
            lastReportAt = Date()
            let aid = detail.aid
            let cid = detail.cid
            Task.detached {
                try? await ActionAPI.reportHistory(aid: aid, cid: cid, progress: Int(seconds))
            }
        }
    }

    // MARK: - 用户操作

    func switchQuality(_ qn: Int) {
        guard qn != currentQN else { return }
        pendingQN = qn
        CDNSettings.shared.preferredQN = qn
        rebuildKeepingPosition()
    }

    func reloadStream() {
        rebuildKeepingPosition()
    }

    func toggleDanmaku() {
        danmakuEnabled.toggle()
        CDNSettings.shared.danmakuOn = danmakuEnabled
        danmakuOverlay?.enabled = danmakuEnabled
    }

    func pinHost(_ host: String?) {
        videoSelector?.pin(host)
        CDNSettings.shared.manualPin = host ?? ""
        videoEngine?.requestStats()
        mp4Engine?.requestStats()
    }

    func manualReprobe() {
        startBackgroundProbe()
    }

    private func rebuildKeepingPosition() {
        let position = player.currentTime()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.buildPipeline(seekTo: position)
            } catch {
                self.fail(error)
            }
        }
    }

    // MARK: - 卡顿恢复 / 测速

    private func handleStall() {
        if let current = videoSelector?.currentHost {
            videoSelector?.recordFailure(host: current, error: "播放停滞")
        }
        scheduleRecoveryProbe()
    }

    private func startBackgroundProbe() {
        probeTask?.cancel()
        let candidates = self.candidates
        probeTask = Task { [weak self] in
            let results = await CDNProber.fullProbe(candidates)
            guard !Task.isCancelled, let self else { return }
            self.videoSelector?.apply(probeResults: results)
            self.videoEngine?.requestStats()
            self.mp4Engine?.requestStats()
            if results.contains(where: { $0.ok }) {
                self.recoveryAttempt = 0
            }
        }
    }

    private func scheduleRecoveryProbe() {
        let delay = min(300.0, 10.0 * pow(2, Double(recoveryAttempt)))
        guard Date().timeIntervalSince(lastRecoveryAt) > delay else { return }
        lastRecoveryAt = Date()
        recoveryAttempt += 1
        startBackgroundProbe()
    }

    private func startPeriodicProbe() {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if case .playing = self.state, self.stats.cacheAheadBytes > 8 * 1024 * 1024 {
                    self.startBackgroundProbe()
                }
            }
        }
    }

    // MARK: - 清理

    private func teardownPipeline() {
        probeTask?.cancel()
        periodicTask?.cancel()
        statusObservation?.invalidate()
        statusObservation = nil
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        stallObserver = nil
        server?.stop()
        server = nil
        videoEngine?.shutdown()
        videoEngine = nil
        audioEngine?.shutdown()
        audioEngine = nil
        mp4Engine?.shutdown()
        mp4Engine = nil
        videoSelector = nil
    }

    func stop() {
        // 退出时保存最终进度并上报
        let finalSeconds = player.currentTime().seconds
        if finalSeconds.isFinite, finalSeconds > 5 {
            ProgressStore.save(bvid: bvid, seconds: finalSeconds)
            if BiliClient.shared.csrf != nil, let detail {
                let aid = detail.aid
                let cid = detail.cid
                Task.detached {
                    try? await ActionAPI.reportHistory(aid: aid, cid: cid, progress: Int(finalSeconds))
                }
            }
        }
        teardownPipeline()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rateObservation?.invalidate()
        rateObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        danmakuOverlay?.clear()
    }

    private func fail(_ error: Error) {
        state = .failed((error as? BiliError)?.errorDescription ?? error.localizedDescription)
    }

    private static func metadata(title: String, author: String?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = .commonIdentifierTitle
        titleItem.value = title as NSString
        titleItem.extendedLanguageTag = "und"
        items.append(titleItem)
        if let author {
            let authorItem = AVMutableMetadataItem()
            authorItem.identifier = .iTunesMetadataTrackSubTitle
            authorItem.value = "UP主:\(author)" as NSString
            authorItem.extendedLanguageTag = "und"
            items.append(authorItem)
        }
        return items
    }
}
