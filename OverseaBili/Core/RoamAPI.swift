import Foundation

/// 解析服务器(BiliRoaming 兼容)。番剧按请求 IP 判定版权地区,海外 -10403 时经它取播放地址。
///
/// 解析服务器只认 App 端 access_key:由用户用手机扫一次电视端登录二维码获得,与网页登录态分开保存。
/// 不拿网页 Cookie 去换(B 站会因此注销网页会话),也不把网页 Cookie 交给第三方 —— 这里的请求都走无 Cookie 的独立 session。
enum RoamAPI {
    static let appKey = "4409e2ce8ffd12b8"
    private static let appSecret = "59b43e04ad6965f34319062b478f83dd"
    static let defaultServer = "https://bili.nepnep.moe"
    private static let authKey = "roam.auth.v1"

    struct Auth: Codable {
        let mid: Int?
        let key: String
        let expires: Date
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    // MARK: - 授权

    static var auth: Auth? {
        get {
            guard let data = UserDefaults.standard.data(forKey: authKey) else { return nil }
            return try? JSONDecoder().decode(Auth.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: authKey)
            } else {
                UserDefaults.standard.removeObject(forKey: authKey)
            }
        }
    }

    static var isAuthorized: Bool {
        guard let auth else { return false }
        return auth.expires > Date()
    }

    private static func accessKey() throws -> String {
        guard let auth, auth.expires > Date() else {
            throw BiliError.api(code: -101, message: "")
        }
        return auth.key
    }

    /// 与 URLSearchParams 一致的表单编码:签名算的就是这个字符串。
    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.* ")
        return (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
            .replacingOccurrences(of: " ", with: "+")
    }

    private static func signed(_ params: [String: String]) -> String {
        var form = params
        form["appkey"] = appKey
        form["ts"] = String(Int(Date().timeIntervalSince1970))
        let query = form.keys.sorted().map { "\($0)=\(encode(form[$0] ?? ""))" }.joined(separator: "&")
        return query + "&sign=" + WBI.md5Hex(query + appSecret)
    }

    private struct TVQR: Decodable {
        let url: String?
        let authCode: String?
    }

    private struct TVPoll: Decodable {
        let mid: Int?
        let accessToken: String?
        let expiresIn: Int?
    }

    private static func tvPost<T: Decodable>(_ path: String, _ params: [String: String]) async throws -> BiliResponse<T> {
        guard let url = URL(string: "https://passport.bilibili.com" + path) else { throw BiliError.badURL }
        var form = params
        form["local_id"] = "0"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(signed(form).utf8)
        let (data, _) = try await session.data(for: req)
        return try decoder.decode(BiliResponse<T>.self, from: data)
    }

    static func generateQR() async throws -> QRGenerateData {
        let wrapped: BiliResponse<TVQR> = try await tvPost("/x/passport-tv-login/qrcode/auth_code", [:])
        guard wrapped.code == 0, let url = wrapped.data?.url, let code = wrapped.data?.authCode else {
            throw BiliError.api(code: wrapped.code, message: wrapped.message ?? "")
        }
        return QRGenerateData(url: url, qrcodeKey: code)
    }

    /// 与网页扫码同一套状态码:0 成功 / 86039 未扫码 / 86090 已扫码待确认 / 86038 已过期。
    static func poll(key: String) async throws -> QRPollData {
        let wrapped: BiliResponse<TVPoll> = try await tvPost("/x/passport-tv-login/qrcode/poll", ["auth_code": key])
        if wrapped.code == 0, let token = wrapped.data?.accessToken {
            let ttl = TimeInterval(wrapped.data?.expiresIn ?? 30 * 86400)
            auth = Auth(mid: wrapped.data?.mid, key: token, expires: Date().addingTimeInterval(ttl - 86400))
        }
        return QRPollData(url: nil, refreshToken: nil, code: wrapped.code, message: wrapped.message)
    }

    // MARK: - 播放地址

    private struct PlayBody: Decodable {
        let info: PlayURLData?

        private enum Keys: String, CodingKey { case videoInfo }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            if let wrapped = try? container.decode(PlayURLData.self, forKey: .videoInfo) {
                info = wrapped
            } else {
                info = try? PlayURLData(from: decoder)
            }
        }
    }

    private struct PlayEnvelope: Decodable {
        let code: Int?
        let message: String?
        let msg: String?
        let result: Lossy<PlayBody>?
        let data: Lossy<PlayBody>?

        var info: PlayURLData? { result?.value?.info ?? data?.value?.info }
        var text: String { message ?? msg ?? "" }
    }

    private static func baseURL() throws -> String {
        let custom = CDNSettings.shared.roamServer.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = custom.isEmpty ? defaultServer : custom
        guard let comps = URLComponents(string: server), comps.scheme == "https", comps.host != nil else {
            throw BiliError.notPlayable("解析服务器必须是 https 地址")
        }
        return server.hasSuffix("/") ? String(server.dropLast()) : server
    }

    private static let areaOrder: [String: [String]] = [
        "auto": ["cn", "hk", "tw"], "cn": ["cn"], "hk": ["hk"], "tw": ["tw"],
    ]

    /// 按地区依次尝试:大陆 → 港澳 → 台湾。只发 access_key。
    static func playURL(epId: Int, cid: Int, qn: Int = 127) async throws -> PlayURLData {
        guard isAuthorized else {
            throw BiliError.notPlayable("该内容有地区限制。到 设置 → 番剧解析 扫码授权后,可经解析服务器播放")
        }
        let base = try baseURL()
        var lastCode = -500
        var lastMessage = "没有返回播放地址"
        for area in areaOrder[CDNSettings.shared.roamArea] ?? areaOrder["auto"]! {
            guard var comps = URLComponents(string: base + "/pgc/player/web/playurl") else { throw BiliError.badURL }
            comps.queryItems = [
                URLQueryItem(name: "ep_id", value: String(epId)),
                URLQueryItem(name: "cid", value: String(cid)),
                URLQueryItem(name: "qn", value: String(qn)),
                URLQueryItem(name: "fnval", value: "4048"),
                URLQueryItem(name: "fnver", value: "0"),
                URLQueryItem(name: "fourk", value: "1"),
                URLQueryItem(name: "area", value: area),
                URLQueryItem(name: "access_key", value: try accessKey()),
            ]
            guard let url = comps.url else { throw BiliError.badURL }
            var req = URLRequest(url: url)
            req.setValue(BiliClient.referer, forHTTPHeaderField: "Referer")
            let (data, response) = try await session.data(for: req)
            guard let envelope = try? decoder.decode(PlayEnvelope.self, from: data) else {
                lastMessage = "解析服务器 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                continue
            }
            let code = envelope.code ?? -500
            if code == 0, let info = envelope.info, info.dash != nil || info.durl != nil {
                return info
            }
            lastCode = code
            lastMessage = envelope.text
            // access_key 失效:清掉,让用户重新扫码
            if code == -101 || code == -2 {
                auth = nil
                throw BiliError.notPlayable("解析服务器授权已失效,请在 设置 → 番剧解析 重新扫码授权")
            }
            // 账号类错误换地区也没用
            if code == -403 || code == -500 { break }
        }
        throw BiliError.notPlayable("解析服务器:\(lastMessage)(\(lastCode))")
    }

    // MARK: - 搜索

    private struct SearchData: Decodable {
        struct Item: Decodable {
            let seasonId: FlexString?
            let title: String?
            let cover: String?
            let uri: String?
            let seasonTypeName: FlexString?
            let area: FlexString?
            let areas: FlexString?
            let styles: FlexString?
            let style: FlexString?
        }

        let items: LossyArray<Item>?
        let pages: Int?
    }

    /// App 端搜索(type 7 番剧 / 8 影视)。海外 IP 的网页搜索会把受地区限制的番剧影视整个过滤掉。
    static func search(keyword: String, movie: Bool, page: Int) async throws -> (items: [SearchMedia], more: Bool) {
        let area = CDNSettings.shared.roamArea == "auto" ? "cn" : CDNSettings.shared.roamArea
        let query = signed([
            "mobi_app": "android_tv_yst",
            "platform": "android",
            "build": "105000",
            "ps": "20",
            "type": movie ? "8" : "7",
            "keyword": keyword,
            "pn": String(page),
            "area": area,
            "access_key": try accessKey(),
        ])
        guard let url = URL(string: try baseURL() + "/x/v2/search/type?" + query) else { throw BiliError.badURL }
        let (data, _) = try await session.data(for: URLRequest(url: url))
        let wrapped = try decoder.decode(BiliResponse<SearchData>.self, from: data)
        #if DEBUG
        // 电视上看不到控制台以外的状态:只打印结果概要,绝不打印 access_key
        let titles = (wrapped.data?.items?.elements ?? []).compactMap(\.title)
        print("[roam-search] movie=\(movie) code=\(wrapped.code) message=\(wrapped.message ?? "") titles=\(titles)")
        #endif
        guard wrapped.code == 0, let result = wrapped.data else {
            throw BiliError.api(code: wrapped.code, message: wrapped.message ?? "")
        }
        // 只要真正的剧集条目(服务器会插推广卡)
        let items = (result.items?.elements ?? []).compactMap { item -> SearchMedia? in
            guard let id = item.seasonId?.value.flatMap({ Int($0) }),
                  item.uri?.contains("/bangumi/play/ss") == true else { return nil }
            return SearchMedia(
                seasonId: id,
                title: item.title,
                cover: item.cover,
                seasonTypeName: item.seasonTypeName?.value,
                areas: item.area?.value ?? item.areas?.value,
                styles: item.styles?.value ?? item.style?.value
            )
        }
        return (items, page < (result.pages ?? 1))
    }
}
