import Foundation

/// 单个线路的运行时状态(实测吞吐 EWMA、失败冷却、测速评分)。
struct HostState {
    var ewmaMbps: Double?
    var probeScore: Double?
    var probeMbps: Double?
    var failures = 0
    var consecutiveFailures = 0
    var cooldownUntil: Date?
    var lastError: String?
    var deliveredBytes: Int64 = 0
    var probeValidated = false

    func isCooling(now: Date = Date()) -> Bool {
        if let until = cooldownUntil { return until > now }
        return false
    }
}

struct HostStatus: Identifiable {
    let candidate: CDNCandidate
    let state: HostState
    let isCurrent: Bool
    let isPinned: Bool
    var id: String { candidate.host }
}

/// 线路选择器:固定优先 → 非降权线路按(评分/实测)排序 → 降权线路兜底;
/// 失败进入指数冷却(15s 起,120s 封顶),全部冷却时选最快解冻的,避免死锁。
final class CDNSelector {
    private(set) var candidates: [CDNCandidate]
    private var states: [String: HostState] = [:]
    private var pinnedHost: String?
    private(set) var currentHost: String?
    private let lock = NSLock()

    init(candidates: [CDNCandidate], pinnedHost: String?) {
        self.candidates = candidates
        // 手动固定的线路必须真实存在于候选里
        self.pinnedHost = candidates.contains { $0.host == pinnedHost } ? pinnedHost : nil
        for c in candidates {
            var state = HostState()
            // API 直接下发的线路视为已验证;换 host 生成的额外镜像需探测通过
            state.probeValidated = !c.isExtra
            states[c.host] = state
        }
    }

    func pin(_ host: String?) {
        lock.lock(); defer { lock.unlock() }
        pinnedHost = candidates.contains { $0.host == host } ? host : nil
    }

    var pinned: String? {
        lock.lock(); defer { lock.unlock() }
        return pinnedHost
    }

    func candidate(for host: String) -> CDNCandidate? {
        candidates.first { $0.host == host }
    }

    /// 挑选下一个要用的线路;`excluding` 用于同一分块内的重试换路。
    func pick(excluding: Set<String> = []) -> CDNCandidate? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()

        func usable(_ c: CDNCandidate) -> Bool {
            guard !excluding.contains(c.host), let s = states[c.host] else { return false }
            return s.probeValidated && !s.isCooling(now: now)
        }

        if let pin = pinnedHost, let c = candidates.first(where: { $0.host == pin }), usable(c) {
            currentHost = c.host
            return c
        }

        let regular = candidates.filter { !$0.risk.deprioritized && usable($0) }
        let deprioritized = candidates.filter { $0.risk.deprioritized && usable($0) }

        func quality(_ c: CDNCandidate) -> Double {
            let s = states[c.host]
            // 统一用 Mbps 比较:实测吞吐(EWMA)与测速吞吐可直接对比,
            // 测速一出结果,下一个分块立刻切到最快线路
            let measured = s?.ewmaMbps ?? 0
            let probed = s?.probeMbps ?? 0
            let base = max(measured, probed)
            return base > 0 ? base : (c.isPrimary ? 0.5 : 0)
        }

        if let best = regular.max(by: { quality($0) < quality($1) }) {
            currentHost = best.host
            return best
        }
        if let fallback = deprioritized.max(by: { quality($0) < quality($1) }) {
            currentHost = fallback.host
            return fallback
        }

        // 全部冷却:选解冻最早的,不无限空转
        let all = candidates.filter { !excluding.contains($0.host) && (states[$0.host]?.probeValidated ?? false) }
        let soonest = all.min {
            (states[$0.host]?.cooldownUntil ?? .distantPast) < (states[$1.host]?.cooldownUntil ?? .distantPast)
        }
        currentHost = soonest?.host ?? currentHost
        return soonest
    }

    func recordSuccess(host: String, bytes: Int, seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        var s = states[host] ?? HostState()
        let mbps = Double(bytes) * 8 / max(seconds, 0.001) / 1_000_000
        s.ewmaMbps = s.ewmaMbps.map { $0 * 0.6 + mbps * 0.4 } ?? mbps
        s.consecutiveFailures = 0
        s.cooldownUntil = nil
        s.lastError = nil
        s.deliveredBytes += Int64(bytes)
        s.probeValidated = true
        states[host] = s
    }

    func recordFailure(host: String, error: String) {
        lock.lock(); defer { lock.unlock() }
        var s = states[host] ?? HostState()
        s.failures += 1
        s.consecutiveFailures += 1
        s.lastError = error
        let cooldown = min(120.0, 15.0 * pow(2, Double(max(0, s.consecutiveFailures - 1))))
        s.cooldownUntil = Date().addingTimeInterval(cooldown)
        states[host] = s
    }

    /// 应用一轮完整测速结果。
    func apply(probeResults: [ProbeResult]) {
        lock.lock(); defer { lock.unlock() }
        for result in probeResults {
            var s = states[result.candidate.host] ?? HostState()
            s.probeScore = result.score
            s.probeMbps = result.minMbps
            if result.ok {
                s.probeValidated = true
                // 测速成功说明线路恢复,清掉旧冷却
                if s.isCooling(), s.consecutiveFailures <= 1 {
                    s.cooldownUntil = nil
                }
            } else if result.samples.contains(where: { $0.status == 403 || $0.status == 404 || $0.status == 416 }) {
                // 签名不被该 host 接受,本次播放内直接淘汰
                s.probeValidated = false
                s.lastError = result.samples.compactMap(\.error).first ?? "签名被拒绝"
            } else if !result.ok {
                s.lastError = result.samples.compactMap(\.error).first
            }
            states[result.candidate.host] = s
        }
    }

    func snapshot() -> [HostStatus] {
        lock.lock(); defer { lock.unlock() }
        return candidates.map {
            HostStatus(candidate: $0,
                       state: states[$0.host] ?? HostState(),
                       isCurrent: $0.host == currentHost,
                       isPinned: $0.host == pinnedHost)
        }
    }

    func state(of host: String) -> HostState? {
        lock.lock(); defer { lock.unlock() }
        return states[host]
    }
}
