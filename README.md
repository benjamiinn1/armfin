# armfin

A free, open-source, standalone **watchOS** app that streams and downloads music from your personal [Jellyfin](https://jellyfin.org) server — no iPhone required.

> **Note:** This app is 100% vibe-coded. The sole goal of this project was to get a working Jellyfin client on the Apple Watch and nothing more. Feel free to request updates if there are features that you would like to see!

## What It Does

armfin connects directly to your Jellyfin server over Wi-Fi or cellular and gives you full access to your music library on your wrist:

- **Browse** your library — Artists, Albums, Tracks
- **Stream** audio directly from your server
- **Download** tracks or full albums to the watch for offline playback during workouts
- **Now Playing** integration with system controls (play/pause/skip from the watch face)
- **Offline fallback** — downloaded tracks play automatically when your server is unreachable

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

Single watchOS target. Pure SwiftUI + SwiftData + AVFoundation.

```
armfin Watch App/
├── App/                  # App delegate, background URLSession handling
├── BetaDownload/         # Download manager, UI buttons, downloads list view
├── Models/               # SwiftData models (server config, artists, albums, tracks, downloads)
├── Playback/             # AVPlayer wrapper, Now Playing/remote command integration
├── Services/             # Jellyfin API client, Keychain store
├── ViewModels/           # Observable view models (login, browse, album, track, now playing)
└── Views/                # SwiftUI views (login, home, artist/album/track lists, now playing, settings)
```

Key design decisions:

- **Schema-versioned SwiftData** — the app tracks a schema version marker and nukes the local database on incompatible upgrades rather than attempting risky migrations on-device.
- **Background downloads** — uses a dedicated background `URLSessionDownloadTask` pipeline (`BetaDownloadManager`) that survives app suspension and resumes on relaunch.
- **Playback engine** — wraps `AVPlayer` with queue management, offline/streaming fallback, and wires into `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` for system integration.

## Privacy

armfin collects **zero** data. No analytics, no telemetry, no third-party SDKs. The only network traffic is between your watch and your Jellyfin server.

[Full Privacy Policy](https://benjamiinn1.github.io/armfin/privacy-policy.html)

## License

[MIT](LICENSE)
