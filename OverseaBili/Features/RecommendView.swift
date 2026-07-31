import SwiftUI

@MainActor
final class RecommendViewModel: ObservableObject {
    @Published var items: [VideoItem] = []
    @Published var loading = false
    @Published var errorText: String?

    private var loadedOnce = false

    func initialLoad() async {
        guard !loadedOnce else { return }
        loadedOnce = true
        await reload()
    }

    func reload() async {
        loading = true
        errorText = nil
        do {
            items = try await FeedAPI.recommended(count: 24)
        } catch {
            errorText = (error as? BiliError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }

    /// 追加一批新推荐。
    func loadMore() async {
        guard !loading else { return }
        let more = (try? await FeedAPI.recommended(count: 24)) ?? []
        let known = Set(items.map(\.bvid))
        items += more.filter { !known.contains($0.bvid) }
    }
}

struct RecommendView: View {
    @EnvironmentObject private var router: PlaybackRouter
    @StateObject private var vm = RecommendViewModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TVLayout.rowSpacing) {
                if let error = vm.errorText {
                    HintView(icon: "wifi.exclamationmark", text: error, actionTitle: "重试") {
                        Task { await vm.reload() }
                    }
                }

                LazyVGrid(columns: TVLayout.columns4, alignment: .leading, spacing: TVLayout.rowSpacing) {
                    ForEach(vm.items) { item in
                        VideoCell(item: item) {
                            router.openDetail(item.bvid)
                        }
                        .onAppear {
                            if item.bvid == vm.items.last?.bvid {
                                Task { await vm.loadMore() }
                            }
                        }
                    }
                }

                if vm.loading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(60)
                }
            }
            .padding(.horizontal, TVLayout.pageHorizontal)
            .padding(.vertical, TVLayout.pageVertical)
        }
        .task { await vm.initialLoad() }
        .onPlayPauseCommand {
            Task { await vm.reload() }
        }
    }
}
