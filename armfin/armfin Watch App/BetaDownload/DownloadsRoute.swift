import SwiftUI

/// Destinations reachable from the Downloads tab.
///
/// Navigation here is value-based (`NavigationLink(value:)` +
/// `.navigationDestination(for:)`) rather than `NavigationLink { destination }`.
/// A closure-style link builds its destination view eagerly for every row, so
/// the artists list was constructing a `DownloadedArtistView` per artist, each
/// of which constructed a `DownloadedAlbumView` per album, each of which built
/// a row (and a `fileExists` call) per track — a whole-library eager build that
/// got deeper the further in you tapped. Per-row `NavigationLink` is a
/// documented watchOS List performance problem for exactly this reason.
///
/// A route value is cheap to construct; the destination is built only when the
/// push actually happens.
enum DownloadsRoute: Hashable {
    case artist(name: String)
    case album(id: String, name: String, artist: String)
}

extension View {
    /// Installs the Downloads destinations. Applied once at the root of the
    /// Downloads `NavigationStack`, not per row.
    func downloadsNavigationDestinations(serverURL: String) -> some View {
        navigationDestination(for: DownloadsRoute.self) { route in
            switch route {
            case .artist(let name):
                DownloadedArtistView(artistName: name, serverURL: serverURL)
            case .album(let id, let name, let artist):
                DownloadedAlbumView(
                    albumId: id,
                    albumName: name,
                    artistName: artist,
                    serverURL: serverURL
                )
            }
        }
    }
}
