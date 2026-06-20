import SwiftUI
import SwiftData

struct TrackListView: View {
    @State private var viewModel: TrackListViewModel

    @Environment(\.playbackEngine) private var playbackEngine
    @Environment(\.nowPlayingManager) private var nowPlayingManager
    @Environment(\.showNowPlaying) private var showNowPlaying

    private let apiClient = JellyfinAPIClient()

    init(serverURL: String, userId: String, accessToken: String, albumId: String, albumName: String, artistName: String) {
        _viewModel = State(
            wrappedValue: TrackListViewModel(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken,
                albumId: albumId,
                albumName: albumName,
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
            case .loaded(let tracks) where tracks.isEmpty:
                emptyState
            case .loaded:
                trackList
            case .failed(let error):
                errorState(error)
            }
        }
        .navigationTitle(viewModel.albumName)
        .background(.black)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                BetaAlbumDownloadButton(
                    albumId: viewModel.albumId,
                    albumName: viewModel.albumName,
                    artistName: viewModel.artistName,
                    serverURL: viewModel.serverURL,
                    userId: viewModel.userId,
                    accessToken: viewModel.accessToken
                )
            }
        }
        .offlineGate(
            tabKey: "album:\(viewModel.albumId)",
            isUnreachable: viewModel.state == .failed(.serverUnreachable),
            isLoaded: isLoadedState,
            onRetry: { await viewModel.load() }
        )
    }

    /// `TrackListViewModel.State.loaded` carries an associated array, so it
    /// can't be compared with `==` against a bare `.loaded` the way the
    /// other four (argument-less `.loaded`) view models' states can.
    private var isLoadedState: Bool {
        if case .loaded = viewModel.state { return true }
        return false
    }

    private var trackList: some View {
        List {
            shuffleButton
                .listRowBackground(Color.clear)

            ForEach(viewModel.tracks, id: \.id) { track in
                trackRow(track)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.black)
    }

    private var shuffleButton: some View {
        Button {
            shuffleAll()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "shuffle")
                    .font(.footnote)
                    .foregroundStyle(.blue)
                Text("Shuffle All")
                    .font(.footnote)
                    .foregroundStyle(.blue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func trackRow(_ track: JellyfinAPIClient.TrackSummary) -> some View {
        HStack(spacing: 6) {
            Button {
                playTrack(track)
            } label: {
                HStack(spacing: 8) {
                    if let index = track.indexNumber {
                        Text("\(index)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.3))
                            .frame(width: 18, alignment: .trailing)
                            .monospacedDigit()
                    }

                    Text(track.name)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            betaDownloadButton(for: track)
        }
    }

    private func playTrack(_ track: JellyfinAPIClient.TrackSummary, shuffle: Bool = false) {
        if shuffle && !playbackEngine.isShuffleEnabled {
            playbackEngine.toggleShuffle()
        } else if !shuffle && playbackEngine.isShuffleEnabled {
            playbackEngine.toggleShuffle()
        }

        let nowPlaying = nowPlayingTrack(for: track)
        let queueItems = viewModel.tracks.map { t in
            QueueItem(
                trackId: t.id,
                title: t.name,
                artistName: viewModel.artistName,
                albumName: viewModel.albumName,
                albumId: t.albumId,
                durationSeconds: Double(t.durationTicks) / 10_000_000,
                serverURL: viewModel.serverURL,
                accessToken: viewModel.accessToken,
                artworkURL: trackArtworkURL(t)
            )
        }
        playbackEngine.setQueue(queueItems, startingAt: nowPlaying.trackId)
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
            trackId: nowPlaying.trackId,
            serverURL: viewModel.serverURL,
            accessToken: viewModel.accessToken
        )
        nowPlayingManager.setNowPlaying(track: nowPlaying)
        showNowPlaying()
    }

    private func shuffleAll() {
        guard case .loaded(let tracks) = viewModel.state, let first = tracks.randomElement() else { return }
        playTrack(first, shuffle: true)
    }

    private func betaDownloadButton(for track: JellyfinAPIClient.TrackSummary) -> some View {
        BetaDownloadButton(jellyfinId: track.id) {
            BetaDownloadManager.shared.download(track: TrackInfo(
                jellyfinId: track.id,
                trackName: track.name,
                artistName: viewModel.artistName,
                albumName: viewModel.albumName,
                albumId: track.albumId ?? "",
                durationTicks: track.durationTicks
            ))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.2))
            Text("No tracks found")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ error: TrackListViewModel.TrackError) -> some View {
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

    private func nowPlayingTrack(for track: JellyfinAPIClient.TrackSummary) -> NowPlayingTrack {
        NowPlayingTrack(
            trackId: track.id,
            title: track.name,
            artistName: viewModel.artistName,
            albumName: viewModel.albumName,
            albumId: track.albumId,
            durationSeconds: Double(track.durationTicks) / 10_000_000,
            artworkURL: trackArtworkURL(track)
        )
    }

    private func trackArtworkURL(_ track: JellyfinAPIClient.TrackSummary) -> URL? {
        let itemId = track.albumId ?? track.id
        return apiClient.imageURL(
            serverURL: viewModel.serverURL,
            itemId: itemId,
            maxWidth: 200,
            maxHeight: 200,
            tag: track.imageTag
        )
    }
}

#Preview {
    TrackListView(
        serverURL: "https://example.com",
        userId: "user-id",
        accessToken: "token",
        albumId: "album-id",
        albumName: "Example Album",
        artistName: "Example Artist"
    )
}
