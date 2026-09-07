import SwiftUI
import SwiftData

struct AllTrackListView: View {
    @State private var viewModel: AllTracksViewModel
    @Binding private var selectedCategory: LibraryCategory
    private let shuffleAction: (() -> Void)?

    @Environment(\.playbackEngine) private var playbackEngine
    @Environment(\.nowPlayingManager) private var nowPlayingManager
    @Environment(\.showNowPlaying) private var showNowPlaying
    @Environment(\.networkStatusService) private var networkStatusService

    private let serverURL: String
    private let userId: String
    private let accessToken: String

    init(
        serverURL: String,
        userId: String,
        accessToken: String,
        selectedCategory: Binding<LibraryCategory>,
        shuffleAction: (() -> Void)?
    ) {
        self.serverURL = serverURL
        self.userId = userId
        self.accessToken = accessToken
        self._selectedCategory = selectedCategory
        self.shuffleAction = shuffleAction
        _viewModel = State(
            wrappedValue: AllTracksViewModel(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken
            )
        )
    }

    /// See `ArtistListView.body` — the header is always the first two rows
    /// of this list so it lines up exactly with every other browse screen.
    var body: some View {
        List {
            LibraryBrowseHeaderRows(
                selection: $selectedCategory,
                shuffleAction: shuffleAction,
                statusLabel: networkStatusService.isOffline ? "Offline" : "Connected"
            )

            content
                .offlineGate(
                    tabKey: "all-tracks",
                    isUnreachable: viewModel.state == .failed(.serverUnreachable),
                    isLoaded: viewModel.state == .loaded,
                    showsStatusText: false,
                    onRetry: { await viewModel.load() }
                )
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.black)
        .environment(\.defaultMinListRowHeight, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
        case .loaded where viewModel.tracks.isEmpty:
            emptyState
                .listRowBackground(Color.clear)
        case .loaded:
            ForEach(viewModel.tracks, id: \.id) { track in
                trackRow(track)
                    .listRowBackground(Color.clear)
            }

            if viewModel.hasMore {
                PaginationFooter(errorMessage: viewModel.loadMoreError) {
                    await viewModel.loadMore()
                }
            }
        case .failed(let error):
            errorState(error)
                .listRowBackground(Color.clear)
        }
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
                genreName: t.genreName
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
                genreName: track.genreName ?? ""
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

    private func errorState(_ error: AllTracksViewModel.TrackError) -> some View {
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
            genreName: track.genreName
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
        AllTrackListView(
            serverURL: "https://example.com",
            userId: "user-id",
            accessToken: "token",
            selectedCategory: .constant(.songs),
            shuffleAction: nil
        )
    }
    .modelContainer(for: [BetaDownloadItem.self], inMemory: true)
}
