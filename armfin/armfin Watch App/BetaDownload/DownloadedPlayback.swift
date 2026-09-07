import Foundation

/// Single source of truth for starting playback from completed downloads.
/// Every offline entry point — the Downloads songs list, a downloaded album,
/// a downloaded artist, and `NowPlayingView`'s shuffle button — routes queue
/// construction, now-playing wiring and engine hand-off through here rather
/// than each rebuilding it (soul.md §4.1).
@MainActor
enum DownloadedPlayback {

    enum StartFailure: Error, Equatable {
        /// Nothing in the requested set has an audio file on disk. The
        /// SwiftData rows exist but the files are gone, so there is nothing
        /// to hand to the engine.
        case noPlayableTracks

        var message: String {
            switch self {
            case .noPlayableTracks:
                return "Those downloads are missing from disk."
            }
        }
    }

    /// Resolves the on-disk audio file for a download, or `nil` when the item
    /// isn't completed or its file is gone. Never call from a view `body`
    /// (soul.md §2.3) — this touches the file system.
    static func fileURL(for item: BetaDownloadItem) -> URL? {
        guard item.status == .completed, let fileName = item.localFileName else { return nil }
        let url = BetaDownloadManager.downloadsDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Starts playback of `items` beginning at `startTrackId`.
    ///
    /// Only items whose audio file is actually present on disk enter the
    /// queue. A queue entry backed by no file used to strand the engine in
    /// `.loadingItem` with nothing to load — the Now Playing screen would
    /// show the track and spin forever — so the filtering here, plus
    /// returning a failure when nothing survives it, is what lets a caller
    /// report the problem instead of navigating to a dead screen
    /// (soul.md §4.3: no silent failure).
    @discardableResult
    static func start(
        items: [BetaDownloadItem],
        startingAt startTrackId: String? = nil,
        shuffle: Bool = false,
        engine: PlaybackEngine,
        nowPlayingManager: NowPlayingManager
    ) -> Result<Void, StartFailure> {
        var fileURLs: [String: URL] = [:]
        let playable = items.filter { item in
            guard let url = fileURL(for: item) else { return false }
            fileURLs[item.jellyfinId] = url
            return true
        }
        guard !playable.isEmpty else { return .failure(.noPlayableTracks) }

        // The requested start track may itself be the one missing from disk;
        // fall back to a track that isn't rather than failing the whole set.
        let resolvedStartId = playable.first(where: { $0.jellyfinId == startTrackId })?.jellyfinId
            ?? (shuffle ? playable.randomElement()! : playable[0]).jellyfinId

        guard let startFileURL = fileURLs[resolvedStartId] else {
            return .failure(.noPlayableTracks)
        }

        let queueItems = playable.map(queueItem(for:))

        if engine.isShuffleEnabled != shuffle { engine.toggleShuffle() }
        engine.setQueue(queueItems, startingAt: resolvedStartId)
        engine.onQueueItemChanged = { [nowPlayingManager] item in
            nowPlayingManager.setNowPlaying(track: nowPlayingTrack(for: item))
        }

        if let startItem = queueItems.first(where: { $0.trackId == resolvedStartId }) {
            nowPlayingManager.setNowPlaying(track: nowPlayingTrack(for: startItem))
        }

        engine.playLocalFile(url: startFileURL, trackId: resolvedStartId)
        return .success(())
    }

    // MARK: - Mapping

    /// Downloads carry no credentials: `PlaybackEngine` resolves each queued
    /// track back to its local file through its own `ModelContext`, so an
    /// empty server URL/token is correct rather than missing information.
    private static func queueItem(for item: BetaDownloadItem) -> QueueItem {
        QueueItem(
            trackId: item.jellyfinId,
            title: item.trackName,
            artistName: item.artistName,
            albumName: item.albumName,
            albumId: item.albumId,
            durationSeconds: item.durationSeconds,
            serverURL: "",
            accessToken: "",
            indexNumber: item.indexNumber,
            discNumber: item.discNumber,
            genreName: item.genreName
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
            indexNumber: item.indexNumber,
            discNumber: item.discNumber,
            genreName: item.genreName
        )
    }
}
