import SwiftUI

@MainActor
final class DetailViewModel: ObservableObject {
    @Published var detail: ViewData?
    @Published var related: [VideoItem] = []
    @Published var liked = false
    @Published var coined = false
    @Published var favoured = false
    @Published var toViewAdded = false
    @Published var loading = true
    @Published var errorText: String?
    @Published var message: String?

    func load(bvid: String) async {
        loading = true
        errorText = nil
        liked = false; coined = false; favoured = false; toViewAdded = false
        do {
            let detail = try await VideoAPI.detail(bvid: bvid)
            self.detail = detail
            related = (try? await VideoAPI.related(bvid: bvid)) ?? []
            if BiliClient.shared.csrf != nil {
                let aid = detail.aid
                async let likedState = ActionAPI.isLiked(aid: aid)
                async let coinState = ActionAPI.coinCount(aid: aid)
                async let favState = ActionAPI.isFavoured(aid: aid)
                liked = await likedState
                coined = await coinState > 0
                favoured = await favState
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

    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = DetailViewModel()
    @State private var currentBvid = ""
    @State private var playRequest: PlayRequest?
    @State private var upRequest: UpSpaceRequest?

    var body: some View {
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
                            Button("返回") { dismiss() }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 260)
                    } else if let detail = vm.detail {
                        header(detail)
                        if !vm.related.isEmpty {
                            relatedRail
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
            await vm.load(bvid: currentBvid)
        }
        .onAppear {
            if currentBvid.isEmpty { currentBvid = bvid }
        }
        .fullScreenCover(item: $playRequest) { request in
            PlayerScreen(bvid: request.bvid)
        }
        .fullScreenCover(item: $upRequest) { request in
            UpSpaceScreen(mid: request.mid, name: request.name, face: request.face)
        }
    }

    private func header(_ detail: ViewData) -> some View {
        HStack(alignment: .top, spacing: 56) {
            Button {
                playRequest = PlayRequest(bvid: currentBvid)
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

                Text("\(formatCount(detail.stat?.view)) 播放 · \(formatCount(detail.stat?.danmaku)) 弹幕 · \(formatCount(detail.stat?.like)) 点赞")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let desc = detail.desc, !desc.isEmpty, desc != "-" {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Spacer(minLength: 0)

                HStack(spacing: 18) {
                    Button {
                        playRequest = PlayRequest(bvid: currentBvid)
                    } label: {
                        Label("播放", systemImage: "play.fill")
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 405)
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
