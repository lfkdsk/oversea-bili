import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthManager
    @ObservedObject private var settings = CDNSettings.shared
    @State private var showLogin = false
    @State private var showRoamLogin = false
    @State private var roamAuthorized = RoamAPI.isAuthorized

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
                Picker("视频编码", selection: $settings.codec) {
                    Text("自动(优先 HEVC)").tag("auto")
                    Text("HEVC").tag("hevc")
                    Text("AVC(兼容优先)").tag("avc")
                }
                Toggle("HDR", isOn: $settings.hdr)
                Toggle("杜比音效(E-AC-3)", isOn: $settings.dolbyAudio)
                Toggle("自动连播", isOn: $settings.autoNext)
                Toggle("默认开启弹幕", isOn: $settings.danmakuOn)
                Picker("直播清晰度", selection: $settings.liveQN) {
                    Text("原画").tag(10000)
                    Text("蓝光").tag(400)
                    Text("超清").tag(250)
                    Text("高清").tag(150)
                    Text("流畅").tag(80)
                }
            } header: {
                Text("播放偏好")
            } footer: {
                Text("4K / 1080P60 需要登录(部分内容需大会员);实际以视频可用清晰度为准。播放中也可在转场条菜单里临时切换。")
            }

            Section {
                Picker("显示区域", selection: $settings.danmakuArea) {
                    Text("四分之一屏").tag(0.25)
                    Text("半屏").tag(0.5)
                    Text("四分之三屏").tag(0.75)
                    Text("全屏").tag(1.0)
                }
                Picker("不透明度", selection: $settings.danmakuOpacity) {
                    Text("40%").tag(0.4)
                    Text("60%").tag(0.6)
                    Text("85%").tag(0.85)
                    Text("100%").tag(1.0)
                }
                Picker("字号", selection: $settings.danmakuScale) {
                    Text("小").tag(0.8)
                    Text("标准").tag(1.0)
                    Text("大").tag(1.25)
                }
                Picker("滚动速度", selection: $settings.danmakuDuration) {
                    Text("快").tag(6.0)
                    Text("标准").tag(9.0)
                    Text("慢").tag(13.0)
                }
                Picker("同屏上限", selection: $settings.danmakuMaxOnScreen) {
                    Text("20 条(清爽)").tag(20)
                    Text("40 条(标准)").tag(40)
                    Text("80 条(密集)").tag(80)
                    Text("150 条(全量)").tag(150)
                }
                Picker("云屏蔽等级", selection: $settings.danmakuLevel) {
                    Text("不屏蔽").tag(0)
                    Text("3 级(轻度)").tag(3)
                    Text("5 级(中度)").tag(5)
                    Text("8 级(严格)").tag(8)
                }
                TextField("屏蔽词(逗号或空格分隔)", text: $settings.danmakuBlockWords)
            } header: {
                Text("弹幕防挡")
            } footer: {
                Text("显示区域限制弹幕只占屏幕上方区域,同屏上限超出后新弹幕直接丢弃 —— 两者组合可避免关键画面被糊住。")
            }

            Section {
                Toggle("地区受限时走解析服务器", isOn: $settings.roamOn)
                Picker("解析地区", selection: $settings.roamArea) {
                    Text("自动(大陆→港澳→台湾)").tag("auto")
                    Text("大陆").tag("cn")
                    Text("港澳").tag("hk")
                    Text("台湾").tag("tw")
                }
                if roamAuthorized {
                    LabeledContent("授权", value: "已授权(UID \(RoamAPI.auth?.mid.map(String.init) ?? "-"))")
                    Button("清除授权", role: .destructive) {
                        RoamAPI.auth = nil
                        roamAuthorized = false
                    }
                } else {
                    Button("扫码授权") { showRoamLogin = true }
                }
                TextField("自定义解析服务器(留空用默认)", text: $settings.roamServer)
            } header: {
                Text("番剧解析")
            } footer: {
                Text("B 站按请求 IP 判定番剧版权地区。官方接口提示地区限制时,改经解析服务器取播放地址,番剧 / 影视搜索也会合并它的结果。解析服务器只会收到 access_key(需单独扫码一次),不会收到网页登录 Cookie;大会员内容仍按你自己的账号判定。")
            }

            Section {
                LabeledContent("当前出口地区", value: ProbeCache.region)
                ForEach(ProbeCache.snapshot().prefix(6), id: \.host) { item in
                    LabeledContent(item.host) {
                        Text(item.rejected
                             ? "签名被拒"
                             : String(format: "%.1f Mbps · %d 分钟前", item.mbps, item.ageMinutes))
                            .font(.caption)
                            .foregroundStyle(item.rejected ? .red : .secondary)
                    }
                }
                Button("清除测速缓存", role: .destructive) {
                    ProbeCache.clear()
                }
            } header: {
                Text("线路测速缓存")
            } footer: {
                Text("按出口地区缓存各线路实测速度(6 小时有效),下次起播直接按历史成绩排序,省掉冷启动探测;换网络导致出口地区变化时自动作废。")
            }

            Section {
                Toggle("附加海外镜像候选", isOn: $settings.extraMirrors)
                if settings.manualPin.isEmpty {
                    LabeledContent("选路模式") {
                        Label("自动优选", systemImage: "wand.and.stars")
                            .foregroundStyle(.green)
                    }
                } else {
                    LabeledContent("选路模式") {
                        Text(settings.manualPin)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button("恢复自动优选") {
                        settings.manualPin = ""
                    }
                }
            } header: {
                Text("播放线路")
            } footer: {
                Text("自动优选会在 B 站下发的候选线路(以及镜像候选)间实时测速,播放中每个分块都走当前最快线路;卡顿时自动冷却切换。镜像候选需探测通过(HTTP 206)才会启用,不影响播放安全。")
            }

            Section("关于") {
                LabeledContent("应用", value: "海外哔哩 for Apple TV")
                LabeledContent("播放管线", value: "DASH → 本地 HLS(最高 8K / HDR)")
                LabeledContent("CDN 调度算法", value: "移植自 bili-pilot")
                Text("仅供个人学习使用。视频内容与账号数据均来自 bilibili 官方接口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fullScreenCover(isPresented: $showLogin) {
            LoginView()
        }
        .fullScreenCover(isPresented: $showRoamLogin) {
            LoginView(roam: true) { roamAuthorized = RoamAPI.isAuthorized }
        }
    }
}
