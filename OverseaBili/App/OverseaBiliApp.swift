import SwiftUI

struct PlayRequest: Identifiable {
    let bvid: String
    var id: String { bvid }
}

/// 全局路由:卡片 → 详情页;调试参数可直达播放器。
@MainActor
final class PlaybackRouter: ObservableObject {
    @Published var detail: PlayRequest?
    @Published var debugPlay: PlayRequest?

    func openDetail(_ bvid: String) {
        detail = PlayRequest(bvid: bvid)
    }
}

@main
struct OverseaBiliApp: App {
    @StateObject private var auth = AuthManager()
    @StateObject private var router = PlaybackRouter()
    @State private var showLogin = UserDefaults.standard.bool(forKey: "showLogin")
    // 调试:-initialTab N 直接定位到第 N 个 tab;-liveRoom <id> 直达直播间
    @State private var selectedTab = UserDefaults.standard.integer(forKey: "initialTab")
    @State private var debugLive: LivePlayRequest?

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
                DetailScreen(bvid: request.bvid)
                    .environmentObject(auth)
                    .environmentObject(router)
            }
            .fullScreenCover(item: $router.debugPlay) { request in
                PlayerScreen(bvid: request.bvid)
            }
            .fullScreenCover(item: $debugLive) { request in
                LivePlayerScreen(roomId: request.roomId, title: request.title)
                    .environmentObject(auth)
            }
            .fullScreenCover(isPresented: $showLogin) {
                LoginView()
            }
        }
    }
}
