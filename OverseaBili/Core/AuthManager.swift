import Foundation
import SwiftUI

@MainActor
final class AuthManager: ObservableObject {
    @Published var isLoggedIn = false
    @Published var uname: String?
    @Published var face: String?
    @Published var mid: Int?

    func refresh() async {
        await BiliClient.shared.bootstrap()
        do {
            let nav = try await LoginAPI.nav()
            isLoggedIn = nav.isLogin
            uname = nav.uname
            face = nav.face
            mid = nav.mid
        } catch {
            // 网络失败时保持现状
        }
    }

    /// 扫码成功后调用:持久化 cookie 并刷新状态。
    func didLogin() async {
        CookieVault.persist()
        await refresh()
    }

    func logout() async {
        CookieVault.clear()
        isLoggedIn = false
        uname = nil
        face = nil
        mid = nil
        await refresh()
    }
}
