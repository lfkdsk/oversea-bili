import CoreImage.CIFilterBuiltins
import SwiftUI

@MainActor
final class LoginViewModel: ObservableObject {
    /// true:解析服务器授权(电视端二维码,只保存 access_key,不影响网页登录态)
    var roam = false
    @Published var qrImage: UIImage?
    @Published var statusText = "正在获取二维码…"
    @Published var loginState: QRLoginState = .waitingScan
    @Published var succeeded = false

    /// 生成二维码并轮询,直到成功或任务取消(随视图消失取消)。
    func run() async {
        while !Task.isCancelled {
            do {
                let qr = roam ? try await RoamAPI.generateQR() : try await LoginAPI.generateQR()
                qrImage = Self.renderQR(qr.url)
                statusText = roam ? "打开手机 bilibili App,扫码授权" : "打开手机 bilibili App,扫码登录"
                loginState = .waitingScan

                let expired = try await poll(key: qr.qrcodeKey)
                if !expired { return }
                statusText = "二维码已过期,正在刷新…"
            } catch {
                statusText = "网络异常,3 秒后重试…"
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// 返回 true 表示二维码过期需要刷新。
    private func poll(key: String) async throws -> Bool {
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let result = roam ? try await RoamAPI.poll(key: key) : try await LoginAPI.poll(key: key)
            switch result.code {
            case 0:
                if !roam { LoginExpiry.needsRelogin = false }
                loginState = .success
                statusText = roam ? "授权成功!" : "登录成功!"
                succeeded = true
                return false
            case 86090:
                loginState = .scannedWaitingConfirm
                statusText = "已扫码,请在手机上确认登录"
            case 86038:
                loginState = .expired
                return true
            default:
                break  // 86101 / 86039 未扫码,继续等
            }
        }
        return false
    }

    private static func renderQR(_ content: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct LoginView: View {
    /// true:解析服务器授权;完成后调用 onDone
    var roam = false
    var onDone: (() -> Void)?

    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = LoginViewModel()

    var body: some View {
        HStack(spacing: 100) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.white)
                    .frame(width: 460, height: 460)
                if let qr = vm.qrImage {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 400, height: 400)
                } else {
                    ProgressView()
                }
                if vm.loginState == .scannedWaitingConfirm {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(.black.opacity(0.75))
                        .frame(width: 460, height: 460)
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 70))
                            .foregroundStyle(.green)
                        Text("请在手机上确认")
                            .foregroundStyle(.white)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 28) {
                Text(roam ? "授权解析服务器" : "扫码登录")
                    .font(.largeTitle.bold())
                if roam {
                    Text("解析服务器只认 App 端 access_key,需要单独扫一次。只保存这个 key,不影响网页登录。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 800, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Label("打开手机 bilibili App", systemImage: "1.circle.fill")
                    Label("点击右下角「我的」→ 扫一扫", systemImage: "2.circle.fill")
                    Label("扫描左侧二维码并确认", systemImage: "3.circle.fill")
                }
                .font(.title3)
                .foregroundStyle(.secondary)
                Text(vm.statusText)
                    .font(.headline)
                    .foregroundStyle(vm.loginState == .success ? .green : .primary)
                Button("取消") { dismiss() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.08, green: 0.08, blue: 0.10).ignoresSafeArea())
        .task {
            vm.roam = roam
            await vm.run()
        }
        .onChange(of: vm.succeeded) { _, ok in
            guard ok else { return }
            Task {
                if roam {
                    onDone?()
                } else {
                    await auth.didLogin()
                }
                dismiss()
            }
        }
    }
}
