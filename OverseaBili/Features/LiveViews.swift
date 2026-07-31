import AVKit
import SwiftUI

struct LivePlayRequest: Identifiable {
    let roomId: Int
    let title: String
    var id: Int { roomId }
}

@MainActor
final class LiveTabViewModel: ObservableObject {
    @Published var following: [LiveRoom] = []
    @Published var recommend: [LiveRoom] = []
    @Published var loading = false
    @Published var errorText: String?

    private var loadedOnce = false

    func initialLoad(loggedIn: Bool) async {
        guard !loadedOnce else { return }
        loadedOnce = true
        await reload(loggedIn: loggedIn)
    }

    func reload(loggedIn: Bool) async {
        loading = true
        errorText = nil
        if loggedIn {
            following = ((try? await LiveAPI.following()) ?? []).filter { $0.isLiving && $0.roomid != nil }
        } else {
            following = []
        }
        do {
            recommend = try await LiveAPI.recommend().filter { $0.roomid != nil }
        } catch {
            if following.isEmpty {
                errorText = (error as? BiliError)?.errorDescription ?? error.localizedDescription
            }
        }
        loading = false
    }
}

struct LiveTabView: View {
    @EnvironmentObject private var auth: AuthManager
    @StateObject private var vm = LiveTabViewModel()
    @State private var playRequest: LivePlayRequest?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TVLayout.rowSpacing) {
                if vm.loading, vm.following.isEmpty, vm.recommend.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 140)
                }
                if let error = vm.errorText {
                    HintView(icon: "dot.radiowaves.left.and.right", text: error, actionTitle: "重试") {
                        Task { await vm.reload(loggedIn: auth.isLoggedIn) }
                    }
                }

                if !vm.following.isEmpty {
                    RailSection(title: "正在直播 · 我的关注") {
                        ForEach(vm.following) { room in
                            liveCell(room)
                                .frame(width: TVLayout.railCardWidth)
                        }
                    }
                }

                if !vm.recommend.isEmpty {
                    Text("直播推荐")
                        .font(.title3.bold())
                    LazyVGrid(columns: TVLayout.columns4, alignment: .leading, spacing: TVLayout.rowSpacing) {
                        ForEach(vm.recommend) { room in
                            liveCell(room)
                        }
                    }
                }

                if !auth.isLoggedIn {
                    Text("登录后可看到关注主播的开播状态")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, TVLayout.pageHorizontal)
            .padding(.vertical, TVLayout.pageVertical)
        }
        .task { await vm.initialLoad(loggedIn: auth.isLoggedIn) }
        .onChange(of: auth.isLoggedIn) { _, loggedIn in
            Task { await vm.reload(loggedIn: loggedIn) }
        }
        .onPlayPauseCommand {
            Task { await vm.reload(loggedIn: auth.isLoggedIn) }
        }
        .fullScreenCover(item: $playRequest) { request in
            LivePlayerScreen(roomId: request.roomId, title: request.title)
        }
    }

    private func liveCell(_ room: LiveRoom) -> some View {
        VideoCell(
            title: room.title ?? "直播间",
            pic: room.coverURL,
            subtitle: "\(room.uname ?? "") · \(room.watchingShow?.numText ?? formatCount(room.online))人气",
            duration: "LIVE"
        ) {
            if let roomId = room.roomid {
                playRequest = LivePlayRequest(roomId: roomId, title: room.title ?? "直播")
            }
        }
    }
}

// MARK: - 直播播放

@MainActor
final class LivePlayerViewModel: ObservableObject {
    enum LiveState: Equatable {
        case loading
        case playing
        case failed(String)
    }

    @Published var state: LiveState = .loading
    @Published var danmakuEnabled = CDNSettings.shared.danmakuOn

    let player = AVPlayer()
    weak var danmakuOverlay: DanmakuOverlayView?
    private let danmakuClient = LiveDanmakuClient()
    private var urls: [URL] = []
    private var index = 0
    private var statusObservation: NSKeyValueObservation?

    func load(roomId: Int, uid: Int) async {
        state = .loading
        danmakuClient.onDanmu = { [weak self] danmu in
            guard let self, self.danmakuEnabled else { return }
            self.danmakuOverlay?.add([danmu])
        }
        do {
            urls = try await LiveAPI.streamURLs(roomId: roomId)
            index = 0
            tryNext()
            await danmakuClient.connect(roomId: roomId, uid: uid)
        } catch {
            state = .failed((error as? BiliError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func toggleDanmaku() {
        danmakuEnabled.toggle()
        danmakuOverlay?.enabled = danmakuEnabled
    }

    private func tryNext() {
        guard index < urls.count else {
            state = .failed("所有直播线路都连接失败")
            return
        }
        let url = urls[index]
        index += 1
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": [
                "User-Agent": BiliClient.userAgent,
                "Referer": "https://live.bilibili.com/",
            ],
        ])
        let item = AVPlayerItem(asset: asset)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor [weak self] in
                switch observed.status {
                case .readyToPlay:
                    self?.state = .playing
                case .failed:
                    self?.tryNext()  // 换下一条直播线路
                default:
                    break
                }
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    func stop() {
        danmakuClient.disconnect()
        statusObservation?.invalidate()
        statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        danmakuOverlay?.clear()
    }
}

struct LivePlayerScreen: View {
    let roomId: Int
    let title: String

    @EnvironmentObject private var auth: AuthManager
    @StateObject private var vm = LivePlayerViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LivePlayerHost(vm: vm)
                .ignoresSafeArea()

            switch vm.state {
            case .loading:
                VStack(spacing: 20) {
                    ProgressView()
                    Text(title).font(.headline).lineLimit(1)
                    Text("正在进入直播间…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(60)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            case .failed(let message):
                VStack(spacing: 24) {
                    Image(systemName: "tv.slash")
                        .font(.system(size: 60))
                        .foregroundStyle(.yellow)
                    Text(message).font(.headline)
                    Button("返回") { dismiss() }
                }
                .padding(60)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            case .playing:
                EmptyView()
            }
        }
        .task { await vm.load(roomId: roomId, uid: auth.mid ?? 0) }
        .onDisappear { vm.stop() }
    }
}

private struct LivePlayerHost: UIViewControllerRepresentable {
    @ObservedObject var vm: LivePlayerViewModel

    final class Coordinator {
        var overlay: DanmakuOverlayView?
        deinit { overlay?.detach() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = vm.player

        let overlay = DanmakuOverlayView(frame: .zero)
        if let container = vc.contentOverlayView {
            overlay.frame = container.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(overlay)
        }
        overlay.enabled = vm.danmakuEnabled
        context.coordinator.overlay = overlay
        vm.danmakuOverlay = overlay
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== vm.player { vc.player = vm.player }
        let model = vm
        vc.transportBarCustomMenuItems = [
            UIAction(
                title: "弹幕",
                image: UIImage(systemName: model.danmakuEnabled ? "captions.bubble.fill" : "captions.bubble"),
                state: model.danmakuEnabled ? .on : .off
            ) { _ in
                Task { @MainActor in model.toggleDanmaku() }
            },
        ]
        context.coordinator.overlay?.enabled = vm.danmakuEnabled
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.overlay?.detach()
    }
}
