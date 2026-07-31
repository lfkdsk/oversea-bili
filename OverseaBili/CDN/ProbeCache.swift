import Foundation

/// 测速结果持久化:按「地区 + 运营商环境」为 key 缓存各 host 的实测吞吐,
/// 下次起播直接用历史成绩排序,省掉冷启动探测(思路来自 bilibili-accelerator 的 6 小时缓存)。
/// 只作为初始排序依据,真实下载一开始就会被实测 EWMA 覆盖。
enum ProbeCache {
    private static let storeKey = "cdn.probeCache.v1"
    private static let ttl: TimeInterval = 6 * 3600

    private struct Entry: Codable {
        var mbps: Double
        var updatedAt: TimeInterval
        /// 探测拿到 403/416 等,说明该 host 不接受本源签名
        var rejected: Bool
    }

    private struct Bucket: Codable {
        var region: String
        var hosts: [String: Entry]
    }

    /// 缓存分区键:用 nav 返回的 ip_region,拿不到时用时区兜底。
    private(set) static var region: String = UserDefaults.standard.string(forKey: "cdn.region")
        ?? TimeZone.current.identifier

    static func setRegion(_ value: String?) {
        guard let value, !value.isEmpty, value != region else { return }
        region = value
        UserDefaults.standard.set(value, forKey: "cdn.region")
        // 换区(换网络/出国)后旧成绩不可信,清掉
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    private static func load() -> Bucket {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let bucket = try? JSONDecoder().decode(Bucket.self, from: data),
              bucket.region == region else {
            return Bucket(region: region, hosts: [:])
        }
        return bucket
    }

    private static func save(_ bucket: Bucket) {
        if let data = try? JSONEncoder().encode(bucket) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    /// 历史成绩(过期返回 nil)。
    static func mbps(for host: String) -> Double? {
        guard let entry = load().hosts[host],
              Date().timeIntervalSince1970 - entry.updatedAt < ttl,
              !entry.rejected else { return nil }
        return entry.mbps
    }

    /// 该 host 上次探测被拒(403/416),本轮可跳过。
    static func isRejected(_ host: String) -> Bool {
        guard let entry = load().hosts[host],
              Date().timeIntervalSince1970 - entry.updatedAt < ttl else { return false }
        return entry.rejected
    }

    static func record(host: String, mbps: Double, rejected: Bool = false) {
        var bucket = load()
        let now = Date().timeIntervalSince1970
        if var existing = bucket.hosts[host], !rejected, existing.mbps > 0,
           now - existing.updatedAt < ttl {
            // 与历史成绩做平滑,避免单次抖动主导
            existing.mbps = existing.mbps * 0.5 + mbps * 0.5
            existing.updatedAt = now
            existing.rejected = false
            bucket.hosts[host] = existing
        } else {
            bucket.hosts[host] = Entry(mbps: mbps, updatedAt: now, rejected: rejected)
        }
        // 控制条目数
        if bucket.hosts.count > 40 {
            let sorted = bucket.hosts.sorted { $0.value.updatedAt < $1.value.updatedAt }
            for (host, _) in sorted.prefix(bucket.hosts.count - 40) {
                bucket.hosts[host] = nil
            }
        }
        save(bucket)
    }

    static func apply(results: [ProbeResult]) {
        for result in results {
            let rejected = !result.ok && result.samples.contains {
                $0.status == 403 || $0.status == 404 || $0.status == 416
            }
            record(host: result.candidate.host, mbps: result.minMbps, rejected: rejected)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    /// 调试/设置页展示用。
    static func snapshot() -> [(host: String, mbps: Double, ageMinutes: Int, rejected: Bool)] {
        let now = Date().timeIntervalSince1970
        return load().hosts
            .map { (host: $0.key,
                    mbps: $0.value.mbps,
                    ageMinutes: Int((now - $0.value.updatedAt) / 60),
                    rejected: $0.value.rejected) }
            .sorted { $0.mbps > $1.mbps }
    }
}
