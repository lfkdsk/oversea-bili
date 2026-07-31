import Foundation
import CryptoKit

/// bilibili WBI 接口签名(w_rid/wts),算法来自 bilibili-API-collect 文档。
enum WBI {
    private static let mixinKeyEncTab: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
        33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61,
        26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36,
        20, 34, 44, 52,
    ]

    static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 从 wbi_img 的 URL 中取出 key(文件名去扩展名)。
    static func extractKey(from urlString: String) -> String {
        guard let last = urlString.split(separator: "/").last else { return "" }
        return String(last.split(separator: ".").first ?? "")
    }

    static func mixinKey(img: String, sub: String) -> String {
        let orig = Array(img + sub)
        var mixed = ""
        for index in mixinKeyEncTab where index < orig.count {
            mixed.append(orig[index])
        }
        return String(mixed.prefix(32))
    }

    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.~")
        return set
    }()

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 返回带 wts / w_rid 的完整参数表。
    static func sign(params: [String: String], imgKey: String, subKey: String, now: Date = Date()) -> [String: String] {
        var result = params
        result["wts"] = String(Int(now.timeIntervalSince1970))
        let filterSet = CharacterSet(charactersIn: "!'()*")
        let query = result.keys.sorted().map { key -> String in
            let raw = result[key] ?? ""
            let filtered = String(raw.unicodeScalars.filter { !filterSet.contains($0) })
            return "\(encode(key))=\(encode(filtered))"
        }.joined(separator: "&")
        result["w_rid"] = md5Hex(query + mixinKey(img: imgKey, sub: subKey))
        return result
    }
}
