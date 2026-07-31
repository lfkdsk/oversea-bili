import SwiftUI

struct SeasonRequest: Identifiable {
    let seasonId: Int
    let title: String
    var id: Int { seasonId }
}

struct EpisodeRequest: Identifiable {
    let bvid: String
    let epId: Int
    var id: Int { epId }
}

@MainActor
final class SeasonViewModel: ObservableObject {
    @Published var season: SeasonDetail?
    @Published var loading = true
    @Published var errorText: String?

    func load(seasonId: Int) async {
        loading = true
        errorText = nil
        do {
            season = try await BangumiAPI.season(seasonId: seasonId)
            if (season?.episodes ?? []).isEmpty {
                errorText = "没有可播放的剧集"
            }
        } catch {
            errorText = (error as? BiliError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }
}

/// 番剧 / 剧集选集页。
struct SeasonScreen: View {
    let seasonId: Int
    let fallbackTitle: String

    @StateObject private var vm = SeasonViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var episodeRequest: EpisodeRequest?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: TVLayout.gridSpacing, alignment: .top), count: 4)

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.09).ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: TVLayout.rowSpacing) {
                    Text(vm.season?.title ?? fallbackTitle)
                        .font(.title2.bold())
                        .padding(.top, 8)

                    if vm.loading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 200)
                    } else if let error = vm.errorText {
                        VStack(spacing: 20) {
                            Text(error).foregroundStyle(.secondary)
                            Text("大会员专享内容可能无法在本应用播放")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Button("返回") { dismiss() }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 180)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: TVLayout.rowSpacing) {
                            ForEach(vm.season?.episodes ?? []) { episode in
                                VideoCell(
                                    title: episode.displayName.isEmpty ? "正片" : episode.displayName,
                                    pic: episode.cover,
                                    subtitle: episode.isVip ? "大会员" : " ",
                                    duration: ""
                                ) {
                                    episodeRequest = EpisodeRequest(bvid: episode.bvid ?? "", epId: episode.id)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, TVLayout.pageHorizontal)
                .padding(.vertical, TVLayout.pageVertical)
            }
        }
        .task {
            await vm.load(seasonId: seasonId)
        }
        .fullScreenCover(item: $episodeRequest) { request in
            PlayerScreen(bvid: request.bvid, epId: request.epId)
        }
    }
}
