import SwiftUI
import SwiftData

/// The completed downloads tagged with one genre. Reached by tapping a row
/// in `BetaDownloadsView`'s Genres tab (a `DownloadsRoute.genre` push).
///
/// Flat song list, not albums — mirrors `GenreTrackListView` (the online
/// genre detail screen, itself modeled on the Songs tab) rather than
/// `DownloadedArtistView`'s album-grouped hierarchy, since a genre's songs
/// aren't naturally organized into albums either online or off. Owns its own
/// `@Query` for the same reason `DownloadedArtistView`/`DownloadedAlbumView`
/// do: a removal made from this screen must be reflected immediately without
/// the caller re-handing it an array.
struct DownloadedGenreView: View {
    let genreName: String
    var serverURL: String = ""

    /// Narrowed to this genre in the store; completion filtering and
    /// ordering happen below in `tracks`, the same split `DownloadedArtistView`
    /// uses.
    @Query private var genreDownloads: [BetaDownloadItem]

    @Environment(\.playbackEngine) private var playbackEngine
    @Environment(\.nowPlayingManager) private var nowPlayingManager
    @Environment(\.showNowPlaying) private var showNowPlaying

    @State private var startFailureMessage: String?
    @State private var itemPendingRemoval: BetaDownloadItem?

    init(genreName: String, serverURL: String = "") {
        self.genreName = genreName
        self.serverURL = serverURL

        _genreDownloads = Query(
            filter: #Predicate<BetaDownloadItem> { $0.genreName == genreName }
        )
    }

    /// Bounded by one genre's downloads, so filtering/sorting in memory is
    /// safe (soul.md §1.1).
    private var tracks: [BetaDownloadItem] {
        genreDownloads
            .filter { $0.status == .completed }
            .sortedByTitle()
    }

    var body: some View {
        let songs = tracks

        return Group {
            if songs.isEmpty {
                DownloadsEmptyState(
                    icon: "music.note.list",
                    title: "No downloads",
                    detail: "The downloads for this genre have been removed."
                )
            } else {
                content(songs: songs)
            }
        }
        .navigationTitle(genreName.isEmpty ? "Unknown Genre" : genreName)
        .background(.black)
        .removeDownloadConfirmation(item: $itemPendingRemoval)
        .downloadStartFailureAlert(message: $startFailureMessage)
    }

    /// `DownloadedShuffleAllRow`, not `DownloadedPlayAllRow`: this is a flat
    /// list with no natural play-in-order sequence (a genre isn't an album),
    /// the same reasoning `BetaDownloadsView.songsContent` documents for the
    /// Songs tab. Tapping any row queues the whole list in title order from
    /// that point.
    private func content(songs: [BetaDownloadItem]) -> some View {
        List {
            DownloadedShuffleAllRow(count: songs.count) {
                startPlayback(items: songs, startingAt: nil, shuffle: true)
            }
            .listRowBackground(Color.clear)

            ForEach(songs, id: \.id) { track in
                Button {
                    startPlayback(items: songs, startingAt: track.jellyfinId, shuffle: false)
                } label: {
                    DownloadedTrackRow(
                        item: track,
                        artworkURL: trackArtworkURL(track),
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

    private func trackArtworkURL(_ track: BetaDownloadItem) -> URL? {
        let itemId = track.albumId.isEmpty ? track.jellyfinId : track.albumId
        return DownloadedArtwork.url(albumId: itemId, serverURL: serverURL)
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
