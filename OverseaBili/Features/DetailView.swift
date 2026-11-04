import SwiftUI

@MainActor
final class DetailViewModel: ObservableObject {
    @Published var detail: ViewData?
    @Published var related: [VideoItem] = []
    @Published var liked = false
    @Published var coined = false
    @Published var favoured = false
    @Published var toViewAdded = false
    @Published var following = false
    @Published var loading = true
    @Published var errorText: String?
    @Published var message: String?
    /// 外部带入的清单(收藏夹/稍后再看/系列),否则用视频所属的 UGC 合集
    @Published var playlist: Playlist?
    @Published var comments: CommentListModel?

    func load(bvid: String, context: Playlist?) async {
        loading = true
        errorText = nil
        liked = false; coined = false; favoured = false; toViewAdded = false
        do {
            let detail = try await VideoAPI.detail(bvid: bvid)
            self.detail = detail
            playlist = context ?? Playlist(ugcSeasonOf: detail)
            comments = CommentListModel(oid: detail.aid, upMid: detail.owner?.mid ?? 0)
            if let playlist, playlist.sections == nil {
                try? await playlist.ensureLoaded(startAid: detail.aid)
            }
            related = (try? await VideoAPI.related(bvid: bvid)) ?? []
            if BiliClient.shared.csrf != nil {
                let aid = detail.aid
                async let likedState = ActionAPI.isLiked(aid: aid)
                async let coinState = ActionAPI.coinCount(aid: aid)
                async let favState = ActionAPI.isFavoured(aid: aid)
                liked = await likedState
                coined = await coinState > 0
                favoured = await favState
                if let mid = detail.owner?.mid {
                    let attribute = await ActionAPI.relation(mid: mid) ?? 0
                    following = attribute == 2 || attribute == 6
                }
            }
        } catch {
            errorText = (error as? BiliError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }

    private func requireLoginAid() -> Int? {
        guard BiliClient.shared.csrf != nil else {
            toast("请先到「设置」扫码登录")
            return nil
        }
        return detail?.aid
    }

    func toggleLike() {
        guard let aid = requireLoginAid() else { return }
        Task {
            do {
                if liked {
                    try await ActionAPI.unlike(aid: aid)
                } else {
                    try await ActionAPI.like(aid: aid)
                }
                liked.toggle()
                toast(liked ? "已点赞 👍" : "已取消点赞")
            } catch {
                toast(errorText(of: error))
            }
        }
    }

    func coin() {
        guard let aid = requireLoginAid() else { return }
        guard !coined else {
            toast("已经投过币啦")
            return
        }
        Task {
            do {
                try await ActionAPI.coin(aid: aid)
                coined = true
                toast("投币成功 🪙")
            } catch {
                toast(errorText(of: error))
            }
        }
    }

    func favorite(mid: Int?) {
        guard let aid = requireLoginAid() else { return }
        guard let mid else {
            toast("账号信息未就绪,稍后再试")
            return
        }
        Task {
            do {
                try await ActionAPI.favorite(aid: aid, mid: mid)
                favoured = true
                toast("已收藏 ⭐")
            } catch {
                toast(errorText(of: error))
            }
        }
    }

    /// 一键三连(点赞 + 投币 + 收藏)。
    func triple() {
        guard let aid = requireLoginAid() else { return }
        Task {
            do {
                try await ActionAPI.triple(aid: aid)
                liked = true
                coined = true
                favoured = true
                toast("一键三连成功 🎉")
            } catch {
                toast(errorText(of: error))
            }
        }
    }

    func toggleFollow() {
        guard requireLoginAid() != nil, let mid = detail?.owner?.mid else { return }
        Task {
            do {
                try await ActionAPI.modifyRelation(mid: mid, follow: !following)
                following.toggle()
                toast(following ? "已关注" : "已取消关注")
            } catch {
                toast(errorText(of: error))
            }
        }
    }

    func addToView() {
        guard let aid = requireLoginAid() else { return }
        Task {
            do {
                try await ActionAPI.addToView(aid: aid)
                toViewAdded = true
                toast("已加入稍后再看")
            } catch {
                toast(errorText(of: error))
            }
        }
    }

    private func errorText(of error: Error) -> String {
        (error as? BiliError)?.errorDescription ?? error.localizedDescription
    }

    private func toast(_ text: String) {
        message = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.message == text { self?.message = nil }
        }
    }
}

/// 视频详情页:大封面 + UP 主/数据/简介 + 互动按钮 + 相关推荐。
struct DetailScreen: View {
    let bvid: String
    /// 从收藏夹/稍后再看/合集进入时带上清单,播放时连播
    var playlist: Playlist? = nil

    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = DetailViewModel()
    @State private var currentBvid = ""
    /// 相关推荐跳走后就不再属于原清单
    @State private var contextPlaylist: Playlist?
    @State private var playRequest: PlayRequest?
    @State private var upRequest: UpSpaceRequest?
    @State private var playlistRequest: PlaylistRequest?
    @State private var localProgress = 0.0

    private struct PlaylistRequest: Identifiable {
        let playlist: Playlist
        var id: ObjectIdentifier { ObjectIdentifier(playlist) }
    }

    var body: some View {
        // 番剧 bvid 的详情带跳转地址 → 走选集页
        if let epId = vm.detail?.redirectEpId {
            SeasonScreen(seasonId: 0, fallbackTitle: vm.detail?.title ?? "选集", epId: epId)
        } else {
            content
        }
    }

    private var content: some View {
        ZStack(alignment: .bottom) {
            Color(red: 0.07, green: 0.07, blue: 0.09).ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 44) {
                    if vm.loading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 300)
                    } else if let error = vm.errorText {
                        VStack(spacing: 20) {
                            Text(error).foregroundStyle(.secondary)
                            Button("重试") { Task { await vm.load(bvid: currentBvid, context: contextPlaylist) } }
                            Button("返回") { dismiss() }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 260)
                    } else if let detail = vm.detail {
                        header(detail)
                        actionsRow(detail)
                        if (detail.pages?.count ?? 0) > 1 {
                            pagesRail(detail.pages ?? [])
                        }
                        if let playlist = vm.playlist {
                            PlaylistRail(playlist: playlist, currentBvid: detail.bvid) { item in
                                play(bvid: item.bvid)
                            } onShowAll: {
                                playlistRequest = PlaylistRequest(playlist: playlist)
                            }
                        }
                        if !vm.related.isEmpty {
                            relatedRail
                        }
                        if let comments = vm.comments {
                            VStack(alignment: .leading, spacing: 24) {
                                Text("评论 \(formatCount(detail.stat?.reply))")
                                    .font(.title3.bold())
                                CommentsView(model: comments)
                                    .id(comments.oid)
                            }
                        }
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 56)
            }

            if let message = vm.message {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 48)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.message)
        .task(id: currentBvid) {
            guard !currentBvid.isEmpty else { return }
            localProgress = ProgressStore.load(bvid: currentBvid) ?? 0
            await vm.load(bvid: currentBvid, context: contextPlaylist)
        }
        .onAppear {
            if currentBvid.isEmpty {
                contextPlaylist = playlist
                currentBvid = bvid
            }
        }
        .onChange(of: playRequest == nil) { _, closed in
            // 从播放器回来:刷新"继续播放"位置
            if closed { localProgress = ProgressStore.load(bvid: currentBvid) ?? 0 }
        }
        .fullScreenCover(item: $playRequest) { request in
            PlayerScreen(request: request)
        }
        .fullScreenCover(item: $playlistRequest) { request in
            PlaylistScreen(playlist: request.playlist)
        }
        .fullScreenCover(item: $upRequest) { request in
            UpSpaceScreen(mid: request.mid, name: request.name, face: request.face)
        }
    }

    private func play(bvid: String? = nil, pageIndex: Int = 0) {
        playRequest = PlayRequest(bvid: bvid ?? currentBvid, pageIndex: pageIndex, playlist: vm.playlist)
    }

    /// 本地记录的续播位置(服务端进度在播放器里优先生效)。
    private func playTitle(_ detail: ViewData) -> String {
        let duration = Double(detail.duration ?? 0)
        guard localProgress > 10, localProgress < duration * 0.95 else { return "播放" }
        return "继续播放 \(formatDuration(Int(localProgress)))"
    }

    private func pagesRail(_ pages: [PageInfo]) -> some View {
        RailSection(title: "选集(\(pages.count)P)") {
            ForEach(Array(pages.enumerated()), id: \.element.cid) { index, page in
                Button {
                    play(pageIndex: index)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("P\(page.page)").font(.caption.bold())
                        Text(page.part ?? "").font(.caption2).lineLimit(2)
                    }
                    .frame(width: 320, height: 110, alignment: .topLeading)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func header(_ detail: ViewData) -> some View {
        HStack(alignment: .top, spacing: 56) {
            Button {
                play()
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    PosterImage(urlString: detail.pic, width: 720, height: 405)
                    Text(formatDuration(detail.duration))
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(14)
                }
                .frame(width: 720, height: 405)
            }
            .buttonStyle(.card)

            VStack(alignment: .leading, spacing: 22) {
                Text(detail.title)
                    .font(.title3.bold())
                    .lineLimit(3)

                // 点击 UP 主进入其空间(投稿列表)
                Button {
                    if let mid = detail.owner?.mid {
                        upRequest = UpSpaceRequest(
                            mid: mid,
                            name: detail.owner?.name ?? "UP主",
                            face: detail.owner?.face
                        )
                    }
                } label: {
                    HStack(spacing: 16) {
                        PosterImage(urlString: detail.owner?.face, width: 96, height: 96)
                            .frame(width: 56, height: 56)
                            .clipShape(Circle())
                        Text(detail.owner?.name ?? "-")
                            .font(.headline)
                        if let pubdate = detail.pubdate {
                            Text(Self.dateText(pubdate))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                }
                .buttonStyle(.card)

                Button {
                    vm.toggleFollow()
                } label: {
                    Label(vm.following ? "已关注" : "关注",
                          systemImage: vm.following ? "checkmark" : "plus")
                        .font(.caption)
                        .fixedSize()
                }
                .buttonStyle(.bordered)

                Text("\(formatCount(detail.stat?.view)) 播放 · \(formatCount(detail.stat?.danmaku)) 弹幕 · \(formatCount(detail.stat?.like)) 点赞 · \(formatCount(detail.stat?.coin)) 投币 · \(formatCount(detail.stat?.favorite)) 收藏 · \(formatCount(detail.stat?.reply)) 评论")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let desc = detail.desc, !desc.isEmpty, desc != "-" {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 405)
        }
    }

    /// 互动按钮单独一行:放在封面右侧的窄栏里放不下,会把整栏撑出屏幕。
    private func actionsRow(_ detail: ViewData) -> some View {
        HStack(spacing: 18) {
            Button {
                play()
            } label: {
                Label(playTitle(detail), systemImage: "play.fill")
                    .fixedSize()
            }
            .buttonStyle(.borderedProminent)

            actionButton(
                vm.toViewAdded ? "已加入" : "稍后",
                icon: vm.toViewAdded ? "checkmark.circle.fill" : "clock"
            ) { vm.addToView() }
            actionButton(
                vm.liked ? "已点赞" : "点赞",
                icon: vm.liked ? "hand.thumbsup.fill" : "hand.thumbsup"
            ) { vm.toggleLike() }
            actionButton(
                vm.coined ? "已投币" : "投币",
                icon: "bitcoinsign.circle"
            ) { vm.coin() }
            actionButton(
                vm.favoured ? "已收藏" : "收藏",
                icon: vm.favoured ? "star.fill" : "star"
            ) { vm.favorite(mid: auth.mid) }
            actionButton("三连", icon: "hands.sparkles") { vm.triple() }
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .fixedSize()
        }
        .buttonStyle(.bordered)
    }

    private var relatedRail: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("相关推荐")
                .font(.title3.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(vm.related) { item in
                        VideoCell(
                            title: item.title,
                            pic: item.pic,
                            subtitle: "\(item.owner?.name ?? "") · \(formatCount(item.stat?.view))播放",
                            duration: formatDuration(item.duration)
                        ) {
                            contextPlaylist = nil
                            currentBvid = item.bvid
                        }
                        .frame(width: 380)
                    }
                }
                .padding(.vertical, 28)
            }
        }
    }

    private static func dateText(_ timestamp: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }
}

/// 详情页的清单行:只放当前附近的 30 条,完整列表进清单页。
private struct PlaylistRail: View {
    @ObservedObject var playlist: Playlist
    let currentBvid: String
    let onPlay: (PlaylistItem) -> Void
    let onShowAll: () -> Void

    var body: some View {
        let start = max(0, (playlist.index(of: currentBvid) ?? 0) - 5)
        let items = Array(playlist.items.dropFirst(start).prefix(30))
        if !items.isEmpty {
            RailSection(title: "\(playlist.kind) · \(playlist.title)(\(max(playlist.total, playlist.items.count)))") {
                ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                    VideoCell(
                        title: item.title,
                        pic: item.cover,
                        subtitle: item.bvid == currentBvid ? "当前" : "\(start + offset + 1) · \(item.author)",
                        duration: formatDuration(item.duration)
                    ) {
                        onPlay(item)
                    }
                    .frame(width: TVLayout.railCardWidth)
                }
                Button(action: onShowAll) {
                    Text("查看全部 ›")
                        .font(.headline)
                        .frame(width: 300, height: 180)
                }
                .buttonStyle(.card)
            }
        }
    }
}
