import SwiftUI
import SwiftData

/// The genre detail screen: songs available in a single genre. Reached by
/// tapping a row in `GenreListView` (a `NavigationLink` push).
///
/// Mirrors `AllTrackListView` (the Songs tab) — the closest existing screen,
/// since a genre's songs are exactly a filtered Songs list — for structure,
/// the Shuffle All row, the per-track play + beta-download row, the
/// pagination footer, the playback wiring, and the `OfflineGate`. The only
/// difference from the Songs tab is the fetch: `GenreTracksViewModel` scopes
/// every `/Items` call to `GenreIds=<genreId>`, so the queue, Shuffle All, and
/// the displayed list are all confined to this genre.
struct GenreTrackListView: View {
    @State private var viewModel: GenreTracksViewModel

    @Environment(\.playbackEngine) private var playbackEngine
    @Environment(\.nowPlayingManager) private var nowPlayingManager
    @Environment(\.showNowPlaying) private var showNowPlaying

    private let serverURL: String
    private let userId: String
    private let accessToken: String

    init(serverURL: String, userId: String, accessToken: String, genreId: String, genreName: String) {
        self.serverURL = serverURL
        self.userId = userId
        self.accessToken = accessToken
        _viewModel = State(
            wrappedValue: GenreTracksViewModel(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken,
                genreId: genreId,
                genreName: genreName
            )
        )
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded where viewModel.tracks.isEmpty:
                emptyState
            case .loaded:
                trackList
            case .failed(let error):
                errorState(error)
            }
        }
        .navigationTitle(viewModel.genreName)
        .background(.black)
        .offlineGate(
            tabKey: "genre:\(viewModel.genreId)",
            isUnreachable: viewModel.state == .failed(.serverUnreachable),
            isLoaded: viewModel.state == .loaded,
            onRetry: { await viewModel.load() }
        )
    }

    private var trackList: some View {
        List {
            shuffleButton
                .listRowBackground(Color.clear)

            ForEach(viewModel.tracks, id: \.id) { track in
                trackRow(track)
                    .listRowBackground(Color.clear)
            }

            if viewModel.hasMore {
                PaginationFooter(errorMessage: viewModel.loadMoreError) {
                    await viewModel.loadMore()
                }
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
                    JellyfinImage(
                        url: trackArtworkURL(track),
                        icon: "music.note"
                    )
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.name)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let artist = track.artistName {
                            Text(artist)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.35))
                                .lineLimit(1)
                        }
                    }
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
        // The queue is built from `viewModel.tracks` — this genre's tracks
        // only — so playback and shuffle stay confined to the selected genre.
        let queueItems = viewModel.tracks.map { t in
            QueueItem(
                trackId: t.id,
                title: t.name,
                artistName: t.artistName ?? "",
                albumName: t.albumName ?? "",
                albumId: t.albumId,
                durationSeconds: Double(t.durationTicks) / 10_000_000,
                serverURL: serverURL,
                accessToken: accessToken,
                artworkURL: trackArtworkURL(t),
                indexNumber: t.indexNumber,
                discNumber: t.discNumber,
                // Every track in this queue came from this one genre's list,
                // so the genre is the screen's own context, not per-track
                // metadata — matches `GenreTracksViewModel`'s scoping.
                genreName: viewModel.genreName
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
                artworkURL: item.artworkURL,
                indexNumber: item.indexNumber,
                discNumber: item.discNumber,
                genreName: item.genreName
            ))
        }
        playbackEngine.play(
            trackId: nowPlaying.trackId,
            serverURL: serverURL,
            accessToken: accessToken
        )
        nowPlayingManager.setNowPlaying(track: nowPlaying)
        showNowPlaying()
    }

    private func shuffleAll() {
        guard !viewModel.tracks.isEmpty, let first = viewModel.tracks.randomElement() else { return }
        playTrack(first, shuffle: true)
    }

    private func betaDownloadButton(for track: JellyfinAPIClient.TrackSummary) -> some View {
        BetaDownloadButton(jellyfinId: track.id) {
            BetaDownloadManager.shared.download(track: TrackInfo(
                jellyfinId: track.id,
                trackName: track.name,
                artistName: track.artistName ?? "",
                albumName: track.albumName ?? "",
                albumId: track.albumId ?? "",
                durationTicks: track.durationTicks,
                indexNumber: track.indexNumber,
                discNumber: track.discNumber,
                genreName: viewModel.genreName
            ))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.2))
            Text("No songs found")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ error: GenreTracksViewModel.TrackError) -> some View {
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
            artistName: track.artistName ?? "",
            albumName: track.albumName ?? "",
            albumId: track.albumId,
            durationSeconds: Double(track.durationTicks) / 10_000_000,
            artworkURL: trackArtworkURL(track),
            indexNumber: track.indexNumber,
            discNumber: track.discNumber,
            genreName: viewModel.genreName
        )
    }

    private func trackArtworkURL(_ track: JellyfinAPIClient.TrackSummary) -> URL? {
        let itemId = track.albumId ?? track.id
        return JellyfinAPIClient.imageURL(
            serverURL: serverURL,
            itemId: itemId,
            maxWidth: 60,
            maxHeight: 60,
            tag: track.imageTag
        )
    }
}

#Preview {
    NavigationStack {
        GenreTrackListView(
            serverURL: "https://example.com",
            userId: "user-id",
            accessToken: "token",
            genreId: "genre-id",
            genreName: "Rock"
        )
    }
    .modelContainer(for: [BetaDownloadItem.self], inMemory: true)
}