import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthManager
    @ObservedObject private var settings = CDNSettings.shared
    @State private var showLogin = false

    var body: some View {
        Form {
            Section("账号") {
                if auth.isLoggedIn {
                    HStack(spacing: 24) {
                        PosterImage(urlString: auth.face, width: 120, height: 120)
                            .frame(width: 80, height: 80)
                            .clipShape(Circle())
                        VStack(alignment: .leading) {
                            Text(auth.uname ?? "已登录")
                                .font(.headline)
                            Text("UID \(auth.mid.map(String.init) ?? "-")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("退出登录", role: .destructive) {
                        Task { await auth.logout() }
                    }
                } else {
                    Text("登录后可看 1080P、获取个性化推荐")
                        .foregroundStyle(.secondary)
                    Button("扫码登录") { showLogin = true }
                }
            }

            Section {
                Picker("画质偏好", selection: $settings.preferredQN) {
                    Text("自动(最高可用)").tag(0)
                    Text("4K").tag(120)
                    Text("1080P60").tag(116)
                    Text("1080P").tag(80)
                    Text("720P").tag(64)
                }
                Toggle("默认开启弹幕", isOn: $settings.danmakuOn)
            } header: {
                Text("播放偏好")
            } footer: {
                Text("4K / 1080P60 需要登录(部分内容需大会员);实际以视频可用清晰度为准。播放中也可在转场条菜单里临时切换。")
            }

            Section {
                Toggle("附加海外镜像候选", isOn: $settings.extraMirrors)
                Picker("固定线路", selection: $settings.manualPin) {
                    Text("自动优选(推荐)").tag("")
                    ForEach(CandidateBuilder.defaultExtraMirrors, id: \.self) { host in
                        Text(host).tag(host)
                    }
                }
            } header: {
                Text("播放线路")
            } footer: {
                Text("自动优选会在 B 站下发的候选线路(以及镜像候选)间实时测速,播放中每个分块都走当前最快线路;卡顿时自动冷却切换。镜像候选需探测通过(HTTP 206)才会启用,不影响播放安全。")
            }

            Section("关于") {
                LabeledContent("应用", value: "海外哔哩 for Apple TV")
                LabeledContent("播放接口", value: "bilibili html5 mp4 (最高 1080P)")
                LabeledContent("CDN 调度算法", value: "移植自 bili-pilot")
                Text("仅供个人学习使用。视频内容与账号数据均来自 bilibili 官方接口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fullScreenCover(isPresented: $showLogin) {
            LoginView()
        }
    }
}
