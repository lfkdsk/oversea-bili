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
    @Published var collections: [UpCollection] = []
    @Published var card: SpaceCardData?
    @Published var following = false
    @Published var loading = false
    @Published var errorText: String?
    @Published var message: String?

    private enum Source { case medialist, arc, dynamic }

    private var source = Source.medialist
    private var page = 1
    private var offset: String?
    private var hasMore = true
    private var loadedOnce = false
    private var uploads: Playlist?

    func initialLoad(mid: Int) async {
        guard !loadedOnce else { return }
        loadedOnce = true
        uploads = Playlist(title: "投稿", kind: "投稿", mlType: Playlist.uploadsType, bizId: mid)
        async let cardTask = try? SpaceAPI.card(mid: mid)
        async let collectionsTask = try? SpaceAPI.collections(mid: mid)
        async let relationTask = BiliClient.shared.csrf != nil ? ActionAPI.relation(mid: mid) : nil
        card = await cardTask
        collections = await collectionsTask ?? []
        let attribute = await relationTask ?? 0
        following = attribute == 2 || attribute == 6
        await loadPage(mid: mid)
    }

    func loadMoreIfNeeded(mid: Int, current: UpVideoRow) async {
        guard hasMore, !loading, current.id == rows.last?.id else { return }
        await loadPage(mid: mid)
    }

    func toggleFollow(mid: Int) {
        guard BiliClient.shared.csrf != nil else {
            toast("请先到「设置」扫码登录")
            return
        }
        Task {
            do {
                try await ActionAPI.modifyRelation(mid: mid, follow: !following)
                following.toggle()
                toast(following ? "已关注" : "已取消关注")
            } catch {
                toast((error as? BiliError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func toast(_ text: String) {
        message = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.message == text { self?.message = nil }
        }
    }

    /// 投稿列表:arc/search 海外实测稳定 -352,优先 medialist type=1,失败依次回落 arc/search、动态投稿流。
    private func loadPage(mid: Int) async {
        loading = true
        errorText = nil
        do {
            try await loadFromSource(mid: mid)
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

    private func loadFromSource(mid: Int) async throws {
        switch source {
        case .medialist:
            do {
                try await loadMedialistPage()
            } catch {
                guard rows.isEmpty else { throw error }
                source = .arc
                try await loadFromSource(mid: mid)
            }
        case .arc:
            do {
                let videos = try await SpaceAPI.videos(mid: mid, page: page)
                let known = Set(rows.map(\.id))
                rows += videos.compactMap { Self.row(from: $0) }.filter { !known.contains($0.id) }
                hasMore = videos.count >= 25
                page += 1
            } catch {
                guard rows.isEmpty else { throw error }
                source = .dynamic
                try await loadFromSource(mid: mid)
            }
        case .dynamic:
            try await loadFallbackPage(mid: mid)
        }
    }

    private func loadMedialistPage() async throws {
        guard let uploads else { return }
        let before = uploads.items.count
        if before == 0 {
            try await uploads.ensureLoaded()
        } else {
            try await uploads.loadMore()
        }
        rows += uploads.items.dropFirst(before).map { item in
            UpVideoRow(id: item.bvid, bvid: item.bvid, title: item.title, cover: item.cover,
                       subtitle: "\(formatCount(item.views))播放", duration: formatDuration(item.duration))
        }
        hasMore = uploads.hasMore
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

/// UP 空间页:头像/昵称/粉丝/签名/关注 + 合集与系列 + 投稿视频流。
struct UpSpaceScreen: View {
    let mid: Int
    let name: String
    let face: String?

    @StateObject private var vm = UpSpaceViewModel()
    @State private var detailRequest: PlayRequest?
    @State private var playlistRequest: UpCollection?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(red: 0.07, green: 0.07, blue: 0.09).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: TVLayout.rowSpacing) {
                    header

                    if !vm.collections.isEmpty {
                        RailSection(title: "合集与系列(\(vm.collections.count))") {
                            ForEach(vm.collections) { collection in
                                VideoCell(
                                    title: collection.title,
                                    pic: collection.cover,
                                    subtitle: "\(collection.label) · \(collection.total) 个视频",
                                    duration: ""
                                ) {
                                    playlistRequest = collection
                                }
                                .frame(width: TVLayout.railCardWidth)
                            }
                        }
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

            if let message = vm.message {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 48)
            }
        }
        .task {
            await vm.initialLoad(mid: mid)
        }
        .fullScreenCover(item: $detailRequest) { request in
            DetailScreen(bvid: request.bvid)
        }
        .fullScreenCover(item: $playlistRequest) { collection in
            PlaylistScreen(playlist: Playlist(title: collection.title, kind: collection.label,
                                              mlType: collection.mlType, bizId: collection.bizId))
        }
    }

    private var header: some View {
        HStack(spacing: 24) {
            PosterImage(urlString: vm.card?.card?.face ?? face, width: 160, height: 160)
                .frame(width: 96, height: 96)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(vm.card?.card?.name ?? name)
                    .font(.title3.bold())
                Text("\(formatCount(vm.card?.follower)) 粉丝 · \(formatCount(vm.card?.archiveCount)) 投稿")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let sign = vm.card?.card?.sign, !sign.isEmpty {
                    Text(sign)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button {
                vm.toggleFollow(mid: mid)
            } label: {
                Label(vm.following ? "已关注" : "关注", systemImage: vm.following ? "checkmark" : "plus")
                    .fixedSize()
            }
            .buttonStyle(.bordered)
        }
    }
}
