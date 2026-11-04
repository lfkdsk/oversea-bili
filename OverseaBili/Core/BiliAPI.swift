import Foundation

enum LoginAPI {
    /// 申请二维码,返回二维码内容与轮询 key。
    static func generateQR() async throws -> QRGenerateData {
        try await BiliClient.shared.get("https://passport.bilibili.com/x/passport-login/web/qrcode/generate")
    }

    /// 轮询扫码状态。data.code: 0 成功 / 86101 未扫码 / 86090 已扫码待确认 / 86038 已过期
    static func poll(key: String) async throws -> QRPollData {
        try await BiliClient.shared.get(
            "https://passport.bilibili.com/x/passport-login/web/qrcode/poll",
            query: ["qrcode_key": key]
        )
    }

    static func nav() async throws -> NavData {
        try await BiliClient.shared.get("https://api.bilibili.com/x/web-interface/nav", allowCodes: [-101])
    }

    /// Cookie 是否需要续期。
    static func cookieNeedsRefresh() async -> (needed: Bool, timestamp: Int)? {
        guard let data: CookieInfoData = try? await BiliClient.shared.get(
            "https://passport.bilibili.com/x/passport-login/web/cookie/info"
        ), let timestamp = data.timestamp else { return nil }
        return (data.refresh ?? false, timestamp)
    }
}

enum FeedAPI {
    static func popular(page: Int = 1, size: Int = 20) async throws -> [VideoItem] {
        let data: PopularData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/popular",
            query: ["pn": String(page), "ps": String(size)]
        )
        return data.list
    }

    /// 登录后的个性化推荐(wbi 签名)。
    static func recommended(count: Int = 16) async throws -> [VideoItem] {
        let data: RcmdData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd",
            query: ["ps": String(count), "fresh_type": "4"],
            wbi: true
        )
        // 混着的广告/直播卡 bvid 为空,只留视频
        return (data.item ?? []).filter { $0.bvid.hasPrefix("BV") }
    }

    static func search(keyword: String, page: Int = 1) async throws -> (items: [SearchItem], more: Bool) {
        let data: SearchTypeData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/wbi/search/type",
            query: ["search_type": "video", "keyword": keyword, "page": String(page)],
            wbi: true
        )
        return ((data.result ?? []).filter { $0.bvid != nil }, page < (data.numPages ?? 1))
    }

    /// 番剧/影视搜索。海外 IP 的网页搜索会过滤掉受地区限制的条目,开了解析服务器时再经它搜一遍并合并。
    static func searchMedia(keyword: String, movie: Bool = false, page: Int = 1) async throws -> (items: [SearchMedia], more: Bool) {
        var items: [SearchMedia] = []
        var more = false
        var webError: Error?
        do {
            let data: SearchMediaData = try await BiliClient.shared.get(
                "https://api.bilibili.com/x/web-interface/wbi/search/type",
                query: [
                    "search_type": movie ? "media_ft" : "media_bangumi",
                    "keyword": keyword,
                    "page": String(page),
                ],
                wbi: true
            )
            items = (data.result ?? []).filter { $0.seasonId != nil }
            more = page < (data.numPages ?? 1)
        } catch {
            webError = error
        }
        if CDNSettings.shared.roamOn, let roam = try? await RoamAPI.search(keyword: keyword, movie: movie, page: page) {
            var seen = Set(items.compactMap(\.seasonId))
            for media in roam.items where seen.insert(media.seasonId ?? 0).inserted {
                items.append(media)
            }
            more = more || roam.more
        }
        if items.isEmpty, let webError { throw webError }
        return (items, more)
    }

    /// UP 主搜索。
    static func searchUser(keyword: String, page: Int = 1) async throws -> (items: [SearchUser], more: Bool) {
        let data: SearchUserData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/wbi/search/type",
            query: ["search_type": "bili_user", "keyword": keyword, "page": String(page)],
            wbi: true
        )
        return ((data.result ?? []).filter { $0.mid != nil }, page < (data.numPages ?? 1))
    }

    /// 热搜词。
    static func hotSearch() async -> [String] {
        guard let data: SearchSquareData = try? await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/wbi/search/square",
            query: ["limit": "20", "platform": "web"],
            wbi: true
        ) else { return [] }
        return (data.trending?.list ?? []).compactMap { $0.showName ?? $0.keyword }
    }

    /// 搜索建议(独立域名,非标准包装)。
    static func suggestions(for keyword: String) async -> [String] {
        guard !keyword.isEmpty,
              let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://s.search.bilibili.com/main/suggest?term=\(encoded)&main_ver=v1&highlight=")
        else { return [] }
        guard let (data, _) = try? await BiliClient.shared.session.data(for: BiliClient.shared.makeRequest(url)),
              let decoded = try? JSONDecoder().decode(SuggestResponse.self, from: data) else { return [] }
        return (decoded.result?.tag ?? []).compactMap { $0.value ?? $0.name }
    }
}

enum VideoAPI {
    /// 优先 wbi/view(海外 IP 上非 wbi 的 view 容易被 -412 封禁),失败回落老接口。
    static func detail(bvid: String) async throws -> ViewData {
        do {
            return try await BiliClient.shared.get(
                "https://api.bilibili.com/x/web-interface/wbi/view",
                query: ["bvid": bvid],
                wbi: true
            )
        } catch BiliError.api(let code, let message) where [-404, 62002, 62004].contains(code) {
            throw BiliError.api(code: code, message: message)
        } catch {
            return try await BiliClient.shared.get(
                "https://api.bilibili.com/x/web-interface/view",
                query: ["bvid": bvid]
            )
        }
    }

    /// DASH 播放地址(fnval=4048 全能力),登录/大会员可拿 1080P60/4K。
    static func playURLDash(bvid: String, cid: Int) async throws -> PlayURLData {
        try await BiliClient.shared.get(
            "https://api.bilibili.com/x/player/wbi/playurl",
            query: [
                "bvid": bvid,
                "cid": String(cid),
                "qn": "127",
                "fnval": "4048",
                "fnver": "0",
                "fourk": "1",
            ],
            wbi: true
        )
    }

    /// 服务端续播进度 + 字幕列表(需登录,跨设备)。
    static func playerV2(aid: Int, cid: Int) async throws -> PlayerV2Data {
        try await BiliClient.shared.get(
            "https://api.bilibili.com/x/player/wbi/v2",
            query: ["aid": String(aid), "cid": String(cid)],
            wbi: true
        )
    }

    /// 下载并转换字幕为 WebVTT。
    static func subtitleVTT(from track: SubtitleTrack) async -> String? {
        guard let urlString = track.url, let url = URL(string: urlString) else { return nil }
        guard let (data, _) = try? await BiliClient.shared.session.data(for: BiliClient.shared.makeRequest(url)),
              let doc = try? JSONDecoder().decode(SubtitleDoc.self, from: data),
              let lines = doc.body, !lines.isEmpty else { return nil }

        func stamp(_ seconds: Double) -> String {
            let total = max(0, seconds)
            let h = Int(total) / 3600
            let m = (Int(total) % 3600) / 60
            let s = Int(total) % 60
            let ms = Int((total - floor(total)) * 1000)
            return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
        }

        var out = "WEBVTT\n\n"
        for (index, line) in lines.enumerated() {
            guard let from = line.from, let to = line.to, to > from,
                  let text = line.content, !text.isEmpty else { continue }
            out += "\(index + 1)\n\(stamp(from)) --> \(stamp(to))\n\(text)\n\n"
        }
        return out
    }

    static func related(bvid: String) async throws -> [VideoItem] {
        try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/archive/related",
            query: ["bvid": bvid]
        )
    }
}

/// 互动:点赞 / 投币 / 收藏 / 稍后再看(均需登录)。
enum ActionAPI {
    struct CoinData: Decodable { let multiply: Int? }
    struct FavouredData: Decodable { let favoured: Bool? }
    struct FavFolderList: Decodable { let list: [FavFolder]? }
    struct FavFolder: Decodable { let id: Int; let title: String? }

    static func like(aid: Int) async throws {
        try await BiliClient.shared.postAction(
            "https://api.bilibili.com/x/web-interface/archive/like",
            form: ["aid": String(aid), "like": "1"]
        )
    }

    static func unlike(aid: Int) async throws {
        try await BiliClient.shared.postAction(
            "https://api.bilibili.com/x/web-interface/archive/like",
            form: ["aid": String(aid), "like": "2"]
        )
    }

    static func coin(aid: Int, count: Int = 1) async throws {
        try await BiliClient.shared.postAction(
            "https://api.bilibili.com/x/web-interface/coin/add",
            form: ["aid": String(aid), "multiply": String(count), "select_like": "0"]
        )
    }

    /// 播放进度上报(历史记录里的"看到 xx:xx",手机端可续播)。
    static func reportHistory(aid: Int, cid: Int, progress: Int) async throws {
        try await BiliClient.shared.postAction(
            "https://api.bilibili.com/x/v2/history/report",
            form: ["aid": String(aid), "cid": String(cid), "progress": String(progress)]
        )
    }

    static func addToView(aid: Int) async throws {
        try await BiliClient.shared.postAction(
            "https://api.bilibili.com/x/v2/history/toview/add",
            form: ["aid": String(aid)]
        )
    }

    /// 收藏到默认收藏夹。
    static func favorite(aid: Int, mid: Int) async throws {
        let folders: FavFolderList = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/v3/fav/folder/created/list-all",
            query: ["up_mid": String(mid)]
        )
        guard let folder = folders.list?.first else {
            throw BiliError.notPlayable("没有可用的收藏夹")
        }
        try await BiliClient.shared.postAction(
            "https://api.bilibili.com/x/v3/fav/resource/deal",
            form: ["rid": String(aid), "type": "2", "add_media_ids": String(folder.id)]
        )
    }

    /// 一键三连。
    static func triple(aid: Int) async throws {
        try await BiliClient.shared.postAction(
            "https://api.bilibili.com/x/web-interface/archive/like/triple",
            form: ["aid": String(aid)]
        )
    }

    /// 关注状态(attribute:0 未关注 / 2 已关注 / 6 互关)。
    static func relation(mid: Int) async -> Int? {
        let data: RelationData? = try? await BiliClient.shared.get(
            "https://api.bilibili.com/x/relation",
            query: ["fid": String(mid)]
        )
        return data?.attribute
    }

    /// act:1 关注 / 2 取关。
    static func modifyRelation(mid: Int, follow: Bool) async throws {
        try await BiliClient.shared.postAction(
            "https://api.bilibili.com/x/relation/modify",
            form: ["fid": String(mid), "act": follow ? "1" : "2", "re_src": "11"]
        )
    }

    static func isLiked(aid: Int) async -> Bool {
        let value: Int? = try? await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/archive/has/like",
            query: ["aid": String(aid)]
        )
        return value == 1
    }

    static func coinCount(aid: Int) async -> Int {
        let data: CoinData? = try? await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/archive/coins",
            query: ["aid": String(aid)]
        )
        return data?.multiply ?? 0
    }

    static func isFavoured(aid: Int) async -> Bool {
        let data: FavouredData? = try? await BiliClient.shared.get(
            "https://api.bilibili.com/x/v2/fav/video/favoured",
            query: ["aid": String(aid)]
        )
        return data?.favoured ?? false
    }
}

enum DynamicAPI {
    /// 关注 UP 的视频动态流(需登录)。polymer 接口对客户端指纹敏感,带 t.bilibili.com Referer。
    static func videoFeed(offset: String?) async throws -> DynFeedData {
        var query = ["type": "video", "features": "itemOpusStyle"]
        if let offset, !offset.isEmpty { query["offset"] = offset }
        return try await BiliClient.shared.get(
            "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/all",
            query: query,
            referer: "https://t.bilibili.com/"
        )
    }

    /// 老版动态接口兜底(卡片是嵌套 JSON 字符串)。
    static func legacyVideoFeed(mid: Int) async throws -> [DynVideoRow] {
        let data: LegacyDynData = try await BiliClient.shared.get(
            "https://api.vc.bilibili.com/dynamic_svr/v1/dynamic_svr/dynamic_new",
            query: ["uid": String(mid), "type_list": "8"],
            referer: "https://t.bilibili.com/"
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return (data.cards ?? []).compactMap { card in
            guard let bvid = card.desc?.bvid, bvid.hasPrefix("BV"),
                  let payload = card.card?.data(using: .utf8),
                  let archive = try? decoder.decode(LegacyArchiveCard.self, from: payload) else { return nil }
            let time = card.desc?.timestamp.map {
                formatter.string(from: Date(timeIntervalSince1970: TimeInterval($0)))
            } ?? ""
            return DynVideoRow(
                id: card.desc?.dynamicIdStr ?? bvid,
                bvid: bvid,
                title: archive.title ?? "",
                cover: archive.pic,
                durationText: formatDuration(archive.duration),
                authorName: card.desc?.userProfile?.info?.uname ?? "",
                pubTime: time
            )
        }
    }

    /// 动态页顶部"最近关注 UP"列表(含有无更新标记)。
    static func upList() async throws -> [DynUpItem] {
        let data: PortalData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/polymer/web-dynamic/v1/portal",
            referer: "https://t.bilibili.com/"
        )
        return (data.upList ?? []).filter { $0.mid != nil }
    }

    /// 指定 UP 的动态(点击头像过滤)。
    static func spaceFeed(hostMid: Int, offset: String?) async throws -> DynFeedData {
        var query = ["host_mid": String(hostMid)]
        if let offset, !offset.isEmpty { query["offset"] = offset }
        return try await BiliClient.shared.get(
            "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/space",
            query: query,
            referer: "https://space.bilibili.com/"
        )
    }

    /// 统一入口:hostMid 非空时看指定 UP;否则全部关注流(polymer 失败回落 legacy)。
    static func rows(mid: Int?, hostMid: Int?, offset: String?) async throws
        -> (rows: [DynVideoRow], offset: String?, hasMore: Bool) {
        if let hostMid {
            let data = try await spaceFeed(hostMid: hostMid, offset: offset)
            let rows = (data.items ?? []).compactMap { DynVideoRow(polymer: $0) }
            return (rows, data.offset, data.hasMore ?? false)
        }
        do {
            let data = try await videoFeed(offset: offset)
            let rows = (data.items ?? []).compactMap { DynVideoRow(polymer: $0) }
            return (rows, data.offset, data.hasMore ?? false)
        } catch {
            guard offset == nil, let mid else { throw error }
            let rows = try await legacyVideoFeed(mid: mid)
            return (rows, nil, false)
        }
    }
}

/// 分区排行榜。rid=0 为全站。
enum RankAPI {
    static let regions: [(rid: Int, name: String)] = [
        (0, "全站"), (1, "动画"), (4, "游戏"), (3, "音乐"), (36, "知识"),
        (188, "科技"), (160, "生活"), (211, "美食"), (181, "影视"),
        (119, "鬼畜"), (129, "舞蹈"), (5, "娱乐"), (234, "运动"), (217, "动物圈"),
    ]

    static func ranking(rid: Int) async throws -> [VideoItem] {
        let data: PopularData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/ranking/v2",
            query: ["rid": String(rid), "type": "all"]
        )
        return data.list
    }
}

extension FeedAPI {
    /// 每周必看(最新一期)。
    static func weekly() async throws -> [VideoItem] {
        let series: SeriesListData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/popular/series/list"
        )
        guard let number = series.list?.first?.number else { return [] }
        let data: PopularData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/popular/series/one",
            query: ["number": String(number)]
        )
        return data.list
    }

    /// 入站必刷。
    static func precious() async throws -> [VideoItem] {
        let data: PopularData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/popular/precious",
            query: ["page_size": "40", "page": "1"]
        )
        return data.list
    }
}

/// 我的:历史 / 稍后再看 / 收藏。
enum MineAPI {
    static func history(max: Int = 0, viewAt: Int = 0) async throws -> (items: [HistoryItem], cursor: HistoryCursorData.Cursor?) {
        var query = ["ps": "30", "type": "archive"]
        if max > 0 {
            query["max"] = String(max)
            query["view_at"] = String(viewAt)
        }
        let data: HistoryCursorData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/history/cursor",
            query: query
        )
        return ((data.list ?? []).filter { $0.bvid?.hasPrefix("BV") == true }, data.cursor)
    }

    static func toview() async throws -> [VideoItem] {
        let data: ToViewData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/v2/history/toview"
        )
        return data.list ?? []
    }

    static func favFolders(mid: Int) async throws -> [ActionAPI.FavFolder] {
        let data: ActionAPI.FavFolderList = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/v3/fav/folder/created/list-all",
            query: ["up_mid": String(mid)]
        )
        return data.list ?? []
    }

    static func favResources(mediaId: Int, page: Int = 1) async throws -> (items: [FavMedia], more: Bool) {
        let data: FavResourceData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/v3/fav/resource/list",
            query: ["media_id": String(mediaId), "ps": "20", "pn": String(page), "platform": "web"]
        )
        return (data.medias ?? [], data.hasMore ?? false)
    }
}

/// 直播。
enum LiveAPI {
    /// 关注的主播(含未开播;需登录)。
    static func following() async throws -> [LiveRoom] {
        let data: LiveFollowData = try await BiliClient.shared.get(
            "https://api.live.bilibili.com/xlive/web-ucenter/user/following",
            query: ["page": "1", "page_size": "29"]
        )
        return data.list ?? []
    }

    /// 直播推荐。
    static func recommend() async throws -> [LiveRoom] {
        let data: LiveRecommendData = try await BiliClient.shared.get(
            "https://api.live.bilibili.com/xlive/web-interface/v1/index/getList",
            query: ["platform": "web"]
        )
        return data.recommendRoomList ?? []
    }

    /// 直播分区树(父分区 → 子分区)。
    static func areaList() async throws -> [LiveParentArea] {
        let data: LiveAreaListData = try await BiliClient.shared.get(
            "https://api.live.bilibili.com/xlive/web-interface/v1/index/getWebAreaList",
            query: ["source_id": "2"],
            referer: "https://live.bilibili.com/"
        )
        return (data.data ?? []).filter { $0.id != nil }
    }

    /// 分区房间列表。新接口 second/getList 海外实测稳定 -352(wbi 也不行),用老接口 room/v3/area/getRoomList。
    static func areaRooms(parentId: Int, areaId: Int, page: Int) async throws -> [LiveRoom] {
        let data: LiveAreaRoomsData = try await BiliClient.shared.get(
            "https://api.live.bilibili.com/room/v3/area/getRoomList",
            query: [
                "platform": "web",
                "parent_area_id": String(parentId),
                "area_id": String(areaId),
                "sort_type": "online",
                "page": String(page),
                "page_size": "30",
            ],
            referer: "https://live.bilibili.com/"
        )
        return (data.list ?? []).filter { $0.roomid != nil }
    }

    /// 取直播 HLS 播放地址(按 fmp4 > ts 优先,avc 编码优先)+ 可用清晰度列表。
    static func streamURLs(roomId: Int, qn: Int = 10000) async throws -> (urls: [URL], qualities: [LiveQuality], currentQn: Int) {
        let data: RoomPlayData = try await BiliClient.shared.get(
            "https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo",
            query: [
                "room_id": String(roomId),
                "protocol": "0,1",
                "format": "0,1,2",
                "codec": "0,1",
                "qn": String(qn),
                "platform": "web",
                "ptype": "8",
            ]
        )
        let qualities = (data.playurlInfo?.playurl?.gQnDesc ?? []).compactMap { item -> LiveQuality? in
            guard let qn = item.qn, let desc = item.desc else { return nil }
            return LiveQuality(qn: qn, desc: desc)
        }
        let streams = data.playurlInfo?.playurl?.stream ?? []
        let hls = streams.filter { $0.protocolName == "http_hls" }
        let formats = hls.flatMap { $0.format ?? [] }
        let ordered = formats.sorted { a, b in
            let rank = { (name: String?) -> Int in
                switch name {
                case "fmp4": return 0
                case "ts": return 1
                default: return 2
                }
            }
            return rank(a.formatName) < rank(b.formatName)
        }
        var urls: [URL] = []
        var actualQn = qn
        for format in ordered {
            let codecs = (format.codec ?? []).sorted { a, _ in a.codecName == "avc" }
            for codec in codecs {
                guard let base = codec.baseUrl else { continue }
                if let current = codec.currentQn { actualQn = current }
                for info in codec.urlInfo ?? [] {
                    guard let host = info.host else { continue }
                    if let url = URL(string: host + base + (info.extra ?? "")) {
                        urls.append(url)
                    }
                }
            }
        }
        guard !urls.isEmpty else { throw BiliError.notPlayable("直播间未开播或没有可用流") }
        return (urls, qualities, actualQn)
    }
}

/// UP 空间。
enum SpaceAPI {
    /// 投稿列表(wbi;此接口风控较凶,失败方调用 DynamicAPI.spaceFeed 兜底)。
    static func videos(mid: Int, page: Int) async throws -> [SpaceVideo] {
        let data: SpaceArcData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/space/wbi/arc/search",
            query: ["mid": String(mid), "ps": "25", "pn": String(page), "order": "pubdate"],
            wbi: true,
            referer: "https://space.bilibili.com/"
        )
        return (data.list?.vlist ?? []).filter { $0.bvid?.hasPrefix("BV") == true }
    }

    static func followers(mid: Int) async -> Int? {
        let data: RelationStatData? = try? await BiliClient.shared.get(
            "https://api.bilibili.com/x/relation/stat",
            query: ["vmid": String(mid)]
        )
        return data?.follower
    }

    /// 名片:签名、粉丝数、投稿数。
    static func card(mid: Int) async throws -> SpaceCardData {
        try await BiliClient.shared.get(
            "https://api.bilibili.com/x/web-interface/card",
            query: ["mid": String(mid), "photo": "false"]
        )
    }

    /// UP 主的合集与系列。
    static func collections(mid: Int) async throws -> [UpCollection] {
        let data: SeasonsSeriesData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/polymer/web-space/seasons_series_list",
            query: ["mid": String(mid), "page_num": "1", "page_size": "20"],
            wbi: true
        )
        let seasons = (data.itemsLists?.seasonsList ?? []).compactMap { entry -> UpCollection? in
            guard let meta = entry.meta, let id = meta.seasonId else { return nil }
            return UpCollection(mlType: Playlist.seasonType, bizId: id, label: "合集",
                                title: (meta.name ?? "").replacingOccurrences(of: "合集·", with: ""),
                                cover: meta.cover, total: meta.total ?? 0)
        }
        let series = (data.itemsLists?.seriesList ?? []).compactMap { entry -> UpCollection? in
            guard let meta = entry.meta, let id = meta.seriesId else { return nil }
            return UpCollection(mlType: Playlist.seriesType, bizId: id, label: "系列",
                                title: meta.name ?? "", cover: meta.cover, total: meta.total ?? 0)
        }
        return seasons + series
    }
}

/// 番剧 / 剧集(PGC)。
enum BangumiAPI {
    /// type: 1 追番 / 2 追剧。
    static func follow(mid: Int, type: Int) async throws -> [BangumiSeason] {
        let data: BangumiFollowData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/space/bangumi/follow/list",
            query: ["type": String(type), "follow_status": "0", "pn": "1", "ps": "20", "vmid": String(mid)]
        )
        return data.list ?? []
    }

    /// 季详情(含全部剧集,用于选集页)。seasonId 为 0 时按 ep_id 查。
    static func season(seasonId: Int, epId: Int? = nil) async throws -> SeasonDetail {
        try await BiliClient.shared.getPGC(
            "https://api.bilibili.com/pgc/view/web/season",
            query: seasonId > 0 ? ["season_id": String(seasonId)] : ["ep_id": String(epId ?? 0)]
        )
    }

    /// 番剧时间表。types:1 番剧 / 4 国创。
    static func timeline(types: Int = 1) async throws -> [TimelineDay] {
        try await BiliClient.shared.getPGC(
            "https://api.bilibili.com/pgc/web/timeline",
            query: ["types": String(types), "before": "1", "after": "5"]
        )
    }

    /// PGC 正规播放链路(ep_id 维度)。番剧/影视的官方入口,
    /// 大会员内容与地区授权都由该接口判定,错误码能明确区分原因。
    /// 海外多数番剧在这里返回 -10403,开了解析服务器时改走它。
    static func playURL(epId: Int, cid: Int) async throws -> PlayURLData {
        do {
            let wrapped: PGCPlayURLResult = try await BiliClient.shared.getPGC(
                "https://api.bilibili.com/pgc/player/web/v2/playurl",
                query: [
                    "ep_id": String(epId),
                    "cid": String(cid),
                    "qn": "127",
                    "fnval": "4048",
                    "fnver": "0",
                    "fourk": "1",
                ]
            )
            guard let info = wrapped.videoInfo else { throw BiliError.emptyData }
            return info
        } catch BiliError.api(let code, _) where (code == -10403 || code == 87008) && CDNSettings.shared.roamOn {
            return try await RoamAPI.playURL(epId: epId, cid: cid)
        }
    }

}

extension VideoAPI {
    /// html5 平台的 playurl:返回单文件 mp4(durl),AVPlayer 可直接播放。
    /// DASH 不可用时的兜底;登录后 qn=80 可拿 1080P。
    static func playURL(bvid: String, cid: Int, qn: Int = 80) async throws -> PlayURLData {
        let data: PlayURLData = try await BiliClient.shared.get(
            "https://api.bilibili.com/x/player/playurl",
            query: [
                "bvid": bvid,
                "cid": String(cid),
                "qn": String(qn),
                "fnval": "1",
                "fnver": "0",
                "fourk": "0",
                "platform": "html5",
                "high_quality": "1",
            ]
        )
        guard let durl = data.durl, !durl.isEmpty else {
            throw BiliError.notPlayable("接口未返回可用播放地址")
        }
        return data
    }
}
