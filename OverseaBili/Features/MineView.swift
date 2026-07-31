import SwiftUI

enum MineSection: Hashable {
    case history
    case toview
    case fav(Int)
}

@MainActor
final class MineViewModel: ObservableObject {
    @Published var selection: MineSection = .history
    @Published var folders: [ActionAPI.FavFolder] = []
    @Published var history: [HistoryItem] = []
    @Published var toview: [VideoItem] = []
    @Published var favContent: [Int: [FavMedia]] = [:]
    @Published var loading = false

    private var lastLoad: [MineSection: Date] = [:]

    /// 每次进入页面都调用:收藏夹列表懒加载一次,当前分区按新鲜度刷新。
    func onAppear(mid: Int?) async {
        guard let mid else { return }
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
        favContent = [:]
        lastLoad = [:]
    }

    /// force=false 时 30 秒内不重复拉,避免焦点来回移动刷爆接口。
    private func load(_ section: MineSection, force: Bool) async {
        if !force, let at = lastLoad[section], Date().timeIntervalSince(at) < 30 { return }
        loading = true
        switch section {
        case .history:
            history = (try? await MineAPI.history()) ?? []
        case .toview:
            toview = (try? await MineAPI.toview()) ?? []
        case .fav(let mediaId):
            favContent[mediaId] = (try? await MineAPI.favResources(mediaId: mediaId)) ?? []
        }
        lastLoad[section] = Date()
        loading = false
    }
}

/// 我的:左侧选项卡(历史 / 稍后再看 / 收藏夹)+ 右侧内容区。
struct MineView: View {
    @EnvironmentObject private var router: PlaybackRouter
    @EnvironmentObject private var auth: AuthManager
    @StateObject private var vm = MineViewModel()
    @State private var showLogin = false
    @State private var showSettings = false

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

            sideButton("观看历史", icon: "clock.arrow.circlepath", section: .history)
            sideButton("稍后再看", icon: "text.badge.plus", section: .toview)
            ForEach(vm.folders.prefix(6), id: \.id) { folder in
                sideButton(folder.title ?? "收藏夹", icon: "star", section: .fav(folder.id))
            }

            Spacer()

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
            LazyVGrid(columns: columns3, alignment: .leading, spacing: TVLayout.rowSpacing) {
                switch vm.selection {
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
                    }
                case .toview:
                    ForEach(vm.toview) { item in
                        VideoCell(item: item) { router.openDetail(item.bvid) }
                    }
                case .fav(let mediaId):
                    ForEach(vm.favContent[mediaId] ?? []) { media in
                        VideoCell(
                            title: media.title ?? "",
                            pic: media.cover,
                            subtitle: "\(media.upper?.name ?? "") · \(formatCount(media.cntInfo?.play))播放",
                            duration: formatDuration(media.duration)
                        ) {
                            if let bvid = media.bvid { router.openDetail(bvid) }
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
        case .fav(let id): return (vm.favContent[id] ?? []).isEmpty
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
