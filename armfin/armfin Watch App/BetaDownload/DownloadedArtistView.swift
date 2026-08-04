import SwiftUI
import SwiftData

/// The albums an artist has completed downloads for. Tapping an album drills
/// into `DownloadedAlbumView`; tracks that carry no album id (Jellyfin didn't
/// report one) are listed directly at the bottom so nothing is unreachable.
///
/// Owns its own `@Query` for the same reason as `DownloadedAlbumView`: a
/// deletion made deeper in the stack must be reflected here without the
/// caller having to re-hand it an array.
struct DownloadedArtistView: View {
    let artistName: String
    var serverURL: String = ""

    /// Narrowed to this artist in the store; completion filtering and ordering
    /// happen below in `tracks`. Single-clause predicate for the same reason
    /// as `DownloadedAlbumView` — it matches the form already shipping in
    /// `BetaDownloadManager`.
    @Query private var artistDownloads: [BetaDownloadItem]

    @Environment(\.playbackEngine) private var playbackEngine
    @Environment(\.nowPlayingManager) private var nowPlayingManager
    @Environment(\.showNowPlaying) private var showNowPlaying

    @State private var startFailureMessage: String?
    @State private var itemPendingRemoval: BetaDownloadItem?

    init(artistName: String, serverURL: String = "") {
        self.artistName = artistName
        self.serverURL = serverURL

        _artistDownloads = Query(
            filter: #Predicate<BetaDownloadItem> { $0.artistName == artistName }
        )
    }

    /// Bounded by one artist's downloads, so filtering and sorting in memory
    /// is safe (soul.md §1.1), and it keeps one ordering rule across every
    /// Downloads screen (soul.md §4.1).
    private var tracks: [BetaDownloadItem] {
        artistDownloads
            .filter { $0.status == .completed }
            .sortedByTitle()
    }

    /// Everything `body` needs, derived exactly once per pass. Reading
    /// `tracks`, `albums` and `looseTracks` as separate computed properties
    /// re-ran the filter/sort/group on every access — four-plus times per
    /// pass, and once per pre-built copy of this view.
    var body: some View {
        let songs = tracks
        let albums = songs.groupedIntoAlbums()
        let looseTracks = songs.withoutAlbum()

        return Group {
            if songs.isEmpty {
                DownloadsEmptyState(
                    icon: "music.mic",
                    title: "No downloads",
                    detail: "The downloads for this artist have been removed."
                )
            } else {
                content(songs: songs, albums: albums, looseTracks: looseTracks)
            }
        }
        .navigationTitle(artistName.isEmpty ? "Unknown Artist" : artistName)
        .background(.black)
        .removeDownloadConfirmation(item: $itemPendingRemoval)
        .downloadStartFailureAlert(message: $startFailureMessage)
    }

    private func content(
        songs: [BetaDownloadItem],
        albums: [DownloadedAlbumGroup],
        looseTracks: [BetaDownloadItem]
    ) -> some View {
        List {
            // Queue in the order this screen presents — albums in the order
            // listed, each in track order — not the flat alphabetical order
            // `songs` carries. Sorting on tap rather than in `body` keeps it
            // off the render path.
            DownloadedPlayAllRow(count: songs.count) { shuffle in
                startPlayback(items: songs.sortedInArtistOrder(), startingAt: nil, shuffle: shuffle)
            }
            .listRowBackground(Color.clear)

            ForEach(albums) { album in
                NavigationLink(
                    value: DownloadsRoute.album(id: album.id, name: album.name, artist: artistName)
                ) {
                    DownloadedGroupRow(
                        title: album.name,
                        subtitle: album.songCountLabel,
                        artworkURL: DownloadedArtwork.url(albumId: album.id, serverURL: serverURL),
                        icon: "opticaldisc"
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }

            if !looseTracks.isEmpty {
                Section {
                    ForEach(looseTracks, id: \.id) { track in
                        Button {
                            startPlayback(items: looseTracks, startingAt: track.jellyfinId, shuffle: false)
                        } label: {
                            DownloadedTrackRow(
                                item: track,
                                artworkURL: nil,
                                subtitle: track.albumName
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .removeDownloadOnLongPress(track, pending: $itemPendingRemoval)
                    }
                } header: {
                    Text("Other Songs")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .listRowBackground(Color.clear)
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
