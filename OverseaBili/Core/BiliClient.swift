import Foundation

enum BiliError: LocalizedError {
    case api(code: Int, message: String)
    case emptyData
    case badURL
    case notPlayable(String)

    var errorDescription: String? {
        switch self {
        case .api(let code, let message):
            switch code {
            case -101: return "账号未登录"
            case -352, -412: return "触发风控(\(code)),稍后再试"
            case -404: return "内容不存在"
            case -10403, 87008:
                return CDNSettings.shared.roamOn
                    ? "该内容有地区限制,解析服务器也没有取到地址"
                    : "该内容有地区限制,海外无法播放(可在 设置 → 番剧解析 中开启解析服务器)"
            case -403: return "没有权限(可能需要大会员)"
            case 12002: return "评论区已关闭"
            default: return "接口错误 \(code): \(message)"
            }
        case .emptyData: return "接口返回为空"
        case .badURL: return "URL 构造失败"
        case .notPlayable(let reason): return reason
        }
    }
}

/// 持久化登录 Cookie(tvOS 的 HTTPCookieStorage 不保证跨启动保留,自己存一份)。
enum CookieVault {
    private static let key = "auth.cookies.v1"

    private struct Item: Codable {
        let name: String
        let value: String
        let domain: String
        let expires: Date?
    }

    static func persist() {
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        let items = cookies
            .filter { $0.domain.contains("bilibili.com") || $0.domain.contains("bilivideo") }
            .map { Item(name: $0.name, value: $0.value, domain: $0.domain, expires: $0.expiresDate) }
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func restore() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return }
        for item in items {
            if let expires = item.expires, expires < Date() { continue }
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: item.name,
                .value: item.value,
                .domain: item.domain,
                .path: "/",
            ]
            if let expires = item.expires { props[.expires] = expires }
            if let cookie = HTTPCookie(properties: props) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.domain.contains("bilibili") {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }
}

final class BiliClient {
    static let shared = BiliClient()

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    static let referer = "https://www.bilibili.com/"

    let session: URLSession
    private let decoder: JSONDecoder

    private var cachedWbiKeys: (img: String, sub: String, at: Date)?
    private var bootstrapped = false

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)

        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        CookieVault.restore()
    }

    func makeRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(Self.referer, forHTTPHeaderField: "Referer")
        return req
    }

    private func buildURL(_ base: String, query: [String: String]) throws -> URL {
        guard var comps = URLComponents(string: base) else { throw BiliError.badURL }
        if !query.isEmpty {
            comps.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        }
        guard let url = comps.url else { throw BiliError.badURL }
        return url
    }

    /// 通用 GET,解 BiliResponse 包装;`allowCodes` 用于 nav 这类未登录也返回数据的接口。
    func get<T: Decodable>(_ base: String,
                           query: [String: String] = [:],
                           wbi: Bool = false,
                           allowCodes: Set<Int> = [],
                           referer: String? = nil,
                           retriedWbi: Bool = false) async throws -> T {
        var q = query
        if wbi {
            let keys = try await wbiKeys()
            q = WBI.sign(params: q, imgKey: keys.img, subKey: keys.sub)
        }
        let url = try buildURL(base, query: q)
        var req = makeRequest(url)
        if let referer {
            req.setValue(referer, forHTTPHeaderField: "Referer")
            req.setValue(String(referer.dropLast(referer.hasSuffix("/") ? 1 : 0)), forHTTPHeaderField: "Origin")
        }
        let (data, _) = try await session.data(for: req)
        let wrapped = try decoder.decode(BiliResponse<T>.self, from: data)
        // wbi 接口偶发 -352/-403:密钥可能已轮换,刷新后重试一次
        if wbi, !retriedWbi, wrapped.code == -352 || wrapped.code == -403 {
            cachedWbiKeys = nil
            return try await get(base, query: query, wbi: true, allowCodes: allowCodes,
                                 referer: referer, retriedWbi: true)
        }
        guard wrapped.code == 0 || allowCodes.contains(wrapped.code) else {
            throw BiliError.api(code: wrapped.code, message: wrapped.message ?? "")
        }
        guard let payload = wrapped.data else { throw BiliError.emptyData }
        return payload
    }

    // MARK: - 启动引导

    /// 补齐 buvid,避免搜索等接口 -412 风控。
    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        if !cookies.contains(where: { $0.name == "buvid3" }) {
            do {
                let spi: SpiData = try await get("https://api.bilibili.com/x/frontend/finger/spi")
                setCookie(name: "buvid3", value: spi.b3)
                if let b4 = spi.b4 { setCookie(name: "buvid4", value: b4) }
            } catch {
                // 拿不到也不阻塞启动
            }
        }
        // 常规 web 指纹 cookie,缺失时 polymer 系接口(动态流)容易 -352 风控
        if !cookies.contains(where: { $0.name == "b_nut" }) {
            setCookie(name: "b_nut", value: String(Int(Date().timeIntervalSince1970)))
        }
        if !cookies.contains(where: { $0.name == "_uuid" }) {
            let value = UUID().uuidString + String(format: "%05d", Int.random(in: 0..<100_000)) + "infoc"
            setCookie(name: "_uuid", value: value)
        }
        CookieVault.persist()
    }

    func setCookie(name: String, value: String, domain: String = ".bilibili.com") {
        let props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
            .expires: Date().addingTimeInterval(3600 * 24 * 365),
        ]
        if let cookie = HTTPCookie(properties: props) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    /// PGC 系接口(番剧/剧集)的包装字段是 result。
    func getPGC<T: Decodable>(_ base: String, query: [String: String] = [:]) async throws -> T {
        let url = try buildURL(base, query: query)
        let (data, _) = try await session.data(for: makeRequest(url))
        let wrapped = try decoder.decode(PGCResponse<T>.self, from: data)
        guard wrapped.code == 0 else {
            throw BiliError.api(code: wrapped.code, message: wrapped.message ?? "")
        }
        guard let payload = wrapped.result else { throw BiliError.emptyData }
        return payload
    }

    // MARK: - POST(点赞/投币/收藏等互动接口)

    /// bili_jct cookie,互动接口的 csrf token。
    var csrf: String? {
        (HTTPCookieStorage.shared.cookies ?? []).first { $0.name == "bili_jct" }?.value
    }

    private struct Ignored: Decodable {
        init(from decoder: Decoder) throws {}
    }

    /// 表单 POST 并解析返回数据(不自动附加 csrf,调用方自行传)。
    func postForm<T: Decodable>(_ base: String, form: [String: String]) async throws -> T {
        guard let url = URL(string: base) else { throw BiliError.badURL }
        var req = makeRequest(url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
        req.httpBody = Data(body.utf8)
        let (data, _) = try await session.data(for: req)
        let wrapped = try decoder.decode(BiliResponse<T>.self, from: data)
        guard wrapped.code == 0 else {
            throw BiliError.api(code: wrapped.code, message: wrapped.message ?? "")
        }
        guard let payload = wrapped.data else { throw BiliError.emptyData }
        return payload
    }

    /// 表单 POST,只关心 code 是否为 0。自动附加 csrf。
    func postAction(_ base: String, form: [String: String]) async throws {
        guard let csrf else { throw BiliError.api(code: -101, message: "未登录") }
        guard let url = URL(string: base) else { throw BiliError.badURL }
        var req = makeRequest(url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var payload = form
        payload["csrf"] = csrf
        let body = payload.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
        req.httpBody = Data(body.utf8)
        let (data, _) = try await session.data(for: req)
        let wrapped = try decoder.decode(BiliResponse<Ignored>.self, from: data)
        guard wrapped.code == 0 else {
            throw BiliError.api(code: wrapped.code, message: wrapped.message ?? "")
        }
    }

    // MARK: - WBI keys

    func wbiKeys() async throws -> (img: String, sub: String) {
        if let cached = cachedWbiKeys, Date().timeIntervalSince(cached.at) < 3600 * 6 {
            return (cached.img, cached.sub)
        }
        let nav: NavData = try await get("https://api.bilibili.com/x/web-interface/nav", allowCodes: [-101])
        guard let img = nav.wbiImg?.imgUrl, let sub = nav.wbiImg?.subUrl else { throw BiliError.emptyData }
        let keys = (WBI.extractKey(from: img), WBI.extractKey(from: sub))
        cachedWbiKeys = (keys.0, keys.1, Date())
        return keys
    }
}
