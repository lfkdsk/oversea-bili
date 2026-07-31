import Foundation
import Network

/// 本地回环 HTTP 服务器:把 m3u8 播放列表和媒体数据以标准 HTTP 提供给 AVPlayer。
/// 媒体路由背后是 ChunkEngine(按块智能选路)。
/// 之所以不用 AVAssetResourceLoader:HLS 的媒体分段必须是 http(s) URL,
/// CoreMedia 抓分段时不会咨询自定义协议的 loader(否则报 -12881)。
final class LocalStreamServer {
    enum Route {
        case playlist(String)
        case media(engine: ChunkEngine, length: Int64, mime: String)
    }

    private var listener: NWListener?
    private var routes: [String: Route] = [:]
    private var connections: Set<ObjectIdentifier> = []
    private var liveConnections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "obili.localserver")
    private(set) var port: UInt16 = 0

    func setRoute(_ path: String, _ route: Route) {
        queue.sync { routes[path] = route }
    }

    /// 启动并返回端口。
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    let port = listener.port?.rawValue ?? 0
                    self?.port = port
                    continuation.resume(returning: port)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for connection in self.liveConnections.values {
                connection.cancel()
            }
            self.liveConnections.removeAll()
        }
    }

    // MARK: - 连接处理

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        liveConnections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.queue.async { self?.liveConnections[key] = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || isComplete && buffer.isEmpty {
                connection.cancel()
                return
            }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerText = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                self.handleRequest(connection, header: headerText)
            } else if buffer.count < 64 * 1024 {
                self.receiveRequest(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func handleRequest(_ connection: NWConnection, header: String) {
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            respondSimple(connection, status: "405 Method Not Allowed")
            return
        }
        let path = String(parts[1].split(separator: "?").first ?? "")
        var range: (start: Int64, end: Int64?)?
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            guard lower.hasPrefix("range:") else { continue }
            let value = line.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
            if value.lowercased().hasPrefix("bytes=") {
                let spec = value.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
                if spec.count == 2, let start = Int64(spec[0]) {
                    range = (start, Int64(spec[1]))
                }
            }
        }

        guard let route = routes[path] else {
            respondSimple(connection, status: "404 Not Found")
            return
        }

        switch route {
        case .playlist(let text):
            servePlaylist(connection, text: text, range: range)
        case .media(let engine, let length, let mime):
            serveMedia(connection, engine: engine, length: length, mime: mime, range: range)
        }
    }

    private func respondSimple(_ connection: NWConnection, status: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func servePlaylist(_ connection: NWConnection, text: String, range: (start: Int64, end: Int64?)?) {
        let full = Data(text.utf8)
        let total = Int64(full.count)
        var body = full
        var status = "200 OK"
        var extra = ""
        if let range {
            let start = min(max(0, range.start), total)
            let end = min(range.end ?? total - 1, total - 1)
            guard start <= end else {
                respondSimple(connection, status: "416 Range Not Satisfiable")
                return
            }
            body = full.subdata(in: Int(start)..<Int(end + 1))
            status = "206 Partial Content"
            extra = "Content-Range: bytes \(start)-\(end)/\(total)\r\n"
        }
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\nAccept-Ranges: bytes\r\n\(extra)Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func serveMedia(_ connection: NWConnection, engine: ChunkEngine, length: Int64, mime: String, range: (start: Int64, end: Int64?)?) {
        let start = min(max(0, range?.start ?? 0), max(0, length - 1))
        let end = min(range?.end ?? length - 1, length - 1)
        guard start <= end else {
            respondSimple(connection, status: "416 Range Not Satisfiable")
            return
        }
        let isPartial = range != nil
        let status = isPartial ? "206 Partial Content" : "200 OK"
        let contentRange = isPartial ? "Content-Range: bytes \(start)-\(end)/\(length)\r\n" : ""
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(end - start + 1)\r\nAccept-Ranges: bytes\r\n\(contentRange)Connection: close\r\n\r\n"

        engine.noteFrontier(start)
        Task {
            do {
                try await self.send(connection, Data(head.utf8))
                var offset = start
                while offset <= end {
                    let idx = offset / ChunkEngine.chunkSize
                    let chunk = try await engine.chunk(at: idx)
                    let chunkStart = idx * ChunkEngine.chunkSize
                    let sliceStart = Int(offset - chunkStart)
                    let sliceEnd = Int(min(Int64(chunk.count), end - chunkStart + 1))
                    guard sliceStart < sliceEnd else { break }
                    try await self.send(connection, chunk.subdata(in: sliceStart..<sliceEnd))
                    offset = chunkStart + Int64(sliceEnd)
                }
                connection.cancel()
            } catch {
                // 客户端断开或分块彻底失败:直接关连接,AVPlayer 会自行重试
                connection.cancel()
            }
        }
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
