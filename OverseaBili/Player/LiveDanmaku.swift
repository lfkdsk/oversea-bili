import Compression
import Foundation

extension LiveAPI {
    /// 注意:此接口必须 wbi 签名,否则 -352 风控。
    static func danmuInfo(roomId: Int) async throws -> DanmuInfoData {
        try await BiliClient.shared.get(
            "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo",
            query: ["id": String(roomId), "type": "0", "web_location": "444.8"],
            wbi: true,
            referer: "https://live.bilibili.com/"
        )
    }
}

/// 直播弹幕长连:wss /sub,16 字节包头协议;
/// 认证(op7)→ 心跳(op2/30s)→ 消息(op5,protover 2 为 zlib 批量包)。
final class LiveDanmakuClient {
    private var socket: URLSessionWebSocketTask?
    private var heartbeat: Task<Void, Never>?
    private var receiveLoop: Task<Void, Never>?

    /// 主线程回调
    var onDanmu: ((Danmu) -> Void)?

    func connect(roomId: Int, uid: Int) async {
        disconnect()
        do {
            let info = try await LiveAPI.danmuInfo(roomId: roomId)
            guard let token = info.token,
                  let hostInfo = info.hostList?.first,
                  let host = hostInfo.host,
                  let url = URL(string: "wss://\(host):\(hostInfo.wssPort ?? 443)/sub") else { return }

            var req = URLRequest(url: url)
            req.setValue(BiliClient.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")
            let task = URLSession.shared.webSocketTask(with: req)
            socket = task
            task.resume()

            let buvid = (HTTPCookieStorage.shared.cookies ?? []).first { $0.name == "buvid3" }?.value ?? ""
            let auth: [String: Any] = [
                "uid": uid,
                "roomid": roomId,
                "protover": 2,
                "platform": "web",
                "type": 2,
                "buvid": buvid,
                "key": token,
            ]
            let body = try JSONSerialization.data(withJSONObject: auth)
            try await task.send(.data(Self.packet(op: 7, body: body)))
            startHeartbeat()
            startReceive()
        } catch {
            // 弹幕连接失败不影响直播播放
        }
    }

    func disconnect() {
        heartbeat?.cancel()
        heartbeat = nil
        receiveLoop?.cancel()
        receiveLoop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    deinit { disconnect() }

    // MARK: - 收发

    private func startHeartbeat() {
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                guard let socket = self?.socket else { return }
                try? await socket.send(.data(Self.packet(op: 2, body: Data())))
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func startReceive() {
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let socket = self?.socket else { return }
                guard let message = try? await socket.receive() else { return }
                if case .data(let data) = message {
                    self?.parseFrames(data)
                }
            }
        }
    }

    private func parseFrames(_ data: Data) {
        let bytes = [UInt8](data)
        var offset = 0
        while offset + 16 <= bytes.count {
            let packLen = Int(u32(bytes, offset))
            guard packLen >= 16, offset + packLen <= bytes.count else { break }
            let version = Int(u16(bytes, offset + 6))
            let op = Int(u32(bytes, offset + 8))
            let body = Data(bytes[(offset + 16)..<(offset + packLen)])
            if op == 5 {
                if version == 2, let inflated = Self.inflate(body) {
                    parseFrames(inflated)
                } else if version == 0 || version == 1 {
                    handleMessage(body)
                }
            }
            offset += packLen
        }
    }

    private func handleMessage(_ body: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let cmd = obj["cmd"] as? String, cmd.hasPrefix("DANMU_MSG"),
              let info = obj["info"] as? [Any], info.count > 1,
              let text = info[1] as? String, !text.isEmpty,
              let meta = info.first as? [Any] else { return }
        let mode = (meta.count > 1 ? meta[1] as? Int : nil) ?? 1
        let fontsize = (meta.count > 2 ? meta[2] as? Int : nil) ?? 25
        let colorInt = (meta.count > 3 ? meta[3] as? Int : nil) ?? 0xFFFFFF
        let danmu = Danmu(
            progressMs: 0,
            mode: (1...5).contains(mode) ? mode : 1,
            fontsize: fontsize,
            color: UInt32(truncatingIfNeeded: colorInt),
            text: text
        )
        DispatchQueue.main.async { [weak self] in
            self?.onDanmu?(danmu)
        }
    }

    // MARK: - 协议工具

    private static func packet(op: UInt32, body: Data) -> Data {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16 + body.count).bigEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).bigEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).bigEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: op.bigEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(1).bigEndian, Array.init))
        data.append(body)
        return data
    }

    /// zlib 解压(Compression 框架吃 raw deflate,跳过 2 字节 zlib 头)。
    private static func inflate(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let src = [UInt8](data.dropFirst(2))
        var capacity = max(64 * 1024, src.count * 16)
        for _ in 0..<3 {
            var dst = [UInt8](repeating: 0, count: capacity)
            let decoded = compression_decode_buffer(&dst, capacity, src, src.count, nil, COMPRESSION_ZLIB)
            guard decoded > 0 else { return nil }
            if decoded < capacity {
                return Data(dst[0..<decoded])
            }
            capacity *= 4
        }
        return nil
    }

    private func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }
}
