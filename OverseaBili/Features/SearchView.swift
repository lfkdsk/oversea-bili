import SwiftUI

enum SearchScope: String, CaseIterable, Identifiable {
    case video = "视频"
    case bangumi = "番剧"
    case movie = "影视"
    case user = "UP主"

    var id: String { rawValue }
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var scope: SearchScope = .video
    @Published var videos: [SearchItem] = []
    @Published var medias: [SearchMedia] = []
    @Published var users: [SearchUser] = []
    @Published var hotWords: [String] = []
    @Published var suggestions: [String] = []
    @Published var history: [String] = UserDefaults.standard.stringArray(forKey: "search.history") ?? []
    @Published var searching = false
    @Published var errorText: String?
    /// 已提交的关键词(用于切换分类时复用)
    @Published private(set) var activeKeyword = ""

    private var searchTask: Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?
    private var loadedHot = false
    private var page = 1
    private var hasMore = false
    private var loadingMore = false

    func loadHot() async {
        guard !loadedHot else { return }
        loadedHot = true
        hotWords = await FeedAPI.hotSearch()
    }

    /// 输入变化:只更新建议,不搜索(避免每个字符打一次搜索接口)。
    func inputChanged(_ text: String) {
        suggestTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1 else {
            suggestions = []
            return
        }
        suggestTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let list = await FeedAPI.suggestions(for: trimmed)
            guard !Task.isCancelled else { return }
            self?.suggestions = list
        }
    }

    func submit(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activeKeyword = trimmed
        suggestions = []
        history = [trimmed] + history.filter { $0 != trimmed }.prefix(19)
        UserDefaults.standard.set(history, forKey: "search.history")
        run()
    }

    /// 回到搜索首页(热搜 / 历史)。
    func clearResults() {
        searchTask?.cancel()
        activeKeyword = ""
        videos = []
        medias = []
        users = []
        errorText = nil
        searching = false
        hasMore = false
    }

    /// 滚到结果末尾时翻页。
    func loadMoreIfNeeded(isLast: Bool) {
        guard isLast, hasMore, !loadingMore, !searching else { return }
        loadingMore = true
        let keyword = activeKeyword
        let scope = scope
        let next = page + 1
        Task { [weak self] in
            guard let self else { return }
            defer { self.loadingMore = false }
            do {
                switch scope {
                case .video:
                    let result = try await FeedAPI.search(keyword: keyword, page: next)
                    guard keyword == self.activeKeyword, scope == self.scope else { return }
                    let known = Set(self.videos.map(\.id))
                    self.videos += result.items.filter { !known.contains($0.id) }
                    self.hasMore = result.more
                case .bangumi, .movie:
                    let result = try await FeedAPI.searchMedia(keyword: keyword, movie: scope == .movie, page: next)
                    guard keyword == self.activeKeyword, scope == self.scope else { return }
                    let known = Set(self.medias.compactMap(\.seasonId))
                    self.medias += result.items.filter { !known.contains($0.seasonId ?? 0) }
                    self.hasMore = result.more
                case .user:
                    let result = try await FeedAPI.searchUser(keyword: keyword, page: next)
                    guard keyword == self.activeKeyword, scope == self.scope else { return }
                    let known = Set(self.users.compactMap(\.mid))
                    self.users += result.items.filter { !known.contains($0.mid ?? 0) }
                    self.hasMore = result.more
                }
                self.page = next
            } catch {
                self.hasMore = false
            }
        }
    }

    func changeScope(_ next: SearchScope) {
        guard next != scope else { return }
        scope = next
        guard !activeKeyword.isEmpty else { return }
        run()
    }

    private func run() {
        searchTask?.cancel()
        let keyword = activeKeyword
        let scope = scope
        searchTask = Task { [weak self] in
            guard let self else { return }
            self.searching = true
            self.errorText = nil
            self.page = 1
            self.hasMore = false
            do {
                switch scope {
                case .video:
                    let result = try await FeedAPI.search(keyword: keyword)
                    guard !Task.isCancelled else { return }
                    videos = result.items
                    hasMore = result.more
                    if videos.isEmpty { errorText = "没有找到相关视频" }
                case .bangumi, .movie:
                    let result = try await FeedAPI.searchMedia(keyword: keyword, movie: scope == .movie)
                    guard !Task.isCancelled else { return }
                    medias = result.items
                    hasMore = result.more
                    if medias.isEmpty { errorText = scope == .movie ? "没有找到相关影视" : "没有找到相关番剧" }
                case .user:
                    let result = try await FeedAPI.searchUser(keyword: keyword)
                    guard !Task.isCancelled else { return }
                    users = result.items
                    hasMore = result.more
                    if users.isEmpty { errorText = "没有找到相关 UP 主" }
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorText = (error as? BiliError)?.errorDescription ?? error.localizedDescription
            }
            self.searching = false
        }
    }
}

struct SearchView: View {
    @EnvironmentObject private var router: PlaybackRouter
    @StateObject private var vm = SearchViewModel()
    @State private var query = ""
    @State private var seasonRequest: SeasonRequest?
    @State private var upRequest: UpSpaceRequest?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 36) {
                if !vm.activeKeyword.isEmpty {
                    scopePicker
                }

                if !vm.suggestions.isEmpty {
                    wordSection(title: "搜索建议", words: vm.suggestions)
                } else if vm.activeKeyword.isEmpty {
                    if !vm.hotWords.isEmpty {
                        wordSection(title: "热搜", words: vm.hotWords)
                    }
                    if !vm.history.isEmpty {
                        wordSection(title: "搜索历史", words: vm.history)
                    }
                }

                if vm.searching {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if let error = vm.errorText {
                    HintView(icon: "magnifyingglass", text: error)
                } else if vm.activeKeyword.isEmpty, vm.hotWords.isEmpty, vm.history.isEmpty {
                    HintView(icon: "magnifyingglass", text: "搜索视频 / 番剧 / UP 主")
                }

                // 海外 IP 的网页搜索搜不到受地区限制的番剧影视,要靠解析服务器
                if vm.scope == .bangumi || vm.scope == .movie, !vm.activeKeyword.isEmpty,
                   CDNSettings.shared.roamOn, !RoamAPI.isAuthorized {
                    Text("受地区限制的番剧影视需要经解析服务器才搜得到:到 我的 → 设置 → 番剧解析 扫码授权")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                results
            }
            .padding(.horizontal, TVLayout.pageHorizontal)
            .padding(.top, 20)
            .padding(.bottom, 80)
        }
        .searchable(text: $query, prompt: "搜索视频 / 番剧 / UP 主")
        .onChange(of: query) { _, newValue in
            vm.inputChanged(newValue)
            if newValue.isEmpty { vm.clearResults() }
        }
        .onSubmit(of: .search) {
            vm.submit(query)
        }
        .task { await vm.loadHot() }
        .fullScreenCover(item: $seasonRequest) { request in
            SeasonScreen(seasonId: request.seasonId, fallbackTitle: request.title)
        }
        .fullScreenCover(item: $upRequest) { request in
            UpSpaceScreen(mid: request.mid, name: request.name, face: request.face)
        }
    }

    private var scopePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(SearchScope.allCases) { item in
                    Button {
                        vm.changeScope(item)
                    } label: {
                        HStack(spacing: 8) {
                            if vm.scope == item {
                                Circle().fill(.pink).frame(width: 10, height: 10)
                            }
                            Text(item.rawValue)
                                .font(.caption.bold())
                                .foregroundStyle(vm.scope == item ? Color.primary : Color.secondary)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func wordSection(title: String, words: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(words.prefix(20), id: \.self) { word in
                        Button {
                            query = word
                            vm.submit(word)
                        } label: {
                            Text(word)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        switch vm.scope {
        case .video:
            LazyVGrid(columns: TVLayout.columns4, alignment: .leading, spacing: TVLayout.rowSpacing) {
                ForEach(vm.videos) { item in
                    VideoCell(
                        title: item.cleanTitle,
                        pic: item.picURL,
                        subtitle: "\(item.author ?? "") · \(formatCount(item.play))播放",
                        duration: item.duration ?? ""
                    ) {
                        if let bvid = item.bvid { router.openDetail(bvid) }
                    }
                    .onAppear { vm.loadMoreIfNeeded(isLast: item.id == vm.videos.last?.id) }
                }
            }
        case .bangumi, .movie:
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: TVLayout.gridSpacing, alignment: .top), count: 6),
                alignment: .leading,
                spacing: TVLayout.rowSpacing
            ) {
                ForEach(vm.medias) { media in
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            seasonRequest = SeasonRequest(seasonId: media.id, title: media.cleanTitle)
                        } label: {
                            PosterImage(urlString: media.coverURL, width: 320, height: 426)
                        }
                        .buttonStyle(.card)
                        .frame(width: 220, height: 293)

                        Text(media.cleanTitle)
                            .font(.caption)
                            .lineLimit(2)
                            .frame(width: 220, height: 60, alignment: .topLeading)
                    }
                    .onAppear { vm.loadMoreIfNeeded(isLast: media.seasonId == vm.medias.last?.seasonId) }
                }
            }
        case .user:
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: TVLayout.gridSpacing, alignment: .top), count: 5),
                alignment: .leading,
                spacing: TVLayout.rowSpacing
            ) {
                ForEach(vm.users) { user in
                    VStack(spacing: 12) {
                        Button {
                            upRequest = UpSpaceRequest(mid: user.id, name: user.uname ?? "", face: user.faceURL)
                        } label: {
                            PosterImage(urlString: user.faceURL, width: 200, height: 200)
                                .frame(width: 140, height: 140)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.card)
                        .clipShape(Circle())

                        Text(user.uname ?? "")
                            .font(.caption)
                            .lineLimit(1)
                        Text("\(formatCount(user.fans)) 粉丝 · \(formatCount(user.videos)) 投稿")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: 240)
                    .onAppear { vm.loadMoreIfNeeded(isLast: user.mid == vm.users.last?.mid) }
                }
            }
        }
    }
}
