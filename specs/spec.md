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
    @State private var networkStatusService = NetworkStatusService()
    private let modelContainer: ModelContainer

    // `true` when the store was wiped during init (schema mismatch / corruption).
    // Drives a one-time "data was reset — sign in again" alert in RootView.
    @State private var didResetCorruptData = false

    init() {
        // Gate the schema BEFORE the container is built: if the on-disk
        // `.armfin_schema_version` marker doesn't match `currentSchemaVersion`,
        // wipe all local data (DB, downloads, artwork, keychain) first, so we
        // never hand a stale store to ModelContainer.
        let wasReset = Self.migrateOrNukeIfNeeded()

        let schema = Schema([
            ServerConfiguration.self, CachedArtist.self, CachedAlbum.self,
            CachedTrack.self, BetaDownloadItem.self
        ])
        modelContainer = Self.createContainer(schema: schema)
        _didResetCorruptData = State(wrappedValue: wasReset)

        let engine = PlaybackEngine()
        engine.setModelContext(container.mainContext)
        _playbackEngine = State(wrappedValue: engine)
        _nowPlayingManager = State(wrappedValue: NowPlayingManager(playbackEngine: engine))
        BetaDownloadManager.shared.configure(modelContext: container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            RootView(didResetCorruptData: $didResetCorruptData)
                .environment(\.playbackEngine, playbackEngine)
                .environment(\.nowPlayingManager, nowPlayingManager)
                .environment(\.networkStatusService, networkStatusService)
        }
        .modelContainer(modelContainer)
    }
}

final class ArmfinAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        BetaDownloadManager.shared.attachIfNeeded()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let urlSessionTask as WKURLSessionRefreshBackgroundTask:
                let id = urlSessionTask.sessionIdentifier
                if id == BetaDownloadManager.sessionIdentifier {
                    BetaDownloadManager.shared.reattach(sessionIdentifier: id)
                }
                urlSessionTask.setTaskCompletedWithSnapshot(false)
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
```

Key architectural choices in the app entry point:
- **Schema-versioned store, nuke-on-mismatch.** `currentSchemaVersion` (`ArmfinApp.swift`) is written to a marker file in Application Support. On launch, `migrateOrNukeIfNeeded()` compares it to the stored value and, on any mismatch (or a missing marker while a store exists), wipes all local data — the SwiftData files, downloaded audio, cached artwork, and Keychain credentials — *before* `ModelContainer` is constructed, then falls back to an in-memory store if re-creation still fails. This trades in-place migration (risky on-device) for a guaranteed-clean store; the trade is that such an upgrade discards downloads and forces re-login.
- A single `ModelContainer` is constructed from a `Schema` and shared with `PlaybackEngine` and `BetaDownloadManager` so all three write to the same SwiftData store.
- `PlaybackEngine`, `NowPlayingManager`, and `NetworkStatusService` are held as `@State`/`@Observable` for stable lifetime and injected into the view hierarchy via environment keys (classic `EnvironmentKey` structs, defined in `Playback/PlaybackEnvironment.swift`).
- The root view is `RootView`, a single permanent 4-tab shell (see §4.1) — there is no separate login screen to push onto.

### 1.2 Architecture Pattern: MVVM

**MVVM**, not Clean Architecture. Justification: this is a single-target app with one persistence layer; SwiftData's `@Model`/`ModelContext` already gives a repository-like boundary, so an additional use-case/interactor layer adds ceremony with no payoff on a battery- and memory-constrained device. MVVM also pairs directly with SwiftUI's `@Observable`/`@Bindable`, keeping the dependency graph shallow.

Layering: **Views** (SwiftUI) → **ViewModels** (`@Observable` classes, one per screen) → **Services** (`JellyfinAPIClient`, `BetaDownloadManager`, `PlaybackEngine`, `NetworkStatusService`, `KeychainStore`) → **SwiftData** (`ModelContainer`/`ModelContext`) + **URLSession**.

### 1.3 Source Tree Layout

Reflects the actual on-disk structure — the `.xcodeproj` and its source folder live one level below the repository root, inside a project directory that shares the app's name:

```
armfin/                                   # repository root
├── CLAUDE.md
├── .gitignore
├── .claude/                              # SDMA loop: agents/, memory.md, rules/soul.md
├── docs/                                 # static site (index.html, privacy-policy.html)
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
        ├── ArmfinApp.swift               # @main, schema-version gate, container
        ├── Info.plist
        ├── PrivacyInfo.xcprivacy
        ├── App/
        │   └── ArmfinAppDelegate.swift   # WKApplicationDelegate: session reattach
        ├── Models/                       # SwiftData @Model types
        │   ├── ServerConfiguration.swift # actively written (session)
        │   ├── CachedArtist.swift        # schema-only — see §1.4 note
        │   ├── CachedAlbum.swift         # schema-only
        │   ├── CachedTrack.swift         # schema-only
        ├── Services/
        │   ├── JellyfinAPIClient.swift   # foreground JSON API + URL builders
        │   ├── KeychainStore.swift       # access token only
        │   └── NetworkStatusService.swift# reactive offline state + per-tab failure memory
        ├── Playback/
        │   ├── PlaybackEngine.swift      # AVPlayer queue engine, local-vs-stream resolution
        │   ├── NowPlayingManager.swift   # MPNowPlayingInfoCenter + remote commands
        │   └── PlaybackEnvironment.swift # EnvironmentKey definitions
        ├── BetaDownload/                 # the whole offline-download system
        │   ├── BetaDownloadItem.swift    # @Model download row + sort/group helpers
        │   ├── BetaDownloadManager.swift # background URLSession, queue, delegate
        │   ├── DownloadedPlayback.swift  # single entry point for playing downloads
        │   ├── BetaDownloadsView.swift   # Downloads tab (4 sub-tabs)
        │   ├── DownloadedArtistView.swift
        │   ├── DownloadedAlbumView.swift
        │   ├── DownloadedGenreView.swift
        │   ├── DownloadsRoute.swift      # value-based navigation routes
        │   ├── DownloadItemReader.swift  # fetch a download row by id
        │   ├── BetaDownloadButton.swift  # per-track download/remove + progress ring
        │   ├── BetaAlbumDownloadButton.swift # per-album bulk download/remove
        │   ├── DownloadedArtwork.swift   # resolve a cached/remote album artwork URL
        │   └── DownloadsComponents.swift # shuffle-all rows, misc components
        ├── ViewModels/
        │   ├── LoginViewModel.swift      # sign-in, server validation, Quick Connect
        │   ├── BrowseViewModel.swift
        │   ├── AlbumListViewModel.swift
        │   ├── TrackListViewModel.swift
        │   ├── AllAlbumsViewModel.swift
        │   ├── AllTracksViewModel.swift
        │   └── NowPlayingViewModel.swift # NowPlayingTrack struct
        └── Views/
            ├── RootView.swift            # permanent 4-tab shell (the app's root)
            ├── SignInView.swift          # signed-out content of the Library tab
            ├── OfflineGate.swift         # shared offline-detection ViewModifier
            ├── SettingsView.swift        # Sign Out / Remove All Downloads / Factory Reset
            ├── ArtistListView.swift
            ├── AlbumListView.swift
            ├── TrackListView.swift
            ├── AllAlbumListView.swift    # library-wide album list
            ├── AllTrackListView.swift    # library-wide song list
            ├── NowPlayingView.swift
            ├── NowPlayingBackdrop.swift
            ├── NothingPlayingView.swift  # empty Now Playing state
            ├── VolumeControl.swift
            ├── PaginationFooter.swift    # sentinel "load more" row
            └── JellyfinImage.swift       # reusable remote/local image view
```

### 1.4 SwiftData Schema

The access token is **never** stored in SwiftData (see §2.5 — Keychain only). Everything else the app needs to render UI offline lives here.

> **Implementation note:** `CachedArtist`, `CachedAlbum`, and `CachedTrack` are registered in the `Schema` and define the schema + relationships for a future offline library cache, but are **not currently populated** during browsing. All library lists currently use in-memory API DTOs returned by `JellyfinAPIClient`. The only actively written models are `ServerConfiguration` and `BetaDownloadItem`.

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
    @Attribute(.unique) var id: String   // Jellyfin item GUID
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

enum BetaDownloadStatus: String, Codable, Sendable {
    case queued, downloading, completed, failed
}

@Model
final class BetaDownloadItem {
    @Attribute(.unique) var id: UUID
    var jellyfinId: String          // Jellyfin item GUID, keys the on-disk file
    var trackName: String
    var artistName: String
    var albumName: String
    var albumId: String
    var genreName: String           // first Jellyfin genre tag, if any ("" = uncaptured/unknown)
    var indexNumber: Int?           // Jellyfin IndexNumber — in-album track position
    var discNumber: Int?            // Jellyfin ParentIndexNumber — which disc

    // Status is persisted as a plain String to avoid SwiftData Codable-enum
    // traps on ARM64_32; the @Transient accessor keeps call sites clean.
    var statusRaw: String
    var totalBytes: Int64           // retained, no longer written during transfer
    var downloadedBytes: Int64      // retained, no longer written during transfer
    var localFileName: String?      // file name inside Downloads/Beta/
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

    init(id: UUID = UUID(), jellyfinId: String, trackName: String, artistName: String,
         albumName: String, albumId: String, indexNumber: Int? = nil, discNumber: Int? = nil,
         status: BetaDownloadStatus = .queued, totalBytes: Int64 = 0, downloadedBytes: Int64 = 0,
         localFileName: String? = nil, createdDate: Date = .now, completedDate: Date? = nil,
         lastError: String? = nil, durationTicks: Int64 = 0, genreName: String = "") {
        self.id = id
        self.jellyfinId = jellyfinId
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.albumId = albumId
        self.genreName = genreName
        self.indexNumber = indexNumber
        self.discNumber = discNumber
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
```

Notes on the download model:
- `BetaDownloadItem` is **standalone** — it carries denormalized `trackName`/`artistName`/`albumName`/`albumId`/`genreName` so the Downloads tab and offline playback work with no `Cached*` rows populated. It has no relationship to `CachedTrack`. `genreName` is the first of a track's Jellyfin genre tags (best-effort, not a full multi-genre model), captured at download time from whichever screen the download started on.
- **Live progress is not stored here.** Byte counts move to `BetaDownloadManager.progressByTrackId` (in memory) because a SwiftData save per download per second invalidated every `@Query` in the app. Only `statusRaw` is durable. See §3.3.
- Sorting/grouping helpers (`sortedInAlbumOrder`, `sortedByTitle`, `sortedInArtistOrder`, `groupedIntoAlbums`) live as an `Array where Element == BetaDownloadItem` extension and drive the Downloads tab and "Play All" queue order.

### 1.5 Networking Stack

Two deliberately separate `URLSession` stacks — they cannot be merged because background sessions disallow completion-handler convenience APIs and cannot be ephemeral, while the foreground client wants async/await ergonomics and per-request cancellation:

1. **Foreground JSON API client** (`JellyfinAPIClient`) — `URLSession(configuration: .default)`, a `Sendable` struct with a `shared` instance for views that fetch and static URL builders for views that only build URLs. Used for server validation, auth, Quick Connect, `/Items`-family browsing, and static URL construction (stream, download, image). Owns header construction (`X-Emby-Authorization`) and JSON decoding.
2. **Background download session** (`BetaDownloadManager`) — `URLSessionConfiguration.background(withIdentifier: "com.armfin.beta-downloads")`, `isDiscretionary = false`, `sessionSendsLaunchEvents = true`, `waitsForConnectivity = true`, delegate-based (`URLSessionDownloadDelegate`, no async/await). A single instance is created **eagerly at app launch** (not lazily on first download) so the delegate is always registered before the system tries to deliver events to a relaunched process.

---

## 2. Jellyfin API Integration & Authentication Flow

### 2.1 Endpoint Reference

| Purpose | Method | Path | Key params |
|---|---|---|---|
| Pre-auth server validation | GET | `/System/Info/Public` | none (validates URL/reachability before showing credentials) |
| Authenticate | POST | `/Users/AuthenticateByName` | body: `Username`, `Pw` |
| Music library discovery | GET | `/Users/{UserId}/Views` | filter response client-side for `CollectionType == "music"` |
| Artists | GET | `/Artists` | `ParentId=<musicLibraryId>`, `SortBy=SortName`, `SortOrder=Ascending`, `userId=<userId>`, `StartIndex`, `Limit` |
| Albums for artist | GET | `/Items` | `IncludeItemTypes=MusicAlbum`, `ArtistIds=<artistId>`, `Recursive=true`, `SortBy=ProductionYear,SortName`, `userId`, `StartIndex`, `Limit` |
| Tracks for album | GET | `/Items` | `ParentId=<albumId>`, `IncludeItemTypes=Audio`, `Recursive=true`, `SortBy=ParentIndexNumber,IndexNumber`, `userId`, `StartIndex`, `Limit` |
| Library-wide albums | GET | `/Items` | `IncludeItemTypes=MusicAlbum`, `Recursive=true`, `ParentId=<musicLibraryId>`, `SortBy=SortName`, `userId`, `StartIndex`, `Limit` (Albums tab) |
| Library-wide songs | GET | `/Items` | `IncludeItemTypes=Audio`, `Recursive=true`, `ParentId=<musicLibraryId>`, `SortBy=SortName`, `userId`, `StartIndex`, `Limit` (Songs tab) |
| Genres | GET | `/Genres` | `IncludeItemTypes=Audio`, `ParentId=<musicLibraryId>`, `Recursive=true`, `SortBy=SortName`, `SortOrder=Ascending`, `userId`, `StartIndex`, `Limit` (Genres tab) |
| Songs for genre | GET | `/Items` | `IncludeItemTypes=Audio`, `GenreIds=<genreId>`, `Recursive=true`, `ParentId=<musicLibraryId>`, `SortBy=SortName`, `userId`, `StartIndex`, `Limit` (genre detail) |
| Streaming | GET | `/Audio/{Id}/universal` | `audioCodec/container/transcodingContainer=aac`, `maxStreamingBitrate=128000`, `audioBitRate=128000`, `maxAudioChannels=2`, `api_key`; add `static=true` for direct-play |
| Background download | GET | `/Audio/{Id}/stream.aac` | `audioCodec=aac`, `audioBitRate=128000`, `maxStreamingBitrate=128000`, `maxAudioChannels=2`, `static=false`, `api_key` — a transcode, not a direct copy |
| Artwork | GET | `/Items/{Id}/Images/Primary` | `maxWidth`, `maxHeight` (capped to rendered size, default 80), `quality=80`, `tag=<imageTag>` (size appropriately for the watch screen — request at 1x/2x display points, never full-resolution server art) |
| Quick Connect: initiate | POST | `/QuickConnect/Initiate` | none, no auth (401 if disabled server-side) |
| Quick Connect: poll | GET | `/QuickConnect/Connect` | `secret=<secret>` |
| Quick Connect: exchange | POST | `/Users/AuthenticateWithQuickConnect` | body: `Secret` |

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

After authentication, append `, Token="<AccessToken>"` to the `X-Emby-Authorization` header on every subsequent call.

### 2.3 Library Browsing Flow

`Items` listing shape (used identically for artists/albums/tracks; only `IncludeItemTypes`/`ParentId`/`ArtistIds` change):
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

The browse lists (artists / albums-for-artist / tracks-for-album) fetch with `StartIndex`/`Limit`-based pagination at a page size of **50 items**. The API client returns a `PagedResult<T>` containing the decoded items, `totalRecordCount`, and `startIndex`. ViewModels accumulate pages incrementally via a `loadMore()` method, triggered by the sentinel `PaginationFooter` row at the bottom of each `List` that fires `onAppear` when scrolled into view.

Edge cases handled:
- `loadMore()` is guarded by `!isLoadingMore && hasMore` to prevent duplicate concurrent fetches.
- If a load-more request fails, existing items remain visible and the user can retry by scrolling again.
- `hasMore` compares `items.count < totalRecordCount` using the server's authoritative count.
- Shuffle actions operate on the currently loaded items — a user with thousands of songs can shuffle the loaded subset without needing to fetch the entire library first.

### 2.4 Streaming & Download URLs
- **Streaming (playback while connected):** request `/Audio/{Id}/universal` with `audioCodec/container/transcodingContainer=aac`, `maxStreamingBitrate=128000`, `audioBitRate=128000`, `maxAudioChannels=2`. The ceiling is a fixed **128 kbps AAC**, chosen to match the download profile exactly so streamed and offline playback sound identical; AirPods and the watch speaker can't benefit from more. `preferDirectPlay` adds `static=true`. Future: expose a user-configurable quality setting in `SettingsView` (e.g. 128/192/256 kbps).
- **Downloading (for offline storage):** request `/Audio/{Id}/stream.aac` with `static=false`, forcing a server-side **transcode to 128 kbps AAC stereo**. This is deliberate, not a fallback: a transcoded response has a predictable, small size regardless of the source codec (FLAC, WAV, high-bitrate AAC), which is what lets the app estimate finished size and draw a progress ring (the response is chunked and carries no `Content-Length`). Files are saved as `{jellyfinId}.aac`.

### 2.5 Credential Storage (Keychain)

Store `serverURL`, `userId`, and `accessToken` together as one Keychain item per configured server:
- `kSecClass`: `kSecClassGenericPassword`
- `kSecAttrAccessible`: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — survives device restarts without requiring biometric/passcode prompt on every playback action, never escapes the device.
- `kSecAttrSynchronizable`: explicitly `false` — never syncs via iCloud Keychain. There's no companion device to share it with, and this is a security-sensitive personal-server credential.

`ServerConfiguration` (SwiftData) holds everything else (server URL display name, username, last login date) so the UI can render "logged in as X on server Y" without touching the Keychain; only `KeychainStore` touches the actual token.

### 2.6 Login UI & Keyboard Handoff

`SignInView` (the signed-out content of the Library tab, §4.1) presents a hero screen that reveals the sign-in form: a `TextField` (server URL), then — once the URL validates against `/System/Info/Public` — a **Quick Connect** button *or* `TextField` (username) + `SecureField` (password), bound to `@Bindable` view-model properties, with `.textInputAutocapitalization(.never)` and autocorrection disabled on the URL field.

watchOS presents its own text input chooser (scribble, dictation, emoji, or wrist-to-iPhone keyboard handoff) automatically when a `TextField` becomes focused — **no extra code is required or possible** to request handoff specifically. The implementation must not assume handoff is available (it requires a reachable paired iPhone) and must not impose a timeout on text entry, since handoff round-trips through the paired phone and can take longer than on-device scribble. If validation against `/System/Info/Public` fails after the server URL is entered, show an inline error ("Can't reach this server") before letting the user proceed to credentials, rather than failing only after a full auth attempt.

### 2.7 Quick Connect Authentication

An alternative to typing username/password once the server URL has validated: the user approves a short code from an already-signed-in Jellyfin client (mobile app, web UI) instead of entering credentials on the watch. Both paths remain available side by side — Quick Connect can be disabled per-server, so password login is never removed.

Flow:
1. **Initiate** — `POST /QuickConnect/Initiate`, no auth. Returns `{ "Authenticated": false, "Secret": "...", "Code": "ABC123", "DateAdded": "..." }`. A `401` here means Quick Connect is disabled on this server; there is no separate `/QuickConnect/Enabled` pre-check.
2. **Display** — show `Code` to the user with the instruction to enter it in Jellyfin on another device.
3. **Poll** — `GET /QuickConnect/Connect?secret=<Secret>`, same response shape, until `Authenticated == true`.
4. **Exchange** — `POST /Users/AuthenticateWithQuickConnect` with body `{"Secret": "<Secret>"}`. Returns the **same `AuthenticationResult` shape as `/Users/AuthenticateByName`** (§2.2) — `User{Id,Name,ServerId}`, `AccessToken`, `ServerId` — so the resulting token is stored via the identical Keychain/`ServerConfiguration` path as password login (§2.5).

**Bounded exception to `.claude/rules/soul.md §2.1` ("No Polling"):** step 3 is inherently poll-based, which soul.md otherwise prohibits. This is scoped narrowly rather than treated as a standing exception:
- Implemented as a single structured-concurrency loop (`Task` + `Task.sleep`), not a repeating `Timer` or `NotificationCenter` observer.
- Fixed cadence of 2 seconds, hard cap of 150 attempts (~5 minutes) — matching the server's own Quick Connect code expiry window, so the watch never polls longer than the code could possibly remain valid.
- Runs only while the Quick Connect pending screen is on-screen; cancelled immediately on approval, on explicit user cancellation, on the attempt cap, and via the screen's `onDisappear` (covers navigating away and the success transition alike).
- One-time bootstrap cost to obtain a token, not steady-state behavior — once signed in, no further polling occurs.

---

## 3. Audio Playback & Sync Engine Specification

### 3.1 Playback State Machine

```swift
enum PlaybackState: Equatable {
    case idle
    /// Preparing: activating the audio session, resolving a URL, loading the
    /// asset, or waiting for the player to have enough to start.
    case loading
    case playing
    case paused
    case failed(message: String)
}
```

**State is derived, never stored.** `PlaybackEngine.currentState` is computed from the player on every read: `failureMessage` → `.failed(message:)`, `isPreparing` → `.loading`, no current item → `.idle`, `player.currentItem.status == .failed` → `.failed`, otherwise `player.timeControlStatus` (`.playing` → `.playing`, `.waitingToPlayAtSpecifiedRate` → `.loading`, `.paused` → `.paused`). Because the engine is `@Observable`, reading `player.timeControlStatus` registers a dependency and SwiftUI updates on its own. There are no KVO observers.

The engine keeps only two pieces of state the player cannot report: `isPreparing` (between "user tapped" and "item handed to the player") and `failureMessage` (a load that failed before an item ever existed). A failed load sets `failureMessage` and the UI shows it.

**Event handling — three `NotificationCenter` observers, registered once.** `init` calls `registerObservers()`, which registers exactly three observers for the engine's lifetime (all removed in `deinit`). Nothing is attached per item, so there is no per-track teardown to get wrong:
- `.AVPlayerItemDidPlayToEndTime` — auto-advance to the next queued track (guarded so only the notification for the *current* item counts).
- `AVAudioSession.interruptionNotification` — pause on `.began`; on `.ended`, resume only if the engine was playing and the system passes `.shouldResume`.
- `AVAudioSession.routeChangeNotification` — pause on reason `.oldDeviceUnavailable` (output lost, e.g. headphones unplugged).

### 3.2 Local-vs-Streaming URL Resolution

Resolved **every time a track is about to play**, never cached statically, so a download completing or a file going missing is picked up immediately. A completed download wins over the network.

```swift
// PlaybackEngine
private func resolveURL(for item: QueueItem) -> URL? {
    if let local = localFileURL(trackId: item.trackId) { return local }
    guard !item.serverURL.isEmpty, !item.accessToken.isEmpty else { return nil }
    return JellyfinAPIClient.streamingURL(
        serverURL: item.serverURL, accessToken: item.accessToken, trackId: item.trackId
    )
}

private func localFileURL(trackId: String) -> URL? {
    guard let modelContext else { return nil }
    let completed = BetaDownloadStatus.completed.rawValue
    let predicate = #Predicate<BetaDownloadItem> { $0.jellyfinId == trackId && $0.statusRaw == completed }
    guard let row = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first,
          let fileName = row.localFileName else { return nil }

    let url = BetaDownloadManager.downloadsDirectory.appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: url.path) else {
        // Completed in SwiftData but the file is gone — repair state and fall back.
        row.statusRaw = BetaDownloadStatus.failed.rawValue
        row.lastError = "File missing from disk"
        try? modelContext.save()
        return nil
    }
    return url
}
```

A track with no local file **and** no credentials has nowhere to play from: `resolveURL` returns `nil`, and the load surfaces "This track isn't available offline."

### 3.3 Background Download Pipeline

```swift
@Observable @MainActor
final class BetaDownloadManager: NSObject {
    static let sessionIdentifier = "com.armfin.beta-downloads"
    static let shared = BetaDownloadManager()

    private static let maxConcurrentTasks = 6
    private(set) var isActive = false
    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var serverURL: String = ""
    @ObservationIgnored private var accessToken: String = ""

    // Live progress for in-flight downloads, keyed by track id. Observed (the UI
    // reads it) but deliberately NOT persisted — see the note below.
    private(set) var progressByTrackId: [String: DownloadProgress] = [:]

    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func configure(modelContext: ModelContext, serverURL: String = "", accessToken: String = "") {
        self.modelContext = modelContext
        self.serverURL = serverURL
        self.accessToken = accessToken
        recoverStalledState()
    }
    func attachIfNeeded() { _ = session }
    func reattach(sessionIdentifier: String) {
        guard sessionIdentifier == Self.sessionIdentifier else { return }
        _ = session
    }
    // download(track:), cancel(jellyfinId:), cancelAll(), removeCompleted(jellyfinId:),
    // removeAllCompleted(), retry(jellyfinId:), downloadAlbum(...), removeAlbumDownloads(...),
    // albumDownloadState(albumId:), purgeQueue()
}
```

Behavior:
- **Enqueue** — `download(track:)` creates a `BetaDownloadItem` (status `.queued`), deletes any stale non-active row for the same `jellyfinId`, then calls `fillDownloadSlots()`.
- **Concurrency** — `fillDownloadSlots()` hands up to `maxConcurrentTasks` (6) queued items to the system daemon (FIFO by `createdDate`) as slots free up. The daemon manages these independently of the app's lifecycle, so downloads continue while suspended.
- **Storage** — audio at `Application Support/Downloads/Beta/{jellyfinId}.aac`; album artwork at `Application Support/Downloads/Beta/Artwork/{albumId}.img` (one per album with a completed track, no format-specific extension — `JellyfinImage` detects the format from magic bytes).
- **Recovery & orphans** — on `configure`, `recoverStalledState()` resets any `.downloading` row to `.queued` (a transfer that didn't survive relaunch), marks completed rows whose file is missing `.failed` ("File missing from disk"), and `cleanOrphanFiles()` deletes on-disk audio/artwork files that have no `BetaDownloadItem` row (and artwork whose album no longer has a completed track).
- **Progress** — live byte counts are held **in memory only** in `progressByTrackId`, throttled to one update per second per task. They are not written to SwiftData: a save per download per second invalidated every `@Query`. Only `statusRaw` is durable. A `DownloadProgress.fraction(expectedBytes:)` caps at 0.99; the denominator is `Content-Length` when present, else the estimate `duration × transcodeBitrate/8` (the transcode is chunked, so a percentage could never be computed from the wire alone).
- **Completion** — `urlSession(_:downloadTask:didFinishDownloadingTo:)` moves the file into `Downloads/Beta/`, then `handleDownloadComplete` marks the row `.completed`, releases the task, refills slots, and best-effort fetches album artwork (never gates the audio's `.completed` status).
- The background `URLSession` keeps transferring at the OS level while the app is suspended. When the system relaunches the process to deliver events, `ArmfinAppDelegate.handle(_:)` (§1.1) reattaches the delegate via the *same* session identifier.

### 3.4 Audio Session & Now Playing Integration

```swift
// .longFormAudio on watchOS must be activated with activate() — setActive(_:)
// is not supported for that policy and throws. Activation completes only once
// an output route exists, which on a cold launch genuinely takes a moment.
func activateSession() async -> Bool {
    // Deduped: one in-flight activation task plus an `isSessionActive` flag,
    // so concurrent loads don't each re-activate the session.
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .default, policy: .longFormAudio,
                             options: [])
    do { try await session.activate() ; return true } catch { return false }
}
```

The session is configured with `.playback` / `.default` / `.longFormAudio` and **no category options** (`options: []`). `.longFormAudio` route-sharing policy matches a music player rather than a voice app.

Two system events drive automatic pause/resume (both observed via `NotificationCenter`, see §3.1):
- **Interruptions** — `AVAudioSession.interruptionNotification` (calls relayed to the watch, other audio, a concurrent workout's cues): pause on `.began`; on `.ended`, resume only if the engine was playing and the system passes `.shouldResume`. The engine re-activates the session first, because the system tears it down on interruption.
- **Output lost** — `AVAudioSession.routeChangeNotification` with reason `.oldDeviceUnavailable` (headphones unplugged, connection dropped): the engine pauses rather than continuing into a dead route.

Now Playing / remote commands:
```swift
func publishNowPlayingInfo(elapsedTime: TimeInterval) {
    let engineState = playbackEngine.currentState
    var info: [String: Any] = [
        MPMediaItemPropertyTitle: metadata.title,
        MPMediaItemPropertyArtist: metadata.artistName,
        MPMediaItemPropertyAlbumTitle: metadata.albumName,
        MPMediaItemPropertyPlaybackDuration: metadata.durationSeconds,
        MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedTime,
        MPNowPlayingInfoPropertyPlaybackRate: engineState == .playing ? 1.0 : 0.0
    ]
    // Artwork is carried forward / sourced from the per-album cache when present.
    if let existing = infoCenter.nowPlayingInfo, let artwork = existing[MPMediaItemPropertyArtwork] {
        info[MPMediaItemPropertyArtwork] = artwork
    } else if let artwork = cachedArtwork {
        info[MPMediaItemPropertyArtwork] = artwork
    }
    infoCenter.nowPlayingInfo = info
}
```

- The observable `nowPlayingSnapshot` carries **elapsed time only** (a 1 Hz sample from the periodic time observer) — not a copy of playback state. State is read live from the engine; copying state into the snapshot previously desynced because the 1 Hz observer only fires while the player is actually advancing.
- Remote commands: play, pause, togglePlayPause, next, previous, and changePlaybackPosition (`MPChangePlaybackPositionCommandEvent`) are all registered on `MPRemoteCommandCenter`, each hop dispatching to the `@MainActor` engine via `Task`.
- **System Now Playing artwork** is wired but not yet populated (`cachedArtwork` is only ever set to `nil`); the in-app `NowPlayingView` artwork (local cache or remote) works. See §4.4.
- **Platform constraint — no in-app route picker:** unlike iOS/tvOS, watchOS exposes no public `AVRoutePickerView`/`MPVolumeView` equivalent for output selection. Bluetooth/AirPlay output selection is owned entirely by system UI (Control Center). `NowPlayingView` layers in its own `VolumeControl` for level but does **not** implement a custom route button.

---

## 4. UI/UX Map & Navigation Hierarchy

### 4.1 View Hierarchy & Navigation Model

The app's root is a single, permanent **`RootView`**: a horizontal paged `TabView` with **four tabs in a fixed order — Now Playing, Downloads, Library, Settings** — each wrapped in its own `NavigationStack`. Nothing appears, disappears, or moves when the auth state changes. Signing in changes exactly one thing: whether the **Library** tab shows the browse UI or the sign-in screen (`SignInView`). There is no `LoginView`→`HomeView` push; the `RootView` replaces that model deliberately, because a push could be silently dropped and dump the user back to sign-in mid-session.

| Tab (swipe position) | Content | Depends on auth? |
|---|---|---|
| 1 | **Now Playing** — `NowPlayingView` (track) or `NothingPlayingView` (empty) | No |
| 2 | **Downloads** — `BetaDownloadsView` (offline browser) | No (local files) |
| 3 | **Library** — browse UI (signed in) or `SignInView` (signed out) | Yes |
| 4 | **Settings** — `SettingsView` | No |

```swift
// RootView structure (simplified)
TabView(selection: $selectedTab) {
    NavigationStack { nowPlayingContent }.tag(Tab.nowPlaying)   // NowPlayingView / NothingPlayingView
    NavigationStack { BetaDownloadsView(serverURL: ...)         // + .downloadsNavigationDestinations
                        .downloadsNavigationDestinations(...) } .tag(Tab.downloads)
    NavigationStack {
        if let session { browseUI(session: session).id(session) }  // browse views, keyed on session
        else { SignInView(viewModel: viewModel) }
    } .tag(Tab.library)
    NavigationStack { SettingsView(onSignOut: ...) }.tag(Tab.settings)
}
.tabViewStyle(.page(indexDisplayMode: .automatic))
.background(.black)
.environment(\.showNowPlaying, { selectedTab = .nowPlaying })
.environment(\.showDownloads, { selectedTab = .downloads })
.alert("Data Reset", isPresented: $didResetCorruptData) { Button("OK") {} }
```

Within the **Library** tab, a custom capsule picker (Artists / Albums / Songs / Genres) selects one of four browse screens, only one alive at a time:
- **Artists** → `ArtistListView` → `AlbumListView` → `TrackListView`
- **Albums** → `AllAlbumListView` → `TrackListView`
- **Songs** → `AllTrackListView`
- **Genres** → `GenreListView` → `GenreTrackListView`

Tapping a track starts playback and switches the `TabView` selection to Now Playing via the `\.showNowPlaying` environment closure. The browse screens are keyed `.id(session)` so a sign-out/sign-in (or switching servers) gives them a fresh identity and never carries the previous account's credentials.

The **Downloads** tab (`BetaDownloadsView`) has its own 4-sub-tab picker (Artists / Albums / Songs / Genres) and uses **value-based** navigation (`NavigationLink(value:)` + `.navigationDestination(for: DownloadsRoute.self)`) into `DownloadedArtistView` / `DownloadedAlbumView` / `DownloadedGenreView`. All offline playback routes through `DownloadedPlayback.start(...)`, which builds the queue only from items whose audio file is actually present on disk.

**Offline handling** is shared: the `OfflineGate` `ViewModifier` wraps each browse screen. It is driven by the outcome of the screen's real API call (not an interface-level signal) and by `NetworkStatusService`, which keeps a session-scoped, per-tab "has this screen already failed" set (per-view `@State` doesn't survive SwiftUI tearing the view down on tab switch). On failure it shows "You're offline" with "Go to Downloads" and "Retry".

### 4.2 Per-View Specification

| View | Key elements | Loading / empty / error states |
|---|---|---|
| `RootView` | Permanent 4-tab shell; owns `LoginViewModel`, tab selection, and download-credential sync. | Data Reset alert when `didResetCorruptData` is set. |
| `SignInView` | Hero screen → form: server URL (validates on submit) then Quick Connect **or** username/password. Restores session from Keychain on launch. | Loading: spinner during validation/auth. Error: inline message distinguishing server-unreachable from bad credentials. |
| `SettingsView` | Sign Out, Remove All Downloads (with count), Factory Reset — each behind a confirmation dialog. | "Remove All Downloads" disabled when none completed. |
| `ArtistListView` | `List` of artist rows with `JellyfinImage` thumbnails + per-artist bulk download. Navigates to `AlbumListView`. `OfflineGate`. | Loading: `ProgressView`. Empty: "No artists found". |
| `AlbumListView` | Albums for one artist; Shuffle All across albums; per-album bulk download; navigates to `TrackListView`. | Loading: `ProgressView`. Empty: "No albums found". |
| `TrackListView` | Tracks for one album; tap to play (queue from album); per-track download/remove; Shuffle All. | Loading: `ProgressView`. Empty: "No tracks found". |
| `AllAlbumListView` | Library-wide flat album list; same navigation/download patterns as artist-scoped. | Loading: `ProgressView`. Empty: "No albums found". |
| `AllTrackListView` | Library-wide song list; play + download per row; Shuffle All. | Loading: `ProgressView`. Empty: "No songs found". |
| `GenreListView` | Library-wide genre list (paged); navigates to `GenreTrackListView`. Mirrors `ArtistListView`. `OfflineGate`. | Loading: `ProgressView`. Empty: "No genres found". |
| `GenreTrackListView` | Songs for one genre (`GenreIds` filter); play + download per row; Shuffle All scoped to the genre; navigates in from `GenreListView`. `OfflineGate`. | Loading: `ProgressView`. Empty: "No songs found". |
| `NowPlayingView` | Artwork (local cache or remote), title/artist, prev/play-pause/next transport (56pt play, 44pt skip), download toggle, shuffle, `VolumeControl`, error display. | Buffering: spinner on artwork. Failed: inline error. |
| `NothingPlayingView` | Empty Now Playing state; Shuffle CTA (online) / Shuffle Downloads (offline content). | — |
| `BetaDownloadsView` | Offline browser, 4 sub-tabs (Artists/Albums/Songs/Genres) grouped by denormalized metadata; active-download progress; offline playback; Shuffle at each level; value-based drill-down. | Empty: "No downloads yet". |
| `DownloadedArtistView` / `DownloadedAlbumView` | One artist's / one album's completed downloads in album order; Play All; per-item play. | Missing-file handling via `DownloadedPlayback.StartFailure`. |
| `DownloadedGenreView` | One genre's completed downloads as a flat song list (mirrors `GenreTrackListView`, not the album-grouped artist/album views); Shuffle All; per-item play. | Missing-file handling via `DownloadedPlayback.StartFailure`. Empty: "No downloads". |
| `BetaDownloadButton` / `BetaAlbumDownloadButton` | Per-track and per-album bulk download/remove with a progress ring. | — |
| `OfflineGate` | Shared offline-detection modifier (see §4.1). | "You're offline" + Go to Downloads / Retry. |
| `JellyfinImage` | Loads from local disk (cached artwork), remote server, or SF Symbol placeholder. | — |

Supporting (non-screen) types: `NetworkStatusService` (reactive offline state + per-tab failure memory), `PlaybackEngine` (queue + local-vs-stream resolution), `NowPlayingManager` (Now Playing + remote commands), `BetaDownloadManager` (download pipeline), `DownloadedPlayback` (offline playback entry point), `PaginationFooter` (load-more sentinel).

### 4.3 Design System Rules

- Pure black (`#000000`) background everywhere: `.background(.black)` on root containers plus `.scrollContentBackground(.hidden)` on every `List`/`ScrollView` to remove the default System Material fill.
- Minimum interactive tap target: **44pt** (matching soul.md §3.4) on controls, with the primary play button larger at **56pt** to suit sweaty fingers and motion during runs.
- Dynamic Type supported; control rows that would clip use layout adaptation at the largest sizes rather than truncating.

### 4.4 Future UI (Not Yet Implemented)

The following are planned but not yet built:

| Feature | Notes |
|---|---|
| Search | Full-text search across the Jellyfin library |
| Scrubber / seek bar | Visible progress bar in `NowPlayingView` (seek already works via system remote commands) |
| System Now Playing artwork | Populate `MPMediaItemPropertyArtwork` in `MPNowPlayingInfoCenter` (in-app artwork already works; the system field is wired but not yet sourced) |

`SettingsView` **exists** but is intentionally minimal (Sign Out / Remove All Downloads / Factory Reset). The following are planned **additions** to it: streaming quality picker, "Allow Cellular Downloads" toggle, "Auto-manage storage" toggle, and a clear-cache action.

---

## 5. Data Management & Offline Rules

### 5.1 Cache Eviction Policy

> **Status: Planned — not yet implemented.** The `lastPlayedDate` field exists on `CachedTrack` but eviction logic is not wired up. The storage thresholds described below are the target design.

Two independent tiers, evicted differently:

- **Metadata cache** (`CachedArtist`/`CachedAlbum`/`CachedTrack` rows without an attached completed download) — cheap text, not subject to storage-pressure eviction. Pruned only on an explicit "Clear Cache" action in a future `SettingsView`, or automatically after a 30-day staleness window for any item not part of a downloaded album.
- **Downloaded audio files** (`BetaDownloadItem.status == .completed`) — the actual storage cost. Storage-pressure thresholds, checked before every new download enqueue and on a periodic background check:
  - **< 1 GB free:** show a non-blocking "Storage running low" warning in `BetaDownloadsView`.
  - **< 500 MB free:** hard-block new downloads until space is freed (existing downloads/playback are unaffected).
  - If the user enables **"Auto-manage storage"** (future `SettingsView` toggle, default off): when free space drops below 1 GB, evict completed downloads in **least-recently-played order** until free space exceeds 750 MB. Eviction deletes the local file and resets the `BetaDownloadItem` to `.queued`/deleted; playback transparently falls back to streaming per §3.2.

### 5.2 Sync & Download Rules

**Currently implemented:**
- **Concurrency:** max **6** concurrent `URLSessionDownloadTask`s (`maxConcurrentTasks`); additional queued downloads run FIFO as slots free up.
- **File storage:** audio at `Application Support/Downloads/Beta/{jellyfinId}.aac`; album artwork at `Application Support/Downloads/Beta/Artwork/{albumId}.img`.
- **Bulk downloads:** per-artist and per-album helpers in `BetaDownloadManager` (`downloadAlbum`, `removeAlbumDownloads`).
- **Progress:** live byte counts held in memory only (`progressByTrackId`), throttled to one update/sec/task — not persisted to SwiftData. Only download status is durable.
- **Recovery & orphans (at launch and on resolve):** `recoverStalledState()` resets `.downloading`→`.queued`, flags completed-but-missing files `.failed`; `cleanOrphanFiles()` deletes on-disk files/artwork with no matching `BetaDownloadItem` row. This is disk-vs-store reconciliation, not a server-diff.

**Planned (not yet implemented):**
- **Cellular downloads toggle:** default **off** (Wi-Fi only), toggled in a future `SettingsView` addition. Offline detection itself is **reactive from actual API call outcomes** via `NetworkStatusService` — it deliberately does **not** use `NWPathMonitor`.
- **Pause/resume:** the status enum is `queued/downloading/completed/failed` — there is **no** `paused` state. `cancel`/`retry` exist; pause/resume does not.
- **Storage pressure checks:** thresholds defined above but not yet enforced before enqueue.