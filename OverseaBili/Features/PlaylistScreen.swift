import SwiftUI

/// 播放清单页:合集 / 系列 / 收藏夹 / 稍后再看。「播放全部」从第一条开始连播,点任一条从该条开始连播。
struct PlaylistScreen: View {
    @ObservedObject var playlist: Playlist

    @State private var playRequest: PlayRequest?
    @State private var errorText: String?

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.09).ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: TVLayout.rowSpacing) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(playlist.kind) · \(playlist.title)")
                            .font(.title3.bold())
                        Text("共 \(playlist.total) 个视频 · 播完自动接下一个")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        play(playlist.items.first)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .fixedSize()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(playlist.items.isEmpty)

                    if let errorText {
                        HintView(icon: "exclamationmark.triangle", text: errorText)
                    } else if playlist.items.isEmpty, !playlist.hasMore {
                        HintView(icon: "tray", text: "清单是空的")
                    }

                    ForEach(playlist.grouped) { section in
                        if !section.title.isEmpty {
                            Text(section.title).font(.headline)
                        }
                        LazyVGrid(columns: TVLayout.columns4, alignment: .leading, spacing: TVLayout.rowSpacing) {
                            ForEach(section.items) { item in
                                VideoCell(
                                    title: item.title,
                                    pic: item.cover,
                                    subtitle: "\((playlist.index(of: item.bvid) ?? 0) + 1) · \(item.author)",
                                    duration: formatDuration(item.duration)
                                ) {
                                    play(item)
                                }
                                .onAppear { loadMoreIfNeeded(item) }
                            }
                        }
                    }
                }
                .padding(.horizontal, TVLayout.pageHorizontal)
                .padding(.vertical, TVLayout.pageVertical)
            }
        }
        .task {
            do {
                try await playlist.ensureLoaded()
            } catch {
                errorText = (error as? BiliError)?.errorDescription ?? error.localizedDescription
            }
        }
        .fullScreenCover(item: $playRequest) { request in
            PlayerScreen(request: request)
        }
    }

    private func play(_ item: PlaylistItem?) {
        guard let item else { return }
        playRequest = PlayRequest(bvid: item.bvid, playlist: playlist)
    }

    private func loadMoreIfNeeded(_ item: PlaylistItem) {
        guard playlist.hasMore, item.id == playlist.items.last?.id else { return }
        Task { try? await playlist.loadMore() }
    }
}
