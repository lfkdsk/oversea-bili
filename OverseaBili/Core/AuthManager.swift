import Foundation
import SwiftUI

@MainActor
final class AuthManager: ObservableObject {
    @Published var isLoggedIn = false
    @Published var uname: String?
    @Published var face: String?
    @Published var mid: Int?
    /// 登录即将过期,建议重新扫码
    @Published var needsRelogin = false

    func refresh() async {
        await BiliClient.shared.bootstrap()
        await LoginExpiry.check()
        needsRelogin = LoginExpiry.needsRelogin
        do {
            let nav = try await LoginAPI.nav()
            // 出口地区变化(换网络/出行)时,CDN 测速缓存自动作废
            ProbeCache.setRegion(nav.ipRegion)
            isLoggedIn = nav.isLogin
            uname = nav.uname
            face = nav.face
            mid = nav.mid
            if !nav.isLogin { needsRelogin = false }
        } catch {
            // 网络失败时保持现状
        }
    }

    /// 扫码成功后调用:持久化 cookie 并刷新状态。
    func didLogin() async {
        CookieVault.persist()
        LoginExpiry.clear()
        await refresh()
    }

    func logout() async {
        CookieVault.clear()
        LoginExpiry.clear()
        needsRelogin = false
        isLoggedIn = false
        uname = nil
        face = nil
        mid = nil
        await refresh()
    }
}
