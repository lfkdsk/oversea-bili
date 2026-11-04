import AVKit
import SwiftUI

struct PlayerScreen: View {
    let request: PlayRequest

    init(request: PlayRequest) {
        self.request = request
    }

    init(bvid: String) {
        request = PlayRequest(bvid: bvid)
    }

    @StateObject private var vm = PlayerViewModel()
    @Environment(\.dismiss) private var dismiss
    /// 当前在播的:初始为 request,连播 / 切集时替换,复用同一个播放器
    @State private var current: PlayRequest?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerHost(vm: vm)
                .ignoresSafeArea()

            switch vm.state {
            case .loading(let text):
                VStack(spacing: 24) {
                    ProgressView()
                    Text(vm.videoTitle.isEmpty ? " " : vm.videoTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let host = vm.stats.currentHost {
                        Text("线路:\(vm.stats.currentLabel ?? "") \(host)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(60)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            case .failed(let message):
                VStack(spacing: 24) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.yellow)
                    Text(message)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 24) {
                        Button("重试") { Task { await vm.load(current ?? request) } }
                        Button("返回") { dismiss() }
                    }
                }
                .padding(60)
                .frame(maxWidth: 900)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            case .playing:
                // 暂停 / 缓冲时右上角显示当前线路与网速
                if vm.timeControl != .playing {
                    VStack {
                        HStack {
                            Spacer()
                            HStack(spacing: 14) {
                                if vm.timeControl == .waitingToPlayAtSpecifiedRate {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "pause.fill")
                                }
                                Text(speedLine)
                                    .font(.caption.monospacedDigit())
                            }
                            .padding(.horizontal, 26)
                            .padding(.vertical, 14)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(44)
                        }
                        Spacer()
                    }
                    .transition(.opacity)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let left = vm.upNextCountdown, let next = vm.upNext {
                UpNextCard(left: left, title: next.title) {
                    vm.playUpNextNow()
                } onCancel: {
                    vm.cancelUpNext()
                }
                .padding(60)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = vm.resumeNotice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 13)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 130)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: vm.resumeNotice)
        .animation(.easeInOut(duration: 0.2), value: vm.timeControl)
        .task(id: current?.id) {
            guard let current else { return }
            vm.onPlayNext = { next in
                Task { @MainActor in
                    vm.stop()
                    self.current = next
                }
            }
            await vm.load(current)
        }
        .onAppear {
            if current == nil { current = request }
        }
        .onDisappear {
            vm.stop()
        }
    }

    private var speedLine: String {
        let current = vm.stats.hosts.first { $0.isCurrent }
        let label = current?.candidate.label ?? vm.stats.currentLabel ?? "-"
        let speed = current?.state.ewmaMbps.map { String(format: "%.1f Mbps", $0) } ?? "测速中"
        return "\(label) · \(speed) · 缓冲 \(formatBytes(vm.stats.cacheAheadBytes))"
    }
}

/// 播完后的倒计时卡片。
private struct UpNextCard: View {
    let left: Int
    let title: String
    let onPlay: () -> Void
    let onCancel: () -> Void

    @FocusState private var playFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(left) 秒后播放下一个")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 20) {
                Button("立即播放", action: onPlay)
                    .focused($playFocused)
                Button("取消", action: onCancel)
            }
        }
        .frame(width: 640, alignment: .leading)
        .padding(36)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .onAppear { playFocused = true }
    }
}

/// AVPlayerViewController 容器:
/// - 弹幕层挂 contentOverlayView
/// - 转场条菜单:选集 / 清晰度 / 弹幕 / 自动连播 / 重新加载;倍速用系统原生 speeds
/// - 下滑信息栏:合集·清单 / 评论 / 线路 / 质量 / 高能
struct PlayerHost: UIViewControllerRepresentable {
    @ObservedObject var vm: PlayerViewModel

    final class Coordinator {
        var overlay: DanmakuOverlayView?
        var panelKey = ""
        var menuKey = ""
        deinit { overlay?.detach() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = vm.player
        if #available(tvOS 16.0, *) {
            vc.speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map {
                AVPlaybackSpeed(rate: Float($0), localizedName: String(format: "%g×", $0))
            }
        }

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

    /// 清单 / 评论面板随内容增减;只在变化时重设,否则会把面板里的焦点打断。
    private func installPanels(on vc: AVPlayerViewController, coordinator: Coordinator) {
        let key = "\(vm.playlist.map { ObjectIdentifier($0).hashValue } ?? 0)-\(vm.comments != nil)"
        guard key != coordinator.panelKey else { return }
        coordinator.panelKey = key

        var panels: [UIViewController] = []
        if let playlist = vm.playlist {
            let panel = UIHostingController(rootView: PlaylistPanelView(vm: vm, playlist: playlist))
            panel.title = String("\(playlist.kind)·\(playlist.title)".prefix(18))
            panel.preferredContentSize = CGSize(width: 1700, height: 460)
            panels.append(panel)
        }
        if vm.comments != nil {
            let panel = UIHostingController(rootView: CommentsPanelView(vm: vm))
            panel.title = "评论"
            panel.preferredContentSize = CGSize(width: 1700, height: 760)
            panels.append(panel)
        }
        let cdnPanel = UIHostingController(rootView: CDNPanelView(vm: vm))
        cdnPanel.title = "线路"
        cdnPanel.preferredContentSize = CGSize(width: 1700, height: 460)
        let statsPanel = UIHostingController(rootView: StatsPanelView(vm: vm))
        statsPanel.title = "质量"
        statsPanel.preferredContentSize = CGSize(width: 1700, height: 460)
        let heatPanel = UIHostingController(rootView: HeatPanelView(vm: vm))
        heatPanel.title = "高能"
        heatPanel.preferredContentSize = CGSize(width: 1700, height: 420)
        vc.customInfoViewControllers = panels + [cdnPanel, statsPanel, heatPanel]
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== vm.player {
            vc.player = vm.player
        }
        installPanels(on: vc, coordinator: context.coordinator)
        // vm 每秒发布多次,菜单只在内容变化时重建,否则展开中的菜单会被打断
        let settings = CDNSettings.shared
        let menuKey = [
            "\(vm.pages.count)", "\(vm.currentPageIndex)", "\(vm.epId ?? 0)", "\(vm.season?.episodes.count ?? 0)",
            "\(vm.availableQualities.map(\.qn))", "\(vm.currentQN)", "\(vm.danmakuEnabled)", "\(settings.autoNext)",
            "\(settings.danmakuArea)", "\(settings.danmakuOpacity)", "\(settings.danmakuLevel)",
        ].joined(separator: "|")
        if menuKey != context.coordinator.menuKey {
            context.coordinator.menuKey = menuKey
            vc.transportBarCustomMenuItems = buildMenus()
        }
        context.coordinator.overlay?.enabled = vm.danmakuEnabled
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.overlay?.detach()
    }

    /// 弹幕防挡的常用项,播放中直接改。
    private func danmakuMenu() -> UIMenu {
        let settings = CDNSettings.shared
        func choice<T: Equatable>(_ title: String, _ options: [(T, String)], current: T, apply: @escaping (T) -> Void) -> UIMenu {
            UIMenu(
                title: title,
                options: .singleSelection,
                children: options.map { value, label in
                    UIAction(title: label, state: value == current ? .on : .off) { _ in apply(value) }
                }
            )
        }
        return UIMenu(
            title: "弹幕设置",
            image: UIImage(systemName: "slider.horizontal.3"),
            children: [
                choice("显示区域", [(0.25, "四分之一屏"), (0.5, "半屏"), (0.75, "四分之三屏"), (1.0, "全屏")],
                       current: settings.danmakuArea) { settings.danmakuArea = $0 },
                choice("不透明度", [(0.4, "40%"), (0.6, "60%"), (0.85, "85%"), (1.0, "100%")],
                       current: settings.danmakuOpacity) { settings.danmakuOpacity = $0 },
                choice("云屏蔽等级", [(0, "不屏蔽"), (3, "3 级(轻度)"), (5, "5 级(中度)"), (8, "8 级(严格)")],
                       current: settings.danmakuLevel) { settings.danmakuLevel = $0 },
            ]
        )
    }

    private func buildMenus() -> [UIMenuElement] {
        let model = vm
        var items: [UIMenuElement] = []
        if model.pages.count > 1 {
            let actions = model.pages.enumerated().map { index, page in
                UIAction(
                    title: page.part?.isEmpty == false ? "P\(page.page) \(page.part!)" : "P\(page.page)",
                    state: index == model.currentPageIndex ? .on : .off
                ) { _ in
                    Task { @MainActor in model.switchPage(index) }
                }
            }
            items.append(UIMenu(
                title: "选集(\(model.pages.count)P)",
                image: UIImage(systemName: "list.number"),
                options: .singleSelection,
                children: actions
            ))
        }
        if let season = model.season, season.episodes.count > 1 {
            let actions = season.episodes.map { episode in
                UIAction(
                    title: episode.title,
                    state: episode.epId == model.epId ? .on : .off
                ) { _ in
                    Task { @MainActor in
                        guard episode.epId != model.epId else { return }
                        model.switchEpisode(episode)
                    }
                }
            }
            items.append(UIMenu(
                title: "选集(\(season.episodes.count))",
                image: UIImage(systemName: "list.number"),
                options: .singleSelection,
                children: actions
            ))
        }
        if model.availableQualities.count > 1 {
            let actions = model.availableQualities.map { option in
                UIAction(
                    title: option.label,
                    state: option.qn == model.currentQN ? .on : .off
                ) { _ in
                    Task { @MainActor in model.switchQuality(option.qn) }
                }
            }
            items.append(UIMenu(
                title: "清晰度",
                image: UIImage(systemName: "sparkles.tv"),
                options: .singleSelection,
                children: actions
            ))
        }
        items.append(UIAction(
            title: "弹幕",
            image: UIImage(systemName: model.danmakuEnabled ? "captions.bubble.fill" : "captions.bubble"),
            state: model.danmakuEnabled ? .on : .off
        ) { _ in
            Task { @MainActor in model.toggleDanmaku() }
        })
        items.append(danmakuMenu())
        let settings = CDNSettings.shared
        items.append(UIAction(
            title: "自动连播",
            image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward"),
            state: settings.autoNext ? .on : .off
        ) { _ in
            settings.autoNext.toggle()
        })
        items.append(UIAction(
            title: "重新加载",
            image: UIImage(systemName: "arrow.clockwise")
        ) { _ in
            Task { @MainActor in model.reloadStream() }
        })
        return items
    }
}

/// 合集·清单面板:横向一排,当前条目高亮,接近末尾自动翻页。
struct PlaylistPanelView: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject var playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(playlist.kind) · \(playlist.title)(\(max(playlist.total, playlist.items.count)))")
                .font(.headline)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 30) {
                        ForEach(playlist.items) { item in
                            cell(item).id(item.bvid)
                        }
                    }
                    .padding(.vertical, 18)
                }
                .onAppear { proxy.scrollTo(vm.bvid, anchor: .center) }
            }
        }
        .padding(32)
    }

    private func cell(_ item: PlaylistItem) -> some View {
        VideoCell(
            title: item.title,
            pic: item.cover,
            subtitle: item.bvid == vm.bvid ? "正在播放" : "\((playlist.index(of: item.bvid) ?? 0) + 1) · \(formatDuration(item.duration))",
            duration: ""
        ) {
            vm.playItem(item)
        }
        .frame(width: 330)
        .onAppear {
            if playlist.hasMore, item.id == playlist.items.last?.id {
                Task { try? await playlist.loadMore() }
            }
        }
    }
}

/// 评论面板:边看边翻。
struct CommentsPanelView: View {
    @ObservedObject var vm: PlayerViewModel

    var body: some View {
        ScrollView {
            if let comments = vm.comments {
                CommentsView(model: comments)
                    .id(comments.oid)
                    .padding(32)
            }
        }
    }
}

/// 播放中下滑呼出的 CDN 线路面板。
struct CDNPanelView: View {
    @ObservedObject var vm: PlayerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 20) {
                // 明确当前处于自动还是手动固定 —— 固定后不再自动切换,必须让用户看得见
                if let pinned = vm.stats.hosts.first(where: { $0.isPinned }) {
                    Label("已固定 \(pinned.candidate.label)", systemImage: "pin.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Button {
                        vm.pinHost(nil)
                    } label: {
                        Label("恢复自动优选", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Label("自动优选中", systemImage: "wand.and.stars")
                        .font(.headline)
                        .foregroundStyle(.green)
                }
                Text("画质 \(vm.qualityName) · 前方缓存 \(formatBytes(vm.stats.cacheAheadBytes)) · 已切换 \(vm.stats.failovers) 次")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    vm.manualReprobe()
                } label: {
                    Label("重新测速", systemImage: "speedometer")
                        .font(.caption)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(vm.stats.hosts) { status in
                        HostCard(status: status) {
                            vm.pinHost(status.isPinned ? nil : status.candidate.host)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding(32)
    }

    private struct HostCard: View {
        let status: HostStatus
        let onPin: () -> Void

        private var speedText: String {
            if let mbps = status.state.ewmaMbps {
                return String(format: "%.1f Mbps(实测)", mbps)
            }
            if let mbps = status.state.probeMbps, mbps > 0 {
                return String(format: "%.1f Mbps(测速)", mbps)
            }
            return "未测速"
        }

        private var stateText: String {
            if !status.state.probeValidated {
                // 还没探测过的镜像是"待验证";探测拿到 403/416 的才是签名不可用
                return status.state.lastError == nil ? "待验证" : "签名不可用"
            }
            if status.state.isCooling() { return "冷却中" }
            if status.isCurrent { return "使用中" }
            return "可用"
        }

        private var stateColor: Color {
            if !status.state.probeValidated {
                return status.state.lastError == nil ? .secondary : .red
            }
            if status.state.isCooling() { return .orange }
            if status.isCurrent { return .green }
            return .secondary
        }

        var body: some View {
            Button(action: onPin) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Circle().fill(stateColor).frame(width: 14, height: 14)
                        Text(status.candidate.label)
                            .font(.headline)
                        if status.isPinned {
                            Image(systemName: "pin.fill").font(.caption)
                        }
                        if status.candidate.risk.deprioritized {
                            Text(status.candidate.risk.kind.rawValue)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.red.opacity(0.3), in: Capsule())
                        }
                    }
                    Text(status.candidate.host)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack {
                        Text(speedText).font(.caption)
                        Spacer()
                        Text(stateText).font(.caption).foregroundStyle(stateColor)
                    }
                    Text(status.isPinned ? "点按取消固定" : "点按固定此线路")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 420)
                .padding(20)
            }
            .buttonStyle(.bordered)
        }
    }
}

/// 播放质量统计:吞吐、卡顿、分块重试、线路切换轨迹。
struct StatsPanelView: View {
    @ObservedObject var vm: PlayerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("本次播放质量")
                .font(.headline)

            HStack(spacing: 46) {
                metric("平均吞吐", String(format: "%.1f", vm.stats.averageMbps), unit: "Mbps")
                metric("峰值", String(format: "%.1f", vm.stats.peakMbps), unit: "Mbps")
                metric("已下载", formatBytes(vm.stats.downloadedBytes), unit: "")
                metric("卡顿", "\(vm.stallCount)", unit: "次",
                       tint: vm.stallCount > 0 ? .orange : .green)
                metric("前方缓存", formatBytes(vm.stats.cacheAheadBytes), unit: "")
                metric("丢帧", "\(vm.droppedFrames)", unit: "帧",
                       tint: vm.droppedFrames > 0 ? .orange : .green)
                metric("线路切换", "\(vm.stats.failovers)", unit: "次")
                metric("分块", "\(vm.stats.chunkCount)", unit: "块")
                metric("重试/失败", "\(vm.stats.chunkRetries)/\(vm.stats.chunkFailures)", unit: "",
                       tint: vm.stats.chunkFailures > 0 ? .red : .secondary)
            }

            Divider()

            Text("线路切换轨迹")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if vm.stats.switchLog.isEmpty {
                Text("尚未发生切换 —— 当前线路全程稳定")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(Array(vm.stats.switchLog.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(.white.opacity(0.08), in: Capsule())
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(32)
    }

    private func metric(_ title: String, _ value: String, unit: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(tint)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 弹幕高能曲线:整片弹幕密度 + 当前位置指示。
struct HeatPanelView: View {
    @ObservedObject var vm: PlayerViewModel

    private let bucketCount = 90

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 20) {
                Text("弹幕高能点")
                    .font(.headline)
                Text("共 \(vm.danmaku.totalCount) 条弹幕 · 峰值处即高能名场面")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(timeText(vm.currentSeconds)) / \(timeText(vm.totalSeconds))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                let buckets = vm.heat(bucketCount)
                let peak = max(1, buckets.max() ?? 1)
                ZStack(alignment: .leading) {
                    if buckets.isEmpty {
                        Text(vm.heatVersion >= 0 ? "弹幕加载中…" : "")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        HStack(alignment: .bottom, spacing: 3) {
                            ForEach(Array(buckets.enumerated()), id: \.offset) { _, count in
                                Capsule()
                                    .fill(Color.pink.opacity(0.35 + 0.65 * Double(count) / Double(peak)))
                                    .frame(
                                        width: max(4, (geo.size.width - CGFloat(bucketCount) * 3) / CGFloat(bucketCount)),
                                        height: max(6, geo.size.height * CGFloat(count) / CGFloat(peak))
                                    )
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .bottom)

                        if vm.totalSeconds > 0 {
                            Rectangle()
                                .fill(.white)
                                .frame(width: 4)
                                .offset(x: geo.size.width * CGFloat(vm.currentSeconds / vm.totalSeconds))
                        }
                    }
                }
            }
            .frame(height: 220)
        }
        .padding(32)
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        return formatDuration(Int(seconds))
    }
}

func formatBytes(_ bytes: Int64) -> String {
    if bytes >= 1024 * 1024 {
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
    return String(format: "%d KB", bytes / 1024)
}
