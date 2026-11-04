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
    /// 直播清晰度(10000 = 原画)
    @Published var liveQN: Int {
        didSet { UserDefaults.standard.set(liveQN, forKey: "play.liveQN") }
    }
    /// 弹幕占屏比例:0.25 / 0.5 / 0.75 / 1.0
    @Published var danmakuArea: Double {
        didSet {
            UserDefaults.standard.set(danmakuArea, forKey: "danmaku.area")
            DanmakuStyle.shared.area = danmakuArea
        }
    }
    @Published var danmakuOpacity: Double {
        didSet {
            UserDefaults.standard.set(danmakuOpacity, forKey: "danmaku.opacity")
            DanmakuStyle.shared.opacity = danmakuOpacity
        }
    }
    /// 字号倍率
    @Published var danmakuScale: Double {
        didSet {
            UserDefaults.standard.set(danmakuScale, forKey: "danmaku.scale")
            DanmakuStyle.shared.scale = danmakuScale
        }
    }
    /// 滚动时长(秒),越大越慢
    @Published var danmakuDuration: Double {
        didSet {
            UserDefaults.standard.set(danmakuDuration, forKey: "danmaku.duration")
            DanmakuStyle.shared.duration = danmakuDuration
        }
    }
    /// 智能防挡:同一时刻最多上屏条数(限流,避免糊屏)
    @Published var danmakuMaxOnScreen: Int {
        didSet {
            UserDefaults.standard.set(danmakuMaxOnScreen, forKey: "danmaku.maxOnScreen")
            DanmakuStyle.shared.maxOnScreen = danmakuMaxOnScreen
        }
    }
    /// 云屏蔽等级 0-10(按 weight 过滤,0 不屏蔽)
    @Published var danmakuLevel: Int {
        didSet {
            UserDefaults.standard.set(danmakuLevel, forKey: "danmaku.level")
            DanmakuStyle.shared.level = danmakuLevel
        }
    }
    /// 视频编码偏好:auto / hevc / avc
    @Published var codec: String {
        didSet { UserDefaults.standard.set(codec, forKey: "play.codec") }
    }
    @Published var hdr: Bool {
        didSet { UserDefaults.standard.set(hdr, forKey: "play.hdr") }
    }
    /// 杜比数字+ 音轨(视频提供时优先)
    @Published var dolbyAudio: Bool {
        didSet { UserDefaults.standard.set(dolbyAudio, forKey: "play.dolbyAudio") }
    }
    @Published var autoNext: Bool {
        didSet { UserDefaults.standard.set(autoNext, forKey: "play.autoNext") }
    }
    /// 番剧地区受限时走解析服务器
    @Published var roamOn: Bool {
        didSet { UserDefaults.standard.set(roamOn, forKey: "roam.on") }
    }
    /// 自定义解析服务器;空字符串 = 内置默认(界面上不显示默认地址)
    @Published var roamServer: String {
        didSet { UserDefaults.standard.set(roamServer, forKey: "roam.server") }
    }
    /// auto(大陆→港澳→台湾)/ cn / hk / tw
    @Published var roamArea: String {
        didSet { UserDefaults.standard.set(roamArea, forKey: "roam.area") }
    }
    /// 屏蔽词,分号分隔
    @Published var danmakuBlockWords: String {
        didSet {
            UserDefaults.standard.set(danmakuBlockWords, forKey: "danmaku.blockWords")
            DanmakuStyle.shared.blockWords = Self.parseWords(danmakuBlockWords)
        }
    }

    static func parseWords(_ text: String) -> [String] {
        text.split(whereSeparator: { ";；, ，".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private init() {
        extraMirrors = UserDefaults.standard.object(forKey: "cdn.extraMirrors") as? Bool ?? true
        manualPin = UserDefaults.standard.string(forKey: "cdn.manualPin") ?? ""
        preferredQN = UserDefaults.standard.object(forKey: "play.preferredQN") as? Int ?? 0
        danmakuOn = UserDefaults.standard.object(forKey: "play.danmakuOn") as? Bool ?? true
        liveQN = UserDefaults.standard.object(forKey: "play.liveQN") as? Int ?? 10000
        danmakuArea = UserDefaults.standard.object(forKey: "danmaku.area") as? Double ?? 0.5
        danmakuOpacity = UserDefaults.standard.object(forKey: "danmaku.opacity") as? Double ?? 0.85
        danmakuScale = UserDefaults.standard.object(forKey: "danmaku.scale") as? Double ?? 1.0
        danmakuDuration = UserDefaults.standard.object(forKey: "danmaku.duration") as? Double ?? 9.0
        danmakuMaxOnScreen = UserDefaults.standard.object(forKey: "danmaku.maxOnScreen") as? Int ?? 40
        danmakuBlockWords = UserDefaults.standard.string(forKey: "danmaku.blockWords") ?? ""
        danmakuLevel = UserDefaults.standard.object(forKey: "danmaku.level") as? Int ?? 0
        codec = UserDefaults.standard.string(forKey: "play.codec") ?? "auto"
        hdr = UserDefaults.standard.object(forKey: "play.hdr") as? Bool ?? true
        dolbyAudio = UserDefaults.standard.object(forKey: "play.dolbyAudio") as? Bool ?? false
        autoNext = UserDefaults.standard.object(forKey: "play.autoNext") as? Bool ?? true
        roamOn = UserDefaults.standard.object(forKey: "roam.on") as? Bool ?? true
        roamServer = UserDefaults.standard.string(forKey: "roam.server") ?? ""
        roamArea = UserDefaults.standard.string(forKey: "roam.area") ?? "auto"

        let style = DanmakuStyle.shared
        style.area = danmakuArea
        style.opacity = danmakuOpacity
        style.scale = danmakuScale
        style.duration = danmakuDuration
        style.maxOnScreen = danmakuMaxOnScreen
        style.blockWords = Self.parseWords(danmakuBlockWords)
        style.level = danmakuLevel
    }
}

/// 弹幕渲染参数(UIKit 层直接读,避免每帧穿透 SwiftUI)。
final class DanmakuStyle {
    static let shared = DanmakuStyle()
    var area: Double = 0.5
    var opacity: Double = 0.85
    var scale: Double = 1.0
    var duration: Double = 9.0
    var maxOnScreen: Int = 40
    var blockWords: [String] = []
    var level: Int = 0

    private init() {}

    func blocked(_ text: String) -> Bool {
        guard !blockWords.isEmpty else { return false }
        let lower = text.lowercased()
        return blockWords.contains { lower.contains($0.lowercased()) }
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
    /// 多 P 分集
    @Published var pages: [PageInfo] = []
    @Published var currentPageIndex = 0
    /// 播完接下一个:下一 P → 清单下一条 → 番剧下一集 → 相关推荐
    @Published var upNext: UpNext?
    /// 播完后的倒计时(秒),nil 表示没有在倒计时
    @Published var upNextCountdown: Int?
    /// 本次播放卡顿次数
    @Published var stallCount = 0
    /// 本次播放丢帧 / 总帧(AVPlayerItem access log)
    @Published var droppedFrames = 0
    /// 当前清单(外部带入,否则用视频所属的 UGC 合集)
    @Published private(set) var playlist: Playlist?
    @Published private(set) var season: SeasonContext?
    @Published private(set) var comments: CommentListModel?
    /// 当前播放的唯一标识(清单面板高亮用)
    @Published private(set) var bvid = ""
    @Published private(set) var epId: Int?
    var onPlayNext: ((PlayRequest) -> Void)?

    enum UpNext {
        case page(Int, String)
        case video(PlayRequest, String)

        var title: String {
            switch self {
            case .page(_, let title), .video(_, let title): return title
            }
        }
    }

    /// 播放所需的元信息(UGC 来自 view 接口,PGC 来自选集页)。
    private struct Media {
        let aid: Int
        let title: String
        let author: String?
        var duration: Int
    }

    let player = AVPlayer()
    let danmaku = DanmakuManager()
    weak var danmakuOverlay: DanmakuOverlayView?

    private var media: Media?
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
    private var endObserver: NSObjectProtocol?
    private var activeCid: Int?
    private var subtitleTracks: [SubtitleTrack] = []
    private var subtitleFiles: [Int: URL] = [:]
    private var stallObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var probeTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var pendingQN: Int?
    private var recoveryAttempt = 0
    private var lastRecoveryAt = Date.distantPast
    private var countdownTask: Task<Void, Never>?
    private var playbackEnded = false
    private var triedAvc = false
    private var currentVideoCodec: String?

    var totalSeconds: Double { Double(media?.duration ?? 0) }
    /// 本地进度的键:PGC 按 ep,UGC 按 bvid
    private var progressKey: String { epId.map { "ep\($0)" } ?? bvid }

    func heat(_ buckets: Int) -> [Int] { danmaku.heatBuckets(buckets) }

    // MARK: - 加载

    func load(_ request: PlayRequest) async {
        bvid = request.bvid
        epId = request.episode?.epId
        season = request.season
        playlist = request.playlist
        upNext = nil
        cancelUpNext()
        playbackEnded = false
        triedAvc = false
        stallCount = 0
        droppedFrames = 0
        danmakuEnabled = CDNSettings.shared.danmakuOn
        do {
            state = .loading("正在解析视频…")
            let cid: Int
            if let episode = request.episode {
                guard episode.cid > 0 else { throw BiliError.notPlayable("这一集缺少播放信息") }
                media = Media(aid: episode.aid, title: episode.title, author: nil, duration: episode.duration)
                pages = []
                currentPageIndex = 0
                cid = episode.cid
            } else {
                let detail = try await VideoAPI.detail(bvid: request.bvid)
                let list = detail.pages ?? []
                let index = list.indices.contains(request.pageIndex) ? request.pageIndex : 0
                media = Media(
                    aid: detail.aid,
                    title: detail.title,
                    author: detail.owner?.name,
                    duration: list.isEmpty ? (detail.duration ?? 0) : (list[index].duration ?? detail.duration ?? 0)
                )
                pages = list
                currentPageIndex = index
                cid = list.isEmpty ? detail.cid : list[index].cid
                if playlist == nil { playlist = Playlist(ugcSeasonOf: detail) }
                if let playlist, playlist.sections == nil {
                    let aid = detail.aid
                    Task { try? await playlist.ensureLoaded(startAid: aid) }
                }
            }
            guard let media else { return }
            videoTitle = media.title
            activeCid = cid
            comments = media.aid > 0 ? CommentListModel(oid: media.aid) : nil
            danmaku.configure(cid: cid, aid: media.aid, duration: Double(media.duration))
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
                let play = try await VideoAPI.playURL(bvid: request.bvid, cid: cid)
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

            try await buildPipeline(seekTo: await resumeTime(aid: media.aid, cid: cid, duration: media.duration))
        } catch {
            fail(error)
        }
    }

    /// 续播位置:服务端进度(跨设备)优先,本地记录兜底;开头/结尾不续播。
    private func resumeTime(aid: Int, cid: Int, duration: Int) async -> CMTime? {
        var resume = 0.0
        if BiliClient.shared.csrf != nil, aid > 0,
           let v2: PlayerV2Data = try? await VideoAPI.playerV2(aid: aid, cid: cid),
           let ms = v2.lastPlayTime, ms > 0 {
            resume = Double(ms) / 1000
        }
        if resume <= 0 {
            resume = ProgressStore.load(bvid: progressKey) ?? 0
        }
        let duration = Double(duration)
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
        guard let cid = activeCid else { return }
        teardownPipeline()
        state = .loading("正在获取播放地址…")
        // PGC 剧集优先走官方 ep_id 链路(大会员/地区授权由该接口判定,错误码更准确)
        let play: PlayURLData
        if let epId {
            play = try await BangumiAPI.playURL(epId: epId, cid: cid)
        } else {
            play = try await VideoAPI.playURLDash(bvid: bvid, cid: cid)
        }
        let labels = play.qualityLabels
        if let dash = play.dash, let video = Self.pickVideo(dash.video ?? [], targetQN: targetQN, forceAvc: triedAvc) {
            try await buildDash(dash: dash, video: video, labels: labels, seekTo: seekTo)
        } else if let durl = play.durl?.first {
            try await buildDurl(play: play, durl: durl, labels: labels, seekTo: seekTo)
        } else {
            throw BiliError.notPlayable("接口未返回可用播放地址")
        }
    }

    // MARK: - 轨道选择

    /// 可播轨过滤:Apple TV 不支持 AV1 硬解,杜比视界(dvh1)容器要求也不同,均剔除。
    /// HDR(125)、4K(120)、8K(127)保留 —— tvOS 4K 机型支持 HEVC Main10 HDR。
    static func isPlayable(_ track: DashTrack) -> Bool {
        guard track.baseUrl != nil, Sidx.parseRange(track.segmentBase?.indexRange) != nil else { return false }
        if track.id == 125, !CDNSettings.shared.hdr { return false }
        let codec = (track.codecs ?? "").lowercased()
        return !codec.hasPrefix("av01") && !codec.hasPrefix("dvh") && !codec.hasPrefix("dav1")
    }

    static func pickVideo(_ tracks: [DashTrack], targetQN: Int, forceAvc: Bool = false) -> DashTrack? {
        func isAvc(_ track: DashTrack) -> Bool { (track.codecs ?? "").lowercased().hasPrefix("avc") }
        func isHevc(_ track: DashTrack) -> Bool {
            let codec = (track.codecs ?? "").lowercased()
            return codec.hasPrefix("hvc") || codec.hasPrefix("hev")
        }
        var usable = tracks.filter(isPlayable)
        // HEVC 解码失败后的兜底:只在 AVC 轨里选(清晰度可能因此降到 AVC 的上限)
        if forceAvc, usable.contains(where: isAvc) { usable = usable.filter(isAvc) }
        let ids = Set(usable.map(\.id))
        guard !ids.isEmpty else { return nil }
        let chosen = ids.filter { $0 <= targetQN }.max() ?? ids.min()!
        let same = usable.filter { $0.id == chosen }
        // HDR / 8K 只有 HEVC 编码;其余按偏好,auto 时优先 HEVC
        if CDNSettings.shared.codec == "avc", let avc = same.first(where: isAvc) { return avc }
        return same.first(where: isHevc) ?? same.first
    }

    /// 音轨:开了杜比音效且视频提供时优先杜比数字+(在 dash.dolby.audio 里);否则 AAC。
    /// 无损 FLAC(30251)在 fMP4-HLS 里不被支持。
    static func pickAudio(_ dash: DashData) -> DashTrack? {
        func hasIndex(_ track: DashTrack) -> Bool {
            track.baseUrl != nil && Sidx.parseRange(track.segmentBase?.indexRange) != nil
        }
        if CDNSettings.shared.dolbyAudio,
           let dolby = dash.dolby?.audio?.first(where: { hasIndex($0) && ($0.codecs ?? "").lowercased().hasPrefix("ec-3") }) {
            return dolby
        }
        return (dash.audio ?? [])
            .filter { hasIndex($0) && ($0.codecs ?? "").lowercased().hasPrefix("mp4a") }
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
        if let audio = Self.pickAudio(dash),
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

        // 字幕(登录后可用):下载转 WebVTT,作为独立字幕轨挂进 master
        var subtitles: [(track: SubtitleTrack, path: String)] = []
        if BiliClient.shared.csrf != nil {
            subtitles = await prepareSubtitles(aid: media?.aid ?? 0, cid: activeCid ?? 0)
            let duration = Double(media?.duration ?? 0)
            for item in subtitles {
                if let vtt = subtitleVTTs[item.path] {
                    server.setRoute(item.path, .text(content: vtt, mime: "text/vtt"))
                    server.setRoute(
                        item.path + ".m3u8",
                        .playlist(HLSBuilder.subtitlePlaylist(base: base, path: item.path, duration: duration))
                    )
                }
            }
        }

        server.setRoute(
            HLSBuilder.masterPath,
            .playlist(HLSBuilder.master(base: base, video: video, audio: audioTrack, subtitles: subtitles))
        )

        guard let url = URL(string: base + HLSBuilder.masterPath) else {
            throw BiliError.badURL
        }
        attachItem(asset: AVURLAsset(url: url), seekTo: seekTo)

        currentQN = video.id
        currentVideoCodec = video.codecs
        qualityName = labels[video.id] ?? QualityLabel.name(video.id)
        let switchable = Set((dash.video ?? []).filter(Self.isPlayable).map(\.id))
        availableQualities = switchable.sorted(by: >).map {
            QualityOption(qn: $0, label: labels[$0] ?? QualityLabel.name($0))
        }
        startBackgroundProbe()
        startPeriodicProbe()
        Task { [weak self] in await self?.prepareUpNext() }
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
        currentVideoCodec = nil
        qualityName = labels[currentQN] ?? QualityLabel.name(currentQN)
        availableQualities = (play.acceptQuality ?? [])
            .filter { $0 <= 80 }
            .map { QualityOption(qn: $0, label: labels[$0] ?? QualityLabel.name($0)) }
        startBackgroundProbe()
        startPeriodicProbe()
        Task { [weak self] in await self?.prepareUpNext() }
    }

    // MARK: - AVPlayer 装配

    private func attachItem(asset: AVURLAsset, seekTo: CMTime?) {
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 30
        item.externalMetadata = Self.metadata(title: media?.title ?? videoTitle, author: media?.author)

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor [weak self] in
                switch observed.status {
                case .readyToPlay:
                    self?.state = .playing
                case .failed:
                    self?.handleItemFailure(observed.error)
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
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handlePlaybackEnded() }
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
                self.updateFrameStats()
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

    /// 解码器/容器不兼容时自动降级到 AVC 再试一次。
    private func handleItemFailure(_ error: Error?) {
        let codec = (currentVideoCodec ?? "").lowercased()
        if !triedAvc, !codec.isEmpty, !codec.hasPrefix("avc") {
            triedAvc = true
            resumeNotice = "当前编码播放失败,自动切换 AVC 重试"
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self?.resumeNotice = nil
            }
            rebuildKeepingPosition()
            return
        }
        state = .failed(error?.localizedDescription ?? "播放失败")
    }

    private func updateFrameStats() {
        guard let dropped = player.currentItem?.accessLog()?.events.reduce(0, { $0 + max(0, $1.numberOfDroppedVideoFrames) }),
              dropped != droppedFrames else { return }
        droppedFrames = dropped
    }

    /// 本地每 5 秒落盘;登录态每 15 秒上报 B 站(历史进度 / 跨设备续播)。
    private func recordProgress(_ seconds: Double) {
        guard seconds > 5, player.rate > 0 else { return }
        if abs(seconds - lastLocalSave) > 5 {
            lastLocalSave = seconds
            ProgressStore.save(bvid: progressKey, seconds: seconds)
        }
        if BiliClient.shared.csrf != nil,
           Date().timeIntervalSince(lastReportAt) > 15,
           let media, media.aid > 0, let cid = activeCid {
            lastReportAt = Date()
            let aid = media.aid
            Task.detached {
                try? await ActionAPI.reportHistory(aid: aid, cid: cid, progress: Int(seconds))
            }
        }
    }

    // MARK: - 多 P / 连播 / 字幕

    /// 切换分 P(换 cid 重建管线,弹幕同步换轨)。
    func switchPage(_ index: Int) {
        guard index >= 0, index < pages.count, index != currentPageIndex, let aid = media?.aid else { return }
        currentPageIndex = index
        activeCid = pages[index].cid
        if let duration = pages[index].duration { media?.duration = duration }
        playbackEnded = false
        cancelUpNext()
        danmaku.configure(cid: pages[index].cid, aid: aid, duration: Double(media?.duration ?? 0))
        danmakuOverlay?.clear()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.buildPipeline(seekTo: nil)
            } catch {
                self.fail(error)
            }
        }
    }

    /// 换到同一季的另一集。
    func switchEpisode(_ episode: SeasonEpisodeRef) {
        onPlayNext?(PlayRequest(bvid: episode.bvid, episode: episode, season: season))
    }

    /// 换到清单里的另一条。
    func playItem(_ item: PlaylistItem) {
        guard item.bvid != bvid else { return }
        onPlayNext?(PlayRequest(bvid: item.bvid, playlist: playlist))
    }

    private func prepareUpNext() async {
        upNext = await computeUpNext()
    }

    /// 播完后的下一个:下一 P → 清单下一条 → 番剧下一集 → 相关推荐。
    private func computeUpNext() async -> UpNext? {
        if currentPageIndex + 1 < pages.count {
            let next = pages[currentPageIndex + 1]
            return .page(currentPageIndex + 1, "P\(next.page) \(next.part ?? "")")
        }
        if let playlist {
            try? await playlist.ensureLoaded(startAid: media?.aid)
            if let next = await playlist.next(after: bvid) {
                return .video(PlayRequest(bvid: next.bvid, playlist: playlist), "\(playlist.kind)下一集:\(next.title)")
            }
            return nil
        }
        if let season, let epId {
            guard let index = season.episodes.firstIndex(where: { $0.epId == epId }),
                  index + 1 < season.episodes.count else { return nil }
            let next = season.episodes[index + 1]
            return .video(PlayRequest(bvid: next.bvid, episode: next, season: season), next.title)
        }
        if epId == nil, let related = try? await VideoAPI.related(bvid: bvid), let first = related.first {
            return .video(PlayRequest(bvid: first.bvid), first.title)
        }
        return nil
    }

    private func handlePlaybackEnded() {
        playbackEnded = true
        // 看完上报 -1(B 站约定:已看完)
        if BiliClient.shared.csrf != nil, let media, media.aid > 0, let cid = activeCid {
            let aid = media.aid
            Task.detached {
                try? await ActionAPI.reportHistory(aid: aid, cid: cid, progress: -1)
            }
        }
        guard CDNSettings.shared.autoNext, upNext != nil else { return }
        countdownTask?.cancel()
        upNextCountdown = 5
        countdownTask = Task { [weak self] in
            for left in stride(from: 4, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if left == 0 {
                    self.playUpNextNow()
                } else {
                    self.upNextCountdown = left
                }
            }
        }
    }

    func cancelUpNext() {
        countdownTask?.cancel()
        countdownTask = nil
        upNextCountdown = nil
    }

    func playUpNextNow() {
        cancelUpNext()
        switch upNext {
        case .page(let index, _):
            switchPage(index)
        case .video(let request, _):
            onPlayNext?(request)
        case nil:
            break
        }
    }

    /// 下载字幕并挂到播放列表(仅 HLS 管线;登录后 player/v2 才返回字幕)。
    private func prepareSubtitles(aid: Int, cid: Int) async -> [(track: SubtitleTrack, path: String)] {
        guard let v2 = try? await VideoAPI.playerV2(aid: aid, cid: cid),
              let tracks = v2.subtitle?.subtitles, !tracks.isEmpty else { return [] }
        var out: [(SubtitleTrack, String)] = []
        for (index, track) in tracks.prefix(3).enumerated() {
            guard let vtt = await VideoAPI.subtitleVTT(from: track) else { continue }
            out.append((track, "/subtitle-\(index).vtt"))
            subtitleVTTs["/subtitle-\(index).vtt"] = vtt
        }
        subtitleTracks = out.map(\.0)
        return out.map { (track: $0.0, path: $0.1) }
    }

    private var subtitleVTTs: [String: String] = [:]

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
        stallCount += 1
        videoEngine?.noteStall()
        mp4Engine?.noteStall()
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
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
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
        cancelUpNext()
        // 退出时保存最终进度并上报;已看完的不再覆盖 -1
        let finalSeconds = player.currentTime().seconds
        if finalSeconds.isFinite, finalSeconds > 5 {
            ProgressStore.save(bvid: progressKey, seconds: finalSeconds)
            if !playbackEnded, BiliClient.shared.csrf != nil, let media, media.aid > 0, let cid = activeCid {
                let aid = media.aid
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
