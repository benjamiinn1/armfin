import SwiftUI
import SwiftData
import os

private let appLog = Logger(subsystem: "com.armfin", category: "App")

/// Bump this any time the SwiftData schema changes in a way that is
/// incompatible with the previous on-disk store. The app compares this
/// against a marker file on launch and wipes the database BEFORE
/// `ModelContainer` is ever constructed — avoiding the CoreData
/// precondition trap that cannot be caught with do/catch.
private let currentSchemaVersion = 5

@main
struct ArmfinApp: App {
    @WKApplicationDelegateAdaptor(ArmfinAppDelegate.self) var appDelegate

    @State private var playbackEngine: PlaybackEngine
    @State private var nowPlayingManager: NowPlayingManager
    @State private var networkStatusService = NetworkStatusService()

    private let modelContainer: ModelContainer

    /// `true` when the database had to be wiped during init because of
    /// unrecoverable corruption. The UI shows a one-time "data was reset"
    /// alert so the user knows they need to sign in again.
    @State private var didResetCorruptData = false

    init() {
        let wasReset = Self.migrateOrNukeIfNeeded()

        let schema = Schema([
            ServerConfiguration.self,
            CachedArtist.self,
            CachedAlbum.self,
            CachedTrack.self,
            BetaDownloadItem.self
        ])
        let container = Self.createContainer(schema: schema)
        modelContainer = container
        _didResetCorruptData = State(wrappedValue: wasReset)

        let engine = PlaybackEngine()
        engine.setModelContext(container.mainContext)
        _playbackEngine = State(wrappedValue: engine)
        _nowPlayingManager = State(wrappedValue: NowPlayingManager(playbackEngine: engine))

        BetaDownloadManager.shared.configure(modelContext: container.mainContext)
    }

    // MARK: - Schema-version gated migration

    private static var schemaVersionURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".armfin_schema_version")
    }

    /// Checks whether the on-disk database was written by the current schema
    /// version. If it wasn't (or if the marker is missing while a database
    /// file exists), wipes ALL data BEFORE `ModelContainer` is constructed.
    /// Returns `true` if data was wiped.
    private static func migrateOrNukeIfNeeded() -> Bool {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let versionFile = schemaVersionURL
        let storedVersion = (try? String(contentsOf: versionFile, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        let databaseExists = Self.databaseFilesExist(in: appSupport)

        if storedVersion == currentSchemaVersion && !databaseExists {
            appLog.notice("No database on disk, fresh install")
            writeSchemaVersion()
            return false
        }

        if storedVersion == currentSchemaVersion {
            appLog.notice("Schema version \(currentSchemaVersion) matches, opening existing DB")
            return false
        }

        if databaseExists {
            appLog.warning("Schema mismatch (stored=\(storedVersion ?? -1), current=\(currentSchemaVersion)) — nuking data before ModelContainer init")
            nukeAllLocalData()
            writeSchemaVersion()
            return true
        }

        appLog.notice("No prior data, writing schema version \(currentSchemaVersion)")
        writeSchemaVersion()
        return false
    }

    private static func databaseFilesExist(in directory: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return false }

        return contents.contains { url in
            let name = url.lastPathComponent.lowercased()
            return name.contains("default.store")
                || name.hasSuffix(".sqlite")
                || name.hasSuffix(".sqlite-wal")
                || name.hasSuffix(".sqlite-shm")
        }
    }

    private static func writeSchemaVersion() {
        try? "\(currentSchemaVersion)".write(to: schemaVersionURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Container creation (post-nuke, always clean)

    /// Creates the `ModelContainer`. At this point any incompatible database
    /// has already been deleted, so this should always succeed for the on-disk
    /// store. If it still fails (disk full, permissions, etc.), falls back to
    /// an in-memory store so the app can at least launch.
    private static func createContainer(schema: Schema) -> ModelContainer {
        let config = ModelConfiguration()
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            appLog.notice("ModelContainer opened successfully")
            writeSchemaVersion()
            return container
        } catch {
            appLog.fault("ModelContainer failed: \(error.localizedDescription) — nuking and retrying")
        }

        nukeAllLocalData()

        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            writeSchemaVersion()
            return container
        } catch {
            appLog.fault("ModelContainer STILL failed after nuke: \(error.localizedDescription) — falling back to in-memory")
        }

        let inMemory = ModelConfiguration(isStoredInMemoryOnly: true)
        do {
            let container = try ModelContainer(for: schema, configurations: [inMemory])
            return container
        } catch {
            fatalError("Cannot create even an in-memory ModelContainer: \(error)")
        }
    }

    /// Aggressive data wipe: removes ALL SwiftData/CoreData artifacts, downloaded
    /// files, artwork, and keychain credentials. Designed to recover from any
    /// schema migration failure, WAL corruption, or locked-file state.
    static func nukeAllLocalData() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        if let contents = try? fm.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: nil) {
            for url in contents {
                let name = url.lastPathComponent.lowercased()
                if name == ".armfin_schema_version" { continue }
                let isDatabase = name.contains("default.store")
                    || name.hasSuffix(".sqlite")
                    || name.hasSuffix(".sqlite-wal")
                    || name.hasSuffix(".sqlite-shm")
                    || name.hasSuffix(".sqlite-journal")
                    || name.contains("_swiftdata")
                    || name.contains("coredata")
                let isAppData = name == "downloads" || name == "artwork"
                if isDatabase || isAppData {
                    try? fm.removeItem(at: url)
                }
            }
        }

        let downloadsDir = appSupport.appendingPathComponent("Downloads", isDirectory: true)
        try? fm.removeItem(at: downloadsDir)
        let artworkDir = appSupport.appendingPathComponent("Artwork", isDirectory: true)
        try? fm.removeItem(at: artworkDir)

        try? KeychainStore().delete()
    }

    var body: some Scene {
        WindowGroup {
            LoginView(didResetCorruptData: $didResetCorruptData)
                .environment(\.playbackEngine, playbackEngine)
                .environment(\.nowPlayingManager, nowPlayingManager)
                .environment(\.networkStatusService, networkStatusService)
        }
        .modelContainer(modelContainer)
    }
}
