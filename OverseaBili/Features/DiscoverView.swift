import SwiftUI

@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published var weekly: [VideoItem] = []
    @Published var precious: [VideoItem] = []
    @Published var bangumi: [BangumiSeason] = []
    @Published var cinema: [BangumiSeason] = []
    @Published var knowledgeRank: [VideoItem] = []
    @Published var movieRank: [VideoItem] = []
    @Published var documentaryRank: [VideoItem] = []
    @Published var timelineToday: [TimelineEpisode] = []
    @Published var loading = false
    @Published var message: String?
    @Published var resolving = false

    private var loadedOnce = false

    func initialLoad(mid: Int?) async {
        guard !loadedOnce else { return }
        loadedOnce = true
        await reload(mid: mid)
    }

    func reload(mid: Int?) async {
        loading = true
        async let weeklyTask = (try? FeedAPI.weekly()) ?? []
        async let preciousTask = (try? FeedAPI.precious()) ?? []
        async let knowledgeTask = (try? RankAPI.ranking(rid: 36)) ?? []
        async let movieTask = (try? RankAPI.ranking(rid: 181)) ?? []
        async let documentaryTask = (try? RankAPI.ranking(rid: 177)) ?? []
        async let timelineTask = (try? BangumiAPI.timeline(types: 1)) ?? []
        weekly = await weeklyTask
        precious = await preciousTask
        knowledgeRank = await knowledgeTask
        movieRank = await movieTask
        documentaryRank = await documentaryTask
        // 今日更新:优先 is_today,没有则取第一个有剧集的日子
        let days = await timelineTask
        timelineToday = days.first(where: { $0.today && !($0.episodes ?? []).isEmpty })?.episodes
            ?? days.first(where: { !($0.episodes ?? []).isEmpty })?.episodes
            ?? []
        if let mid {
            async let bangumiTask = (try? BangumiAPI.follow(mid: mid, type: 1)) ?? []
            async let cinemaTask = (try? BangumiAPI.follow(mid: mid, type: 2)) ?? []
            bangumi = await bangumiTask
            cinema = await cinemaTask
        } else {
            bangumi = []
            cinema = []
        }
        loading = false
    }

}

/// 发现:每周必看 / 入站必刷 / 追番追剧 / 分区精选。
struct DiscoverView: View {
    @EnvironmentObject private var router: PlaybackRouter
    @EnvironmentObject private var auth: AuthManager
    @StateObject private var vm = DiscoverViewModel()
    @State private var seasonRequest: SeasonRequest?
    @State private var timelineTypes: TimelineRequest?

    private struct TimelineRequest: Identifiable {
        let types: Int
        var id: Int { types }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TVLayout.rowSpacing) {
                    HStack(spacing: 24) {
                        Button("番剧时间表") { timelineTypes = TimelineRequest(types: 1) }
                        Button("国创时间表") { timelineTypes = TimelineRequest(types: 4) }
                    }

                    if vm.loading, vm.weekly.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 140)
                    }

                    if !vm.timelineToday.isEmpty {
                        RailSection(title: "今日更新") {
                            ForEach(vm.timelineToday) { episode in
                                TimelineCell(episode: episode) {
                                    if let seasonId = episode.seasonId {
                                        seasonRequest = SeasonRequest(
                                            seasonId: seasonId,
                                            title: episode.title ?? "番剧",
                                            epId: episode.episodeId
                                        )
                                    }
                                }
                            }
                        }
                    }

                    if !vm.bangumi.isEmpty {
                        RailSection(title: "我的追番") {
                            ForEach(vm.bangumi) { season in
                                BangumiCell(season: season) {
                                    openSeason(season)
                                }
                            }
                        }
                    }

                    if !vm.cinema.isEmpty {
                        RailSection(title: "我的追剧") {
                            ForEach(vm.cinema) { season in
                                BangumiCell(season: season) {
                                    openSeason(season)
                                }
                            }
                        }
                    }

                    if !vm.weekly.isEmpty {
                        RailSection(title: "每周必看") {
                            ForEach(vm.weekly) { item in
                                VideoCell(item: item) { router.openDetail(item.bvid) }
                                    .frame(width: TVLayout.railCardWidth)
                            }
                        }
                    }

                    if !vm.precious.isEmpty {
                        RailSection(title: "入站必刷") {
                            ForEach(vm.precious) { item in
                                VideoCell(item: item) { router.openDetail(item.bvid) }
                                    .frame(width: TVLayout.railCardWidth)
                            }
                        }
                    }

                    if !vm.knowledgeRank.isEmpty {
                        RailSection(title: "知识区精选") {
                            ForEach(vm.knowledgeRank.prefix(15)) { item in
                                VideoCell(item: item) { router.openDetail(item.bvid) }
                                    .frame(width: TVLayout.railCardWidth)
                            }
                        }
                    }

                    if !vm.movieRank.isEmpty {
                        RailSection(title: "影视区精选") {
                            ForEach(vm.movieRank.prefix(15)) { item in
                                VideoCell(item: item) { router.openDetail(item.bvid) }
                                    .frame(width: TVLayout.railCardWidth)
                            }
                        }
                    }

                    if !vm.documentaryRank.isEmpty {
                        RailSection(title: "纪录片区精选") {
                            ForEach(vm.documentaryRank.prefix(15)) { item in
                                VideoCell(item: item) { router.openDetail(item.bvid) }
                                    .frame(width: TVLayout.railCardWidth)
                            }
                        }
                    }

                    if !auth.isLoggedIn {
                        Text("登录后这里还会显示你的追番、追剧")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, TVLayout.pageHorizontal)
                .padding(.vertical, TVLayout.pageVertical)
            }

            if let message = vm.message {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 48)
            }
            if vm.resolving {
                ProgressView()
                    .padding(.bottom, 60)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.message)
        .fullScreenCover(item: $seasonRequest) { request in
            SeasonScreen(seasonId: request.seasonId, fallbackTitle: request.title, epId: request.epId)
        }
        .fullScreenCover(item: $timelineTypes) { request in
            TimelineScreen(types: request.types)
        }
        .task { await vm.initialLoad(mid: auth.mid) }
        .onChange(of: auth.isLoggedIn) { _, _ in
            Task { await vm.reload(mid: auth.mid) }
        }
        .onPlayPauseCommand {
            Task { await vm.reload(mid: auth.mid) }
        }
    }

    private func openSeason(_ season: BangumiSeason) {
        guard let seasonId = season.seasonId else { return }
        seasonRequest = SeasonRequest(seasonId: seasonId, title: season.title ?? "选集")
    }
}

/// 时间表卡片:横版封面 + 更新话数/时间。
struct TimelineCell: View {
    let episode: TimelineEpisode
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: action) {
                ZStack(alignment: .bottomLeading) {
                    PosterImage(urlString: episode.cover, width: 480, height: 270)
                    if !episode.isPublished {
                        Text(episode.pubTime ?? "待更新")
                            .font(.caption2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.7), in: Capsule())
                            .padding(10)
                    }
                }
            }
            .buttonStyle(.card)
            .frame(width: TVLayout.railCardWidth, height: TVLayout.railCardWidth * 9 / 16)

            Text(episode.title ?? "")
                .font(.callout)
                .lineLimit(2)
                .frame(width: TVLayout.railCardWidth, height: 68, alignment: .topLeading)

            Text(episode.pubIndex ?? "")
                .font(.caption2)
                .foregroundStyle(episode.isPublished ? Color.pink : Color.secondary)
                .lineLimit(1)
                .frame(width: TVLayout.railCardWidth, alignment: .leading)
        }
    }
}

/// 番剧竖版封面卡。
struct BangumiCell: View {
    let season: BangumiSeason
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: action) {
                PosterImage(urlString: season.cover, width: 320, height: 426)
            }
            .buttonStyle(.card)
            .frame(width: 252, height: 336)

            Text(season.title ?? "")
                .font(.callout)
                .lineLimit(2)
                .frame(width: 252, height: 72, alignment: .topLeading)

            Text(season.newEp?.indexShow ?? season.progress ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 252, alignment: .leading)
        }
    }
}
