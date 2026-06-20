import SwiftUI
import SwiftData

struct BetaDownloadsView: View {
    var serverURL: String = ""
    var accessToken: String = ""

    @Query(sort: \BetaDownloadItem.createdDate, order: .reverse)
    private var allItems: [BetaDownloadItem]

    @Environment(\.playbackEngine) private var playbackEngine
    @Environment(\.nowPlayingManager) private var nowPlayingManager
    @Environment(\.showNowPlaying) private var showNowPlaying

    @State private var itemPendingRemoval: BetaDownloadItem?
    @State private var showPurgeConfirmation = false
    @State private var selectedTab: DownloadsTab = .songs

    private let apiClient = JellyfinAPIClient()

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

    var body: some View {
        Group {
            if allItems.isEmpty {
                emptyState
            } else {
                downloadsList
            }
        }
        .navigationTitle("Downloads")
        .background(.black)
        .confirmationDialog(
            "Remove Download",
            isPresented: Binding(
                get: { itemPendingRemoval != nil },
                set: { if !$0 { itemPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let item = itemPendingRemoval {
                    BetaDownloadManager.shared.removeCompleted(jellyfinId: item.jellyfinId)
                }
                itemPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                itemPendingRemoval = nil
            }
        } message: {
            Text("This will delete the downloaded file.")
        }
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.2))
            Text("No downloads yet")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
            Text("Download songs from the library to listen offline.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.25))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let item = failedItems[index]
                            BetaDownloadManager.shared.removeCompleted(jellyfinId: item.jellyfinId)
                        }
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
                        .frame(maxWidth: .infinity, minHeight: 28)
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
        Group {
            if completedItems.count > 1 {
                shuffleButton
            }

            ForEach(completedItems, id: \.id) { item in
                completedRow(item)
            }
            .onDelete { offsets in
                for index in offsets {
                    let item = completedItems[index]
                    BetaDownloadManager.shared.removeCompleted(jellyfinId: item.jellyfinId)
                }
            }
        }
    }

    private var albumsContent: some View {
        let grouped = Dictionary(grouping: completedItems) { $0.albumId }
        let sortedAlbums = grouped.sorted { lhs, rhs in
            let lhsName = lhs.value.first?.albumName ?? ""
            let rhsName = rhs.value.first?.albumName ?? ""
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }

        return ForEach(sortedAlbums, id: \.key) { albumId, tracks in
            albumGroupRow(albumId: albumId, tracks: tracks)
        }
    }

    private var artistsContent: some View {
        let grouped = Dictionary(grouping: completedItems) { $0.artistName }
        let sortedArtists = grouped.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        return ForEach(sortedArtists, id: \.self) { artistName in
            let tracks = grouped[artistName] ?? []
            artistGroupRow(artistName: artistName, tracks: tracks)
        }
    }

    // MARK: - Album Group Row

    private func albumGroupRow(albumId: String, tracks: [BetaDownloadItem]) -> some View {
        let albumName = tracks.first?.albumName ?? "Unknown Album"
        let artistName = tracks.first?.artistName ?? ""

        return Button {
            playAlbumTracks(tracks)
        } label: {
            HStack(spacing: 8) {
                JellyfinImage(
                    url: albumArtURL(albumId: albumId),
                    icon: "opticaldisc"
                )
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(albumName)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(artistName) \u{2022} \(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "play.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Artist Group Row

    private func artistGroupRow(artistName: String, tracks: [BetaDownloadItem]) -> some View {
        let representativeAlbumId = tracks.first(where: { !$0.albumId.isEmpty })?.albumId

        return Button {
            playArtistTracks(tracks)
        } label: {
            HStack(spacing: 8) {
                JellyfinImage(
                    url: representativeAlbumId.flatMap { albumArtURL(albumId: $0) },
                    icon: "music.mic",
                    cornerRadius: 14
                )
                .frame(width: 28, height: 28)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(artistName)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    let albumCount = Set(tracks.compactMap { $0.albumId.isEmpty ? nil : $0.albumId }).count
                    Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s") \u{2022} \(albumCount) album\(albumCount == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "play.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Shuffle

    private var shuffleButton: some View {
        Button {
            shuffleCompleted()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "shuffle")
                    .font(.footnote)
                    .foregroundStyle(.blue)
                Text("Shuffle Downloads")
                    .font(.footnote)
                    .foregroundStyle(.blue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func shuffleCompleted() {
        guard !completedItems.isEmpty else { return }
        startPlayback(items: completedItems, shuffle: true)
    }

    // MARK: - Row views

    private func activeRow(_ item: BetaDownloadItem) -> some View {
        HStack(spacing: 8) {
            JellyfinImage(
                url: albumArtURL(for: item),
                icon: "music.note"
            )
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
                if item.totalBytes > 0 {
                    Text(formatBytes(item.downloadedBytes) + " / " + formatBytes(item.totalBytes))
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.2))
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.totalBytes > 0 {
                CircularProgressView(progress: item.progress)
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.blue)
            }

            Button {
                BetaDownloadManager.shared.cancel(jellyfinId: item.jellyfinId)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
    }

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
        return albumArtURL(albumId: itemId)
    }

    private func albumArtURL(albumId: String) -> URL? {
        guard !albumId.isEmpty else { return nil }

        let cachedFile = BetaDownloadManager.artworkFileURL(forAlbumId: albumId)
        if FileManager.default.fileExists(atPath: cachedFile.path) {
            return cachedFile
        }

        guard !serverURL.isEmpty else { return nil }
        return apiClient.imageURL(
            serverURL: serverURL,
            itemId: albumId,
            maxWidth: 60,
            maxHeight: 60
        )
    }

    private func queuedRow(_ item: BetaDownloadItem) -> some View {
        HStack(spacing: 8) {
            JellyfinImage(
                url: albumArtURL(for: item),
                icon: "music.note"
            )
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

            Button {
                BetaDownloadManager.shared.cancel(jellyfinId: item.jellyfinId)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
    }

    private func completedRow(_ item: BetaDownloadItem) -> some View {
        Button {
            playCompletedItem(item)
        } label: {
            HStack(spacing: 8) {
                JellyfinImage(
                    url: albumArtURL(for: item),
                    icon: "music.note"
                )
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

                Image(systemName: "play.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        }
        .buttonStyle(.plain)
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
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Playback

    private func playCompletedItem(_ item: BetaDownloadItem) {
        guard let fileName = item.localFileName else { return }
        let fileURL = BetaDownloadManager.downloadsDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        startPlayback(items: completedItems, startingAt: item.jellyfinId)
    }

    private func playAlbumTracks(_ tracks: [BetaDownloadItem]) {
        guard let first = tracks.first else { return }
        startPlayback(items: tracks, startingAt: first.jellyfinId)
    }

    private func playArtistTracks(_ tracks: [BetaDownloadItem]) {
        guard let first = tracks.first else { return }
        startPlayback(items: tracks, startingAt: first.jellyfinId)
    }

    private func startPlayback(items: [BetaDownloadItem], startingAt trackId: String? = nil, shuffle: Bool = false) {
        let queueItems = items.compactMap { dl -> QueueItem? in
            guard dl.localFileName != nil else { return nil }
            return QueueItem(
                trackId: dl.jellyfinId,
                title: dl.trackName,
                artistName: dl.artistName,
                albumName: dl.albumName,
                albumId: dl.albumId,
                durationSeconds: dl.durationSeconds,
                serverURL: "",
                accessToken: ""
            )
        }
        guard !queueItems.isEmpty else { return }

        let startId: String
        if shuffle {
            if !playbackEngine.isShuffleEnabled { playbackEngine.toggleShuffle() }
            startId = queueItems.randomElement()!.trackId
        } else {
            if playbackEngine.isShuffleEnabled { playbackEngine.toggleShuffle() }
            startId = trackId ?? queueItems[0].trackId
        }

        playbackEngine.setQueue(queueItems, startingAt: startId)
        playbackEngine.onQueueItemChanged = { [nowPlayingManager] queueItem in
            nowPlayingManager.setNowPlaying(track: NowPlayingTrack(
                trackId: queueItem.trackId,
                title: queueItem.title,
                artistName: queueItem.artistName,
                albumName: queueItem.albumName,
                albumId: queueItem.albumId,
                durationSeconds: queueItem.durationSeconds
            ))
        }

        if let dlItem = items.first(where: { $0.jellyfinId == startId }),
           let fileName = dlItem.localFileName {
            let fileURL = BetaDownloadManager.downloadsDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                playbackEngine.playLocalFile(url: fileURL, trackId: startId)
            }
        }

        if let startItem = queueItems.first(where: { $0.trackId == startId }) {
            nowPlayingManager.setNowPlaying(track: NowPlayingTrack(
                trackId: startItem.trackId,
                title: startItem.title,
                artistName: startItem.artistName,
                albumName: startItem.albumName,
                albumId: startItem.albumId,
                durationSeconds: startItem.durationSeconds
            ))
        }
        showNowPlaying()
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
