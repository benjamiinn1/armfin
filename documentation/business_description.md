## Business Description: armfin

### Overview & Purpose

**armfin** is an open-source, completely independent, standalone **watchOS** application designed to provide direct audio streaming and offline playback from a personal **Jellyfin** media server. It eliminates the need for an iPhone, cloud storage mid-points, or complex companion application syncing.

The application targets a highly specific subset of the self-hosted software community: fitness enthusiasts, runners, and minimalist users who want to untether from their mobile devices completely while retaining native access to their private music libraries.

Distributed entirely free on the watchOS App Store with zero trackers, paywalls, or advertisements, armfin is built to be a dedicated, distraction-free utility.

### System Evolution & Core Capabilities

Because there is no iOS companion app to proxy authentication, pass credentials, or download files over a local bridge, armfin must handle all operations natively on the wrist:

* **The Standalone Client (Baseline):** A high-performance watchOS audio player. The watch interfaces directly with the Jellyfin REST API via the watch's own Wi-Fi or cellular connection. Users log into their server directly on-screen or using Apple's native wrist-to-iPhone keyboard handoff. The interface presents a highly scannable, multi-level hierarchy of the Jellyfin Music Library (`Artists` > `Albums` > `Tracks`) that lazy-loads text data and metadata directly to the watch cache.
* **The Pure-Watch Sync Engine:** A completely native download and file storage pipeline. Users can download individual tracks or full albums directly into the app's secure watchOS storage container via background `URLSession` download tasks. The download pipeline (`BetaDownloadManager`) uses a dedicated background session identifier, survives app suspension, and automatically resumes pending downloads on relaunch. Once cached, the playback engine dynamically switches: if local media files exist on flash storage it acts as a direct local player; otherwise it streams from the server endpoint.

### Design & Engineering Philosophy

Every single line of code in armfin must respect the hardware realities of a wearable device. The application follows a strict **"High-Contrast Minimalist" style** mapped directly to Apple's watchOS Human Interface Guidelines (HIG). The UI operates exclusively on pure black (`#000000`) screens to turn off OLED pixels and maximize battery runtime. Text elements leverage dynamic type scaling so they remain readable at high running paces.

Architecturally, the elimination of a companion iOS target drastically simplifies the project directory. The repository consists of a **single independent watchOS App target** (plus a thin App Store packaging container with no source code). This allows development in a tightly scoped, uniform environment using pure `SwiftUI`, `SwiftData`, and native `AVFoundation` playback queues without dealing with multi-target synchronization bugs.

### Open-Source & Contributor Setup

The project is structured for open-source collaboration while keeping individual developer credentials private:

* **`Config.xcconfig`** (committed) — shared build configuration that `#include?`s the local file below.
* **`LocalDeveloperSettings.xcconfig.sample`** (committed) — documents the required keys (`DEVELOPMENT_TEAM`, `APP_BUNDLE_IDENTIFIER`, `WATCHAPP_BUNDLE_IDENTIFIER`).
* **`LocalDeveloperSettings.xcconfig`** (gitignored) — each contributor fills this in with their own Apple Developer Team ID and bundle identifiers.

The `project.pbxproj` references these variables (`$(DEVELOPMENT_TEAM)`, `$(APP_BUNDLE_IDENTIFIER)`, etc.) instead of hardcoding any individual's credentials. This means the repository never contains personal developer IDs or proprietary bundle identifiers.

---

## The Elevator Pitch

> **For self-hosted music lovers who want to leave their phone behind completely, armfin is a free, standalone Apple Watch app that connects directly to your personal Jellyfin server over Wi-Fi or cellular—allowing you to stream your music library or download tracks directly to your wrist for true phone-free, offline playback during workouts.**
