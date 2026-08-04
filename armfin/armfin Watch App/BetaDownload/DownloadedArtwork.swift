import Foundation

/// Resolves the artwork URL for a downloaded album, cache-first. Every
/// Downloads screen (list, album, artist) and `NowPlayingView` share this one
/// definition of "where does a downloaded album's art come from" rather than
/// each re-deriving the path and remote fallback (soul.md §4.1).
enum DownloadedArtwork {

    /// Prefers the artwork `BetaDownloadManager` cached alongside the audio,
    /// falling back to the server only when there is no local copy — which is
    /// the case for tracks downloaded before artwork caching shipped, and is
    /// the reason `serverURL` is still needed here.
    static func url(albumId: String, serverURL: String, maxDimension: Int = 60) -> URL? {
        guard !albumId.isEmpty else { return nil }

        let cachedFile = BetaDownloadManager.artworkFileURL(forAlbumId: albumId)
        if FileManager.default.fileExists(atPath: cachedFile.path) {
            return cachedFile
        }

        guard !serverURL.isEmpty else { return nil }
        return JellyfinAPIClient.imageURL(
            serverURL: serverURL,
            itemId: albumId,
            maxWidth: maxDimension,
            maxHeight: maxDimension
        )
    }
}
