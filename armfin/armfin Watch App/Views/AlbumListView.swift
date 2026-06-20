import SwiftUI
import SwiftData

struct AlbumListView: View {
    @State private var viewModel: AlbumListViewModel

    private let serverURL: String
    private let userId: String
    private let accessToken: String
    private let artistId: String

    @Environment(\.playbackEngine) private var playbackEngine
    @Environment(\.nowPlayingManager) private var nowPlayingManager
    @Environment(\.showNowPlaying) private var showNowPlaying
    @Environment(\.modelContext) private var modelContext

    @State private var isLoadingShuffle = false

    private let apiClient = JellyfinAPIClient()

    init(serverURL: String, userId: String, accessToken: String, artistId: String, artistName: String) {
        self.serverURL = serverURL
        self.userId = userId
        self.accessToken = accessToken
        self.artistId = artistId
        _viewModel = State(
            wrappedValue: AlbumListViewModel(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken,
                artistId: artistId,
                artistName: artistName
            )
        )
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded where viewModel.albums.isEmpty:
                emptyState
            case .loaded:
                albumList
            case .failed(let error):
                errorState(error)
            }
        }
        .navigationTitle(viewModel.artistName)
        .background(.black)
        .offlineGate(
            tabKey: "artist:\(artistId)",
            isUnreachable: viewModel.state == .failed(.serverUnreachable),
            isLoaded: viewModel.state == .loaded,
            onRetry: { await viewModel.load() }
        )
    }

    private var albumList: some View {
        List {
            shuffleButton
                .listRowBackground(Color.clear)

            ForEach(viewModel.albums, id: \.id) { album in
                albumRow(album)
                    .listRowBackground(Color.clear)
            }

            if viewModel.hasMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .onAppear {
                        Task { await viewModel.loadMore() }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.black)
    }

    private var shuffleButton: some View {
        Button {
            Task { await shuffleAllTracks() }
        } label: {
            HStack(spacing: 8) {
                if isLoadingShuffle {
                    ProgressView()
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "shuffle")
                        .font(.footnote)
                        .foregroundStyle(.blue)
                }
                Text("Shuffle All")
                    .font(.footnote)
                    .foregroundStyle(.blue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(isLoadingShuffle)
    }

    private func shuffleAllTracks() async {
        guard !isLoadingShuffle else { return }
        isLoadingShuffle = true
        defer { isLoadingShuffle = false }

        var queueItems: [QueueItem] = []

        for album in viewModel.albums {
            if let result = try? await apiClient.fetchTracks(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken,
                albumId: album.id
            ) {
                for t in result.items {
                    let itemId = t.albumId ?? t.id
                    queueItems.append(QueueItem(
                        trackId: t.id,
                        title: t.name,
                        artistName: viewModel.artistName,
                        albumName: t.albumName ?? album.name,
                        albumId: t.albumId,
                        durationSeconds: Double(t.durationTicks) / 10_000_000,
                        serverURL: serverURL,
                        accessToken: accessToken,
                        artworkURL: apiClient.imageURL(
                            serverURL: serverURL,
                            itemId: itemId,
                            maxWidth: 200,
                            maxHeight: 200,
                            tag: t.imageTag
                        )
                    ))
                }
            }
        }

        guard let firstItem = queueItems.randomElement() else { return }

        if !playbackEngine.isShuffleEnabled {
            playbackEngine.toggleShuffle()
        }

        playbackEngine.setQueue(queueItems, startingAt: firstItem.trackId)
        playbackEngine.onQueueItemChanged = { item in
            nowPlayingManager.setNowPlaying(track: NowPlayingTrack(
                trackId: item.trackId,
                title: item.title,
                artistName: item.artistName,
                albumName: item.albumName,
                albumId: item.albumId,
                durationSeconds: item.durationSeconds,
                artworkURL: item.artworkURL
            ))
        }
        playbackEngine.play(
            trackId: firstItem.trackId,
            serverURL: serverURL,
            accessToken: accessToken
        )
        nowPlayingManager.setNowPlaying(track: NowPlayingTrack(
            trackId: firstItem.trackId,
            title: firstItem.title,
            artistName: firstItem.artistName,
            albumName: firstItem.albumName,
            albumId: firstItem.albumId,
            durationSeconds: firstItem.durationSeconds,
            artworkURL: firstItem.artworkURL
        ))
        showNowPlaying()
    }

    private func albumRow(_ album: JellyfinAPIClient.AlbumSummary) -> some View {
        HStack(spacing: 6) {
            NavigationLink {
                TrackListView(
                    serverURL: serverURL,
                    userId: userId,
                    accessToken: accessToken,
                    albumId: album.id,
                    albumName: album.name,
                    artistName: viewModel.artistName
                )
            } label: {
                HStack(spacing: 10) {
                    JellyfinImage(
                        url: apiClient.imageURL(
                            serverURL: serverURL,
                            itemId: album.id,
                            maxWidth: 56,
                            maxHeight: 56,
                            tag: album.imageTag
                        ),
                        icon: "opticaldisc"
                    )
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(album.name)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let year = album.productionYear {
                            Text(String(year))
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            BetaAlbumDownloadButton(
                albumId: album.id,
                albumName: album.name,
                artistName: viewModel.artistName,
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "opticaldisc")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.2))
            Text("No albums found")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ error: AlbumListViewModel.AlbumError) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(.red.opacity(0.6))
            Text(error.message)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    NavigationStack {
        AlbumListView(
            serverURL: "https://example.com",
            userId: "user-id",
            accessToken: "token",
            artistId: "artist-id",
            artistName: "Example Artist"
        )
    }
    .modelContainer(for: [BetaDownloadItem.self], inMemory: true)
}
