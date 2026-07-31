import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var results: [SearchItem] = []
    @Published var searching = false
    @Published var errorText: String?

    private var searchTask: Task<Void, Never>?

    func search(_ keyword: String, debounce: Bool = true) {
        searchTask?.cancel()
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            errorText = nil
            searching = false
            return
        }
        searchTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            guard !Task.isCancelled, let self else { return }
            self.searching = true
            self.errorText = nil
            do {
                let items = try await FeedAPI.search(keyword: trimmed)
                guard !Task.isCancelled else { return }
                self.results = items
                if items.isEmpty { self.errorText = "没有找到相关视频" }
            } catch {
                guard !Task.isCancelled else { return }
                self.errorText = (error as? BiliError)?.errorDescription ?? error.localizedDescription
            }
            self.searching = false
        }
    }
}

struct SearchView: View {
    @EnvironmentObject private var router: PlaybackRouter
    @StateObject private var vm = SearchViewModel()
    @State private var query = ""

    var body: some View {
        ScrollView {
            LazyVStack(spacing: TVLayout.rowSpacing) {
                if vm.searching {
                    ProgressView().padding(.top, 80)
                } else if let error = vm.errorText {
                    HintView(icon: "magnifyingglass", text: error)
                } else if vm.results.isEmpty {
                    HintView(icon: "magnifyingglass", text: "搜索 B 站视频 / UP 主")
                }

                LazyVGrid(columns: TVLayout.columns4, alignment: .leading, spacing: TVLayout.rowSpacing) {
                    ForEach(vm.results) { item in
                        VideoCell(
                            title: item.cleanTitle,
                            pic: item.picURL,
                            subtitle: "\(item.author ?? "") · \(formatCount(item.play))播放",
                            duration: item.duration ?? ""
                        ) {
                            if let bvid = item.bvid {
                                router.openDetail(bvid)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, TVLayout.pageHorizontal)
            .padding(.vertical, TVLayout.pageVertical)
        }
        .searchable(text: $query, prompt: "搜索视频 / UP 主")
        .onChange(of: query) { _, newValue in
            vm.search(newValue)
        }
        .onSubmit(of: .search) {
            vm.search(query, debounce: false)
        }
    }
}
