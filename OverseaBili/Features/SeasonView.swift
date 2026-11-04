import SwiftUI

struct SeasonRequest: Identifiable {
    let seasonId: Int
    let title: String
    var epId: Int? = nil
    var id: String { "\(seasonId)-\(epId ?? 0)" }
}

@MainActor
final class SeasonViewModel: ObservableObject {
    @Published var season: SeasonDetail?
    @Published var loading = true
    @Published var errorText: String?

    func load(seasonId: Int, epId: Int?) async {
        loading = true
        errorText = nil
        do {
            season = try await BangumiAPI.season(seasonId: seasonId, epId: epId)
            if (season?.episodes ?? []).isEmpty {
                errorText = "没有可播放的剧集"
            }
        } catch {
            errorText = (error as? BiliError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }

    /// 选集页带给播放器的整季信息(接下一集、转场条选集用)。
    var context: SeasonContext? {
        guard let season else { return nil }
        let title = season.title ?? ""
        return SeasonContext(title: title, episodes: (season.episodes ?? []).map { episode in
            SeasonEpisodeRef(
                epId: episode.id,
                cid: episode.cid ?? 0,
                aid: episode.aid ?? 0,
                bvid: episode.bvid ?? "",
                title: [title, episode.displayName].filter { !$0.isEmpty }.joined(separator: " "),
                duration: (episode.duration ?? 0) / 1000
            )
        })
    }
}

/// 番剧 / 剧集选集页:海报、评分、简介、地区提示、选集、花絮。
struct SeasonScreen: View {
    let seasonId: Int
    let fallbackTitle: String
    var epId: Int? = nil

    @StateObject private var vm = SeasonViewModel()
    @ObservedObject private var settings = CDNSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var playRequest: PlayRequest?
    @State private var detailRequest: PlayRequest?

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.09).ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: TVLayout.rowSpacing) {
                    if vm.loading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 300)
                    } else if let error = vm.errorText {
                        VStack(spacing: 20) {
                            Text(error).foregroundStyle(.secondary)
                            Button("重试") { Task { await vm.load(seasonId: seasonId, epId: epId) } }
                            Button("返回") { dismiss() }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 180)
                    } else if let season = vm.season {
                        hero(season)
                        episodes(season)
                        ForEach(Array((season.section?.elements ?? []).enumerated()), id: \.offset) { _, section in
                            extras(section)
                        }
                    }
                }
                .padding(.horizontal, TVLayout.pageHorizontal)
                .padding(.vertical, TVLayout.pageVertical)
            }
        }
        .task {
            await vm.load(seasonId: seasonId, epId: epId)
        }
        .fullScreenCover(item: $playRequest) { request in
            PlayerScreen(request: request)
        }
        .fullScreenCover(item: $detailRequest) { request in
            DetailScreen(bvid: request.bvid)
        }
    }

    private func hero(_ season: SeasonDetail) -> some View {
        HStack(alignment: .top, spacing: 48) {
            PosterImage(urlString: season.cover, width: 450, height: 600)
                .frame(width: 300, height: 400)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 20) {
                Text(season.title ?? fallbackTitle)
                    .font(.title2.bold())
                Text(statsLine(season))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(settings.roamOn
                     ? "提示:B 站番剧/影视按请求 IP 判定版权地区;地区受限的剧集会经解析服务器取播放地址(设置 → 番剧解析)。"
                     : "提示:B 站番剧/影视按请求 IP 判定版权地区,海外多数剧集不可观看。可在 设置 → 番剧解析 中开启解析服务器。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if let evaluate = season.evaluate, !evaluate.isEmpty {
                    Text(evaluate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statsLine(_ season: SeasonDetail) -> String {
        var parts: [String] = []
        if let title = season.seasonTitle, !title.isEmpty { parts.append(title) }
        if let score = season.rating?.score, score > 0 { parts.append(String(format: "%.1f 分", score)) }
        if let views = season.stat?.views, views > 0 { parts.append("\(formatCount(views))播放") }
        if let desc = season.newEp?.desc, !desc.isEmpty { parts.append(desc) }
        return parts.joined(separator: " · ")
    }

    private func episodes(_ season: SeasonDetail) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("选集(\(season.episodes?.count ?? 0))")
                .font(.title3.bold())
            LazyVGrid(columns: TVLayout.columns4, alignment: .leading, spacing: TVLayout.rowSpacing) {
                let context = vm.context
                ForEach(Array((season.episodes ?? []).enumerated()), id: \.element.id) { index, episode in
                    VideoCell(
                        title: episode.displayName.isEmpty ? "正片" : episode.displayName,
                        pic: episode.cover,
                        subtitle: episode.badge?.isEmpty == false ? episode.badge! : " ",
                        duration: formatDuration((episode.duration ?? 0) / 1000)
                    ) {
                        guard let context else { return }
                        let ref = context.episodes[index]
                        playRequest = PlayRequest(bvid: ref.bvid, episode: ref, season: context)
                    }
                }
            }
        }
    }

    /// 花絮等附加内容是普通视频。
    @ViewBuilder
    private func extras(_ section: SeasonDetail.Section) -> some View {
        let items = (section.episodes?.elements ?? []).filter { $0.bvid?.hasPrefix("BV") == true }
        if !items.isEmpty {
            RailSection(title: section.title ?? "花絮") {
                ForEach(items) { episode in
                    VideoCell(
                        title: episode.longTitle?.isEmpty == false ? episode.longTitle! : (episode.title ?? ""),
                        pic: episode.cover,
                        subtitle: " ",
                        duration: ""
                    ) {
                        if let bvid = episode.bvid { detailRequest = PlayRequest(bvid: bvid) }
                    }
                    .frame(width: TVLayout.railCardWidth)
                }
            }
        }
    }
}

/// 时间表:按天分列,默认聚焦今天。types: 1 番剧 / 4 国创。
struct TimelineScreen: View {
    let types: Int

    @State private var days: [TimelineDay] = []
    @State private var errorText: String?
    @State private var loading = true
    @State private var seasonRequest: SeasonRequest?
    @FocusState private var focused: Int?

    private static let week = ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.09).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                Text(types == 4 ? "国创时间表" : "番剧时间表")
                    .font(.title3.bold())
                    .padding(.horizontal, TVLayout.pageHorizontal)

                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 200)
                } else if let errorText {
                    HintView(icon: "calendar", text: errorText)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 28) {
                                ForEach(days) { day in
                                    column(day).id(day.id)
                                }
                            }
                            .padding(.horizontal, TVLayout.pageHorizontal)
                        }
                        .onAppear {
                            if let today = days.first(where: \.today) { proxy.scrollTo(today.id, anchor: .leading) }
                        }
                    }
                }
            }
            .padding(.top, TVLayout.pageVertical)
        }
        .task {
            do {
                days = try await BangumiAPI.timeline(types: types)
                focused = days.first(where: \.today)?.episodes?.first?.id
            } catch {
                errorText = (error as? BiliError)?.errorDescription ?? error.localizedDescription
            }
            loading = false
        }
        .fullScreenCover(item: $seasonRequest) { request in
            SeasonScreen(seasonId: request.seasonId, fallbackTitle: request.title, epId: request.epId)
        }
    }

    private func column(_ day: TimelineDay) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(day.date ?? "") \(Self.week[safe: day.dayOfWeek ?? 0] ?? "")\(day.today ? " · 今天" : "")")
                .font(.headline)
                .foregroundStyle(day.today ? Color.pink : Color.primary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(day.episodes ?? []) { episode in
                        Button {
                            if let seasonId = episode.seasonId {
                                seasonRequest = SeasonRequest(seasonId: seasonId, title: episode.title ?? "选集", epId: episode.episodeId)
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 16) {
                                PosterImage(urlString: episode.squareCover ?? episode.cover, width: 160, height: 160)
                                    .frame(width: 90, height: 90)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(episode.title ?? "")
                                        .font(.caption)
                                        .lineLimit(2)
                                    Text("\(episode.pubTime ?? "") \(episode.pubIndex ?? "")")
                                        .font(.caption2)
                                        .foregroundStyle(episode.isPublished ? Color.pink : Color.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(CommentButtonStyle())
                        .focused($focused, equals: episode.id)
                    }
                    if (day.episodes ?? []).isEmpty {
                        Text("无更新").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 60)
            }
        }
        .frame(width: 420)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
