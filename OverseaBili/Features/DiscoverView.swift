import SwiftUI

@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published var weekly: [VideoItem] = []
    @Published var precious: [VideoItem] = []
    @Published var bangumi: [BangumiSeason] = []
    @Published var cinema: [BangumiSeason] = []
    @Published var knowledgeRank: [VideoItem] = []
    @Published var movieRank: [VideoItem] = []
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
        weekly = await weeklyTask
        precious = await preciousTask
        knowledgeRank = await knowledgeTask
        movieRank = await movieTask
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

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TVLayout.rowSpacing) {
                    if vm.loading, vm.weekly.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 140)
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
            SeasonScreen(seasonId: request.seasonId, fallbackTitle: request.title)
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
