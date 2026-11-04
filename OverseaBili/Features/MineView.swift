import SwiftUI

enum MineSection: Hashable {
    case history
    case toview
    case bangumi
    case drama
    case fav(Int)
}

@MainActor
final class MineViewModel: ObservableObject {
    @Published var selection: MineSection = .history
    @Published var folders: [ActionAPI.FavFolder] = []
    @Published var history: [HistoryItem] = []
    @Published var toview: [VideoItem] = []
    @Published var bangumi: [BangumiSeason] = []
    @Published var drama: [BangumiSeason] = []
    @Published var favContent: [Int: [FavMedia]] = [:]
    @Published var loading = false

    private var lastLoad: [MineSection: Date] = [:]
    private var historyCursor: HistoryCursorData.Cursor?
    private var favPage: [Int: Int] = [:]
    private var favHasMore: [Int: Bool] = [:]
    private var loadingMore = false
    private var mid: Int?

    /// 每次进入页面都调用:收藏夹列表懒加载一次,当前分区按新鲜度刷新。
    func onAppear(mid: Int?) async {
        guard let mid else { return }
        self.mid = mid
        if folders.isEmpty {
            folders = (try? await MineAPI.favFolders(mid: mid)) ?? []
        }
        await load(selection, force: false)
    }

    func select(_ section: MineSection) {
        guard section != selection else { return }
        selection = section
        Task { await load(section, force: true) }
    }

    func refreshCurrent() async {
        await load(selection, force: true)
    }

    func reset() {
        folders = []
        history = []
        toview = []
        bangumi = []
        drama = []
        favContent = [:]
        favPage = [:]
        favHasMore = [:]
        historyCursor = nil
        lastLoad = [:]
    }

    /// 收藏夹 / 稍后再看作为播放清单连续播放(medialist 接口)。
    var currentPlaylist: Playlist? {
        switch selection {
        case .toview:
            guard let mid else { return nil }
            return Playlist(title: "稍后再看", kind: "稍后再看", mlType: Playlist.toviewType, bizId: mid)
        case .fav(let id):
            let title = folders.first { $0.id == id }?.title ?? "收藏夹"
            return Playlist(title: title, kind: "收藏夹", mlType: Playlist.favType, bizId: id)
        default:
            return nil
        }
    }

    /// force=false 时 30 秒内不重复拉,避免焦点来回移动刷爆接口。
    private func load(_ section: MineSection, force: Bool) async {
        if !force, let at = lastLoad[section], Date().timeIntervalSince(at) < 30 { return }
        loading = true
        switch section {
        case .history:
            let result = try? await MineAPI.history()
            history = result?.items ?? []
            historyCursor = result?.cursor
        case .toview:
            toview = (try? await MineAPI.toview()) ?? []
        case .bangumi:
            if let mid { bangumi = (try? await BangumiAPI.follow(mid: mid, type: 1)) ?? [] }
        case .drama:
            if let mid { drama = (try? await BangumiAPI.follow(mid: mid, type: 2)) ?? [] }
        case .fav(let mediaId):
            let result = try? await MineAPI.favResources(mediaId: mediaId)
            favContent[mediaId] = result?.items ?? []
            favPage[mediaId] = 1
            favHasMore[mediaId] = result?.more ?? false
        }
        lastLoad[section] = Date()
        loading = false
    }

    func loadMoreHistory() {
        guard !loadingMore, let cursor = historyCursor, let max = cursor.max, max > 0 else { return }
        loadingMore = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.loadingMore = false }
            guard let result = try? await MineAPI.history(max: max, viewAt: cursor.viewAt ?? 0) else { return }
            let known = Set(self.history.map(\.id))
            self.history += result.items.filter { !known.contains($0.id) }
            self.historyCursor = result.items.isEmpty ? nil : result.cursor
        }
    }

    func loadMoreFav(_ mediaId: Int) {
        guard !loadingMore, favHasMore[mediaId] == true else { return }
        loadingMore = true
        let next = (favPage[mediaId] ?? 1) + 1
        Task { [weak self] in
            guard let self else { return }
            defer { self.loadingMore = false }
            guard let result = try? await MineAPI.favResources(mediaId: mediaId, page: next) else { return }
            let known = Set((self.favContent[mediaId] ?? []).map(\.id))
            self.favContent[mediaId, default: []] += result.items.filter { !known.contains($0.id) }
            self.favPage[mediaId] = next
            self.favHasMore[mediaId] = result.more
        }
    }
}

/// 我的:左侧选项卡(历史 / 稍后再看 / 追番追剧 / 收藏夹)+ 右侧内容区。
struct MineView: View {
    @EnvironmentObject private var router: PlaybackRouter
    @EnvironmentObject private var auth: AuthManager
    @StateObject private var vm = MineViewModel()
    @State private var showLogin = false
    @State private var showSettings = false
    @State private var seasonRequest: SeasonRequest?
    @State private var playRequest: PlayRequest?

    private let columns4 = Array(repeating: GridItem(.flexible(), spacing: TVLayout.gridSpacing, alignment: .top), count: 4)
    private let columns3 = Array(repeating: GridItem(.flexible(), spacing: TVLayout.gridSpacing, alignment: .top), count: 3)

    var body: some View {
        Group {
            if !auth.isLoggedIn {
                VStack(spacing: 28) {
                    HintView(icon: "person.crop.circle.badge.questionmark",
                             text: "登录后查看观看历史、稍后再看和收藏",
                             actionTitle: "扫码登录") { showLogin = true }
                    Button {
                        showSettings = true
                    } label: {
                        Label("设置", systemImage: "gearshape.fill")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                HStack(alignment: .top, spacing: 48) {
                    sidebar
                        .frame(width: 400)
                        .padding(.vertical, TVLayout.pageVertical)
                    content
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, TVLayout.pageHorizontal)
                .task(id: auth.mid) {
                    await vm.onAppear(mid: auth.mid)
                }
                .onPlayPauseCommand {
                    Task { await vm.refreshCurrent() }
                }
            }
        }
        .onChange(of: auth.isLoggedIn) { _, loggedIn in
            vm.reset()
            if loggedIn {
                Task { await vm.onAppear(mid: auth.mid) }
            }
        }
        .fullScreenCover(isPresented: $showLogin) {
            LoginView()
        }
        .fullScreenCover(isPresented: $showSettings) {
            ZStack {
                Color(red: 0.08, green: 0.08, blue: 0.10).ignoresSafeArea()
                SettingsView()
            }
        }
        .fullScreenCover(item: $seasonRequest) { request in
            SeasonScreen(seasonId: request.seasonId, fallbackTitle: request.title)
        }
        .fullScreenCover(item: $playRequest) { request in
            PlayerScreen(request: request)
        }
    }

    // MARK: - 左侧选项卡

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                PosterImage(urlString: auth.face, width: 120, height: 120)
                    .frame(width: 60, height: 60)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(auth.uname ?? "")
                        .font(.headline)
                        .lineLimit(1)
                    Text("UID \(auth.mid.map(String.init) ?? "-")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 24)

            if auth.needsRelogin {
                Button {
                    showLogin = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("登录即将过期,点此重新扫码")
                            .font(.caption)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.bordered)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sideButton("观看历史", icon: "clock.arrow.circlepath", section: .history)
                    sideButton("稍后再看", icon: "text.badge.plus", section: .toview)
                    sideButton("我的追番", icon: "sparkles.tv", section: .bangumi)
                    sideButton("我的追剧", icon: "film", section: .drama)
                    ForEach(vm.folders, id: \.id) { folder in
                        sideButton(folder.title ?? "收藏夹", icon: "star", section: .fav(folder.id))
                    }
                }
                .padding(.vertical, 8)
            }

            Button {
                showSettings = true
            } label: {
                HStack {
                    Image(systemName: "gearshape.fill")
                    Text("设置")
                    Spacer()
                }
                .padding(.horizontal, 8)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sideButton(_ title: String, icon: String, section: MineSection) -> some View {
        let selected = vm.selection == section
        return Button {
            vm.select(section)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .foregroundStyle(selected ? .pink : .secondary)
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(selected ? .primary : .secondary)
                Spacer()
                if selected {
                    Circle().fill(.pink).frame(width: 10, height: 10)
                }
            }
            .padding(.horizontal, 8)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - 右侧内容

    private var content: some View {
        // 垂直 padding 放在滚动内容上(而非视口上),让视口贯穿到屏幕底部,
        // 未滚到的行会在底部露出一半,有正常的滚动可见性
        ScrollView {
            VStack(spacing: TVLayout.rowSpacing) {
            if let playlist = vm.currentPlaylist {
                HStack(spacing: 24) {
                    Button {
                        playAll(playlist)
                    } label: {
                        Label("连续播放全部", systemImage: "play.fill")
                            .fixedSize()
                    }
                    .buttonStyle(.borderedProminent)
                    Text("播完自动接下一个")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            if vm.selection == .bangumi || vm.selection == .drama {
                LazyVGrid(columns: columns4, alignment: .leading, spacing: TVLayout.rowSpacing) {
                    ForEach(vm.selection == .bangumi ? vm.bangumi : vm.drama) { season in
                        BangumiCell(season: season) {
                            if let id = season.seasonId {
                                seasonRequest = SeasonRequest(seasonId: id, title: season.title ?? "选集")
                            }
                        }
                    }
                }
            } else {
            LazyVGrid(columns: columns3, alignment: .leading, spacing: TVLayout.rowSpacing) {
                switch vm.selection {
                case .bangumi, .drama:
                    EmptyView()
                case .history:
                    ForEach(vm.history) { item in
                        VideoCell(
                            title: item.title ?? "",
                            pic: item.cover,
                            subtitle: historySubtitle(item),
                            duration: formatDuration(item.duration)
                        ) {
                            if let bvid = item.bvid { router.openDetail(bvid) }
                        }
                        .onAppear {
                            if item.id == vm.history.last?.id { vm.loadMoreHistory() }
                        }
                    }
                case .toview:
                    ForEach(vm.toview) { item in
                        VideoCell(item: item) { router.openDetail(item.bvid, playlist: vm.currentPlaylist) }
                    }
                case .fav(let mediaId):
                    ForEach(vm.favContent[mediaId] ?? []) { media in
                        VideoCell(
                            title: media.title ?? "",
                            pic: media.cover,
                            subtitle: "\(media.upper?.name ?? "") · \(formatCount(media.cntInfo?.play))播放",
                            duration: formatDuration(media.duration)
                        ) {
                            if let bvid = media.bvid { router.openDetail(bvid, playlist: vm.currentPlaylist) }
                        }
                        .onAppear {
                            if media.id == vm.favContent[mediaId]?.last?.id { vm.loadMoreFav(mediaId) }
                        }
                    }
                }
            }
            }

            if vm.loading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(60)
            } else if isCurrentEmpty {
                HintView(icon: "tray", text: "这里还是空的")
            }
            }
            .padding(.top, TVLayout.pageVertical)
            .padding(.bottom, 80)
        }
    }

    private var isCurrentEmpty: Bool {
        switch vm.selection {
        case .history: return vm.history.isEmpty
        case .toview: return vm.toview.isEmpty
        case .bangumi: return vm.bangumi.isEmpty
        case .drama: return vm.drama.isEmpty
        case .fav(let id): return (vm.favContent[id] ?? []).isEmpty
        }
    }

    private func playAll(_ playlist: Playlist) {
        Task {
            try? await playlist.ensureLoaded()
            if let first = playlist.items.first {
                playRequest = PlayRequest(bvid: first.bvid, playlist: playlist)
            }
        }
    }

    private func historySubtitle(_ item: HistoryItem) -> String {
        var parts = [item.authorName ?? ""]
        if let progress = item.progress, progress > 0 {
            parts.append("看到 \(formatDuration(progress))")
        } else if item.progress == -1 {
            parts.append("已看完")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
