import SwiftUI

@MainActor
final class DynamicViewModel: ObservableObject {
    @Published var rows: [DynVideoRow] = []
    @Published var ups: [DynUpItem] = []
    @Published var selectedUp: Int?
    @Published var loading = false
    @Published var errorText: String?

    private var offset: String?
    private var hasMore = true
    private var loadedOnce = false

    func initialLoad(mid: Int?) async {
        guard !loadedOnce else { return }
        loadedOnce = true
        await reload(mid: mid)
    }

    func selectUp(_ upMid: Int?, mid: Int?) {
        guard upMid != selectedUp else { return }
        selectedUp = upMid
        rows = []
        Task { await reloadRows(mid: mid) }
    }

    func reload(mid: Int?) async {
        if let ups = try? await DynamicAPI.upList() {
            self.ups = ups
        }
        await reloadRows(mid: mid)
    }

    private func reloadRows(mid: Int?) async {
        loading = true
        errorText = nil
        offset = nil
        hasMore = true
        do {
            let result = try await DynamicAPI.rows(mid: mid, hostMid: selectedUp, offset: nil)
            rows = result.rows
            offset = result.offset
            hasMore = result.hasMore
            if rows.isEmpty {
                errorText = selectedUp == nil ? "还没有关注 UP 的视频动态" : "这位 UP 最近没有视频投稿"
            }
        } catch {
            errorText = (error as? BiliError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }

    func loadMoreIfNeeded(mid: Int?, current: DynVideoRow) async {
        guard hasMore, !loading, current.id == rows.last?.id, let offset else { return }
        guard let more = try? await DynamicAPI.rows(mid: mid, hostMid: selectedUp, offset: offset) else {
            hasMore = false
            return
        }
        let known = Set(rows.map(\.id))
        rows += more.rows.filter { !known.contains($0.id) }
        self.offset = more.offset
        hasMore = more.hasMore
    }
}

/// 关注 UP 的最新投稿;顶部是最近关注 UP 头像栏,点击过滤只看 ta。
struct DynamicView: View {
    @EnvironmentObject private var router: PlaybackRouter
    @EnvironmentObject private var auth: AuthManager
    @StateObject private var vm = DynamicViewModel()
    @State private var showLogin = false

    var body: some View {
        Group {
            if !auth.isLoggedIn {
                HintView(icon: "person.2", text: "登录后查看关注 UP 主的最新投稿",
                         actionTitle: "扫码登录") { showLogin = true }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if !vm.ups.isEmpty {
                            upRail
                        }

                        if let error = vm.errorText {
                            HintView(icon: "wifi.exclamationmark", text: error, actionTitle: "重试") {
                                Task { await vm.reload(mid: auth.mid) }
                            }
                        }

                        LazyVGrid(columns: TVLayout.columns4, alignment: .leading, spacing: TVLayout.rowSpacing) {
                            ForEach(vm.rows) { row in
                                VideoCell(
                                    title: row.title,
                                    pic: row.cover,
                                    subtitle: "\(row.authorName) · \(row.pubTime)",
                                    duration: row.durationText
                                ) {
                                    router.openDetail(row.bvid)
                                }
                                .onAppear {
                                    Task { await vm.loadMoreIfNeeded(mid: auth.mid, current: row) }
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
                    .padding(.top, 16)
                    .padding(.bottom, TVLayout.pageVertical)
                }
                .task { await vm.initialLoad(mid: auth.mid) }
                .onPlayPauseCommand {
                    Task { await vm.reload(mid: auth.mid) }
                }
            }
        }
        .onChange(of: auth.isLoggedIn) { _, _ in
            Task { await vm.reload(mid: auth.mid) }
        }
        .fullScreenCover(isPresented: $showLogin) {
            LoginView()
        }
    }

    // MARK: - 最近关注 UP 头像栏

    private var upRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                upButton(nil, name: "全部动态", face: nil, hasUpdate: false)
                ForEach(vm.ups) { up in
                    upButton(up.mid, name: up.uname ?? "", face: up.face, hasUpdate: up.hasUpdate ?? false)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
    }

    private func upButton(_ mid: Int?, name: String, face: String?, hasUpdate: Bool) -> some View {
        Button {
            vm.selectUp(mid, mid: auth.mid)
        } label: {
            UpAvatarLabel(
                name: name,
                face: face,
                hasUpdate: hasUpdate,
                selected: vm.selectedUp == mid
            )
        }
        .buttonStyle(.plain)
        // 默认按钮背景是圆角矩形,会在圆形头像外露出方角
        .clipShape(Circle())
    }
}

/// UP 头像:聚焦时放大 + 白色描边 + 泛光(card 样式被圆形裁剪后焦点效果太弱,自绘)。
private struct UpAvatarLabel: View {
    @Environment(\.isFocused) private var isFocused

    let name: String
    let face: String?
    let hasUpdate: Bool
    let selected: Bool

    private var ringColor: Color {
        if isFocused { return .white }
        if selected { return .pink }
        return .clear
    }

    private let size: CGFloat = 76

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                if let face {
                    PosterImage(urlString: face, width: 160, height: 160)
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: size, height: size)
                        .overlay {
                            Image(systemName: "person.2.fill")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                }
                if hasUpdate {
                    Circle()
                        .fill(.pink)
                        .frame(width: 13, height: 13)
                        .offset(x: 1, y: -1)
                }
            }
            .overlay {
                Circle()
                    .strokeBorder(ringColor, lineWidth: isFocused ? 4 : (selected ? 3.5 : 0))
            }
            .shadow(color: isFocused ? .white.opacity(0.4) : .clear, radius: 14)
            // 未选中且未聚焦的整体压暗,让"当前选中"一眼可辨
            .saturation(selected || isFocused ? 1.0 : 0.5)
            .opacity(selected || isFocused ? 1.0 : 0.55)
            .scaleEffect(isFocused ? 1.12 : (selected ? 1.04 : 1.0))

            // 文字框比头像宽,长名字轻微压缩而不是截断
            Text(name)
                .font(isFocused || selected ? .caption2.bold() : .caption2)
                .foregroundStyle(isFocused ? Color.primary : (selected ? Color.pink : Color.secondary))
                .opacity(selected || isFocused ? 1.0 : 0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 150)
        }
        .padding(.horizontal, 2)
        .padding(.top, 8)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
        .animation(.easeInOut(duration: 0.18), value: selected)
    }
}
