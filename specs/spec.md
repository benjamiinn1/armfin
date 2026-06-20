# armfin — Technical Specification

## 0. Purpose & Scope

This document is the single source of truth for implementing **armfin**: a free, open-source, standalone watchOS application that streams and downloads music directly from a user's personal Jellyfin server, with no iPhone, no companion app, and no cloud intermediary. It covers architecture, the Jellyfin integration contract, the playback/sync engine, UI/navigation, and offline data rules. Anything not specified here should default to the simplest option consistent with the engineering philosophy in §1.2.

**Platform note on API accuracy:** Jellyfin's REST surface is documented by each server at `{serverURL}/api-docs/openapi.json`. The endpoint shapes below reflect the stable, long-standing Jellyfin API contract; before implementing each call, diff it against the live OpenAPI schema of a real target server, since field availability can shift between server versions.

---

## 1. Project Architecture & Tech Stack

### 1.1 Target & Deployment
- Single, independent **watchOS app target** — the modern unified watchOS app (no WatchKit Extension + iOS container split). No iOS companion target exists or is planned.
- Deployment target: **watchOS 26+**.
- Swift 6 language mode, strict concurrency checking enabled.
- App entry point uses the SwiftUI app lifecycle with `WKApplicationDelegateAdaptor` for the one piece of UIKit-era ceremony that SwiftUI doesn't cover: background `URLSession` reattachment.
- Xcode's watchOS App template generates **two** build targets: **`armfin Watch App`** (the real app — all source, all features) and a thin **`armfin`** packaging/signing container (`productType: application.watchapp2-container`) that the App Store requires in order to install a standalone watchOS app. The container has no source of its own and must stay that way — never add code, UI, or capabilities to it; every implementation task targets `armfin Watch App`.
- No external Swift Package Manager dependencies — pure Apple frameworks only.

```swift
@main
struct ArmfinApp: App {
    @WKApplicationDelegateAdaptor(ArmfinAppDelegate.self) var appDelegate

    @State private var playbackEngine: PlaybackEngine
    @State private var nowPlayingManager: NowPlayingManager
    private let modelContainer: ModelContainer

    init() {
        let engine = PlaybackEngine()
        _playbackEngine = State(wrappedValue: engine)
        _nowPlayingManager = State(wrappedValue: NowPlayingManager(playbackEngine: engine))

        let container: ModelContainer
        do {
            container = try ModelContainer(for: ServerConfiguration.self, CachedArtist.self,
                                           CachedAlbum.self, CachedTrack.self, DownloadTaskState.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        modelContainer = container
        BackgroundDownloadCoordinator.shared.setModelContext(container.mainContext)
        engine.setModelContext(container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            LoginView()
                .environment(\.playbackEngine, playbackEngine)
                .environment(\.nowPlayingManager, nowPlayingManager)
        }
        .modelContainer(modelContainer)
    }
}

final class ArmfinAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        BackgroundDownloadCoordinator.shared.attachIfNeeded()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let urlSessionTask as WKURLSessionRefreshBackgroundTask:
                BackgroundDownloadCoordinator.shared.reattach(sessionIdentifier: urlSessionTask.sessionIdentifier)
                urlSessionTask.setTaskCompletedWithSnapshot(false)
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
```

Key architectural choices in the app entry point:
- A single `ModelContainer` is constructed explicitly and shared with both `BackgroundDownloadCoordinator` and `PlaybackEngine` so all three write to the same SwiftData store.
- `PlaybackEngine` and `NowPlayingManager` are held as `@State` for stable lifetime and injected into the view hierarchy via custom `EnvironmentKey`s (defined in `Playback/PlaybackEnvironment.swift`).
- The root view is `LoginView`, which wraps a `NavigationStack` and auto-navigates to `HomeView` once a valid session is restored or login completes.

### 1.2 Architecture Pattern: MVVM

**MVVM**, not Clean Architecture. Justification: this is a single-target app with one persistence layer; SwiftData's `@Model`/`ModelContext` already gives a repository-like boundary, so an additional use-case/interactor layer adds ceremony with no payoff on a battery- and memory-constrained device. MVVM also pairs directly with SwiftUI's `@Observable`/`@Bindable`, keeping the dependency graph shallow.

Layering: **Views** (SwiftUI) → **ViewModels** (`@Observable` classes, one per screen) → **Services** (`JellyfinAPIClient`, `BackgroundDownloadCoordinator`, `PlaybackEngine`, `KeychainStore`) → **SwiftData** (`ModelContainer`/`ModelContext`) + **URLSession**.

### 1.3 Source Tree Layout

Reflects the actual on-disk structure — the `.xcodeproj` and its source folder live one level below the repository root, inside a project directory that shares the app's name:

```
armfin/                                   # repository root
├── CLAUDE.md
├── .gitignore
├── documentation/
│   └── business_description.md
├── specs/
│   └── spec.md
└── armfin/                               # Xcode project directory
    ├── armfin.xcodeproj/                 # two targets: "armfin" (thin container,
    │                                      # no source — see §1.1) and
    │                                      # "armfin Watch App" (the real app)
    └── armfin Watch App/                 # ALL real source lives here. Xcode 16's
        │                                 # file-system-synchronized group: any file
        │                                 # or folder placed in this directory is
        │                                 # picked up automatically — no manual
        │                                 # project.pbxproj editing required.
        ├── ArmfinApp.swift
        ├── App/
        │   └── ArmfinAppDelegate.swift
        ├── Models/
        │   ├── ServerConfiguration.swift
        │   ├── CachedArtist.swift         # schema-only — see §1.4 note
        │   ├── CachedAlbum.swift          # schema-only
        │   ├── CachedTrack.swift          # schema-only
        │   └── DownloadTaskState.swift
        ├── Services/
        │   ├── JellyfinAPIClient.swift
        │   ├── KeychainStore.swift
        │   └── BackgroundDownloadCoordinator.swift
        ├── Playback/
        │   ├── PlaybackEngine.swift
        │   ├── NowPlayingManager.swift
        │   └── PlaybackEnvironment.swift  # EnvironmentKey definitions
        ├── ViewModels/
        │   ├── LoginViewModel.swift
        │   ├── BrowseViewModel.swift
        │   ├── AlbumListViewModel.swift
        │   ├── TrackListViewModel.swift
        │   ├── AllAlbumsViewModel.swift
        │   ├── AllTracksViewModel.swift
        │   └── NowPlayingViewModel.swift  # NowPlayingTrack struct
        ├── Views/
        │   ├── LoginView.swift            # pre-login hub (TabView pages)
        │   ├── HomeView.swift             # post-login hub (TabView pages)
        │   ├── ArtistListView.swift
        │   ├── AlbumListView.swift
        │   ├── TrackListView.swift
        │   ├── AllAlbumListView.swift     # library-wide album list
        │   ├── AllTrackListView.swift     # library-wide song list
        │   ├── NowPlayingView.swift
        │   ├── NothingPlayingView.swift   # empty Now Playing state
        │   ├── DownloadsView.swift
        │   ├── DownloadIndicator.swift    # bulk download/remove buttons
        │   └── JellyfinImage.swift        # reusable remote/local image view
        └── Assets.xcassets/
```

### 1.4 SwiftData Schema

The access token is **never** stored in SwiftData (see §2.5 — Keychain only). Everything else the app needs to render UI offline lives here.

> **Implementation note:** `CachedArtist`, `CachedAlbum`, and `CachedTrack` are registered in the `ModelContainer` and define the schema + relationships for a future offline library cache, but are **not currently populated** during browsing. All library lists currently use in-memory API DTOs returned by `JellyfinAPIClient`. The only actively written models are `ServerConfiguration` and `DownloadTaskState`.

```swift
import SwiftData
import Foundation

@Model
final class ServerConfiguration {
    @Attribute(.unique) var id: UUID
    var serverURL: String
    var userId: String
    var username: String
    var serverName: String
    var lastLoginDate: Date
    var lastValidatedDate: Date?

    init(id: UUID = UUID(), serverURL: String, userId: String, username: String,
         serverName: String, lastLoginDate: Date = .now) {
        self.id = id
        self.serverURL = serverURL
        self.userId = userId
        self.username = username
        self.serverName = serverName
        self.lastLoginDate = lastLoginDate
    }
}

@Model
final class CachedArtist {
    @Attribute(.unique) var id: String   // Jellyfin item GUID
    var name: String
    var sortName: String
    var imageTag: String?
    var lastRefreshed: Date

    @Relationship(deleteRule: .cascade, inverse: \CachedAlbum.artist)
    var albums: [CachedAlbum] = []

    init(id: String, name: String, sortName: String, imageTag: String? = nil, lastRefreshed: Date = .now) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.imageTag = imageTag
        self.lastRefreshed = lastRefreshed
    }
}

@Model
final class CachedAlbum {
    @Attribute(.unique) var id: String
    var name: String
    var sortName: String
    var productionYear: Int?
    var imageTag: String?
    var lastRefreshed: Date
    var artist: CachedArtist?

    @Relationship(deleteRule: .cascade, inverse: \CachedTrack.album)
    var tracks: [CachedTrack] = []

    init(id: String, name: String, sortName: String, productionYear: Int? = nil,
         imageTag: String? = nil, lastRefreshed: Date = .now) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.productionYear = productionYear
        self.imageTag = imageTag
        self.lastRefreshed = lastRefreshed
    }
}

@Model
final class CachedTrack {
    @Attribute(.unique) var id: String
    var name: String
    var indexNumber: Int?
    var discNumber: Int?
    var durationTicks: Int64        // Jellyfin ticks: 10,000,000 ticks/sec
    var container: String?
    var codec: String?
    var bitrate: Int?
    var lastPlayedDate: Date?       // drives future LRU eviction, see §5.1
    var lastRefreshed: Date
    var album: CachedAlbum?

    @Relationship(deleteRule: .cascade, inverse: \DownloadTaskState.track)
    var downloadState: DownloadTaskState?

    var runtimeSeconds: Double { Double(durationTicks) / 10_000_000 }

    init(id: String, name: String, indexNumber: Int? = nil, discNumber: Int? = nil,
         durationTicks: Int64, container: String? = nil, codec: String? = nil,
         bitrate: Int? = nil, lastRefreshed: Date = .now) {
        self.id = id
        self.name = name
        self.indexNumber = indexNumber
        self.discNumber = discNumber
        self.durationTicks = durationTicks
        self.container = container
        self.codec = codec
        self.bitrate = bitrate
        self.lastRefreshed = lastRefreshed
    }
}

enum DownloadStatus: String, Codable {
    case notDownloaded, queued, downloading, paused, completed, failed
}

@Model
final class DownloadTaskState {
    @Attribute(.unique) var id: UUID
    var trackId: String
    var status: DownloadStatus
    var totalBytes: Int64
    var downloadedBytes: Int64
    var localFilePath: String?      // relative path inside Application Support/Downloads
    var createdDate: Date
    var completedDate: Date?
    var retryCount: Int
    var lastError: String?
    var track: CachedTrack?

    // Denormalized metadata — allows offline UI rendering without
    // needing the CachedTrack/CachedAlbum/CachedArtist graph populated.
    var trackName: String?
    var artistName: String?
    var albumName: String?
    var albumId: String?
    var durationTicks: Int64

    var durationSeconds: Double { Double(durationTicks) / 10_000_000 }

    init(id: UUID = UUID(), trackId: String, status: DownloadStatus = .notDownloaded,
         totalBytes: Int64 = 0, downloadedBytes: Int64 = 0, createdDate: Date = .now,
         retryCount: Int = 0, trackName: String? = nil, artistName: String? = nil,
         albumName: String? = nil, albumId: String? = nil, durationTicks: Int64 = 0) {
        self.id = id
        self.trackId = trackId
        self.status = status
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.createdDate = createdDate
        self.retryCount = retryCount
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.albumId = albumId
        self.durationTicks = durationTicks
    }
}
```

### 1.5 Networking Stack

Two deliberately separate `URLSession` stacks — they cannot be merged because background sessions disallow completion-handler convenience APIs and cannot be ephemeral, while the foreground client wants async/await ergonomics and per-request cancellation:

1. **Foreground JSON API client** (`JellyfinAPIClient`) — `URLSession(configuration: .default)`, used for `AuthenticateByName`, `/Items` browsing calls, and image fetches via `async/await` `data(for:)`. Owns header construction (`X-Emby-Authorization`, `X-Emby-Token`) and JSON decoding.
2. **Background download session** (`BackgroundDownloadCoordinator`) — `URLSessionConfiguration.background(withIdentifier: "com.armfin.background-downloads")`, `isDiscretionary = false`, `sessionSendsLaunchEvents = true`, delegate-based (`URLSessionDownloadDelegate`, no async/await). A single instance is created **eagerly at app launch** (not lazily on first download) so the delegate is always registered before the system tries to deliver events to a relaunched process.

---

## 2. Jellyfin API Integration & Authentication Flow

### 2.1 Endpoint Reference

| Purpose | Method | Path | Key params |
|---|---|---|---|
| Pre-auth server validation | GET | `/System/Info/Public` | none (validates URL/reachability before showing the login form's password field) |
| Authenticate | POST | `/Users/AuthenticateByName` | body: `Username`, `Pw` |
| Music library discovery | GET | `/Users/{UserId}/Views` | filter response client-side for `CollectionType == "music"` |
| Artists | GET | `/Items` | `IncludeItemTypes=MusicArtist`, `Recursive=true`, `ParentId=<musicLibraryId>`, `SortBy=SortName`, `userId=<userId>` |
| Albums for artist | GET | `/Items` | `IncludeItemTypes=MusicAlbum`, `ArtistIds=<artistId>`, `Recursive=true`, `SortBy=ProductionYear,SortName` |
| Tracks for album | GET | `/Items` | `ParentId=<albumId>`, `IncludeItemTypes=Audio`, `SortBy=ParentIndexNumber,IndexNumber` |
| Direct-play stream | GET | `/Audio/{Id}/stream` | `static=true`, `api_key=<token>` |
| Adaptive/transcoded stream | GET | `/Audio/{Id}/universal` | `audioCodec`, `maxStreamingBitrate`, `container`, `transcodingContainer`, `api_key` |
| Background download | GET | `/Audio/{Id}/stream` | same as direct-play, fetched via `URLSessionDownloadTask` instead of played in place |
| Artwork | GET | `/Items/{Id}/Images/Primary` | `tag=<imageTag>`, `maxWidth=<px>` (size appropriately for watch screen — request at 1x/2x display points, never full-resolution server art) |

### 2.2 Authentication Flow

Every request carries:
```
X-Emby-Authorization: MediaBrowser Client="armfin", Device="Apple Watch", DeviceId="<persisted-UUID>", Version="<app version>"
```

Request:
```json
POST /Users/AuthenticateByName
{
  "Username": "exampleUser",
  "Pw": "user-entered-password"
}
```

Response:
```json
{
  "User": {
    "Id": "8c7c6d2f1e3a4b8d9f0a1b2c3d4e5f60",
    "Name": "exampleUser",
    "ServerId": "f1e2d3c4b5a6"
  },
  "AccessToken": "a1b2c3d4e5f6...",
  "ServerId": "f1e2d3c4b5a6"
}
```

After authentication, append `, Token="<AccessToken>"` to the `X-Emby-Authorization` header (or send a separate `X-Emby-Token` header — both forms are accepted by Jellyfin) on every subsequent call.

### 2.3 Library Browsing Flow

`Items` listing shape (used identically for artists/albums/tracks, only `IncludeItemTypes`/`ParentId`/`ArtistIds` change):
```json
{
  "Items": [
    {
      "Id": "8f2a...",
      "Name": "Abbey Road",
      "AlbumArtist": "The Beatles",
      "ProductionYear": 1969,
      "ImageTags": { "Primary": "abc123" },
      "Type": "MusicAlbum"
    }
  ],
  "TotalRecordCount": 47,
  "StartIndex": 0
}
```

All list fetches use `StartIndex`/`Limit`-based pagination with a page size of **50 items**. The API client returns a `PagedResult<T>` containing the decoded items, `totalRecordCount`, and `startIndex`. ViewModels accumulate pages incrementally via a `loadMore()` method, triggered by a sentinel `ProgressView` row at the bottom of each `List` that fires `onAppear` when scrolled into view.

Edge cases handled:
- `loadMore()` is guarded by `!isLoadingMore && hasMore` to prevent duplicate concurrent fetches.
- If a load-more request fails, existing items remain visible and the user can retry by scrolling again.
- `hasMore` compares `items.count < totalRecordCount` using the server's authoritative count.
- Shuffle actions operate on the currently loaded items — a user with thousands of songs can shuffle the loaded subset without needing to fetch the entire library first.

### 2.4 Streaming & Download URLs
- **Streaming (playback while connected):** prefer `/Audio/{Id}/universal` so the server can transcode if the watch's decode path or network conditions require it; pass `audioCodec=aac` and `maxStreamingBitrate=192000` (currently fixed at 192 kbps AAC). Future: expose user-configurable quality setting (e.g. 128/256/320 kbps) in `SettingsView`.
- **Downloading (for offline storage):** request `/Audio/{Id}/stream?static=true`, forcing a direct byte-for-byte copy of the original file rather than a transcode — this guarantees the stored file matches the source codec/container metadata and avoids re-encoding loss.

### 2.5 Credential Storage (Keychain)

Store `serverURL`, `userId`, and `accessToken` together as one Keychain item per configured server:
- `kSecClass`: `kSecClassGenericPassword`
- `kSecAttrAccessible`: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — survives device restarts without requiring biometric/passcode prompt on every playback action, never escapes the device.
- `kSecAttrSynchronizable`: explicitly `false` — never syncs via iCloud Keychain. There's no companion device to share it with, and this is a security-sensitive personal-server credential.

`ServerConfiguration` (SwiftData) holds everything else (server URL display name, username, last login date) so the UI can render "logged in as X on server Y" without touching the Keychain; only `KeychainStore` touches the actual token.

### 2.6 Login UI & Keyboard Handoff

`LoginView` uses a plain SwiftUI `TextField` (server URL), `TextField` (username), and `SecureField` (password) bound to `@State`/`@Bindable` view-model properties, with `.textInputAutocapitalization(.never)` and autocorrection disabled on the URL field only.

watchOS presents its own text input chooser (scribble, dictation, emoji, or wrist-to-iPhone keyboard handoff) automatically when a `TextField` becomes focused — **no extra code is required or possible** to request handoff specifically. The implementation must not assume handoff is available (it requires a reachable paired iPhone) and must not impose a timeout on text entry, since handoff round-trips through the paired phone and can take longer than on-device scribble. If validation against `/System/Info/Public` fails after the server URL is entered, show an inline error ("Can't reach this server") before letting the user proceed to credentials, rather than failing only after a full auth attempt.

---

## 3. Audio Playback & Sync Engine Specification

### 3.1 Playback State Machine

```swift
enum PlaybackState: Equatable {
    case idle
    case loadingItem(trackId: String)
    case readyToPlay
    case playing
    case paused
    case buffering
    case finishedTrack
    case failed(message: String)
}
```

Transitions are driven by observing `AVPlayerItem` status/`AVPlayer.timeControlStatus` (via KVO bridged to `AsyncSequence`, e.g. `player.publisher(for: \.timeControlStatus)`) plus `NotificationCenter` for `.AVPlayerItemDidPlayToEndTime` (→ `.finishedTrack`, then auto-advance) and `.AVPlayerItemFailedToPlayToEndTime` (→ `.failed`).

### 3.2 Local-vs-Streaming URL Resolution

Resolved **every time a track is about to play**, never cached statically, so a download completing or a file going missing is picked up immediately. `PlaybackEngine` queries `DownloadTaskState` by track ID:

```swift
func resolvedPlaybackURL(for trackId: String, context: ModelContext) -> URL {
    let predicate = #Predicate<DownloadTaskState> { $0.trackId == trackId && $0.status == .completed }
    if let state = try? context.fetch(FetchDescriptor(predicate: predicate)).first,
       let path = state.localFilePath {
        let fileURL = downloadsDirectory.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        // Completed in SwiftData but the file is gone — repair state and fall back to streaming.
        state.status = .notDownloaded
        state.localFilePath = nil
        try? context.save()
    }
    return JellyfinAPIClient.streamingURL(forTrackId: trackId, serverURL: serverURL, token: accessToken)
}
```

### 3.3 Background Download Pipeline

```swift
final class BackgroundDownloadCoordinator: NSObject {
    static let shared = BackgroundDownloadCoordinator()
    static let sessionIdentifier = "com.armfin.background-downloads"

    private var modelContext: ModelContext?
    private let maxConcurrent = 2

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func setModelContext(_ context: ModelContext) { modelContext = context }
    func attachIfNeeded() { _ = session }
    func reattach(sessionIdentifier: String) {
        guard sessionIdentifier == Self.sessionIdentifier else { return }
        _ = session
    }

    func enqueueDownload(for trackId: String, url: URL, metadata: TrackMetadata) {
        // Creates DownloadTaskState row, respects maxConcurrent limit,
        // queues excess downloads for FIFO dispatch as slots free up.
        let task = session.downloadTask(with: url)
        task.taskDescription = trackId
        task.resume()
    }
}
```

The coordinator also provides bulk helpers (`downloadAllTracks(for artist:)`, `downloadAlbum(...)`) that enumerate child tracks and enqueue each one. Progress is throttled to at most one SwiftData write per second per task. Album artwork is downloaded separately and cached to `Application Support/Downloads/Artwork/{albumId}.jpg`.

The background `URLSession` keeps transferring at the OS level even while the app is suspended. When the system relaunches the process to deliver events, `ArmfinAppDelegate.handle(_:)` (§1.1) reattaches the delegate via the *same* session identifier — reusing an identifier is what lets the system match the relaunch to the in-flight transfer.

### 3.4 Audio Session & Now Playing Integration

```swift
func configureAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [.allowBluetoothA2DP])
    try session.setActive(true)
}
```
`.allowBluetoothA2DP` (not the HFP-oriented `.allowBluetooth`) is the correct option for high-quality stereo workout headphones. `.longFormAudio` route-sharing policy matches a music player rather than a voice app.

Interruptions (phone calls relayed to the watch, other audio, a concurrent workout's audio cues):
```swift
NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
    guard let info = note.userInfo,
          let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
    switch type {
    case .began:
        PlaybackEngine.shared.pauseForInterruption()
    case .ended:
        if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt,
           AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
            PlaybackEngine.shared.resumeIfWasPlaying()
        }
    @unknown default: break
    }
}
```

Now Playing / remote commands:
```swift
func updateNowPlayingInfo(for track: NowPlayingTrack) {
    var info: [String: Any] = [
        MPMediaItemPropertyTitle: track.title,
        MPMediaItemPropertyArtist: track.artistName ?? "",
        MPMediaItemPropertyAlbumTitle: track.albumName ?? "",
        MPMediaItemPropertyPlaybackDuration: track.durationSeconds,
        MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
        MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
    ]
    // Future: add MPMediaItemPropertyArtwork once artwork caching
    // is integrated with NowPlayingManager.
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
}

func registerRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.addTarget { _ in self.play(); return .success }
    center.pauseCommand.addTarget { _ in self.pause(); return .success }
    center.togglePlayPauseCommand.addTarget { _ in self.togglePlayPause(); return .success }
    center.nextTrackCommand.addTarget { _ in self.advanceToNext(); return .success }
    center.previousTrackCommand.addTarget { _ in self.returnToPrevious(); return .success }
    center.changePlaybackPositionCommand.addTarget { event in
        guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
        self.seek(to: event.positionTime)
        return .success
    }
}
```

`NowPlayingManager` publishes an observable `nowPlayingSnapshot` (updated via a 1Hz periodic time observer) and `currentTrack: NowPlayingTrack?` for the UI to bind against.

**Platform constraint — no in-app route picker:** unlike iOS/tvOS, watchOS exposes no public `AVRoutePickerView`/`MPVolumeView` equivalent. Bluetooth/AirPlay output selection is owned entirely by system UI (Control Center swipe-up). `NowPlayingView` therefore does **not** implement a custom route button.

---

## 4. UI/UX Map & Navigation Hierarchy

### 4.1 View Hierarchy & Navigation Model

The app uses a **horizontal paged `TabView`** (`.tabViewStyle(.page)`) as the primary navigation container, with `NavigationStack`/`NavigationLink` drill-downs within individual pages. There are two hub views — `LoginView` (pre-auth) and `HomeView` (post-auth) — each presenting the same three-page layout:

| Page (swipe position) | Purpose |
|---|---|
| Left | **Now Playing** — full player UI or empty state with shuffle CTA |
| Center | **Library/Landing** — browse tabs (post-login) or sign-in form (pre-login) |
| Right | **Downloads** — offline content browser with playback |

`LoginView` wraps a `NavigationStack` and uses `.navigationDestination(item:)` to push `HomeView` when login succeeds or a session is restored from Keychain. `HomeView` hides the back button to prevent accidental return to the login form.

```swift
// LoginView structure (simplified)
NavigationStack {
    TabView(selection: $selectedPage) {
        nowPlayingPage.tag(LoginTab.nowPlaying)
        landingPage.tag(LoginTab.landing)
        downloadsPage.tag(LoginTab.downloads)
    }
    .tabViewStyle(.page(indexDisplayMode: .automatic))
    .navigationDestination(item: signedInSessionBinding) { session in
        HomeView(serverURL: ..., userId: ..., accessToken: ..., onSignOut: ...)
    }
}

// HomeView structure (simplified)
TabView(selection: $selectedPage) {
    nowPlayingPage.tag(HomeTab.nowPlaying)
    libraryPage.tag(HomeTab.library)
    downloadsPage.tag(HomeTab.downloads)
}
.tabViewStyle(.page(indexDisplayMode: .automatic))
.navigationBarBackButtonHidden(true)
```

Within the library page, three sub-tabs (Artists / Albums / Songs) are presented via a `Picker` with `.pickerStyle(.segmented)`. Each sub-tab navigates deeper via `NavigationLink`:
- **Artists** → `ArtistListView` → `AlbumListView` → `TrackListView`
- **Albums** → `AllAlbumListView` → `TrackListView`
- **Songs** → `AllTrackListView`

Tapping a track starts playback and programmatically switches the `TabView` selection to the Now Playing page via an environment closure (`\.showNowPlaying`).

### 4.2 Per-View Specification

| View | Key elements | Loading / empty / error states |
|---|---|---|
| `LoginView` | 3-page TabView hub. Center: server URL field, username field, secure password field, "Sign In" button. Auto-restores session from Keychain on appear. Left: Now Playing (offline shuffle if downloads exist). Right: Downloads. | Loading: spinner during `/System/Info/Public` validation and during auth. Error: inline "Can't reach this server" vs. "Incorrect username or password", distinguished by which call failed. |
| `HomeView` | 3-page TabView hub. Center: segmented picker (Artists/Albums/Songs) with `NavigationLink` rows. Sign Out in toolbar. Shuffle Play button. Left: Now Playing. Right: Downloads. | Empty: shown before library loads. Error: inline error in browse content area. |
| `ArtistListView` | `List` of artist rows with artwork thumbnails via `JellyfinImage`. Per-artist bulk download button (`ContainerDownloadButton`). Navigates to `AlbumListView`. | Loading: `ProgressView`. Empty: "No artists found". |
| `AlbumListView` | Albums for one artist. Shuffle All across albums. Per-album bulk download. Navigates to `TrackListView`. | Loading: `ProgressView`. Empty: "No albums found". |
| `TrackListView` | Tracks for one album. Tap to play (builds queue from album). Per-track download/remove. Shuffle All. Orphan detection on refresh. | Loading: `ProgressView`. Empty: "No tracks found". |
| `AllAlbumListView` | Library-wide flat album list (limit 200). Same navigation/download patterns as artist-scoped. | Loading: `ProgressView`. Empty: "No albums found". |
| `AllTrackListView` | Library-wide song list (limit 200). Play + download per row. Shuffle All. | Loading: `ProgressView`. Empty: "No songs found". |
| `NowPlayingView` | Full-screen player: artwork (local cache or remote `AsyncImage`), title/artist, prev/play-pause/next transport controls, download toggle, shuffle toggle, error display. | Buffering: spinner on artwork. Failed: inline error banner with message. |
| `NothingPlayingView` | Empty Now Playing state. "Shuffle Play" CTA if online, "Shuffle Downloads" if offline content exists. | — |
| `DownloadsView` | Downloads browser with segmented picker: Artists / Albums / Songs (grouped by denormalized metadata). Active download progress display. Offline playback from completed downloads. Shuffle at each level. Nested drill-downs to `DownloadedAlbumsForArtistView` / `DownloadedTracksForAlbumView`. | Empty: "No downloads yet". |
| `DownloadIndicator` | Reusable `ContainerDownloadButton` component for bulk download/remove on artist and album rows. Computes aggregate `ContainerDownloadState` across child tracks. | — |
| `JellyfinImage` | Reusable image component: loads from local disk (cached artwork), remote `AsyncImage` (server), or SF Symbol placeholder fallback. | — |

### 4.3 Design System Rules

- Pure black (`#000000`) background everywhere: `.background(.black)` on root containers plus `.scrollContentBackground(.hidden)` on every `List`/`ScrollView` to remove the default System Material fill.
- Minimum interactive touch target: **50–60pt** (above Apple HIG's 44pt floor) on all primary controls (play/pause/skip/download-toggle), accounting for sweaty fingers and motion during runs.
- Dynamic Type supported; control rows that would clip use layout adaptation at the largest sizes rather than truncating.

### 4.4 Future UI (Not Yet Implemented)

The following views/features are planned but not yet built:

| Feature | Notes |
|---|---|
| `SettingsView` | Streaming quality picker, "Allow Cellular Downloads" toggle, "Auto-manage storage" toggle, clear-cache action |
| Search | Full-text search across the Jellyfin library |
| Scrubber/seek bar | Visible progress bar in `NowPlayingView` (seek works via system remote commands) |
| Now Playing artwork in system UI | `MPMediaItemPropertyArtwork` in `MPNowPlayingInfoCenter` |

---

## 5. Data Management & Offline Rules

### 5.1 Cache Eviction Policy

> **Status: Planned — not yet implemented.** The `lastPlayedDate` field exists on `CachedTrack` but eviction logic is not wired up. The storage thresholds described below are the target design.

Two independent tiers, evicted differently:

- **Metadata cache** (`CachedArtist`/`CachedAlbum`/`CachedTrack` rows without an attached completed download) — cheap text, not subject to storage-pressure eviction. Pruned only on an explicit "Clear Cache" action in a future `SettingsView`, or automatically after a 30-day staleness window for any item not part of a downloaded album.
- **Downloaded audio files** (`DownloadTaskState.status == .completed`) — the actual storage cost. Storage-pressure thresholds, checked before every new download enqueue and on a periodic background check:
  - **< 1 GB free:** show a non-blocking "Storage running low" warning in `DownloadsView`.
  - **< 500 MB free:** hard-block new downloads until space is freed (existing downloads/playback are unaffected).
  - If the user enables **"Auto-manage storage"** (future `SettingsView` toggle, default off): when free space drops below 1 GB, evict completed downloads in **least-recently-played order** (`CachedTrack.lastPlayedDate`, nulls — i.e. never played since download — evicted first) until free space exceeds 750 MB. Eviction deletes the local file and resets `DownloadTaskState` to `.notDownloaded`; playback transparently falls back to streaming per §3.2.

### 5.2 Sync & Download Rules

**Currently implemented:**
- **Concurrency:** max **2** concurrent `URLSessionDownloadTask`s to avoid saturating the watch's radio and battery; additional queued downloads run sequentially as slots free up (FIFO).
- **File storage:** audio at `Application Support/Downloads/{trackId}.{ext}`, album artwork cached at `Application Support/Downloads/Artwork/{albumId}.jpg`.
- **Bulk downloads:** per-artist and per-album bulk download helpers in `BackgroundDownloadCoordinator`.
- **Progress throttling:** download progress persisted to SwiftData at most once per second per task to avoid write thrash.
- **Server-side deletion / orphan handling:** on album track refresh, diff the set of locally-`.completed` track IDs against the latest `/Items` response; a track missing from the server response is marked `.failed` with `lastError = "No longer available on server"` and surfaced in `DownloadsView` for removal.

**Planned (not yet implemented):**
- **Cellular downloads toggle:** default **off** (Wi-Fi only), toggled in a future `SettingsView`. Before enqueueing, check `NWPathMonitor.currentPath.usesInterfaceType(.wifi)`; if cellular-only and the toggle is off, leave the task in `.queued` and resume automatically once a Wi-Fi path is observed.
- **Pause/resume:** `DownloadStatus.paused` exists in the enum but no pause UI or retry logic is wired up yet.
- **Storage pressure checks:** thresholds defined above but not yet enforced before enqueue.
