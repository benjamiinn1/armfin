import Foundation
import SwiftData

enum BetaDownloadStatus: String, Codable, Sendable {
    case queued, downloading, completed, failed
}

@Model
final class BetaDownloadItem {
    @Attribute(.unique) var id: UUID
    var jellyfinId: String
    var trackName: String
    var artistName: String
    var albumName: String
    var albumId: String

    /// First genre tag, if any, denormalized the same way `artistName` and
    /// `albumName` are — captured at download time so the offline Genres tab
    /// (`BetaDownloadsView`) can group completed downloads without a server
    /// round-trip. Empty means "not captured" and groups as "Unknown Genre",
    /// the same convention `artistName` already uses for "Unknown Artist".
    var genreName: String

    /// Jellyfin's `IndexNumber` / `ParentIndexNumber` — track position within
    /// its disc, and which disc. Optional because Jellyfin reports them only
    /// when the source tags carry them. Persisted so downloaded albums list
    /// in album order offline, where there is no server to re-ask.
    var indexNumber: Int?
    var discNumber: Int?

    /// Persisted as a plain String to avoid SwiftData Codable-enum traps on
    /// ARM64_32 (watchOS uses 32-bit pointers on older hardware).
    var statusRaw: String

    /// Retained but no longer written during a transfer. Live progress moved
    /// to `BetaDownloadManager.progressByTrackId` because persisting byte
    /// counts meant a SwiftData save per download per second, and each save
    /// invalidated every `@Query` in the app. Kept as stored properties rather
    /// than deleted: removing them changes the schema, and this app's version
    /// gate responds to a schema change by wiping all downloads.
    var totalBytes: Int64
    var downloadedBytes: Int64
    var localFileName: String?
    var createdDate: Date
    var completedDate: Date?
    var lastError: String?
    var durationTicks: Int64

    @Transient
    var status: BetaDownloadStatus {
        get { BetaDownloadStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }

    var durationSeconds: Double { Double(durationTicks) / 10_000_000 }

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(downloadedBytes) / Double(totalBytes)
    }

    init(
        id: UUID = UUID(),
        jellyfinId: String,
        trackName: String,
        artistName: String,
        albumName: String,
        albumId: String,
        indexNumber: Int? = nil,
        discNumber: Int? = nil,
        status: BetaDownloadStatus = .queued,
        totalBytes: Int64 = 0,
        downloadedBytes: Int64 = 0,
        localFileName: String? = nil,
        createdDate: Date = .now,
        completedDate: Date? = nil,
        lastError: String? = nil,
        durationTicks: Int64 = 0,
        genreName: String = ""
    ) {
        self.id = id
        self.jellyfinId = jellyfinId
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.albumId = albumId
        self.indexNumber = indexNumber
        self.discNumber = discNumber
        self.genreName = genreName
        self.statusRaw = status.rawValue
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.localFileName = localFileName
        self.createdDate = createdDate
        self.completedDate = completedDate
        self.lastError = lastError
        self.durationTicks = durationTicks
    }
}

extension Array where Element == BetaDownloadItem {

    /// Album order: disc, then track number, then title. Tracks Jellyfin gave
    /// no index for sort after the numbered ones rather than jumping to the
    /// front, and fall back to title among themselves. Use inside a single
    /// album; across albums the numbers collide and mean nothing.
    func sortedInAlbumOrder() -> [BetaDownloadItem] {
        sorted { lhs, rhs in
            let lhsDisc = lhs.discNumber ?? Int.max
            let rhsDisc = rhs.discNumber ?? Int.max
            if lhsDisc != rhsDisc { return lhsDisc < rhsDisc }

            let lhsIndex = lhs.indexNumber ?? Int.max
            let rhsIndex = rhs.indexNumber ?? Int.max
            if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }

            return lhs.trackName.localizedStandardCompare(rhs.trackName) == .orderedAscending
        }
    }

    /// Title order, for lists that span more than one album.
    /// `localizedStandardCompare` so "Track 2" precedes "Track 10".
    func sortedByTitle() -> [BetaDownloadItem] {
        sorted { $0.trackName.localizedStandardCompare($1.trackName) == .orderedAscending }
    }

    /// Ordered the way an artist's downloads are *presented*: album by album in
    /// the order the albums are listed, each album in disc/track order, with
    /// tracks belonging to no album last.
    ///
    /// This is what "Play All" on an artist must queue. `sortedByTitle()` is
    /// right for a flat list that spans albums (the Songs tab), but using it
    /// for an artist's Play All starts playback at whichever song is
    /// alphabetically first across every album — an order the artist screen
    /// never shows, which makes Play All indistinguishable from Shuffle.
    func sortedInArtistOrder() -> [BetaDownloadItem] {
        let byAlbum = Dictionary(grouping: filter { !$0.albumId.isEmpty }, by: \.albumId)
        var result = groupedIntoAlbums().flatMap { album in
            (byAlbum[album.id] ?? []).sortedInAlbumOrder()
        }
        result.append(contentsOf: withoutAlbum().sortedByTitle())
        return result
    }

    /// Groups into albums, alphabetical by album name. Items with an empty
    /// album id are excluded — grouping on `""` would collapse unrelated
    /// tracks into one bogus album — and come back from `withoutAlbum()`
    /// instead, so nothing is unreachable.
    func groupedIntoAlbums() -> [DownloadedAlbumGroup] {
        Dictionary(grouping: filter { !$0.albumId.isEmpty }, by: \.albumId)
            .map { albumId, tracks in
                DownloadedAlbumGroup(
                    id: albumId,
                    name: tracks.first?.albumName ?? "Unknown Album",
                    artistName: tracks.first?.artistName ?? "",
                    trackCount: tracks.count
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func withoutAlbum() -> [BetaDownloadItem] {
        filter { $0.albumId.isEmpty }
    }
}

/// One album's completed downloads reduced to what a row needs. A concrete
/// `Identifiable` type rather than a tuple so `ForEach` and `NavigationLink`
/// values stay straightforward.
struct DownloadedAlbumGroup: Identifiable, Hashable {
    /// The Jellyfin album id.
    let id: String
    let name: String
    let artistName: String
    let trackCount: Int

    var songCountLabel: String {
        "\(trackCount) song\(trackCount == 1 ? "" : "s")"
    }
}
