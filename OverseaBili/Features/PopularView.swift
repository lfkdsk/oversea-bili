import SwiftUI

@MainActor
final class PopularViewModel: ObservableObject {
    /// rid == nil 表示"综合热门",否则是分区排行。
    @Published var selectedRid: Int? = nil
    @Published var items: [VideoItem] = []
    @Published var loading = false
    @Published var errorText: String?

    private var popularPage = 1
    private var popularEnded = false
    private var loadedOnce = false

    func initialLoad() async {
        guard !loadedOnce else { return }
        loadedOnce = true
        await reload()
    }

    func select(_ rid: Int?) {
        guard rid != selectedRid else { return }
        selectedRid = rid
        items = []
        Task { await reload() }
    }

    func reload() async {
        loading = true
        errorText = nil
        popularPage = 1
        popularEnded = false
        do {
            if let rid = selectedRid {
                items = try await RankAPI.ranking(rid: rid)
            } else {
                items = try await FeedAPI.popular(page: 1)
                popularPage = 2
            }
        } catch {
            errorText = (error as? BiliError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }

    func loadMoreIfNeeded(current: VideoItem) async {
        // 排行榜一次性返回,只有综合热门有分页
        guard selectedRid == nil, !popularEnded, !loading,
              current.bvid == items.last?.bvid else { return }
        do {
            let more = try await FeedAPI.popular(page: popularPage)
            if more.isEmpty { popularEnded = true }
            let known = Set(items.map(\.bvid))
            items += more.filter { !known.contains($0.bvid) }
            popularPage += 1
        } catch {
            popularEnded = true
        }
    }
}

struct PopularView: View {
    @EnvironmentObject private var router: PlaybackRouter
    @StateObject private var vm = PopularViewModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TVLayout.rowSpacing) {
                chipRow

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
                            Task { await vm.loadMoreIfNeeded(current: item) }
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

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                chip("综合热门", rid: nil)
                ForEach(RankAPI.regions, id: \.rid) { region in
                    chip("\(region.name)榜", rid: region.rid)
                }
            }
            .padding(.vertical, 16)
        }
    }

    private func chip(_ title: String, rid: Int?) -> some View {
        let selected = vm.selectedRid == rid
        return Button {
            vm.select(rid)
        } label: {
            HStack(spacing: 8) {
                if selected {
                    Circle().fill(.pink).frame(width: 10, height: 10)
                }
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.bordered)
    }
}
