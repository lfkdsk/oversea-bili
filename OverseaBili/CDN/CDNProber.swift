import Foundation

struct ProbeSample {
    let ok: Bool
    let bytes: Int
    let mbps: Double
    let ttfbMs: Double
    let totalMs: Double
    let status: Int
    let totalBytes: Int64
    let error: String?
}

struct ProbeResult: Identifiable {
    let candidate: CDNCandidate
    let samples: [ProbeSample]
    let minMbps: Double
    let harmonicMbps: Double
    let failures: Int
    let score: Double
    let totalBytes: Int64

    var id: String { candidate.host }
    var ok: Bool { samples.contains { $0.ok } }
}

/// Range 抽样测速,评分公式移植自 bili-pilot core.js scoreProbeResult:
/// score = minMbps*0.72 + harmonicMbps*0.28 - failures*80 - avgTTFB/500
enum CDNProber {
    static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func probeRange(url: URL, start: Int64, sampleBytes: Int, timeout: TimeInterval) async -> ProbeSample {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue(BiliClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(BiliClient.referer, forHTTPHeaderField: "Referer")
        req.setValue("bytes=\(start)-\(start + Int64(sampleBytes) - 1)", forHTTPHeaderField: "Range")
        let startedAt = Date()
        do {
            let (bytes, response) = try await probeSession.bytes(for: req)
            let ttfbMs = Date().timeIntervalSince(startedAt) * 1000
            guard let http = response as? HTTPURLResponse else {
                return failed(error: "非 HTTP 响应", ttfbMs: ttfbMs, startedAt: startedAt)
            }
            guard http.statusCode == 206 || http.statusCode == 200 else {
                return failed(error: "HTTP \(http.statusCode)", status: http.statusCode, ttfbMs: ttfbMs, startedAt: startedAt)
            }
            let totalBytes = parseTotal(http)
            var received = 0
            for try await _ in bytes {
                received += 1
                if received >= sampleBytes { break }
            }
            let totalMs = max(1, Date().timeIntervalSince(startedAt) * 1000)
            return ProbeSample(
                ok: received > 0,
                bytes: received,
                mbps: Double(received) * 8 / (totalMs / 1000) / 1_000_000,
                ttfbMs: ttfbMs,
                totalMs: totalMs,
                status: http.statusCode,
                totalBytes: totalBytes,
                error: received > 0 ? nil : "空响应"
            )
        } catch {
            let isTimeout = (error as? URLError)?.code == .timedOut
            return failed(error: isTimeout ? "超时" : error.localizedDescription, startedAt: startedAt, timeout: timeout)
        }
    }

    private static func failed(error: String, status: Int = 0, ttfbMs: Double? = nil,
                               startedAt: Date, timeout: TimeInterval = 0) -> ProbeSample {
        ProbeSample(ok: false, bytes: 0, mbps: 0,
                    ttfbMs: ttfbMs ?? timeout * 1000,
                    totalMs: Date().timeIntervalSince(startedAt) * 1000,
                    status: status, totalBytes: 0, error: error)
    }

    private static func parseTotal(_ response: HTTPURLResponse) -> Int64 {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let totalPart = contentRange.split(separator: "/").last,
           let total = Int64(totalPart) {
            return total
        }
        return Int64(response.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) } ?? 0)
    }

    /// 逐个验证候选,返回第一个探测通过的(用于快速起播),避免并发抢带宽。
    static func firstHealthy(_ candidates: [CDNCandidate]) async -> (CDNCandidate, ProbeSample)? {
        for candidate in candidates {
            let sample = await probeRange(url: candidate.url, start: 0, sampleBytes: 128 * 1024, timeout: 4)
            if sample.ok { return (candidate, sample) }
        }
        return nil
    }

    /// 完整测速:每个候选顺序抽样(0 位置 + 文件中部),产出排名。
    static func fullProbe(_ candidates: [CDNCandidate],
                          sampleBytes: Int = 512 * 1024,
                          timeout: TimeInterval = 5) async -> [ProbeResult] {
        var results: [ProbeResult] = []
        for candidate in candidates {
            if Task.isCancelled { break }
            var samples: [ProbeSample] = []
            let first = await probeRange(url: candidate.url, start: 0, sampleBytes: sampleBytes, timeout: timeout)
            samples.append(first)
            if first.ok, first.totalBytes > Int64(sampleBytes * 4) {
                let mid = first.totalBytes / 2
                samples.append(await probeRange(url: candidate.url, start: mid, sampleBytes: sampleBytes, timeout: timeout))
            }
            results.append(score(candidate: candidate, samples: samples))
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return rank(results)
    }

    static func score(candidate: CDNCandidate, samples: [ProbeSample]) -> ProbeResult {
        let successes = samples.filter { $0.ok }
        let failures = samples.count - successes.count
        let totalBytes = samples.map(\.totalBytes).max() ?? 0
        guard !successes.isEmpty else {
            return ProbeResult(candidate: candidate, samples: samples, minMbps: 0,
                               harmonicMbps: 0, failures: failures, score: -10000, totalBytes: totalBytes)
        }
        let speeds = successes.map(\.mbps).filter { $0 > 0 }
        let minMbps = speeds.min() ?? 0
        let harmonic = speeds.isEmpty ? 0 : Double(speeds.count) / speeds.reduce(0) { $0 + 1 / $1 }
        let avgTtfb = successes.map(\.ttfbMs).reduce(0, +) / Double(successes.count)
        let score = minMbps * 0.72 + harmonic * 0.28 - Double(failures) * 80 - avgTtfb / 500
        return ProbeResult(candidate: candidate, samples: samples, minMbps: minMbps,
                           harmonicMbps: harmonic, failures: failures, score: score, totalBytes: totalBytes)
    }

    /// 官方线路只要有一个可用,PCDN/MCDN 永远排后面。
    static func rank(_ results: [ProbeResult]) -> [ProbeResult] {
        let hasRegularSuccess = results.contains { !$0.candidate.risk.deprioritized && $0.ok }
        return results.sorted { a, b in
            if hasRegularSuccess, a.candidate.risk.deprioritized != b.candidate.risk.deprioritized {
                return !a.candidate.risk.deprioritized
            }
            return a.score > b.score
        }
    }
}
