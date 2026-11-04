import SwiftUI

/// PGC 单集:海外受限的番剧 view 接口可能拿不到信息,播放所需字段都从选集页带过来。
struct SeasonEpisodeRef {
    let epId: Int
    let cid: Int
    let aid: Int
    let bvid: String
    let title: String
    /// 秒
    let duration: Int
}

struct SeasonContext {
    let title: String
    let episodes: [SeasonEpisodeRef]
}

/// 一次播放:UGC 视频(可带分 P、清单)或 PGC 单集(可带所属季,用于接下一集)。
struct PlayRequest: Identifiable {
    let bvid: String
    var pageIndex = 0
    var playlist: Playlist?
    var episode: SeasonEpisodeRef?
    var season: SeasonContext?

    var id: String { episode.map { "ep\($0.epId)" } ?? "\(bvid)#\(pageIndex)" }
}

/// 全局路由:卡片 → 详情页;调试参数可直达播放器。
@MainActor
final class PlaybackRouter: ObservableObject {
    @Published var detail: PlayRequest?
    @Published var debugPlay: PlayRequest?

    func openDetail(_ bvid: String, playlist: Playlist? = nil) {
        detail = PlayRequest(bvid: bvid, playlist: playlist)
    }
}

private struct DebugTimeline: Identifiable {
    let types: Int
    var id: Int { types }
}

@main
struct OverseaBiliApp: App {
    @StateObject private var auth = AuthManager()
    @StateObject private var router = PlaybackRouter()
    @State private var showLogin = UserDefaults.standard.bool(forKey: "showLogin")
    @State private var showRoamLogin = UserDefaults.standard.bool(forKey: "showRoamLogin")
    // 调试:-initialTab N 直接定位到第 N 个 tab;-liveRoom <id> 直达直播间
    @State private var selectedTab = UserDefaults.standard.integer(forKey: "initialTab")
    @State private var debugLive: LivePlayRequest?
    // 调试:-seasonId <id> 直达选集页;-upMid <mid> 直达 UP 空间;-timeline <1|4> 直达时间表
    @State private var debugSeason: SeasonRequest?
    @State private var debugUp: UpSpaceRequest?
    @State private var debugTimeline: DebugTimeline?

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                NavigationStack { RecommendView() }
                    .tabItem { Label("推荐", systemImage: "hand.thumbsup.fill") }
                    .tag(0)
                NavigationStack { PopularView() }
                    .tabItem { Label("热门", systemImage: "flame.fill") }
                    .tag(1)
                NavigationStack { LiveTabView() }
                    .tabItem { Label("直播", systemImage: "dot.radiowaves.left.and.right") }
                    .tag(2)
                NavigationStack { DiscoverView() }
                    .tabItem { Label("发现", systemImage: "safari.fill") }
                    .tag(3)
                NavigationStack { DynamicView() }
                    .tabItem { Label("动态", systemImage: "person.2.fill") }
                    .tag(4)
                NavigationStack { MineView() }
                    .tabItem { Label("我的", systemImage: "person.crop.circle") }
                    .tag(5)
                NavigationStack { SearchView() }
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                    .tag(6)
            }
            .environmentObject(auth)
            .environmentObject(router)
            .task {
                await auth.refresh()
                // 调试:-playBvid 直达播放器;-detailBvid 直达详情页
                if let bvid = UserDefaults.standard.string(forKey: "playBvid"), bvid.hasPrefix("BV") {
                    router.debugPlay = PlayRequest(bvid: bvid)
                } else if let bvid = UserDefaults.standard.string(forKey: "detailBvid"), bvid.hasPrefix("BV") {
                    router.detail = PlayRequest(bvid: bvid)
                } else if case let room = UserDefaults.standard.integer(forKey: "liveRoom"), room > 0 {
                    debugLive = LivePlayRequest(roomId: room, title: "直播调试")
                } else if case let season = UserDefaults.standard.integer(forKey: "seasonId"), season > 0 {
                    debugSeason = SeasonRequest(seasonId: season, title: "选集")
                } else if case let mid = UserDefaults.standard.integer(forKey: "upMid"), mid > 0 {
                    debugUp = UpSpaceRequest(mid: mid, name: "UP 主", face: nil)
                } else if case let types = UserDefaults.standard.integer(forKey: "timeline"), types > 0 {
                    debugTimeline = DebugTimeline(types: types)
                }
            }
            // overseabili://play/BV1xxxx —— 打开视频详情页
            .onOpenURL { url in
                guard url.scheme == "overseabili" else { return }
                let bvid: String?
                if url.host == "play" {
                    bvid = url.pathComponents.count > 1 ? url.pathComponents[1] : nil
                } else {
                    bvid = url.host
                }
                if let bvid, bvid.hasPrefix("BV") {
                    router.openDetail(bvid)
                }
            }
            .fullScreenCover(item: $router.detail) { request in
                DetailScreen(bvid: request.bvid, playlist: request.playlist)
                    .environmentObject(auth)
                    .environmentObject(router)
            }
            .fullScreenCover(item: $router.debugPlay) { request in
                PlayerScreen(request: request)
            }
            .fullScreenCover(item: $debugLive) { request in
                LivePlayerScreen(roomId: request.roomId, title: request.title)
                    .environmentObject(auth)
            }
            .fullScreenCover(item: $debugSeason) { request in
                SeasonScreen(seasonId: request.seasonId, fallbackTitle: request.title)
                    .environmentObject(auth)
                    .environmentObject(router)
            }
            .fullScreenCover(item: $debugUp) { request in
                UpSpaceScreen(mid: request.mid, name: request.name, face: request.face)
                    .environmentObject(auth)
                    .environmentObject(router)
            }
            .fullScreenCover(item: $debugTimeline) { request in
                TimelineScreen(types: request.types)
                    .environmentObject(auth)
                    .environmentObject(router)
            }
            .fullScreenCover(isPresented: $showLogin) {
                LoginView()
            }
            .fullScreenCover(isPresented: $showRoamLogin) {
                LoginView(roam: true)
                    .environmentObject(auth)
            }
        }
    }
}
