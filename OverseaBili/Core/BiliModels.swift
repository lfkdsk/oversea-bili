import Foundation

struct BiliResponse<T: Decodable>: Decodable {
    let code: Int
    let message: String?
    let data: T?
}

// MARK: - 登录

struct QRGenerateData: Decodable {
    let url: String
    let qrcodeKey: String
}

struct QRPollData: Decodable {
    let url: String?
    let refreshToken: String?
    let code: Int
    let message: String?
}

enum QRLoginState: Equatable {
    case waitingScan
    case scannedWaitingConfirm
    case expired
    case success
}

struct WbiImg: Decodable {
    let imgUrl: String?
    let subUrl: String?
}

struct NavData: Decodable {
    let isLogin: Bool
    let uname: String?
    let face: String?
    let mid: Int?
    let wbiImg: WbiImg?
    /// 请求出口地区(用于 CDN 测速缓存分区)
    let ipRegion: String?
}

struct SpiData: Decodable {
    let b3: String
    let b4: String?
}

// MARK: - 视频列表

struct Owner: Decodable, Hashable {
    let mid: Int?
    let name: String?
    let face: String?
}

struct Stat: Decodable, Hashable {
    let view: Int?
    let danmaku: Int?
    let like: Int?
    var reply: Int? = nil
    var coin: Int? = nil
    var favorite: Int? = nil
}

struct VideoItem: Decodable, Identifiable, Hashable {
    let aid: Int?
    let bvid: String
    let cid: Int?
    let title: String
    let pic: String?
    let duration: Int?
    let owner: Owner?
    let stat: Stat?

    var id: String { bvid }
}

struct PopularData: Decodable {
    let list: [VideoItem]
    let noMore: Bool?
}

struct RcmdData: Decodable {
    let item: [VideoItem]?
}

// MARK: - 搜索增强

struct SearchSquareData: Decodable {
    let trending: Trending?

    struct Trending: Decodable {
        let list: [Item]?
        struct Item: Decodable { let keyword: String?; let showName: String? }
    }
}

/// s.search.bilibili.com/main/suggest 的响应(不是标准 BiliResponse 包装)。
struct SuggestResponse: Decodable {
    let result: Result?
    struct Result: Decodable {
        let tag: [Tag]?
        struct Tag: Decodable { let value: String?; let name: String? }
    }
}

/// 搜索里的番剧结果(search_type=media_bangumi)。
struct SearchMedia: Decodable, Identifiable {
    let seasonId: Int?
    let title: String?
    let cover: String?
    let seasonTypeName: String?
    let areas: String?
    let styles: String?

    var id: Int { seasonId ?? Int.random(in: Int.min...(-1)) }
    var cleanTitle: String {
        (title ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
    var coverURL: String? {
        guard let cover, !cover.isEmpty else { return nil }
        return cover.hasPrefix("//") ? "https:" + cover : cover
    }
}

/// 搜索里的 UP 主结果(search_type=bili_user)。
struct SearchUser: Decodable, Identifiable {
    let mid: Int?
    let uname: String?
    let upic: String?
    let fans: Int?
    let videos: Int?

    var id: Int { mid ?? Int.random(in: Int.min...(-1)) }
    var faceURL: String? {
        guard let upic, !upic.isEmpty else { return nil }
        return upic.hasPrefix("//") ? "https:" + upic : upic
    }
}

struct SearchMediaData: Decodable {
    let result: [SearchMedia]?
    var numPages: Int? = nil
}

struct SearchUserData: Decodable {
    let result: [SearchUser]?
    var numPages: Int? = nil
}

// MARK: - 直播分区

struct LiveAreaListData: Decodable {
    let data: [LiveParentArea]?
}

struct LiveParentArea: Decodable, Identifiable {
    let id: Int
    let name: String?
    let list: [LiveArea]?
}

/// 注意:子分区的 id / parent_id 在 JSON 里是字符串。
struct LiveArea: Decodable, Identifiable {
    let id: Int
    let parentId: Int
    let name: String?
    let pic: String?

    enum CodingKeys: String, CodingKey {
        case id, parentId, name, pic
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(Int.self, forKey: .id) {
            id = value
        } else {
            id = Int((try? container.decode(String.self, forKey: .id)) ?? "") ?? -1
        }
        if let value = try? container.decode(Int.self, forKey: .parentId) {
            parentId = value
        } else {
            parentId = Int((try? container.decode(String.self, forKey: .parentId)) ?? "") ?? -1
        }
        name = try? container.decode(String.self, forKey: .name)
        pic = try? container.decode(String.self, forKey: .pic)
    }
}

struct LiveAreaRoomsData: Decodable {
    let list: [LiveRoom]?
    let hasMore: Int?
}

// MARK: - 番剧时间表

struct TimelineDay: Decodable, Identifiable {
    let date: String?
    let dateTs: Int?
    let dayOfWeek: Int?
    let isToday: Int?
    let episodes: [TimelineEpisode]?

    var id: String { date ?? UUID().uuidString }
    var today: Bool { isToday == 1 }
}

struct TimelineEpisode: Decodable, Identifiable {
    let episodeId: Int?
    let seasonId: Int?
    let title: String?
    let pubIndex: String?
    let pubTime: String?
    let cover: String?
    let squareCover: String?
    let published: Int?
    let follows: String?

    var id: Int { episodeId ?? Int.random(in: Int.min...(-1)) }
    var isPublished: Bool { published == 1 }
}

// MARK: - 搜索

struct SearchTypeData: Decodable {
    let result: [SearchItem]?
    let numResults: Int?
    var numPages: Int? = nil
}

struct SearchItem: Decodable, Identifiable, Hashable {
    let bvid: String?
    let title: String?
    let pic: String?
    let author: String?
    let play: Int?
    let duration: String?

    var id: String { bvid ?? UUID().uuidString }

    /// 搜索标题里带 <em class="keyword"> 高亮标签,展示前去掉。
    var cleanTitle: String {
        (title ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    /// 搜索接口的封面不带协议头(//i0.hdslb.com/...)。
    var picURL: String? {
        guard let pic else { return nil }
        if pic.hasPrefix("//") { return "https:" + pic }
        return pic
    }
}

// MARK: - 视频详情 / 播放地址

struct PageInfo: Decodable, Hashable {
    let cid: Int
    let page: Int
    let part: String?
    var duration: Int? = nil
}

/// 单个字段解析失败时置空,不让整个外层结构报错(合集等附加信息结构不稳定)。
struct Lossy<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

/// view 接口里的 UGC 合集(分节、全部剧集)。
struct UgcSeason: Decodable {
    struct Section: Decodable {
        let title: String?
        let episodes: LossyArray<Episode>?
    }

    struct Episode: Decodable {
        struct Arc: Decodable {
            let pic: String?
            let duration: Int?
            let author: Owner?
            let stat: Stat?
        }

        let aid: Int?
        let bvid: String?
        let title: String?
        let arc: Arc?
    }

    let title: String?
    let sections: LossyArray<Section>?
}

struct ViewData: Decodable {
    let bvid: String
    let aid: Int
    let cid: Int
    let title: String
    let desc: String?
    let pic: String?
    let duration: Int?
    let pubdate: Int?
    let owner: Owner?
    let stat: Stat?
    let pages: [PageInfo]?
    var ugcSeason: Lossy<UgcSeason>? = nil
    /// 番剧 bvid 的详情带跳转地址(/bangumi/play/epXXX)
    var redirectUrl: String? = nil

    var redirectEpId: Int? {
        guard let redirectUrl,
              let range = redirectUrl.range(of: #"/bangumi/play/ep\d+"#, options: .regularExpression) else { return nil }
        return Int(redirectUrl[range].dropFirst("/bangumi/play/ep".count))
    }
}

// MARK: - UP 空间(投稿列表)

struct SpaceArcData: Decodable {
    let list: SpaceArcList?
}

struct SpaceArcList: Decodable {
    let vlist: [SpaceVideo]?
}

struct SpaceVideo: Decodable, Identifiable {
    let aid: Int?
    let bvid: String?
    let title: String?
    let pic: String?
    /// "mm:ss" 字符串
    let length: String?
    /// 数字或 "--"
    let play: FlexString?
    let created: Int?

    var id: String { bvid ?? UUID().uuidString }
}

struct RelationStatData: Decodable {
    let follower: Int?
}

/// UP 空间页统一行(arc/search 与动态兜底都映射到它)。
struct UpVideoRow: Identifiable {
    let id: String
    let bvid: String
    let title: String
    let cover: String?
    let subtitle: String
    let duration: String
}

/// x/player/wbi/v2:续播进度(毫秒)+ 字幕列表。
struct PlayerV2Data: Decodable {
    let lastPlayTime: Int?
    let lastPlayCid: Int?
    let subtitle: SubtitleInfo?

    struct SubtitleInfo: Decodable {
        let subtitles: [SubtitleTrack]?
    }
}

struct SubtitleTrack: Decodable, Identifiable {
    let id: Int?
    let lan: String?
    let lanDoc: String?
    let subtitleUrl: String?
    /// AI 生成字幕标记
    let type: Int?

    var identifier: String { lan ?? String(id ?? 0) }
    var url: String? {
        guard var raw = subtitleUrl, !raw.isEmpty else { return nil }
        if raw.hasPrefix("//") { raw = "https:" + raw }
        return raw
    }
}

/// 字幕 JSON(bilibili 自有格式)。
struct SubtitleDoc: Decodable {
    let body: [Line]?

    struct Line: Decodable {
        let from: Double?
        let to: Double?
        let content: String?
    }
}

// MARK: - Cookie 续期

struct CookieInfoData: Decodable {
    let refresh: Bool?
    let timestamp: Int?
}

struct CookieRefreshData: Decodable {
    let status: Int?
    let message: String?
    let refreshToken: String?
}

struct RelationData: Decodable {
    /// 0 未关注 / 1 悄悄关注 / 2 已关注 / 6 互关
    let attribute: Int?
}

struct Durl: Decodable {
    let order: Int?
    let length: Int?
    let size: Int?
    let url: String
    let backupUrl: [String]?
}

struct DashSegmentBase: Decodable {
    let initialization: String?
    let indexRange: String?
}

struct DashTrack: Decodable {
    let id: Int
    let baseUrl: String?
    let backupUrl: [String]?
    let bandwidth: Int?
    let codecs: String?
    let width: Int?
    let height: Int?
    let frameRate: String?
    let segmentBase: DashSegmentBase?
    let codecid: Int?
}

struct DashData: Decodable {
    struct Dolby: Decodable {
        let audio: [DashTrack]?
    }

    let duration: Int?
    let video: [DashTrack]?
    let audio: [DashTrack]?
    var dolby: Dolby? = nil
}

struct PlayURLData: Decodable {
    let quality: Int?
    let format: String?
    let timelength: Int?
    let acceptQuality: [Int]?
    let acceptDescription: [String]?
    let durl: [Durl]?
    let dash: DashData?

    /// qn → 描述("高清 1080P" 等)
    var qualityLabels: [Int: String] {
        var map: [Int: String] = [:]
        for (qn, desc) in zip(acceptQuality ?? [], acceptDescription ?? []) {
            map[qn] = desc
        }
        return map
    }
}

// MARK: - 关注动态(登录后)

/// 消费掉任意 JSON 值(用于 LossyArray 跳过坏元素)。
struct AnyIgnore: Decodable {
    init(from decoder: Decoder) throws {}
}

/// 数组容错解码:单个元素解析失败就跳过,不让整个数组报错。
/// polymer 动态流里混着直播/图文/转发等多种动态类型,结构不稳定。
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !container.isAtEnd {
            if let value = try? container.decode(Element.self) {
                out.append(value)
            } else {
                _ = try? container.decode(AnyIgnore.self)
            }
        }
        elements = out
    }
}

/// 兼容 string / int 混用的字段。
struct FlexString: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            value = s
        } else if let i = try? container.decode(Int.self) {
            value = String(i)
        } else {
            value = nil
        }
    }
}

struct DynFeedData: Decodable {
    let items: [DynItem]?
    let hasMore: Bool?
    let offset: String?

    enum CodingKeys: String, CodingKey {
        case items, hasMore, offset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? container.decode(LossyArray<DynItem>.self, forKey: .items))?.elements
        hasMore = try? container.decode(Bool.self, forKey: .hasMore)
        offset = try? container.decode(String.self, forKey: .offset)
    }
}

struct DynItem: Decodable, Identifiable {
    let idStr: String?
    let modules: DynModules?

    var id: String { idStr ?? UUID().uuidString }
    var archive: DynArchive? { modules?.moduleDynamic?.major?.archive }
    var authorName: String? { modules?.moduleAuthor?.name }
    var pubTime: String? { modules?.moduleAuthor?.pubTime }
}

struct DynModules: Decodable {
    let moduleAuthor: DynAuthor?
    let moduleDynamic: DynDynamic?
}

struct DynAuthor: Decodable {
    let name: String?
    let face: String?
    let pubTime: String?
}

struct DynDynamic: Decodable {
    let major: DynMajor?
}

struct DynMajor: Decodable {
    let type: String?
    let archive: DynArchive?
}

struct DynArchive: Decodable {
    let aid: Int?
    let bvid: String?
    let title: String?
    let cover: String?
    let durationText: String?
    let stat: DynStat?

    enum CodingKeys: String, CodingKey {
        case aid, bvid, title, cover, durationText, stat
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // polymer 接口的 aid 有时是数字有时是字符串
        if let value = try? container.decode(Int.self, forKey: .aid) {
            aid = value
        } else if let text = try? container.decode(String.self, forKey: .aid) {
            aid = Int(text)
        } else {
            aid = nil
        }
        bvid = try? container.decode(String.self, forKey: .bvid)
        title = try? container.decode(String.self, forKey: .title)
        cover = try? container.decode(String.self, forKey: .cover)
        durationText = try? container.decode(String.self, forKey: .durationText)
        stat = try? container.decode(DynStat.self, forKey: .stat)
    }
}

struct DynStat: Decodable {
    let play: FlexString?
    let danmaku: FlexString?
}

/// 动态页顶部的"最近关注 UP"列表(portal 接口)。
struct PortalData: Decodable {
    let upList: [DynUpItem]?
}

struct DynUpItem: Decodable, Identifiable {
    let mid: Int?
    let uname: String?
    let face: String?
    let hasUpdate: Bool?

    var id: Int { mid ?? -1 }
}

/// 动态 tab 的统一行模型(polymer 新接口与 legacy 老接口都映射到它)。
struct DynVideoRow: Identifiable {
    let id: String
    let bvid: String
    let title: String
    let cover: String?
    let durationText: String
    let authorName: String
    let pubTime: String
}

extension DynVideoRow {
    init?(polymer item: DynItem) {
        guard let archive = item.archive, let bvid = archive.bvid, bvid.hasPrefix("BV") else { return nil }
        self.init(
            id: item.id,
            bvid: bvid,
            title: archive.title ?? "",
            cover: archive.cover,
            durationText: archive.durationText ?? "",
            authorName: item.authorName ?? "",
            pubTime: item.pubTime ?? ""
        )
    }
}

// 老版动态接口(api.vc.bilibili.com dynamic_new),作为 polymer 风控/变更时的兜底
struct LegacyDynData: Decodable {
    let cards: [LegacyDynCard]?
}

struct LegacyDynCard: Decodable {
    let desc: Desc?
    let card: String?

    struct Desc: Decodable {
        let dynamicIdStr: String?
        let timestamp: Int?
        let bvid: String?
        let userProfile: Profile?

        struct Profile: Decodable {
            let info: Info?
            struct Info: Decodable { let uname: String? }
        }
    }
}

struct LegacyArchiveCard: Decodable {
    let aid: Int?
    let title: String?
    let pic: String?
    let duration: Int?
    let owner: Owner?
}

// MARK: - 我的(历史 / 稍后再看 / 收藏)

struct HistoryCursorData: Decodable {
    struct Cursor: Decodable {
        let max: Int?
        let viewAt: Int?
    }

    let list: [HistoryItem]?
    var cursor: Cursor? = nil
}

struct HistoryItem: Decodable, Identifiable {
    struct Key: Decodable {
        let bvid: String?
        let business: String?
    }

    let title: String?
    let cover: String?
    let authorName: String?
    let duration: Int?
    let progress: Int?
    let history: Key?

    var id: String { history?.bvid ?? UUID().uuidString }
    var bvid: String? { history?.bvid }
}

struct ToViewData: Decodable {
    let list: [VideoItem]?
}

struct FavResourceData: Decodable {
    let medias: [FavMedia]?
    var hasMore: Bool? = nil
}

struct FavMedia: Decodable, Identifiable {
    struct Upper: Decodable { let name: String? }
    struct CntInfo: Decodable { let play: Int? }

    let id: Int
    let bvid: String?
    let title: String?
    let cover: String?
    let duration: Int?
    let upper: Upper?
    let cntInfo: CntInfo?
}

// MARK: - 直播

struct LiveFollowData: Decodable {
    let list: [LiveRoom]?
}

struct LiveRecommendData: Decodable {
    let recommendRoomList: [LiveRoom]?
}

struct LiveRoom: Decodable, Identifiable {
    let roomid: Int?
    let uid: Int?
    let uname: String?
    let title: String?
    let face: String?
    let cover: String?
    let keyframe: String?
    let userCover: String?
    /// user/following 接口的封面字段
    let coverFromUser: String?
    let roomCover: String?
    let liveStatus: Int?
    let online: Int?
    let watchingShow: WatchingShow?

    struct WatchingShow: Decodable { let numText: String? }

    var id: Int { roomid ?? Int.random(in: Int.min...(-1)) }
    /// 多来源封面字段取第一个非空,最后用主播头像兜底。
    var coverURL: String? {
        for candidate in [keyframe, coverFromUser, roomCover, userCover, cover, face] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }
    var isLiving: Bool { liveStatus == nil || liveStatus == 1 }
}

struct DanmuInfoData: Decodable {
    let token: String?
    let hostList: [DanmuHost]?

    struct DanmuHost: Decodable {
        let host: String?
        let wssPort: Int?
    }
}

struct LiveQuality: Identifiable, Hashable {
    let qn: Int
    let desc: String
    var id: Int { qn }
}

struct RoomPlayData: Decodable {
    let playurlInfo: PlayurlInfo?

    struct PlayurlInfo: Decodable { let playurl: Playurl? }
    struct Playurl: Decodable {
        let stream: [Stream]?
        /// 全部可用清晰度(杜比/4K/2K/原画/蓝光/超清/高清/流畅)
        let gQnDesc: [QnDesc]?
    }
    struct QnDesc: Decodable {
        let qn: Int?
        let desc: String?
    }
    struct Stream: Decodable {
        let protocolName: String?
        let format: [Format]?
    }
    struct Format: Decodable {
        let formatName: String?
        let codec: [Codec]?
    }
    struct Codec: Decodable {
        let codecName: String?
        let currentQn: Int?
        let baseUrl: String?
        let urlInfo: [URLInfo]?
    }
    struct URLInfo: Decodable {
        let host: String?
        let extra: String?
    }
}

// MARK: - 番剧 / 剧集(PGC,响应包装是 result 而非 data)

struct PGCResponse<T: Decodable>: Decodable {
    let code: Int
    let message: String?
    let result: T?
}

struct BangumiFollowData: Decodable {
    let list: [BangumiSeason]?
}

struct BangumiSeason: Decodable, Identifiable {
    let seasonId: Int?
    let title: String?
    let cover: String?
    let newEp: NewEp?
    let progress: String?

    struct NewEp: Decodable { let indexShow: String? }

    var id: Int { seasonId ?? Int.random(in: Int.min...(-1)) }
}

/// pgc/player/web/v2/playurl 的包装(真正数据在 video_info)。
struct PGCPlayURLResult: Decodable {
    let videoInfo: PlayURLData?
}

struct SeasonDetail: Decodable {
    struct Rating: Decodable { let score: Double? }
    struct Stats: Decodable { let views: Int? }
    struct NewEp: Decodable { let desc: String? }

    struct Section: Decodable {
        let title: String?
        let episodes: LossyArray<Episode>?
    }

    let title: String?
    let episodes: [Episode]?
    var cover: String? = nil
    var evaluate: String? = nil
    var seasonTitle: String? = nil
    var rating: Rating? = nil
    var stat: Stats? = nil
    var newEp: NewEp? = nil
    var section: LossyArray<Section>? = nil

    struct Episode: Decodable, Identifiable {
        /// ep_id(PGC 播放链路用)
        let id: Int
        let bvid: String?
        let cid: Int?
        let cover: String?
        let title: String?
        let longTitle: String?
        let badge: String?
        var aid: Int? = nil
        /// 毫秒
        var duration: Int? = nil

        /// 需要大会员
        var isVip: Bool { (badge ?? "").contains("会员") }
        /// "第 1 话 标题" 形式的展示名
        var displayName: String {
            let index = title.map { "第\($0)话" } ?? ""
            let name = longTitle ?? ""
            return [index, name].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }
}

struct SeriesMeta: Decodable {
    let number: Int?
}

struct SeriesListData: Decodable {
    let list: [SeriesMeta]?
}
