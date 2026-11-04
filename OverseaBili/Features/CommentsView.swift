import SwiftUI

// 评论区:x/v2/reply/wbi/main(WBI 签名,热门 mode=3 / 最新 mode=2,游标分页)
// + 楼中楼 x/v2/reply/reply(页码分页)。
// 展示:UP 置顶、UP 标识、等级、点赞数、IP 属地、时间、表情图片、评论配图(点按看大图)。

struct CommentContent: Decodable {
    struct Emote: Decodable {
        struct Meta: Decodable { let size: Int? }
        let url: String?
        let meta: Meta?
    }

    struct Picture: Decodable { let imgSrc: String? }

    let message: String?
    let emote: [String: Emote]?
    let pictures: [Picture]?
}

struct CommentReply: Decodable, Identifiable {
    struct Member: Decodable {
        struct Level: Decodable { let currentLevel: Int? }
        struct Vip: Decodable { let vipStatus: Int? }

        let uname: String?
        let avatar: String?
        let levelInfo: Level?
        let vip: Vip?
    }

    struct Control: Decodable {
        let location: String?
        let subReplyEntryText: String?
    }

    struct UpAction: Decodable { let like: Bool? }

    let rpid: Int
    let mid: Int?
    let rcount: Int?
    let ctime: Int?
    let like: Int?
    let member: Member?
    let content: CommentContent?
    let replyControl: Control?
    let upAction: UpAction?

    var id: Int { rpid }
}

struct CommentPageData: Decodable {
    struct Cursor: Decodable {
        struct Pagination: Decodable { let nextOffset: String? }
        let allCount: Int?
        let isEnd: Bool?
        let paginationReply: Pagination?
    }

    struct Upper: Decodable { let mid: Int? }

    let cursor: Cursor?
    let upper: Upper?
    let topReplies: LossyArray<CommentReply>?
    let replies: LossyArray<CommentReply>?
}

struct SubReplyData: Decodable {
    struct Page: Decodable { let count: Int? }

    let page: Page?
    let upper: CommentPageData.Upper?
    let replies: LossyArray<CommentReply>?
}

enum CommentAPI {
    static func page(oid: Int, mode: Int, offset: String) async throws -> CommentPageData {
        try await BiliClient.shared.get(
            "https://api.bilibili.com/x/v2/reply/wbi/main",
            query: [
                "oid": String(oid),
                "type": "1",
                "mode": String(mode),
                "pagination_str": "{\"offset\":\"\(offset.replacingOccurrences(of: "\"", with: "\\\""))\"}",
                "plat": "1",
                "web_location": "1315875",
            ],
            wbi: true
        )
    }

    static func subReplies(oid: Int, root: Int, page: Int) async throws -> SubReplyData {
        try await BiliClient.shared.get(
            "https://api.bilibili.com/x/v2/reply/reply",
            query: ["oid": String(oid), "type": "1", "root": String(root), "ps": "10", "pn": String(page)]
        )
    }
}

@MainActor
final class CommentListModel: ObservableObject {
    struct Thread: Identifiable {
        let reply: CommentReply
        let pinned: Bool
        var expanded = false
        var subs: [CommentReply] = []
        var subPage = 0
        var subTotal: Int
        var subBusy = false
        var subError: String?

        var id: Int { reply.rpid }
    }

    let oid: Int
    @Published var upMid: Int
    @Published private(set) var mode = 3
    @Published private(set) var threads: [Thread] = []
    @Published private(set) var countText = ""
    @Published private(set) var footer = ""

    private var offset = ""
    private var end = false
    private var busy = false
    private var token = 0
    private var started = false

    init(oid: Int, upMid: Int = 0) {
        self.oid = oid
        self.upMid = upMid
    }

    func start() {
        guard !started else { return }
        started = true
        reset()
    }

    func setMode(_ next: Int) {
        guard next != mode else { return }
        mode = next
        reset()
    }

    private func reset() {
        offset = ""
        end = false
        busy = false
        token += 1
        threads = []
        loadPage(first: true)
    }

    func loadMoreIfNeeded(current: Thread) {
        guard let index = threads.firstIndex(where: { $0.id == current.id }), index >= threads.count - 4 else { return }
        loadPage(first: false)
    }

    private func loadPage(first: Bool) {
        guard !busy, first || !end else { return }
        busy = true
        let my = token
        footer = "评论加载中…"
        Task { [self] in
            do {
                let data = try await CommentAPI.page(oid: oid, mode: mode, offset: offset)
                guard my == token else { return }
                if first {
                    if let mid = data.upper?.mid { upMid = mid }
                    countText = (data.cursor?.allCount ?? 0) > 0 ? "共 \(formatCount(data.cursor?.allCount)) 条评论" : ""
                    append(data.topReplies?.elements ?? [], pinned: true)
                }
                append(data.replies?.elements ?? [], pinned: false)
                let next = data.cursor?.paginationReply?.nextOffset ?? ""
                offset = next
                end = (data.cursor?.isEnd ?? false) || next.isEmpty
                if threads.isEmpty {
                    footer = "还没有评论"
                } else if end {
                    footer = BiliClient.shared.csrf != nil
                        ? "— 没有更多评论了 —"
                        : "— 未登录时 B 站只返回第一页评论,登录后可继续翻页 —"
                } else {
                    footer = ""
                }
            } catch {
                guard my == token else { return }
                footer = "评论加载失败:" + ((error as? BiliError)?.errorDescription ?? error.localizedDescription)
                end = true
            }
            if my == token { busy = false }
        }
    }

    private func append(_ replies: [CommentReply], pinned: Bool) {
        var seen = Set(threads.map(\.id))
        for reply in replies where seen.insert(reply.rpid).inserted {
            threads.append(Thread(reply: reply, pinned: pinned, subTotal: reply.rcount ?? 0))
        }
    }

    /// 展开 / 收起楼中楼。
    func toggle(_ rpid: Int) {
        guard let index = threads.firstIndex(where: { $0.id == rpid }), threads[index].subTotal > 0 else { return }
        threads[index].expanded.toggle()
        if threads[index].expanded, threads[index].subPage == 0 { loadSubs(rpid) }
    }

    func loadSubs(_ rpid: Int) {
        guard let index = threads.firstIndex(where: { $0.id == rpid }), !threads[index].subBusy else { return }
        threads[index].subBusy = true
        threads[index].subError = nil
        let page = threads[index].subPage + 1
        let my = token
        Task { [self] in
            let result = await Task { try await CommentAPI.subReplies(oid: oid, root: rpid, page: page) }.result
            guard my == token, let index = threads.firstIndex(where: { $0.id == rpid }) else { return }
            threads[index].subBusy = false
            switch result {
            case .success(let data):
                threads[index].subPage = page
                threads[index].subs += data.replies?.elements ?? []
                threads[index].subTotal = data.page?.count ?? threads[index].subTotal
                if let mid = data.upper?.mid { upMid = mid }
                if threads[index].subs.isEmpty { threads[index].subError = "回复已被折叠或删除" }
            case .failure(let error):
                threads[index].subError = "回复加载失败:" + ((error as? BiliError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}

/// 评论行的焦点样式:不放大,只高亮背景(长文本放大后会被裁切)。
struct CommentButtonStyle: ButtonStyle {
    private struct FocusBody: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(focused ? 0.16 : 0.03))
                )
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        FocusBody(configuration: configuration)
    }
}

/// 文本 + [表情]:表情按 content.emote 映射成图片,拼进同一个 Text 以保持折行。
private struct CommentRichText: View {
    let content: CommentContent?
    let font: Font

    private enum Token {
        case text(String)
        case emote(key: String, url: URL, big: Bool)
    }

    @State private var images: [String: UIImage] = [:]

    private var tokens: [Token] {
        let message = content?.message ?? ""
        let emotes = content?.emote ?? [:]
        guard !emotes.isEmpty, let regex = try? NSRegularExpression(pattern: #"\[[^\[\]]{1,20}\]"#) else {
            return [.text(message)]
        }
        let ns = message as NSString
        var out: [Token] = []
        var last = 0
        for match in regex.matches(in: message, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range)
            // posterURL 会转成 jpg,表情要保留透明通道
            guard let emote = emotes[key], var raw = emote.url else { continue }
            if raw.hasPrefix("http://") { raw = "https://" + raw.dropFirst(7) }
            guard let url = URL(string: raw + "@96w_96h.webp") else { continue }
            if match.range.location > last {
                out.append(.text(ns.substring(with: NSRange(location: last, length: match.range.location - last))))
            }
            out.append(.emote(key: key, url: url, big: emote.meta?.size == 2))
            last = match.range.location + match.range.length
        }
        if last < ns.length { out.append(.text(ns.substring(from: last))) }
        return out
    }

    private var rendered: Text {
        tokens.reduce(Text("")) { result, token in
            switch token {
            case .text(let string):
                return result + Text(string)
            case .emote(let key, _, _):
                if let image = images[key] {
                    return result + Text(Image(uiImage: image)).baselineOffset(-8)
                }
                return result + Text(key)
            }
        }
    }

    var body: some View {
        rendered
            .font(font)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: content?.message) {
                for case .emote(let key, let url, let big) in tokens where images[key] == nil {
                    guard let raw = await ImageLoader.shared.load(url) else { continue }
                    let side: CGFloat = big ? 76 : 40
                    let format = UIGraphicsImageRendererFormat.default()
                    images[key] = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
                        raw.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
                    }
                }
            }
    }
}

private struct ImageViewerRequest: Identifiable {
    let url: String
    var id: String { url }
}

/// 评论配图大图。
private struct CommentImageViewer: View {
    let url: String
    @State private var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            } else {
                ProgressView()
            }
            // tvOS 需要一个可聚焦元素来接收点按,菜单键由系统关闭
            Button("") { dismiss() }
                .buttonStyle(.plain)
                .opacity(0.01)
        }
        .task {
            var raw = url
            if raw.hasPrefix("//") { raw = "https:" + raw }
            if raw.hasPrefix("http://") { raw = "https://" + raw.dropFirst(7) }
            if let target = URL(string: raw) {
                image = await ImageLoader.shared.load(target)
            }
        }
    }
}

private struct CommentBody: View {
    let reply: CommentReply
    let pinned: Bool
    let upMid: Int
    var trailing: String?

    private var metaLine: String {
        var parts: [String] = []
        if let ctime = reply.ctime {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            parts.append(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ctime))))
        }
        if let location = reply.replyControl?.location, !location.isEmpty {
            parts.append(location.replacingOccurrences(of: "IP属地:", with: "IP 属地 ")
                .replacingOccurrences(of: "IP属地:", with: "IP 属地 "))
        }
        parts.append("赞 \(formatCount(reply.like ?? 0))")
        if reply.upAction?.like == true { parts.append("UP 主觉得很赞") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            PosterImage(urlString: reply.member?.avatar, width: 96, height: 96)
                .frame(width: 56, height: 56)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(reply.member?.uname ?? "")
                        .font(.caption.bold())
                        .foregroundStyle((reply.member?.vip?.vipStatus ?? 0) > 0 ? Color.pink : Color.primary)
                        .lineLimit(1)
                    if let level = reply.member?.levelInfo?.currentLevel {
                        Text("LV\(level)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if upMid > 0, reply.mid == upMid { tag("UP", .pink) }
                    if pinned { tag("置顶", .orange) }
                }
                CommentRichText(content: reply.content, font: .caption)
                Text(metaLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let trailing {
                    Text(trailing)
                        .font(.caption2)
                        .foregroundStyle(.pink)
                }
            }
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(color.opacity(0.3), in: Capsule())
    }
}

/// 评论列表(不含外层滚动,由详情页 / 播放器面板决定怎么放)。
struct CommentsView: View {
    @ObservedObject var model: CommentListModel
    @State private var viewer: ImageViewerRequest?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                modeButton("热门", 3)
                modeButton("最新", 2)
                Text(model.countText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.threads) { thread in
                threadView(thread)
                    .onAppear { model.loadMoreIfNeeded(current: thread) }
            }

            if !model.footer.isEmpty {
                Text(model.footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }
        }
        .onAppear { model.start() }
        .fullScreenCover(item: $viewer) { request in
            CommentImageViewer(url: request.url)
        }
    }

    private func modeButton(_ title: String, _ mode: Int) -> some View {
        Button {
            model.setMode(mode)
        } label: {
            HStack(spacing: 8) {
                if model.mode == mode {
                    Circle().fill(.pink).frame(width: 10, height: 10)
                }
                Text(title).font(.caption.bold())
            }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func threadView(_ thread: CommentListModel.Thread) -> some View {
        let reply = thread.reply
        VStack(alignment: .leading, spacing: 12) {
            Button {
                model.toggle(reply.rpid)
            } label: {
                CommentBody(reply: reply, pinned: thread.pinned, upMid: model.upMid, trailing: entryText(thread))
            }
            .buttonStyle(CommentButtonStyle())

            pictures(reply)

            if thread.expanded {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(thread.subs) { sub in
                        Button {} label: {
                            CommentBody(reply: sub, pinned: false, upMid: model.upMid)
                        }
                        .buttonStyle(CommentButtonStyle())
                        pictures(sub)
                    }
                    if thread.subBusy {
                        Text("加载回复…").font(.caption2).foregroundStyle(.secondary)
                    } else if let error = thread.subError {
                        Text(error).font(.caption2).foregroundStyle(.secondary)
                    } else if thread.subs.count < thread.subTotal {
                        Button {
                            model.loadSubs(reply.rpid)
                        } label: {
                            Text("加载更多回复(\(thread.subs.count)/\(thread.subTotal))")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.leading, 74)
            }
        }
    }

    @ViewBuilder
    private func pictures(_ reply: CommentReply) -> some View {
        let urls = (reply.content?.pictures ?? []).compactMap(\.imgSrc).prefix(4)
        if !urls.isEmpty {
            HStack(spacing: 18) {
                ForEach(Array(urls), id: \.self) { url in
                    Button {
                        viewer = ImageViewerRequest(url: url)
                    } label: {
                        PosterImage(urlString: url, width: 360, height: 360)
                            .frame(width: 200, height: 200)
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(.leading, 74)
        }
    }

    private func entryText(_ thread: CommentListModel.Thread) -> String? {
        guard thread.subTotal > 0 else { return nil }
        if thread.expanded { return "收起回复 ‹" }
        return thread.reply.replyControl?.subReplyEntryText ?? "共 \(thread.subTotal) 条回复 ›"
    }
}
