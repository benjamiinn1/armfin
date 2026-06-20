import Foundation

/// Plain, `Sendable` identity for the track `NowPlayingView` was pushed for.
struct NowPlayingTrack: Hashable, Sendable {
    let trackId: String
    let title: String
    let artistName: String
    let albumName: String
    let albumId: String?
    let durationSeconds: Double
    let artworkURL: URL?

    init(trackId: String, title: String, artistName: String, albumName: String,
         albumId: String? = nil, durationSeconds: Double, artworkURL: URL? = nil) {
        self.trackId = trackId
        self.title = title
        self.artistName = artistName
        self.albumName = albumName
        self.albumId = albumId
        self.durationSeconds = durationSeconds
        self.artworkURL = artworkURL
    }
}
