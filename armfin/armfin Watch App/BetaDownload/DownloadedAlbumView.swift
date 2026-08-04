import SwiftUI
import SwiftData

/// The completed downloads belonging to one album. Owns its own `@Query`
/// rather than receiving an array from `BetaDownloadsView`, so deleting a
/// song here updates this screen immediately instead of leaving the caller
/// holding a stale snapshot.
struct DownloadedAlbumView: View {
    let albumId: String
    let albumName: String
    let artistName: String
    var serverURL: String = ""

    /// Narrowed to this album in the store; completion filtering and ordering
    /// happen below in `tracks`. The predicate stays single-clause to match
    /// `BetaDownloadManager.removeAlbumDownloads`, the shipped form.
    @Query private var albumDownloads: [BetaDownloadItem]

    @Environment(\.playbackEngine) private var playbackEngine
    @Environment(\.nowPlayingManager) private var nowPlayingManager
    @Environment(\.showNowPlaying) private var showNowPlaying

    @State private var startFailureMessage: String?
    @State private var itemPendingRemoval: BetaDownloadItem?

    init(albumId: String, albumName: String, artistName: String, serverURL: String = "") {
        self.albumId = albumId
        self.albumName = albumName
        self.artistName = artistName
        self.serverURL = serverURL

        _albumDownloads = Query(
            filter: #Predicate<BetaDownloadItem> { $0.albumId == albumId }
        )
    }

    /// Real album order — disc, then track number — from the index persisted
    /// at download time, falling back to title for untagged tracks. Bounded
    /// by one album's downloads, so sorting in memory is safe (soul.md §1.1).
    private var tracks: [BetaDownloadItem] {
        albumDownloads
            .filter { $0.status == .completed }
            .sortedInAlbumOrder()
    }

    var body: some View {
        Group {
            if tracks.isEmpty {
                DownloadsEmptyState(
                    icon: "opticaldisc",
                    title: "No downloads",
                    detail: "The downloads for this album have been removed."
                )
            } else {
                trackList
            }
        }
        .navigationTitle(albumName)
        .background(.black)
        .removeDownloadConfirmation(item: $itemPendingRemoval)
        .downloadStartFailureAlert(message: $startFailureMessage)
    }

    private var trackList: some View {
        // Bound once so the sort isn't re-run for every row, and so the
        // rendered list and the queue handed to playback are the same array.
        let songs = tracks
        // Every row on this screen shares one album, so this is one artwork
        // lookup instead of one `fileExists` syscall per row per body pass
        // (soul.md §2.3: no file I/O in a view body).
        let artwork = DownloadedArtwork.url(albumId: albumId, serverURL: serverURL)

        return List {
            DownloadedPlayAllRow(count: songs.count) { shuffle in
                startPlayback(items: songs, startingAt: nil, shuffle: shuffle)
            }
            .listRowBackground(Color.clear)

            ForEach(songs, id: \.id) { track in
                Button {
                    startPlayback(items: songs, startingAt: track.jellyfinId, shuffle: false)
                } label: {
                    DownloadedTrackRow(
                        item: track,
                        artworkURL: artwork,
                        subtitle: track.artistName
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .removeDownloadOnLongPress(track, pending: $itemPendingRemoval)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.black)
    }

    private func startPlayback(items: [BetaDownloadItem], startingAt trackId: String?, shuffle: Bool) {
        let result = DownloadedPlayback.start(
            items: items,
            startingAt: trackId,
            shuffle: shuffle,
            engine: playbackEngine,
            nowPlayingManager: nowPlayingManager
        )
        switch result {
        case .success:
            showNowPlaying()
        case .failure(let failure):
            startFailureMessage = failure.message
        }
    }
}
