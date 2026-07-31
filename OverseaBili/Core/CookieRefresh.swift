import Foundation

/// 登录有效期监控。
///
/// 说明:B 站官方的 Cookie 自动续期流程需要用官方 RSA 公钥加密生成 CorrespondPath,
/// 该公钥没有可靠的公开来源(参考文档仓库已于 2026-01 关停),编造密钥只会让续期静默失败。
/// 因此这里只做"到期检测 + 提示用户重新扫码",行为可预期且不依赖任何逆向信息。
enum LoginExpiry {
    private static let lastCheckKey = "auth.lastExpiryCheck"
    private static let needsReloginKey = "auth.needsRelogin"

    /// Cookie 已进入 B 站建议的刷新期(通常意味着即将失效)。
    static var needsRelogin: Bool {
        get { UserDefaults.standard.bool(forKey: needsReloginKey) }
        set { UserDefaults.standard.set(newValue, forKey: needsReloginKey) }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: lastCheckKey)
        UserDefaults.standard.removeObject(forKey: needsReloginKey)
    }

    /// 启动时检查,每天最多一次。
    static func check() async {
        guard BiliClient.shared.csrf != nil else {
            needsRelogin = false
            return
        }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 86400 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        if let info = await LoginAPI.cookieNeedsRefresh() {
            needsRelogin = info.needed
        }
    }
}
