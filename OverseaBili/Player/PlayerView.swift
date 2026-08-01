import AVKit
import SwiftUI

struct PlayerScreen: View {
    let bvid: String
    /// PGC 剧集传 ep_id,走官方播放链路
    var epId: Int?

    @StateObject private var vm = PlayerViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var playingBvid = ""

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
                        Button("重试") { Task { await vm.load(bvid: bvid) } }
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
        .task(id: playingBvid) {
            guard !playingBvid.isEmpty else { return }
            // 自动连播:播完接下一个视频,复用同一个播放器
            vm.onPlayNext = { next in
                Task { @MainActor in
                    vm.stop()
                    playingBvid = next
                }
            }
            // 连播换视频后回到普通 UGC 链路
            await vm.load(bvid: playingBvid, epId: playingBvid == bvid ? epId : nil)
        }
        .onAppear {
            if playingBvid.isEmpty { playingBvid = bvid }
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

/// AVPlayerViewController 容器:
/// - 弹幕层挂 contentOverlayView
/// - 转场条菜单:清晰度 / 弹幕开关 / 重新加载;倍速用系统原生 speeds
/// - 下滑信息栏:「线路」CDN 面板 + 「高能」弹幕密度曲线
struct PlayerHost: UIViewControllerRepresentable {
    @ObservedObject var vm: PlayerViewModel

    final class Coordinator {
        var overlay: DanmakuOverlayView?
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

        let cdnPanel = UIHostingController(rootView: CDNPanelView(vm: vm))
        cdnPanel.title = "线路"
        cdnPanel.preferredContentSize = CGSize(width: 1700, height: 460)
        let statsPanel = UIHostingController(rootView: StatsPanelView(vm: vm))
        statsPanel.title = "质量"
        statsPanel.preferredContentSize = CGSize(width: 1700, height: 460)
        let heatPanel = UIHostingController(rootView: HeatPanelView(vm: vm))
        heatPanel.title = "高能"
        heatPanel.preferredContentSize = CGSize(width: 1700, height: 420)
        vc.customInfoViewControllers = [cdnPanel, statsPanel, heatPanel]
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== vm.player {
            vc.player = vm.player
        }
        vc.transportBarCustomMenuItems = buildMenus()
        context.coordinator.overlay?.enabled = vm.danmakuEnabled
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.overlay?.detach()
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
        items.append(UIAction(
            title: "重新加载",
            image: UIImage(systemName: "arrow.clockwise")
        ) { _ in
            Task { @MainActor in model.reloadStream() }
        })
        return items
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
