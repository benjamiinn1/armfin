import SwiftUI
import SwiftData

struct BetaDownloadsView: View {
    var serverURL: String = ""

    /// Sorted by download time because the in-progress sections (Downloading,
    /// Queue) are ordered work, and the queue's order is the order the manager
    /// will actually process them in. The completed sections re-sort by name —
    /// see `completedSongs` / `albums` / `artists`.
    @Query(sort: \BetaDownloadItem.createdDate, order: .forward)
    private var allItems: [BetaDownloadItem]

    @Environment(\.playbackEngine) private var playbackEngine
    @Environment(\.nowPlayingManager) private var nowPlayingManager
    @Environment(\.showNowPlaying) private var showNowPlaying

    @State private var showPurgeConfirmation = false
    @State private var itemPendingRemoval: BetaDownloadItem?
    @State private var selectedTab: DownloadsTab = .songs
    @State private var startFailureMessage: String?

    enum DownloadsTab: String, CaseIterable {
        case artists = "Artists"
        case albums = "Albums"
        case songs = "Songs"
    }

    private var downloadingItems: [BetaDownloadItem] {
        allItems.filter { $0.status == .downloading }
    }

    private var queuedItems: [BetaDownloadItem] {
        allItems.filter { $0.status == .queued }
    }

    private var completedItems: [BetaDownloadItem] {
        allItems.filter { $0.status == .completed }
    }

    private var failedItems: [BetaDownloadItem] {
        allItems.filter { $0.status == .failed }
    }

    private var hasActiveWork: Bool {
        !downloadingItems.isEmpty || !queuedItems.isEmpty
    }

    // MARK: - Completed, grouped and sorted for display

    /// Alphabetical by title. `allItems` is ordered by download time, which is
    /// meaningful for the queue but arbitrary for a finished library.
    private var completedSongs: [BetaDownloadItem] {
        completedItems.sortedByTitle()
    }

    private var albums: [DownloadedAlbumGroup] {
        completedItems.groupedIntoAlbums()
    }

    /// An empty artist name is a legitimate group (every track Jellyfin gave no
    /// artist for), unlike an empty album id — it's displayed as "Unknown
    /// Artist" and still matches exactly on the drill-down's predicate.
    private var artists: [(name: String, songCount: Int, albumCount: Int, artworkAlbumId: String?)] {
        Dictionary(grouping: completedItems, by: \.artistName)
            .map { artistName, tracks in
                (
                    name: artistName,
                    songCount: tracks.count,
                    albumCount: Set(tracks.map(\.albumId).filter { !$0.isEmpty }).count,
                    artworkAlbumId: tracks.first(where: { !$0.albumId.isEmpty })?.albumId
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Group {
            if allItems.isEmpty {
                DownloadsEmptyState(
                    icon: "arrow.down.circle",
                    title: "No downloads yet",
                    detail: "Download songs from the library to listen offline."
                )
            } else {
                downloadsList
            }
        }
        .navigationTitle("Downloads")
        .background(.black)
        .downloadStartFailureAlert(message: $startFailureMessage)
        .confirmationDialog(
            "Clear Download Queue",
            isPresented: $showPurgeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear \(queuedItems.count) Queued", role: .destructive) {
                BetaDownloadManager.shared.purgeQueue()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all queued downloads. The current download and completed files are not affected.")
        }
    }

    private var downloadsList: some View {
        List {
            if !downloadingItems.isEmpty {
                Section {
                    ForEach(downloadingItems, id: \.id) { item in
                        activeRow(item)
                    }
                } header: {
                    Text("Downloading (\(downloadingItems.count))")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .listRowBackground(Color.clear)
            }

            if !queuedItems.isEmpty {
                Section {
                    ForEach(queuedItems, id: \.id) { item in
                        queuedRow(item)
                    }
                } header: {
                    HStack {
                        Text("Queue (\(queuedItems.count))")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.4))
                        Spacer()
                        Button("Clear") {
                            showPurgeConfirmation = true
                        }
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.8))
                    }
                }
                .listRowBackground(Color.clear)
            }

            if !failedItems.isEmpty {
                Section {
                    ForEach(failedItems, id: \.id) { item in
                        failedRow(item)
                            .removeDownloadOnLongPress(item, pending: $itemPendingRemoval)
                    }
                } header: {
                    Text("Failed")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .listRowBackground(Color.clear)
            }

            if !completedItems.isEmpty {
                Section {
                    tabPicker
                        .listRowBackground(Color.clear)

                    completedContent
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.black)
        .removeDownloadConfirmation(item: $itemPendingRemoval)
        .toolbar {
            if hasActiveWork {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel All") {
                        BetaDownloadManager.shared.cancelAll()
                    }
                    .font(.caption2)
                    .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(DownloadsTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 10, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundStyle(selectedTab == tab ? .white : .white.opacity(0.35))
                        .frame(maxWidth: .infinity, minHeight: downloadsRowMinHeight)
                        .background(
                            selectedTab == tab ? Color.white.opacity(0.12) : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Completed Content by Tab

    @ViewBuilder
    private var completedContent: some View {
        switch selectedTab {
        case .songs:
            songsContent
        case .albums:
            albumsContent
        case .artists:
            artistsContent
        }
    }

    private var songsContent: some View {
        // Bound once so the sort isn't re-run for every row, and so the
        // rendered list and the queue handed to playback are the same array.
        let songs = completedSongs
        return Group {
            DownloadedShuffleAllRow(count: songs.count) {
                startPlayback(items: songs, startingAt: nil, shuffle: true)
            }
            .listRowBackground(Color.clear)

            ForEach(songs, id: \.id) { item in
                Button {
                    startPlayback(items: songs, startingAt: item.jellyfinId, shuffle: false)
                } label: {
                    DownloadedTrackRow(
                        item: item,
                        artworkURL: DownloadedArtwork.url(albumId: item.albumId, serverURL: serverURL),
                        subtitle: item.artistName
                    )
                }
                .buttonStyle(.plain)
                .removeDownloadOnLongPress(item, pending: $itemPendingRemoval)
            }
        }
    }

    private var albumsContent: some View {
        ForEach(albums) { album in
            NavigationLink(
                value: DownloadsRoute.album(id: album.id, name: album.name, artist: album.artistName)
            ) {
                DownloadedGroupRow(
                    title: album.name,
                    subtitle: "\(album.artistName) \u{2022} \(album.songCountLabel)",
                    artworkURL: DownloadedArtwork.url(albumId: album.id, serverURL: serverURL),
                    icon: "opticaldisc"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var artistsContent: some View {
        ForEach(artists, id: \.name) { artist in
            NavigationLink(value: DownloadsRoute.artist(name: artist.name)) {
                DownloadedGroupRow(
                    title: artist.name.isEmpty ? "Unknown Artist" : artist.name,
                    subtitle: "\(artist.songCount) song\(artist.songCount == 1 ? "" : "s") \u{2022} \(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s")",
                    artworkURL: artist.artworkAlbumId.flatMap {
                        DownloadedArtwork.url(albumId: $0, serverURL: serverURL)
                    },
                    icon: "music.mic",
                    isCircular: true
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - In-progress rows

    private func activeRow(_ item: BetaDownloadItem) -> some View {
        let progress = BetaDownloadManager.shared.progressByTrackId[item.jellyfinId]

        return HStack(spacing: 8) {
            JellyfinImage(url: albumArtURL(for: item), icon: "music.note")
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.trackName)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(item.artistName)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The ring is the progress indicator. Its denominator is estimated
            // from the track's duration, since a transcoded response carries no
            // Content-Length — see `DownloadProgress.estimatedBytes`.
            if let fraction = progress?.fraction(
                expectedBytes: DownloadProgress.estimatedBytes(forDurationSeconds: item.durationSeconds)
            ) {
                CircularProgressView(progress: fraction)
                    .frame(width: 22, height: 22)
            } else {
                // Jellyfin transcodes before sending the first byte, so a
                // just-started download legitimately has nothing to show yet.
                Image(systemName: "arrow.down.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.blue)
            }

            cancelButton(for: item)
        }
        .frame(minHeight: downloadsRowMinHeight)
    }

    private func queuedRow(_ item: BetaDownloadItem) -> some View {
        HStack(spacing: 8) {
            JellyfinImage(url: albumArtURL(for: item), icon: "music.note")
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.trackName)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(item.albumName)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.25))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "clock.circle.fill")
                .font(.callout)
                .foregroundStyle(.blue.opacity(0.4))

            cancelButton(for: item)
        }
        .frame(minHeight: downloadsRowMinHeight)
    }

    private func failedRow(_ item: BetaDownloadItem) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.trackName)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let error = item.lastError {
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundStyle(.red.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                BetaDownloadManager.shared.retry(jellyfinId: item.jellyfinId)
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(width: 32, height: downloadsRowMinHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry \(item.trackName)")
        }
        .frame(minHeight: downloadsRowMinHeight)
    }

    /// 32 pt wide, not the 44 pt soul.md §3.4 asks for: on a 32 mm screen a
    /// 44 pt cancel button alongside artwork and a progress ring squeezes the
    /// track title to unreadable. Height is the full 44 pt row and the hit
    /// area is widened with `contentShape`, so this is taller and easier to
    /// hit than the 30x30 it replaces — but it is a deliberate partial fix,
    /// not compliance.
    private func cancelButton(for item: BetaDownloadItem) -> some View {
        Button {
            BetaDownloadManager.shared.cancel(jellyfinId: item.jellyfinId)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.3))
                .frame(width: 32, height: downloadsRowMinHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel \(item.trackName)")
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1 {
            return String(format: "%.1f MB", mb)
        }
        let kb = Double(bytes) / 1024
        return String(format: "%.0f KB", kb)
    }

    private func albumArtURL(for item: BetaDownloadItem) -> URL? {
        let itemId = item.albumId.isEmpty ? item.jellyfinId : item.albumId
        return DownloadedArtwork.url(albumId: itemId, serverURL: serverURL)
    }

    // MARK: - Playback

    private func startPlayback(items: [BetaDownloadItem], startingAt trackId: String?, shuffle: Bool) {
        let result = DownloadedPlayback.start(
            items: items,
            startingAt: trackId,
            shuffle: shuffle,
            engine: playbackEngine,
            nowPlayingManager: nowPlayingManager
        )
        switch result {
        case .success:
            showNowPlaying()
        case .failure(let failure):
            startFailureMessage = failure.message
        }
    }
}

/// Lightweight circular progress indicator for active downloads.
private struct CircularProgressView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.blue.opacity(0.2), lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
