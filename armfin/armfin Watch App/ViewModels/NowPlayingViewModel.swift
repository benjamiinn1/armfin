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

    /// Carried purely so the Now Playing screen's download button can persist
    /// them — it has no other handle on the track's position in its album.
    let indexNumber: Int?
    let discNumber: Int?

    /// First genre tag, if any. Carried so `NowPlayingView`'s download
    /// button (`toggleBetaDownload`) can persist genre offline the same way
    /// `indexNumber`/`discNumber` are persisted for album order.
    let genreName: String?

    init(trackId: String, title: String, artistName: String, albumName: String,
         albumId: String? = nil, durationSeconds: Double, artworkURL: URL? = nil,
         indexNumber: Int? = nil, discNumber: Int? = nil, genreName: String? = nil) {
        self.trackId = trackId
        self.title = title
        self.artistName = artistName
        self.albumName = albumName
        self.albumId = albumId
        self.durationSeconds = durationSeconds
        self.artworkURL = artworkURL
        self.indexNumber = indexNumber
        self.discNumber = discNumber
        self.genreName = genreName
    }
}
