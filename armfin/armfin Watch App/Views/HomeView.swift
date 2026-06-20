import SwiftUI
import SwiftData

struct HomeView: View {
    let serverURL: String
    let userId: String
    let accessToken: String
    var onSignOut: (() -> Void)?

    @State private var selectedPage: HomeTab = .library
    @State private var selectedBrowseTab: BrowseTab = .artists
    @State private var shuffleErrorMessage: String?

    @Query private var allBetaDownloads: [BetaDownloadItem]

    @Environment(\.playbackEngine) private var playbackEngine
    @Environment(\.nowPlayingManager) private var nowPlayingManager

    enum HomeTab: Hashable {
        case nowPlaying
        case library
        case downloads
        case settings
    }

    enum BrowseTab: String, CaseIterable {
        case artists = "Artists"
        case albums = "Albums"
        case songs = "Songs"
    }

    var body: some View {
        TabView(selection: $selectedPage) {
            nowPlayingPage
                .tag(HomeTab.nowPlaying)

            downloadsPage
                .tag(HomeTab.downloads)

            libraryPage
                .tag(HomeTab.library)

            settingsPage
                .tag(HomeTab.settings)
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .background(.black)
        .navigationBarBackButtonHidden(true)
        .environment(\.showNowPlaying, { selectedPage = .nowPlaying })
        .environment(\.showDownloads, { selectedPage = .downloads })
        .onAppear {
            BetaDownloadManager.shared.updateCredentials(serverURL: serverURL, accessToken: accessToken)
        }
    }

    // MARK: - Now Playing page

    private var nowPlayingPage: some View {
        Group {
            if let track = nowPlayingManager.currentTrack {
                NowPlayingView(track: track)
            } else {
                nothingPlayingView
            }
        }
    }

    private var nothingPlayingView: some View {
        NothingPlayingView(
            hasOfflineContent: allBetaDownloads.contains { $0.statusRaw == BetaDownloadStatus.completed.rawValue },
            shuffleDownloadsAction: { shuffleBetaDownloads() },
            errorMessage: shuffleErrorMessage
        )
    }

    private func shuffleBetaDownloads() {
        let completed = allBetaDownloads.filter { $0.statusRaw == BetaDownloadStatus.completed.rawValue }
        guard !completed.isEmpty else { return }

        let queueItems = completed.compactMap { dl -> QueueItem? in
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

        if !playbackEngine.isShuffleEnabled { playbackEngine.toggleShuffle() }
        let startId = queueItems.randomElement()!.trackId

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

        if let dlItem = completed.first(where: { $0.jellyfinId == startId }),
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
    }

    // MARK: - Library page (center, default)

    private var libraryPage: some View {
        VStack(spacing: 0) {
            browsePicker
                .padding(.horizontal, 2)
                .padding(.top, 2)
                .padding(.bottom, 4)

            browseContent
        }
        .background(.black)
    }

    // MARK: - Downloads page

    private var downloadsPage: some View {
        NavigationStack {
            BetaDownloadsView(serverURL: serverURL, accessToken: accessToken)
        }
    }

    // MARK: - Settings page

    private var settingsPage: some View {
        SettingsView(onSignOut: onSignOut)
    }

    // MARK: - Browse tab picker

    private var browsePicker: some View {
        HStack(spacing: 4) {
            ForEach(BrowseTab.allCases, id: \.self) { tab in
                Button {
                    selectedBrowseTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 11, weight: selectedBrowseTab == tab ? .semibold : .regular))
                        .foregroundStyle(selectedBrowseTab == tab ? .white : .white.opacity(0.35))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(
                            selectedBrowseTab == tab ? Color.white.opacity(0.12) : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Browse content — only one tab alive at a time

    @ViewBuilder
    private var browseContent: some View {
        switch selectedBrowseTab {
        case .artists:
            ArtistListView(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken
            )
        case .albums:
            AllAlbumListView(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken
            )
        case .songs:
            AllTrackListView(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken
            )
        }
    }
}

#Preview {
    NavigationStack {
        HomeView(serverURL: "https://example.com", userId: "user", accessToken: "token")
    }
    .modelContainer(for: [BetaDownloadItem.self], inMemory: true)
}
