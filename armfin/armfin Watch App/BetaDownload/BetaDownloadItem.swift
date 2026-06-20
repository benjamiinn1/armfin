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

    /// Persisted as a plain String to avoid SwiftData Codable-enum traps on
    /// ARM64_32 (watchOS uses 32-bit pointers on older hardware).
    var statusRaw: String

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
        status: BetaDownloadStatus = .queued,
        totalBytes: Int64 = 0,
        downloadedBytes: Int64 = 0,
        localFileName: String? = nil,
        createdDate: Date = .now,
        completedDate: Date? = nil,
        lastError: String? = nil,
        durationTicks: Int64 = 0
    ) {
        self.id = id
        self.jellyfinId = jellyfinId
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.albumId = albumId
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
