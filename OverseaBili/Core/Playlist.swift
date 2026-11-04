import Foundation

// 播放清单:UGC 合集(view.ugc_season,分节全集)/ UP 主系列与合集 / 收藏夹 / 稍后再看。
// 后几种统一走 medialist 接口(x/v2/medialist/resource/list),type:
//   1 UP 投稿(biz_id = mid)/ 2 稍后再看(biz_id = 自己的 mid)/ 3 收藏夹(biz_id = media_id)/ 5 系列 / 8 合集

struct PlaylistItem: Identifiable, Hashable {
    let bvid: String
    let aid: Int
    let title: String
    let cover: String?
    let duration: Int
    let author: String
    let views: Int?

    var id: String { bvid }
}

struct PlaylistSection: Identifiable {
    let title: String
    let items: [PlaylistItem]

    var id: String { title + (items.first?.bvid ?? "") }
}

/// UP 空间里的一个合集或系列。
struct UpCollection: Identifiable {
    let mlType: Int
    let bizId: Int
    let label: String
    let title: String
    let cover: String?
    let total: Int

    var id: String { "\(mlType)-\(bizId)" }
}

struct MediaListData: Decodable {
    struct Media: Decodable {
        struct Upper: Decodable { let name: String? }
        struct CntInfo: Decodable { let play: Int? }

        let id: Int?
        let type: Int?
        let title: String?
        let cover: String?
        let duration: Int?
        let bvId: String?
        let bvid: String?
        let upper: Upper?
        let cntInfo: CntInfo?
    }

    let mediaList: LossyArray<Media>?
    let hasMore: Bool?
    let totalCount: Int?
}

struct SpaceCardData: Decodable {
    struct Card: Decodable {
        let name: String?
        let face: String?
        let sign: String?
    }

    let card: Card?
    let follower: Int?
    let archiveCount: Int?
}

struct SeasonsSeriesData: Decodable {
    struct Lists: Decodable {
        let seasonsList: [Entry]?
        let seriesList: [Entry]?
    }

    struct Entry: Decodable { let meta: Meta? }

    struct Meta: Decodable {
        let seasonId: Int?
        let seriesId: Int?
        let name: String?
        let cover: String?
        let total: Int?
    }

    let itemsLists: Lists?
}

@MainActor
final class Playlist: ObservableObject {
    static let uploadsType = 1
    static let toviewType = 2
    static let favType = 3
    static let seriesType = 5
    static let seasonType = 8

    let title: String
    let kind: String
    let sections: [PlaylistSection]?
    let mlType: Int
    let bizId: Int

    @Published private(set) var items: [PlaylistItem] = []
    @Published private(set) var hasMore: Bool
    @Published private(set) var total = 0

    private var loading: Task<Void, Error>?

    init(title: String, kind: String, mlType: Int, bizId: Int) {
        self.title = title
        self.kind = kind
        self.mlType = mlType
        self.bizId = bizId
        sections = nil
        hasMore = true
    }

    init(title: String, kind: String, sections: [PlaylistSection]) {
        self.title = title
        self.kind = kind
        self.sections = sections
        mlType = 0
        bizId = 0
        hasMore = false
        items = sections.flatMap(\.items)
        total = items.count
    }

    /// 从 view 接口的 ugc_season 构造合集清单;少于两条时没有清单的意义。
    convenience init?(ugcSeasonOf detail: ViewData) {
        guard let season = detail.ugcSeason?.value else { return nil }
        let sections = (season.sections?.elements ?? []).compactMap { section -> PlaylistSection? in
            let items = (section.episodes?.elements ?? []).compactMap { episode -> PlaylistItem? in
                guard let bvid = episode.bvid, bvid.hasPrefix("BV") else { return nil }
                return PlaylistItem(
                    bvid: bvid,
                    aid: episode.aid ?? 0,
                    title: episode.title ?? "",
                    cover: episode.arc?.pic,
                    duration: episode.arc?.duration ?? 0,
                    author: episode.arc?.author?.name ?? "",
                    views: episode.arc?.stat?.view
                )
            }
            return items.isEmpty ? nil : PlaylistSection(title: section.title ?? "", items: items)
        }
        guard sections.reduce(0, { $0 + $1.items.count }) >= 2 else { return nil }
        self.init(title: season.title ?? "合集", kind: "合集", sections: sections)
    }

    /// 首次加载;startAid 有值时从该条开始(收藏夹很长时直接定位到当前视频)。
    func ensureLoaded(startAid: Int? = nil) async throws {
        guard sections == nil, items.isEmpty else { return }
        try await fetch(oid: startAid ?? 0, withCurrent: startAid != nil)
        // 起点不在列表里(已删除/失效)时从头加载
        if startAid != nil, items.isEmpty {
            try await fetch(oid: 0, withCurrent: false)
        }
    }

    func loadMore() async throws {
        guard hasMore, sections == nil else { return }
        try await fetch(oid: items.last?.aid ?? 0, withCurrent: false)
    }

    private func fetch(oid: Int, withCurrent: Bool) async throws {
        if let loading {
            try await loading.value
            return
        }
        let task = Task { [self] in
            // 合集/系列按正序(第一集在前)连播;其余按最近添加在前
            let desc = !(mlType == Self.seasonType || mlType == Self.seriesType)
            var query = [
                "type": String(mlType),
                "biz_id": String(bizId),
                "ps": "20",
                "direction": "false",
                "desc": desc ? "true" : "false",
                "sort_field": "1",
                "tid": "0",
                "with_current": withCurrent ? "true" : "false",
            ]
            if oid > 0 {
                query["oid"] = String(oid)
                query["otype"] = "2"
            }
            let data: MediaListData = try await BiliClient.shared.get(
                "https://api.bilibili.com/x/v2/medialist/resource/list",
                query: query
            )
            var seen = Set(items.map(\.bvid))
            let medias = data.mediaList?.elements ?? []
            for media in medias {
                // 只要视频(收藏夹里可能混有音频/合集)
                guard let bvid = media.bvId ?? media.bvid, bvid.hasPrefix("BV"),
                      media.type == nil || media.type == 2,
                      seen.insert(bvid).inserted else { continue }
                items.append(PlaylistItem(
                    bvid: bvid,
                    aid: media.id ?? 0,
                    title: media.title ?? "",
                    cover: media.cover,
                    duration: media.duration ?? 0,
                    author: media.upper?.name ?? "",
                    views: media.cntInfo?.play
                ))
            }
            hasMore = (data.hasMore ?? false) && !medias.isEmpty
            total = data.totalCount ?? items.count
        }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    func index(of bvid: String) -> Int? {
        items.firstIndex { $0.bvid == bvid }
    }

    /// 下一条(到列表末尾时自动翻页)。
    func next(after bvid: String) async -> PlaylistItem? {
        guard var index = index(of: bvid) else { return nil }
        if index + 1 >= items.count, hasMore {
            try? await loadMore()
            index = self.index(of: bvid) ?? index
        }
        return index + 1 < items.count ? items[index + 1] : nil
    }

    /// 按分节返回(清单页展示用)。
    var grouped: [PlaylistSection] {
        if let sections, sections.count > 1 { return sections }
        return [PlaylistSection(title: "", items: items)]
    }
}
