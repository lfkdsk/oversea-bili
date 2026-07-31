import Foundation
import UIKit

struct Danmu {
    let progressMs: Int
    let mode: Int  // 1-3 滚动 / 4 底部 / 5 顶部
    let fontsize: Int
    let color: UInt32
    let text: String
}

/// 手写最小 protobuf 解析,对应 DmSegMobileReply { repeated DanmakuElem elems = 1 }
/// DanmakuElem: progress=2, mode=3, fontsize=4, color=5, content=7
enum DanmakuProto {
    static func parseSegment(_ data: Data) -> [Danmu] {
        let bytes = [UInt8](data)
        var i = 0
        var out: [Danmu] = []
        while i < bytes.count {
            guard let key = readVarint(bytes, &i) else { break }
            let field = key >> 3
            let wire = UInt8(key & 0x7)
            if field == 1, wire == 2 {
                guard let len = readVarint(bytes, &i).map({ Int($0) }), len >= 0, i + len <= bytes.count else { break }
                if let danmu = parseElem(bytes, start: i, length: len) { out.append(danmu) }
                i += len
            } else if !skip(bytes, &i, wire: wire) {
                break
            }
        }
        return out.sorted { $0.progressMs < $1.progressMs }
    }

    private static func parseElem(_ bytes: [UInt8], start: Int, length: Int) -> Danmu? {
        var i = start
        let end = start + length
        var progress = 0
        var mode = 1
        var fontsize = 25
        var color: UInt32 = 0xFFFFFF
        var text = ""
        while i < end {
            guard let key = readVarint(bytes, &i) else { return nil }
            let field = key >> 3
            let wire = UInt8(key & 0x7)
            if wire == 0 {
                guard let value = readVarint(bytes, &i) else { return nil }
                switch field {
                case 2: progress = Int(truncatingIfNeeded: Int64(bitPattern: value))
                case 3: mode = Int(value)
                case 4: fontsize = Int(value)
                case 5: color = UInt32(truncatingIfNeeded: value)
                default: break
                }
            } else if wire == 2 {
                guard let len = readVarint(bytes, &i).map({ Int($0) }), len >= 0, i + len <= end else { return nil }
                if field == 7 {
                    text = String(bytes: bytes[i..<i + len], encoding: .utf8) ?? ""
                }
                i += len
            } else if !skip(bytes, &i, wire: wire) {
                return nil
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, progress >= 0, (1...5).contains(mode) else { return nil }
        return Danmu(progressMs: progress, mode: mode, fontsize: fontsize, color: color, text: trimmed)
    }

    private static func readVarint(_ bytes: [UInt8], _ i: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < bytes.count, shift < 64 {
            let byte = bytes[i]
            i += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    private static func skip(_ bytes: [UInt8], _ i: inout Int, wire: UInt8) -> Bool {
        switch wire {
        case 0: return readVarint(bytes, &i) != nil
        case 1: i += 8; return i <= bytes.count
        case 2:
            guard let len = readVarint(bytes, &i).map({ Int($0) }), len >= 0, i + len <= bytes.count else { return false }
            i += len
            return true
        case 5: i += 4; return i <= bytes.count
        default: return false
        }
    }
}

/// 分段拉取(seg.so 每段 6 分钟)+ 按播放进度发射弹幕 + 高能密度数据。
@MainActor
final class DanmakuManager {
    private(set) var all: [Danmu] = []
    private var fetched: Set<Int> = []
    private var fetching: Set<Int> = []
    private var cid = 0
    private var aid = 0
    private var duration: Double = 0
    private var cursor = 0
    private var lastTime: Double = -1
    var onDanmaku: (([Danmu]) -> Void)?
    var onLoaded: (() -> Void)?

    func configure(cid: Int, aid: Int, duration: Double) {
        self.cid = cid
        self.aid = aid
        self.duration = duration
        all = []
        fetched = []
        fetching = []
        cursor = 0
        lastTime = -1
    }

    var totalCount: Int { all.count }

    func tick(_ seconds: Double, emit: Bool) {
        guard cid != 0 else { return }
        let segment = Int(seconds / 360) + 1
        ensureSegment(segment)
        if seconds.truncatingRemainder(dividingBy: 360) > 300 {
            ensureSegment(segment + 1)
        }
        if lastTime < 0 || abs(seconds - lastTime) > 2 {  // 起播或 seek
            cursor = insertionIndex(for: seconds - 0.1)
        }
        lastTime = seconds
        guard emit else { return }
        let limitMs = Int(seconds * 1000)
        var emitted: [Danmu] = []
        while cursor < all.count, all[cursor].progressMs <= limitMs {
            if all[cursor].progressMs >= limitMs - 1500, emitted.count < 12 {
                emitted.append(all[cursor])
            }
            cursor += 1
        }
        if !emitted.isEmpty { onDanmaku?(emitted) }
    }

    /// 高能曲线:整片按 count 个桶统计弹幕密度。
    func heatBuckets(_ count: Int) -> [Int] {
        guard duration > 0, !all.isEmpty, count > 0 else { return [] }
        var buckets = [Int](repeating: 0, count: count)
        for danmu in all {
            let position = Double(danmu.progressMs) / 1000 / duration
            let index = min(count - 1, max(0, Int(position * Double(count))))
            buckets[index] += 1
        }
        return buckets
    }

    private func insertionIndex(for seconds: Double) -> Int {
        let target = Int(seconds * 1000)
        var low = 0
        var high = all.count
        while low < high {
            let mid = (low + high) / 2
            if all[mid].progressMs < target { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func ensureSegment(_ index: Int) {
        guard index >= 1, !fetched.contains(index), !fetching.contains(index) else { return }
        if duration > 0, Double(index - 1) * 360 >= duration { return }
        fetching.insert(index)
        let cid = cid
        let aid = aid
        Task { [weak self] in
            let danmus = await Self.fetchSegment(cid: cid, aid: aid, index: index)
            guard let self else { return }
            self.fetching.remove(index)
            self.fetched.insert(index)
            guard !danmus.isEmpty, self.cid == cid else { return }
            let time = self.lastTime
            self.all.append(contentsOf: danmus)
            self.all.sort { $0.progressMs < $1.progressMs }
            self.cursor = self.insertionIndex(for: max(0, time))
            self.onLoaded?()
        }
    }

    private nonisolated static func fetchSegment(cid: Int, aid: Int, index: Int) async -> [Danmu] {
        var comps = URLComponents(string: "https://api.bilibili.com/x/v2/dm/web/seg.so")!
        comps.queryItems = [
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "oid", value: String(cid)),
            URLQueryItem(name: "pid", value: String(aid)),
            URLQueryItem(name: "segment_index", value: String(index)),
        ]
        guard let url = comps.url else { return [] }
        let req = BiliClient.shared.makeRequest(url)
        guard let (data, response) = try? await BiliClient.shared.session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty else { return [] }
        return DanmakuProto.parseSegment(data)
    }
}

extension UIColor {
    convenience init(danmakuRGB rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// 弹幕渲染层:挂在 AVPlayerViewController.contentOverlayView 上,
/// CADisplayLink 驱动;滚动弹幕分弹道防重叠,顶部/底部静态 4.5s。
final class DanmakuOverlayView: UIView {
    private final class ScrollItem {
        let label: UILabel
        let speed: CGFloat
        init(label: UILabel, speed: CGFloat) {
            self.label = label
            self.speed = speed
        }
    }

    private struct StaticItem {
        let label: UILabel
        let lane: Int
        let top: Bool
        var remaining: Double
    }

    private var scrollItems: [ScrollItem] = []
    private var staticItems: [StaticItem] = []
    private var laneLast: [UILabel?] = []
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private let rowHeight: CGFloat = 46
    private let staticLaneCount = 5

    var enabled = true {
        didSet { if !enabled { clear() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    func detach() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func setPaused(_ paused: Bool) {
        displayLink?.isPaused = paused
        lastTimestamp = 0
    }

    func clear() {
        for item in scrollItems { item.label.removeFromSuperview() }
        for item in staticItems { item.label.removeFromSuperview() }
        scrollItems = []
        staticItems = []
        laneLast = Array(repeating: nil, count: laneLast.count)
    }

    func add(_ danmus: [Danmu]) {
        guard enabled, bounds.width > 100 else { return }
        let style = DanmakuStyle.shared
        for danmu in danmus {
            // 智能防挡:屏蔽词过滤 + 同屏条数上限(超限直接丢弃,优先保证画面可见)
            guard !style.blocked(danmu.text) else { continue }
            guard scrollItems.count + staticItems.count < style.maxOnScreen else { continue }
            addOne(danmu)
        }
    }

    private func addOne(_ danmu: Danmu) {
        let style = DanmakuStyle.shared
        // 弹幕只占屏幕上方 area 比例的高度
        let usableHeight = bounds.height * CGFloat(style.area)
        let lanes = max(2, min(14, Int(usableHeight / (rowHeight * CGFloat(style.scale)))))
        if laneLast.count != lanes {
            laneLast = Array(repeating: nil, count: lanes)
        }
        let label = makeLabel(danmu)
        switch danmu.mode {
        case 4, 5:
            let top = danmu.mode == 5
            guard let lane = (0..<staticLaneCount).first(where: { lane in
                !staticItems.contains { $0.top == top && $0.lane == lane }
            }) else { return }
            let laneHeight = rowHeight * CGFloat(style.scale)
            let y = top
                ? CGFloat(lane) * laneHeight + 16
                : bounds.height - CGFloat(lane + 1) * laneHeight - 90
            label.frame.origin = CGPoint(x: (bounds.width - label.bounds.width) / 2, y: y)
            addSubview(label)
            staticItems.append(StaticItem(label: label, lane: lane, top: top, remaining: 4.5))
        default:
            guard let lane = (0..<laneLast.count).first(where: { lane in
                guard let last = laneLast[lane], last.superview != nil else { return true }
                return last.frame.maxX < bounds.width - 60
            }) else { return }
            label.frame.origin = CGPoint(
                x: bounds.width,
                y: CGFloat(lane) * rowHeight * CGFloat(style.scale) + 16
            )
            addSubview(label)
            laneLast[lane] = label
            let speed = (bounds.width + label.bounds.width) / CGFloat(max(3, style.duration))
            scrollItems.append(ScrollItem(label: label, speed: speed))
        }
    }

    private func makeLabel(_ danmu: Danmu) -> UILabel {
        let style = DanmakuStyle.shared
        let label = UILabel()
        let base: CGFloat = danmu.fontsize <= 18 ? 26 : 32
        label.font = .systemFont(ofSize: base * CGFloat(style.scale), weight: .medium)
        label.text = danmu.text
        label.textColor = UIColor(danmakuRGB: danmu.color)
        label.alpha = CGFloat(style.opacity)
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOffset = CGSize(width: 1, height: 1)
        label.layer.shadowOpacity = 0.9
        label.layer.shadowRadius = 1.5
        label.sizeToFit()
        return label
    }

    @objc private func step(_ link: CADisplayLink) {
        let dt = lastTimestamp == 0 ? 1.0 / 60 : min(0.1, link.timestamp - lastTimestamp)
        lastTimestamp = link.timestamp
        guard !scrollItems.isEmpty || !staticItems.isEmpty else { return }

        var keep: [ScrollItem] = []
        keep.reserveCapacity(scrollItems.count)
        for item in scrollItems {
            item.label.frame.origin.x -= item.speed * CGFloat(dt)
            if item.label.frame.maxX < -10 {
                item.label.removeFromSuperview()
            } else {
                keep.append(item)
            }
        }
        scrollItems = keep

        for index in staticItems.indices {
            staticItems[index].remaining -= dt
        }
        for item in staticItems where item.remaining <= 0 {
            item.label.removeFromSuperview()
        }
        staticItems.removeAll { $0.remaining <= 0 }
    }
}
