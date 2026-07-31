import SwiftUI
import UIKit

// MARK: - 带 Referer/UA 的图片加载(AsyncImage 无法带头,B 站图床偶尔校验)

final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024)
        return URLSession(configuration: config)
    }()

    private init() {
        cache.totalCostLimit = 192 * 1024 * 1024
    }

    func load(_ url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        var req = URLRequest(url: url)
        req.setValue(BiliClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(BiliClient.referer, forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await session.data(for: req),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL, cost: data.count)
        return image
    }
}

/// 封面图:http→https,hdslb 图床追加缩放参数。
func posterURL(_ raw: String?, width: Int = 480, height: Int = 270) -> URL? {
    guard var s = raw, !s.isEmpty else { return nil }
    if s.hasPrefix("//") { s = "https:" + s }
    if s.hasPrefix("http://") { s = "https://" + s.dropFirst(7) }
    if s.contains("hdslb.com"), !s.contains("@") {
        s += "@\(width)w_\(height)h_1c.jpg"
    }
    return URL(string: s)
}

struct PosterImage: View {
    let urlString: String?
    var width: Int = 480
    var height: Int = 270

    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "play.rectangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .task(id: urlString) {
                image = nil
                guard let url = posterURL(urlString, width: width, height: height) else { return }
                image = await ImageLoader.shared.load(url)
            }
    }
}

// MARK: - 格式化

func formatCount(_ count: Int?) -> String {
    guard let count else { return "-" }
    if count >= 100_000_000 { return String(format: "%.1f亿", Double(count) / 100_000_000) }
    if count >= 10_000 { return String(format: "%.1f万", Double(count) / 10_000) }
    return String(count)
}

func formatDuration(_ seconds: Int?) -> String {
    guard let seconds, seconds > 0 else { return "" }
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

// MARK: - 布局常量

enum TVLayout {
    static let pageHorizontal: CGFloat = 80
    static let pageVertical: CGFloat = 48
    static let gridSpacing: CGFloat = 40
    static let rowSpacing: CGFloat = 56
    static let railCardWidth: CGFloat = 392

    static var columns4: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing, alignment: .top), count: 4)
    }
}

// MARK: - 视频卡片(焦点只在封面上,文字不参与缩放)

struct VideoCell: View {
    let title: String
    let pic: String?
    let subtitle: String
    let duration: String
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: action) {
                ZStack(alignment: .bottomTrailing) {
                    PosterImage(urlString: pic)
                    if !duration.isEmpty {
                        Text(duration)
                            .font(.caption2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(10)
                    }
                }
            }
            .buttonStyle(.card)
            .aspectRatio(16 / 9, contentMode: .fit)

            Text(title)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension VideoCell {
    init(item: VideoItem, action: @escaping () -> Void) {
        self.init(
            title: item.title,
            pic: item.pic,
            subtitle: "\(item.owner?.name ?? "") · \(formatCount(item.stat?.view))播放",
            duration: formatDuration(item.duration),
            action: action
        )
    }
}

/// 横向 rail 容器。
struct RailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: TVLayout.gridSpacing) {
                    content
                }
                .padding(.vertical, 26)
            }
        }
    }
}

/// 空态 / 提示。
struct HintView: View {
    let icon: String
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text(text)
                .foregroundStyle(.secondary)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 140)
    }
}
