# armfin

A free, open-source, standalone **watchOS** app that streams and downloads music from your personal [Jellyfin](https://jellyfin.org) server — no iPhone required.

> **Note:** This app is 100% vibe-coded. The sole goal of this project was to get a working Jellyfin client on the Apple Watch and nothing more. Feel free to request updates if there are features that you would like to see!

## What It Does

armfin connects directly to your Jellyfin server over Wi-Fi or cellular and gives you full access to your music library on your wrist:

- **Sign in** with username and password, or Quick Connect — approve a short code on any device where you're already signed in to Jellyfin
- **Browse** your library — Artists, Albums, Tracks
- **Stream** audio directly from your server (AAC, 128 kbps)
- **Download** tracks or full albums to the watch for offline playback during workouts
- **Now Playing** integration with system controls (play/pause/skip from the watch face)
- **Offline playback** — local-first: a downloaded track always plays from the watch, and the server is only used for tracks you haven't downloaded (your downloads keep playing when the server is unreachable)

No companion iOS app. No cloud intermediary. No accounts, trackers, or ads.

## Requirements

- Apple Watch running **watchOS 26+**
- A **Jellyfin** media server accessible over your network
- Xcode 16+ to build from source

## Build & Run

1. Clone the repo
2. Copy the xcconfig sample and fill in your Apple Developer Team ID:
   ```bash
   cp armfin/LocalDeveloperSettings.xcconfig.sample armfin/LocalDeveloperSettings.xcconfig
   ```
   Edit `armfin/LocalDeveloperSettings.xcconfig` with your values:
   ```
   DEVELOPMENT_TEAM = YOUR_TEAM_ID
   APP_BUNDLE_IDENTIFIER = com.yourname.armfin
   WATCHAPP_BUNDLE_IDENTIFIER = com.yourname.armfin.watchkitapp
   ```
3. Open `armfin/armfin.xcodeproj` in Xcode
4. Select the **armfin Watch App** scheme
5. Build and run on a watchOS Simulator or your Apple Watch

The Xcode project uses file-system-synchronized groups — no manual file registration needed.

### Developer Configuration

The project keeps developer-specific settings (Team ID, bundle identifiers) out of source control using xcconfig files:

| File | Tracked | Purpose |
|------|---------|---------|
| `Config.xcconfig` | Yes | Shared base config; includes the local file |
| `LocalDeveloperSettings.xcconfig.sample` | Yes | Template showing required keys |
| `LocalDeveloperSettings.xcconfig` | **No** (gitignored) | Your real developer values |

`Config.xcconfig` uses `#include?` so the project opens without errors even if the local file is missing — it falls back to placeholder bundle IDs. Signing will fail until you create your own `LocalDeveloperSettings.xcconfig`.

## Architecture

Single watchOS target. SwiftUI + SwiftData + AVFoundation, with WatchKit where SwiftUI can't reach: the `WKApplicationDelegate` that reattaches the background download session on relaunch, and the Digital Crown volume control on the Now Playing screen. All source lives under `armfin/armfin Watch App/` (the `armfin` target is a thin App Store packaging container with no source of its own).

```
armfin Watch App/
├── ArmfinApp.swift          # @main, schema-version gate, ModelContainer
├── App/ArmfinAppDelegate.swift   # WKApplicationDelegate: background session reattach
├── Models/                  # SwiftData models (server config, artist/album/track cache)
├── Services/                # JellyfinAPIClient, KeychainStore, NetworkStatusService
├── Playback/                # PlaybackEngine (queue + local-vs-stream), NowPlayingManager
├── BetaDownload/            # the offline-download system: BetaDownloadItem model,
│                            #   BetaDownloadManager (background URLSession), download
│                            #   views + navigation, DownloadedPlayback entry point
├── ViewModels/              # Observable view models (login, browse, album/track lists,
│                            #   library-wide lists, now playing)
└── Views/                   # RootView (permanent 4-tab shell), SignInView, OfflineGate,
                             #   SettingsView, artist/album/track lists, Now Playing, etc.
```

Key design decisions:

- **Schema-versioned SwiftData** — the app tracks a schema version marker and wipes the local store (data, downloads, and credentials) on incompatible upgrades rather than attempting risky migrations on-device.
- **Background downloads** — a dedicated background `URLSessionDownloadTask` pipeline (`BetaDownloadManager`) that survives app suspension and resumes on relaunch. Downloads are a 128 kbps AAC transcode so every file lands the same small size regardless of source format.
- **Playback engine** — wraps `AVPlayer` with queue management, local-vs-streaming fallback (a completed download wins), and wires into `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` for system integration.
- **Offline detection** — reactive from the outcome of real API calls (`NetworkStatusService`), never from an interface-level signal.

## Privacy

armfin collects **zero** data. No analytics, no telemetry, no third-party SDKs. The only network traffic is between your watch and your Jellyfin server.

[Full Privacy Policy](https://benjamiinn1.github.io/armfin/privacy-policy.html)

## License

[MIT](LICENSE)