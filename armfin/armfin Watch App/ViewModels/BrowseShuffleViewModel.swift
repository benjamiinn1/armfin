import Foundation

/// Backs the "shuffle all songs" action available from every Library browse
/// tab (Artists/Albums/Songs/Genres) via the circular button beside the
/// category dropdown — not just from the Songs tab. Deliberately independent
/// of `AllTracksViewModel`: that view model's `tracks` are paginated and only
/// populated once the Songs tab has been visited, and reusing it would mean
/// the button behaves differently depending on browsing history. This
/// fetches a fresh random batch from the server on every tap instead, so the
/// button is the same action everywhere and never holds the library in
/// memory (soul.md §1.1).
@Observable
final class BrowseShuffleViewModel {
    enum ShuffleError: Equatable {
        case unreachable
        case noSongs

        var message: String {
            switch self {
            case .unreachable:
                return "Can't reach this server"
            case .noSongs:
                return "No songs found to shuffle"
            }
        }
    }

    private(set) var lastError: ShuffleError?

    private let apiClient: JellyfinAPIClient
    private let serverURL: String
    private let userId: String
    private let accessToken: String
    private let batchSize = 50

    init(
        serverURL: String,
        userId: String,
        accessToken: String,
        apiClient: JellyfinAPIClient = JellyfinAPIClient()
    ) {
        self.serverURL = serverURL
        self.userId = userId
        self.accessToken = accessToken
        self.apiClient = apiClient
    }

    @MainActor
    func shuffleAll(engine: PlaybackEngine, nowPlayingManager: NowPlayingManager, showNowPlaying: () -> Void) async {
        lastError = nil
        do {
            let libraryId = try await apiClient.fetchMusicLibraryId(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken
            )
            let result = try await apiClient.fetchRandomTracks(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken,
                musicLibraryId: libraryId,
                limit: batchSize
            )
            guard !result.items.isEmpty else {
                lastError = .noSongs
                return
            }

            let queueItems = result.items.map(queueItem(for:))
            let startId = queueItems.randomElement()!.trackId

            if !engine.isShuffleEnabled { engine.toggleShuffle() }
            engine.setQueue(queueItems, startingAt: startId)
            engine.onQueueItemChanged = { [nowPlayingManager] item in
                nowPlayingManager.setNowPlaying(track: Self.nowPlayingTrack(for: item))
            }
            if let startItem = queueItems.first(where: { $0.trackId == startId }) {
                nowPlayingManager.setNowPlaying(track: Self.nowPlayingTrack(for: startItem))
            }
            engine.play(trackId: startId, serverURL: serverURL, accessToken: accessToken)
            showNowPlaying()
        } catch {
            lastError = .unreachable
        }
    }

    private func queueItem(for track: JellyfinAPIClient.TrackSummary) -> QueueItem {
        QueueItem(
            trackId: track.id,
            title: track.name,
            artistName: track.artistName ?? "",
            albumName: track.albumName ?? "",
            albumId: track.albumId,
            durationSeconds: Double(track.durationTicks) / 10_000_000,
            serverURL: serverURL,
            accessToken: accessToken,
            artworkURL: JellyfinAPIClient.imageURL(
                serverURL: serverURL,
                itemId: track.albumId ?? track.id,
                maxWidth: 60,
                maxHeight: 60,
                tag: track.imageTag
            ),
            indexNumber: track.indexNumber,
            discNumber: track.discNumber,
            genreName: track.genreName
        )
    }

    private static func nowPlayingTrack(for item: QueueItem) -> NowPlayingTrack {
        NowPlayingTrack(
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
        )
    }
}
