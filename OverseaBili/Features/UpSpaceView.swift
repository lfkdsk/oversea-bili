import SwiftUI

struct UpSpaceRequest: Identifiable {
    let mid: Int
    let name: String
    let face: String?
    var id: Int { mid }
}

@MainActor
final class UpSpaceViewModel: ObservableObject {
    @Published var rows: [UpVideoRow] = []
    @Published var followers: Int?
    @Published var loading = false
    @Published var errorText: String?

    private var page = 1
    private var offset: String?
    private var hasMore = true
    private var usingFallback = false
    private var loadedOnce = false

    func initialLoad(mid: Int) async {
        guard !loadedOnce else { return }
        loadedOnce = true
        followers = await SpaceAPI.followers(mid: mid)
        await loadPage(mid: mid)
    }

    func loadMoreIfNeeded(mid: Int, current: UpVideoRow) async {
        guard hasMore, !loading, current.id == rows.last?.id else { return }
        await loadPage(mid: mid)
    }

    private func loadPage(mid: Int) async {
        loading = true
        errorText = nil
        do {
            if usingFallback {
                try await loadFallbackPage(mid: mid)
            } else {
                do {
                    let videos = try await SpaceAPI.videos(mid: mid, page: page)
                    let known = Set(rows.map(\.id))
                    rows += videos.compactMap { Self.row(from: $0) }.filter { !known.contains($0.id) }
                    hasMore = videos.count >= 25
                    page += 1
                } catch {
                    // arc/search 风控:回落到该 UP 的动态投稿流
                    guard rows.isEmpty else { throw error }
                    usingFallback = true
                    try await loadFallbackPage(mid: mid)
                }
            }
            if rows.isEmpty {
                errorText = "这位 UP 还没有投稿"
            }
        } catch {
            if rows.isEmpty {
                errorText = (error as? BiliError)?.errorDescription ?? error.localizedDescription
            }
            hasMore = false
        }
        loading = false
    }

    private func loadFallbackPage(mid: Int) async throws {
        let data = try await DynamicAPI.spaceFeed(hostMid: mid, offset: offset)
        let known = Set(rows.map(\.id))
        let newRows = (data.items ?? [])
            .compactMap { DynVideoRow(polymer: $0) }
            .map { row in
                UpVideoRow(id: row.id, bvid: row.bvid, title: row.title,
                           cover: row.cover, subtitle: row.pubTime, duration: row.durationText)
            }
            .filter { !known.contains($0.id) }
        rows += newRows
        offset = data.offset
        hasMore = data.hasMore ?? false
    }

    private static func row(from video: SpaceVideo) -> UpVideoRow? {
        guard let bvid = video.bvid else { return nil }
        var parts: [String] = []
        if let play = video.play?.value, let count = Int(play) {
            parts.append("\(formatCount(count))播放")
        }
        if let created = video.created {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            parts.append(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(created))))
        }
        return UpVideoRow(
            id: bvid,
            bvid: bvid,
            title: video.title ?? "",
            cover: video.pic,
            subtitle: parts.joined(separator: " · "),
            duration: video.length ?? ""
        )
    }
}

/// UP 空间页:头像/昵称/粉丝 + 投稿视频流。
struct UpSpaceScreen: View {
    let mid: Int
    let name: String
    let face: String?

    @StateObject private var vm = UpSpaceViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var detailRequest: PlayRequest?

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.09).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: TVLayout.rowSpacing) {
                    HStack(spacing: 24) {
                        PosterImage(urlString: face, width: 160, height: 160)
                            .frame(width: 96, height: 96)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 8) {
                            Text(name)
                                .font(.title3.bold())
                            Text("\(vm.followers.map { formatCount($0) } ?? "-") 粉丝 · 最新投稿")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    if let error = vm.errorText {
                        HintView(icon: "person.crop.rectangle.stack", text: error)
                    }

                    LazyVGrid(columns: TVLayout.columns4, alignment: .leading, spacing: TVLayout.rowSpacing) {
                        ForEach(vm.rows) { row in
                            VideoCell(
                                title: row.title,
                                pic: row.cover,
                                subtitle: row.subtitle,
                                duration: row.duration
                            ) {
                                detailRequest = PlayRequest(bvid: row.bvid)
                            }
                            .onAppear {
                                Task { await vm.loadMoreIfNeeded(mid: mid, current: row) }
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
                .padding(.top, TVLayout.pageVertical)
                .padding(.bottom, 80)
            }
        }
        .task {
            await vm.initialLoad(mid: mid)
        }
        .fullScreenCover(item: $detailRequest) { request in
            DetailScreen(bvid: request.bvid)
        }
    }
}
