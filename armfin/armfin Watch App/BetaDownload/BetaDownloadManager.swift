import Foundation
import SwiftData
import os

private nonisolated(unsafe) let log = Logger(subsystem: "com.armfin", category: "BetaDownloadManager")

struct TrackInfo: Sendable {
    let jellyfinId: String
    let trackName: String
    let artistName: String
    let albumName: String
    let albumId: String
    let durationTicks: Int64
    /// Jellyfin's `IndexNumber` / `ParentIndexNumber`. Optional at every layer
    /// because not every source is tagged with them.
    var indexNumber: Int? = nil
    var discNumber: Int? = nil
    /// First genre tag, if any. Denormalized onto `BetaDownloadItem` the same
    /// way `artistName`/`albumName` already are, so the offline Genres tab
    /// can group completed downloads without touching the server.
    var genreName: String = ""
}

enum AlbumDownloadState {
    case none, downloading, partial, completed, mixed
}

/// Live byte counts for one in-flight download.
struct DownloadProgress: Sendable, Equatable {
    let downloadedBytes: Int64

    /// `nil` when the server sent no `Content-Length`. armfin asks Jellyfin to
    /// transcode to AAC on the fly, so the response is chunked and the total
    /// size is genuinely unknowable up front — `totalBytesExpectedToWrite`
    /// arrives as `NSURLSessionTransferSizeUnknown`. This is why a percentage
    /// ring could never move: it wasn't stuck, there was no denominator.
    let totalBytes: Int64?

    /// How full to draw the ring, `nil` if there's no usable denominator.
    ///
    /// `expectedBytes` is normally the estimate from `estimatedBytes(forDurationSeconds:)`
    /// rather than a real `Content-Length`, so this is approximate by nature.
    /// It's capped just below full: an estimate that runs short would
    /// otherwise park the ring at 100% while bytes were still arriving, which
    /// reads as finished-but-stuck. The row disappears on completion, so the
    /// last sliver is never something the user waits on.
    func fraction(expectedBytes: Int64) -> Double? {
        let denominator = totalBytes ?? expectedBytes
        guard denominator > 0 else { return nil }
        return min(Double(downloadedBytes) / Double(denominator), 0.99)
    }

    /// Estimated finished size of a transcoded track: duration x the bitrate
    /// armfin asks Jellyfin for. Jellyfin transcodes on the fly, so the
    /// response is chunked and carries no `Content-Length` — without this
    /// there is no denominator and no ring can be drawn at all.
    ///
    /// Constant-bitrate AAC makes duration x bitrate a close estimate.
    /// Returns 0 when the duration is unknown, which callers treat as
    /// "no ring".
    static func estimatedBytes(forDurationSeconds seconds: Double) -> Int64 {
        guard seconds > 0 else { return 0 }
        return Int64(seconds * Double(JellyfinAPIClient.transcodeBitrateBitsPerSecond) / 8)
    }
}

@Observable
@MainActor
final class BetaDownloadManager: NSObject {

    static let sessionIdentifier = "com.armfin.beta-downloads"

    static let shared = BetaDownloadManager()

    /// Max tasks handed to the system daemon at once. The daemon manages
    /// concurrency internally; we just need to avoid flooding it with
    /// hundreds of tasks which could cause memory pressure.
    private static let maxConcurrentTasks = 6

    private(set) var isActive = false

    @ObservationIgnored
    private var modelContext: ModelContext?

    @ObservationIgnored
    private var serverURL: String = ""

    @ObservationIgnored
    private var accessToken: String = ""

    @ObservationIgnored
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Track IDs currently handed off to the system download daemon.
    @ObservationIgnored
    private var activeTaskIds: Set<String> = []

    /// Last progress write per in-flight download. Keyed by track id because a
    /// single shared timestamp meant the 1-second throttle was global: with up
    /// to `maxConcurrentTasks` downloads running, whichever delegate callback
    /// won the race each second was the only row that updated, and the other
    /// five showed stale byte counts and frozen progress rings.
    ///
    /// Bounded by `maxConcurrentTasks` — entries are always released together
    /// with `activeTaskIds` via `releaseTask` (soul.md §1.2).
    @ObservationIgnored
    private var lastProgressUpdate: [String: Date] = [:]

    /// Live progress for in-flight downloads, keyed by track id.
    ///
    /// Deliberately observed (not `@ObservationIgnored`) — the UI reads it —
    /// and deliberately NOT persisted. Writing byte counts to SwiftData meant
    /// up to `maxConcurrentTasks` saves per second, and every save invalidates
    /// every `@Query`, which re-ran the grouping and sorting behind the whole
    /// Downloads list several times a second. Progress is ephemeral: a
    /// download that doesn't survive relaunch restarts its own counter, and
    /// `BetaDownloadItem.status` (which does persist) is what actually needs
    /// to be durable.
    ///
    /// Bounded by `maxConcurrentTasks` — released in `releaseTask`.
    private(set) var progressByTrackId: [String: DownloadProgress] = [:]

    @ObservationIgnored
    private let apiClient = JellyfinAPIClient()

    nonisolated static var betaDownloadsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Downloads/Beta", isDirectory: true)
    }

    nonisolated static var downloadsDirectory: URL { betaDownloadsDirectory }

    /// One cached artwork file per distinct downloaded album: `{albumId}.img`.
    /// No format-specific extension — `/Items/{Id}/Images/Primary` negotiates
    /// WebP/JPEG/PNG/GIF server-side, so the extension can't be assumed at
    /// request time. `JellyfinImage` decodes via `UIImage(contentsOfFile:)`,
    /// which detects format from magic bytes regardless of extension.
    /// Storage bound (soul.md §1.2): exactly one file per album that has at
    /// least one `.completed` track; `cleanOrphanFiles` deletes a file the
    /// moment its last completed track is removed, so this never grows
    /// unbounded relative to the audio downloads themselves.
    nonisolated static var betaArtworkDirectory: URL {
        betaDownloadsDirectory.appendingPathComponent("Artwork", isDirectory: true)
    }

    /// Single source of truth for where a given album's cached artwork file
    /// lives on disk. All call sites (this manager, `BetaDownloadsView`,
    /// `NowPlayingView`) must go through this rather than re-deriving the
    /// path themselves (soul.md §4.1: one source of truth).
    nonisolated static func artworkFileURL(forAlbumId albumId: String) -> URL {
        betaArtworkDirectory.appendingPathComponent("\(albumId).img")
    }

    override private init() {
        super.init()
    }

    func configure(modelContext: ModelContext, serverURL: String = "", accessToken: String = "") {
        self.modelContext = modelContext
        self.serverURL = serverURL
        self.accessToken = accessToken
        recoverStalledState()
    }

    private func recoverStalledState() {
        guard let modelContext else { return }

        let downloadingRaw = BetaDownloadStatus.downloading.rawValue
        let downloadingPredicate = #Predicate<BetaDownloadItem> { $0.statusRaw == downloadingRaw }
        if let stalled = try? modelContext.fetch(FetchDescriptor(predicate: downloadingPredicate)) {
            for item in stalled {
                item.status = .queued
                item.downloadedBytes = 0
                item.totalBytes = 0
                log.notice("Recovered stalled download: \(item.jellyfinId) (\(item.trackName))")
            }
        }

        let completedRaw = BetaDownloadStatus.completed.rawValue
        let completedPredicate = #Predicate<BetaDownloadItem> { $0.statusRaw == completedRaw }
        if let completed = try? modelContext.fetch(FetchDescriptor(predicate: completedPredicate)) {
            for item in completed {
                guard let fileName = item.localFileName else {
                    item.status = .failed
                    item.lastError = "No file recorded"
                    continue
                }
                let fileURL = Self.betaDownloadsDirectory.appendingPathComponent(fileName)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    item.status = .failed
                    item.lastError = "File missing from disk"
                    log.warning("Completed item missing file: \(item.jellyfinId)")
                }
            }
        }

        cleanOrphanFiles(modelContext: modelContext)
        try? modelContext.save()

        fillDownloadSlots()
    }

    private func cleanOrphanFiles(modelContext: ModelContext) {
        let fm = FileManager.default
        let allItems = (try? modelContext.fetch(FetchDescriptor<BetaDownloadItem>())) ?? []

        let dir = Self.betaDownloadsDirectory
        if fm.fileExists(atPath: dir.path),
           let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let knownFileNames = Set(allItems.compactMap(\.localFileName))
            for fileURL in files {
                // Skip the Artwork subdirectory itself; it's swept separately below.
                guard !fileURL.hasDirectoryPath else { continue }
                let fileName = fileURL.lastPathComponent
                if !knownFileNames.contains(fileName) {
                    try? fm.removeItem(at: fileURL)
                    log.notice("Removed orphan file: \(fileName)")
                }
            }
        }

        let artworkDir = Self.betaArtworkDirectory
        if fm.fileExists(atPath: artworkDir.path),
           let artworkFiles = try? fm.contentsOfDirectory(at: artworkDir, includingPropertiesForKeys: nil) {
            let albumIdsWithCompletedTrack = Set(
                allItems.filter { $0.status == .completed }.map(\.albumId)
            )
            for fileURL in artworkFiles {
                let albumId = fileURL.deletingPathExtension().lastPathComponent
                if !albumIdsWithCompletedTrack.contains(albumId) {
                    try? fm.removeItem(at: fileURL)
                    log.notice("Removed orphan artwork: \(fileURL.lastPathComponent)")
                }
            }
        }
    }

    func updateCredentials(serverURL: String, accessToken: String) {
        self.serverURL = serverURL
        self.accessToken = accessToken
    }

    func attachIfNeeded() {
        _ = session
    }

    func reattach(sessionIdentifier: String) {
        guard sessionIdentifier == Self.sessionIdentifier else { return }
        _ = session
    }

    // MARK: - Public API

    func download(track: TrackInfo) {
        guard let modelContext else {
            log.error("download called before modelContext configured")
            return
        }

        let jellyfinId = track.jellyfinId
        let predicate = #Predicate<BetaDownloadItem> { $0.jellyfinId == jellyfinId }
        if let existing = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first {
            let status = existing.status
            if status == .queued || status == .downloading || status == .completed {
                log.notice("Track \(jellyfinId) already in state \(existing.statusRaw), skipping")
                return
            }
            modelContext.delete(existing)
        }

        let item = BetaDownloadItem(
            jellyfinId: track.jellyfinId,
            trackName: track.trackName,
            artistName: track.artistName,
            albumName: track.albumName,
            albumId: track.albumId,
            indexNumber: track.indexNumber,
            discNumber: track.discNumber,
            status: .queued,
            durationTicks: track.durationTicks,
            genreName: track.genreName
        )
        modelContext.insert(item)
        try? modelContext.save()

        fillDownloadSlots()
    }

    func cancel(jellyfinId: String) {
        guard let modelContext else { return }

        if activeTaskIds.contains(jellyfinId) {
            session.getActiveTasks { tasks in
                for task in tasks where task.taskDescription == jellyfinId {
                    task.cancel()
                }
            }
            releaseTask(jellyfinId)
        }

        let predicate = #Predicate<BetaDownloadItem> { $0.jellyfinId == jellyfinId }
        if let item = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first {
            if let fileName = item.localFileName {
                let fileURL = Self.betaDownloadsDirectory.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
            modelContext.delete(item)
            try? modelContext.save()
        }

        fillDownloadSlots()
    }

    func cancelAll() {
        guard let modelContext else { return }

        session.getActiveTasks { tasks in
            for task in tasks { task.cancel() }
        }
        releaseAllTasks()

        let descriptor = FetchDescriptor<BetaDownloadItem>()
        if let items = try? modelContext.fetch(descriptor) {
            for item in items where item.status != .completed {
                modelContext.delete(item)
            }
            try? modelContext.save()
        }

        isActive = false
    }

    func removeCompleted(jellyfinId: String) {
        guard let modelContext else { return }

        let predicate = #Predicate<BetaDownloadItem> { $0.jellyfinId == jellyfinId }
        if let item = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first {
            if let fileName = item.localFileName {
                let fileURL = Self.betaDownloadsDirectory.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
            modelContext.delete(item)
            try? modelContext.save()
        }
    }

    func removeAllCompleted() {
        guard let modelContext else { return }

        let completedRaw = BetaDownloadStatus.completed.rawValue
        let predicate = #Predicate<BetaDownloadItem> { $0.statusRaw == completedRaw }
        if let items = try? modelContext.fetch(FetchDescriptor(predicate: predicate)) {
            for item in items {
                if let fileName = item.localFileName {
                    let fileURL = Self.betaDownloadsDirectory.appendingPathComponent(fileName)
                    try? FileManager.default.removeItem(at: fileURL)
                }
                modelContext.delete(item)
            }
            try? modelContext.save()
        }
    }

    func retry(jellyfinId: String) {
        guard let modelContext else { return }

        let predicate = #Predicate<BetaDownloadItem> { $0.jellyfinId == jellyfinId }
        if let item = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first,
           item.status == .failed {
            item.status = .queued
            item.lastError = nil
            item.downloadedBytes = 0
            item.totalBytes = 0
            try? modelContext.save()
            fillDownloadSlots()
        }
    }

    // MARK: - Album-level operations

    func downloadAlbum(
        albumId: String,
        albumName: String,
        artistName: String,
        serverURL: String,
        userId: String,
        accessToken: String
    ) async {
        guard let result = try? await apiClient.fetchTracks(
            serverURL: serverURL,
            userId: userId,
            accessToken: accessToken,
            albumId: albumId,
            limit: 500
        ) else { return }

        for track in result.items {
            download(track: TrackInfo(
                jellyfinId: track.id,
                trackName: track.name,
                artistName: track.artistName ?? artistName,
                albumName: track.albumName ?? albumName,
                albumId: track.albumId ?? albumId,
                durationTicks: track.durationTicks,
                indexNumber: track.indexNumber,
                discNumber: track.discNumber,
                genreName: track.genreName ?? ""
            ))
        }
    }

    func removeAlbumDownloads(albumId: String) {
        guard let modelContext else { return }

        let predicate = #Predicate<BetaDownloadItem> { $0.albumId == albumId }
        guard let items = try? modelContext.fetch(FetchDescriptor(predicate: predicate)) else { return }

        var idsToCancel: [String] = []
        for item in items {
            if item.status == .downloading, activeTaskIds.contains(item.jellyfinId) {
                idsToCancel.append(item.jellyfinId)
                releaseTask(item.jellyfinId)
            }
            if let fileName = item.localFileName {
                let fileURL = Self.betaDownloadsDirectory.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
            modelContext.delete(item)
        }
        if !idsToCancel.isEmpty {
            let cancelSet = Set(idsToCancel)
            session.getActiveTasks { tasks in
                for task in tasks where cancelSet.contains(task.taskDescription ?? "") {
                    task.cancel()
                }
            }
        }
        try? modelContext.save()
        fillDownloadSlots()
    }

    func albumDownloadState(albumId: String) -> AlbumDownloadState {
        guard let modelContext else { return .none }

        let predicate = #Predicate<BetaDownloadItem> { $0.albumId == albumId }
        guard let items = try? modelContext.fetch(FetchDescriptor(predicate: predicate)),
              !items.isEmpty else { return .none }

        let completed = items.filter { $0.status == .completed }.count
        let active = items.filter { $0.status == .queued || $0.status == .downloading }.count

        if active > 0 { return .downloading }
        if completed == items.count { return .completed }
        if completed > 0 { return .partial }
        return .mixed
    }

    func purgeQueue() {
        guard let modelContext else { return }

        let queuedRaw = BetaDownloadStatus.queued.rawValue
        let predicate = #Predicate<BetaDownloadItem> { $0.statusRaw == queuedRaw }
        guard let items = try? modelContext.fetch(FetchDescriptor(predicate: predicate)) else { return }

        for item in items {
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    // MARK: - Internal queue management

    /// Releases every piece of per-task state for `jellyfinId` at once. Single
    /// entry point so a task can never leave `activeTaskIds` while leaving its
    /// throttle timestamp behind (soul.md §4.1).
    private func releaseTask(_ jellyfinId: String) {
        activeTaskIds.remove(jellyfinId)
        lastProgressUpdate[jellyfinId] = nil
        progressByTrackId[jellyfinId] = nil
    }

    private func releaseAllTasks() {
        activeTaskIds.removeAll()
        lastProgressUpdate.removeAll()
        progressByTrackId.removeAll()
    }

    /// Fills available download slots by handing queued items to the system
    /// daemon. Up to `maxConcurrentTasks` are in-flight simultaneously.
    /// The daemon manages these independently of our app's lifecycle —
    /// downloads continue even when the wrist drops and the app suspends.
    private func fillDownloadSlots() {
        guard let modelContext else { return }

        let availableSlots = Self.maxConcurrentTasks - activeTaskIds.count
        guard availableSlots > 0 else { return }

        let queuedRaw = BetaDownloadStatus.queued.rawValue
        let predicate = #Predicate<BetaDownloadItem> { $0.statusRaw == queuedRaw }
        var descriptor = FetchDescriptor<BetaDownloadItem>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.createdDate, order: .forward)]
        )
        descriptor.fetchLimit = availableSlots

        guard let nextItems = try? modelContext.fetch(descriptor), !nextItems.isEmpty else {
            if activeTaskIds.isEmpty {
                isActive = false
            }
            return
        }

        let fm = FileManager.default
        let dir = Self.betaDownloadsDirectory
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        for item in nextItems {
            guard let url = JellyfinAPIClient.betaDownloadURL(
                serverURL: serverURL,
                accessToken: accessToken,
                trackId: item.jellyfinId
            ) else {
                item.status = .failed
                item.lastError = "Could not build download URL"
                continue
            }

            let task = session.downloadTask(with: url)
            task.taskDescription = item.jellyfinId
            activeTaskIds.insert(item.jellyfinId)

            item.status = .downloading
            log.notice("Enqueued download for \(item.jellyfinId): \(item.trackName)")
            task.resume()
        }

        isActive = !activeTaskIds.isEmpty
        try? modelContext.save()
    }
}

// MARK: - URLSessionDownloadDelegate

extension BetaDownloadManager: URLSessionDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let jellyfinId = downloadTask.taskDescription ?? ""
        let fileName = "\(jellyfinId).aac"
        let destinationDir = Self.betaDownloadsDirectory
        let destination = destinationDir.appendingPathComponent(fileName)

        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: destinationDir.path) {
                try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            }
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: location, to: destination)
            log.notice("Saved \(fileName) to Beta downloads")
        } catch {
            log.error("Failed to move download for \(jellyfinId): \(error.localizedDescription)")
        }

        Task { @MainActor [weak self] in
            self?.handleDownloadComplete(jellyfinId: jellyfinId, fileName: fileName)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }

        let jellyfinId = task.taskDescription ?? ""
        let message = error.localizedDescription

        if (error as NSError).code == NSURLErrorCancelled {
            log.notice("Download cancelled for \(jellyfinId)")
            Task { @MainActor [weak self] in
                self?.releaseTask(jellyfinId)
                self?.fillDownloadSlots()
            }
            return
        }

        log.error("Download failed for \(jellyfinId): \(message)")

        Task { @MainActor [weak self] in
            self?.handleDownloadError(jellyfinId: jellyfinId, message: message)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let jellyfinId = downloadTask.taskDescription ?? ""

        Task { @MainActor [weak self] in
            self?.handleProgress(jellyfinId: jellyfinId, written: totalBytesWritten, total: totalBytesExpectedToWrite)
        }
    }

    // MARK: - MainActor callbacks

    private func handleDownloadComplete(jellyfinId: String, fileName: String) {
        guard let modelContext else { return }

        let predicate = #Predicate<BetaDownloadItem> { $0.jellyfinId == jellyfinId }
        if let item = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first {
            item.status = .completed
            item.localFileName = fileName
            item.completedDate = .now
            try? modelContext.save()
            log.notice("Marked \(jellyfinId) as completed")

            // Best-effort artwork fetch. Never gates the audio download's
            // `.completed` status — it runs after the item is already saved,
            // and any failure here is logged and dropped, not retried
            // (soul.md §2.1: no polling/retry loops) and not surfaced as a
            // download failure.
            let albumId = item.albumId
            if !albumId.isEmpty {
                fetchArtworkIfNeeded(albumId: albumId)
            }
        }

        releaseTask(jellyfinId)
        fillDownloadSlots()
    }

    /// Fetches and caches album artwork for `albumId` if it isn't already on
    /// disk. De-duplication is the file-existence check itself — disk-backed,
    /// so it survives relaunch with no in-memory tracking needed. If two
    /// tracks from the same album complete around the same time, both may
    /// pass the check and fetch concurrently; worst case is a redundant
    /// fetch with last-write-wins, which is harmless.
    ///
    /// A non-2xx response (no Primary image on the server, transient 5xx,
    /// etc.) is treated as a failed fetch: nothing is written to disk, so
    /// the file-existence de-dup guard does NOT consider this album cached,
    /// and a later download-completion event for the same album will retry.
    /// Writing the raw response body unconditionally would otherwise let an
    /// error page silently and permanently poison the cache for that album.
    private func fetchArtworkIfNeeded(albumId: String) {
        let destination = Self.artworkFileURL(forAlbumId: albumId)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }

        guard let url = JellyfinAPIClient.imageURL(
            serverURL: serverURL,
            itemId: albumId,
            maxWidth: 200,
            maxHeight: 200
        ) else {
            log.error("Could not build artwork URL for album \(albumId)")
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse else {
                    log.error("Artwork fetch for album \(albumId) returned a non-HTTP response")
                    return
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    log.error("Artwork fetch for album \(albumId) failed with status \(httpResponse.statusCode)")
                    return
                }
                try self.saveArtwork(data: data, to: destination)
            } catch {
                log.error("Artwork fetch failed for album \(albumId): \(error.localizedDescription)")
            }
        }
    }

    private func saveArtwork(data: Data, to destination: URL) throws {
        let fm = FileManager.default
        let dir = destination.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try data.write(to: destination, options: .atomic)
    }

    private func handleDownloadError(jellyfinId: String, message: String) {
        guard let modelContext else { return }

        let predicate = #Predicate<BetaDownloadItem> { $0.jellyfinId == jellyfinId }
        if let item = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first {
            item.status = .failed
            item.lastError = message
            try? modelContext.save()
        }

        releaseTask(jellyfinId)
        fillDownloadSlots()
    }

    /// Records progress in memory only — no fetch, no `save()`. See
    /// `progressByTrackId` for why this must not touch the store.
    private func handleProgress(jellyfinId: String, written: Int64, total: Int64) {
        let now = Date()
        let last = lastProgressUpdate[jellyfinId] ?? .distantPast
        guard now.timeIntervalSince(last) >= 1.0 else { return }
        lastProgressUpdate[jellyfinId] = now

        progressByTrackId[jellyfinId] = DownloadProgress(
            downloadedBytes: written,
            totalBytes: total > 0 ? total : nil
        )
    }
}

// MARK: - URLSession helper

private extension URLSession {
    func getActiveTasks(completion: @escaping @Sendable ([URLSessionTask]) -> Void) {
        getTasksWithCompletionHandler { _, _, downloadTasks in
            completion(downloadTasks)
        }
    }
}
