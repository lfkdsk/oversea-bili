import Foundation

/// 线路风险分类,规则移植自 bili-pilot core.js 的 classifyCdnRoute:
/// MCDN / PCDN / IP 直连 / 非 443 端口等一律降权,只作兜底,不参与优先调度。
struct RouteRisk: Hashable {
    enum Kind: String {
        case official = "官方"
        case pcdn = "PCDN"
        case mcdn = "MCDN"
        case unknown = "未知"
    }

    let kind: Kind
    let deprioritized: Bool
    let reasons: [String]

    static func classify(_ url: URL) -> RouteRisk {
        let host = (url.host ?? "").lowercased()
        let firstLabel = host.split(separator: ".").first.map(String.init) ?? ""
        var reasons: [String] = []

        let mcdnHost = host.range(of: #"\.mcdn\.bilivideo\.(com|cn|net)$"#, options: .regularExpression) != nil
        let mcdnQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "os" }?.value?.lowercased() == "mcdn"
        if mcdnHost { reasons.append("mcdn-host") }
        if mcdnQuery { reasons.append("mcdn-query") }

        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ Int($0).map { $0 >= 0 && $0 <= 255 } ?? false }) {
            reasons.append("ip-host")
        }
        if host == "upos-sz-mirror14b.bilivideo.com" { reasons.append("known-pcdn-host") }
        for suffix in [".szbdyd.com", ".mountaintoys.cn", ".nexusedgeio.com", ".ahdohpiechei.com"]
        where host.hasSuffix(suffix) {
            reasons.append("known-pcdn-suffix")
        }
        if firstLabel.hasPrefix("upos-"), firstLabel.contains("302") { reasons.append("redirect-pcdn-host") }
        if let port = url.port, port != 443 { reasons.append("non-standard-port") }

        let deprioritized = !reasons.isEmpty
        let kind: Kind
        if mcdnHost || mcdnQuery {
            kind = .mcdn
        } else if deprioritized {
            kind = .pcdn
        } else if [".bilivideo.com", ".bilivideo.cn", ".akamaized.net", ".gcdn.co", ".hdslb.com"]
            .contains(where: { host.hasSuffix($0) }) {
            kind = .official
        } else {
            kind = .unknown
        }
        return RouteRisk(kind: kind, deprioritized: deprioritized, reasons: reasons)
    }
}

struct CDNCandidate: Identifiable, Hashable {
    let url: URL
    let host: String
    /// API 返回的第一个 URL
    let isPrimary: Bool
    /// 非 API 下发、由本地镜像列表换 host 生成,必须探测通过(HTTP 206)才可用
    let isExtra: Bool
    let risk: RouteRisk

    var id: String { host }

    var label: String {
        let value = host.lowercased()
        if value.contains("akamaized") || value.contains("akam") { return "Akamai" }
        if value.contains("mirrorcos") || value.contains("cosov") { return "腾讯云 COS" }
        if value.contains("mcdn") { return "Bili MCDN" }
        if value.contains("alio") || value.contains("mirrorali") { return "阿里云" }
        if value.contains("hw") { return "华为云" }
        if value.contains("gcdn") { return "Gcore" }
        if value.contains("bilivideo") { return "Bili CDN" }
        return "CDN"
    }
}

enum QualityLabel {
    static func name(_ qn: Int) -> String {
        switch qn {
        case 127: return "8K"
        case 126: return "杜比视界"
        case 125: return "HDR"
        case 120: return "4K"
        case 116: return "1080P60"
        case 112: return "1080P+"
        case 80: return "1080P"
        case 74: return "720P60"
        case 64: return "720P"
        case 32: return "480P"
        case 16: return "360P"
        default: return "QN\(qn)"
        }
    }
}

enum CandidateBuilder {
    /// 海外常见 upos 镜像(参考 bili-pilot 与 bilibili-accelerator 的域名池)。
    /// 作为"额外候选"参与探测,探测不过(403 等)自动淘汰。
    static let defaultExtraMirrors = [
        "upos-sz-mirroraliov.bilivideo.com",
        "upos-sz-mirrorcosov.bilivideo.com",
        "upos-sz-mirrorhwo1.bilivideo.com",
        "upos-hz-mirrorakam.akamaized.net",
        "upos-sz-mirrorakam.akamaized.net",
        "upos-sz-mirrorcos.bilivideo.com",
        "upos-sz-mirrorali.bilivideo.com",
        "upos-tf-all-tx.bilivideo.com",
    ]

    /// 主地址 + backup + (可选)本地镜像换 host,按 host 去重。
    static func build(primary: String, backups: [String], includeExtraMirrors: Bool) -> [CDNCandidate] {
        var result: [CDNCandidate] = []
        var seen = Set<String>()

        func append(_ urlString: String, primary: Bool, extra: Bool) {
            guard let url = URL(string: urlString),
                  url.scheme == "https" || url.scheme == "http",
                  let host = url.host,
                  !seen.contains(host) else { return }
            seen.insert(host)
            result.append(CDNCandidate(url: url, host: host, isPrimary: primary, isExtra: extra,
                                       risk: RouteRisk.classify(url)))
        }

        append(primary, primary: true, extra: false)
        for backup in backups {
            append(backup, primary: false, extra: false)
        }

        if includeExtraMirrors, let primaryURL = URL(string: primary),
           var comps = URLComponents(url: primaryURL, resolvingAgainstBaseURL: false) {
            for mirror in defaultExtraMirrors {
                comps.host = mirror
                comps.scheme = "https"
                if let swapped = comps.url {
                    append(swapped.absoluteString, primary: false, extra: true)
                }
            }
        }
        return result
    }

    static func build(from durl: Durl, includeExtraMirrors: Bool) -> [CDNCandidate] {
        build(primary: durl.url, backups: durl.backupUrl ?? [], includeExtraMirrors: includeExtraMirrors)
    }

    static func build(from track: DashTrack, includeExtraMirrors: Bool) -> [CDNCandidate] {
        build(primary: track.baseUrl ?? "", backups: track.backupUrl ?? [],
              includeExtraMirrors: includeExtraMirrors)
    }
}
