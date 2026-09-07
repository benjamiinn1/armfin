import SwiftUI
import SwiftData

/// The app's single, permanent shell: four tabs that always exist, in a fixed
/// order — Now Playing, Downloads, Library, Settings.
///
/// Signing in changes exactly one thing: whether the Library tab shows the
/// browse UI or the sign-in screen. Nothing appears, disappears, or moves.
/// This replaces a `LoginView` (3 tabs) that *pushed* a `HomeView` (4 tabs)
/// once signed in — two overlapping tab structures where a tab's index and
/// existence depended on auth state, and where the push could be silently
/// dropped, dumping the user back to the login screen mid-session.
struct RootView: View {
    @Binding var didResetCorruptData: Bool

    @State private var viewModel = LoginViewModel()
    @State private var selectedTab: Tab = .library
    @State private var selectedBrowseTab: LibraryCategory = .artists
    @State private var shuffleFailureMessage: String?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.playbackEngine) private var playbackEngine
    @Environment(\.nowPlayingManager) private var nowPlayingManager

    enum Tab: Hashable {
        case nowPlaying
        case downloads
        case library
        case settings
    }

    /// Non-nil whenever there's a usable session — restored from the Keychain
    /// on launch by `LoginViewModel.init`, or set by a successful sign-in.
    private var session: LoginViewModel.AuthSession? {
        if case let .signedIn(session) = viewModel.phase {
            return session
        }
        return nil
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            nowPlayingPage
                .tag(Tab.nowPlaying)

            downloadsPage
                .tag(Tab.downloads)

            libraryPage
                .tag(Tab.library)

            settingsPage
                .tag(Tab.settings)
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .background(.black)
        .environment(\.showNowPlaying, { selectedTab = .nowPlaying })
        .environment(\.showDownloads, { selectedTab = .downloads })
        .onAppear { syncDownloadCredentials() }
        .onChange(of: session) { _, _ in syncDownloadCredentials() }
        .alert("Data Reset", isPresented: $didResetCorruptData) {
            Button("OK") {}
        } message: {
            Text("The app's data was corrupted and had to be reset. Please sign in again.")
        }
        .downloadStartFailureAlert(message: $shuffleFailureMessage)
    }

    /// Keeps the download manager's credentials in step with the session, so a
    /// sign-in — or a switch to a different server — is picked up by downloads
    /// queued afterwards.
    private func syncDownloadCredentials() {
        BetaDownloadManager.shared.updateCredentials(
            serverURL: session?.serverURL ?? "",
            accessToken: session?.accessToken ?? ""
        )
    }

    // MARK: - Tabs
    //
    // Each page owns its own `NavigationStack`. A stack per page keeps a push
    // inside the page that started it instead of replacing the whole TabView,
    // and toolbars (Now Playing's download/shuffle buttons) need a navigation
    // container to render into.

    private var nowPlayingPage: some View {
        NavigationStack {
            Group {
                if let track = nowPlayingManager.currentTrack {
                    NowPlayingView(track: track)
                } else {
                    NothingPlayingView()
                }
            }
        }
    }

    /// Always present, signed in or out. Downloads are local files; they don't
    /// need a session to play. `serverURL` is only used to fall back to remote
    /// artwork for tracks downloaded before artwork caching, so an empty
    /// string while signed out degrades to the placeholder icon.
    private var downloadsPage: some View {
        NavigationStack {
            BetaDownloadsView(serverURL: session?.serverURL ?? "")
                .downloadsNavigationDestinations(serverURL: session?.serverURL ?? "")
        }
    }

    /// The only tab whose content depends on auth state.
    private var libraryPage: some View {
        NavigationStack {
            Group {
                if let session {
                    browseContent(session: session)
                        // Browse view models capture the server URL and token
                        // in `@State(wrappedValue:)`, which initialises once
                        // per view identity. Keying on the session forces a
                        // fresh identity when the account changes, so a
                        // sign-out/sign-in never leaves the previous account's
                        // credentials in place.
                        .id(session)
                } else {
                    SignInView(viewModel: viewModel)
                }
            }
            .background(.black)
        }
    }

    private var settingsPage: some View {
        NavigationStack {
            SettingsView(onSignOut: { viewModel.signOut(context: modelContext) })
        }
    }

    // MARK: - Library browse

    /// Fetches a fresh random batch from the server and starts shuffled
    /// playback, regardless of which browse tab is currently showing — see
    /// `BrowseShuffleViewModel`.
    private func shuffleAllSongs(session: LoginViewModel.AuthSession) {
        Task {
            let shuffleViewModel = BrowseShuffleViewModel(
                serverURL: session.serverURL,
                userId: session.userId,
                accessToken: session.accessToken
            )
            await shuffleViewModel.shuffleAll(
                engine: playbackEngine,
                nowPlayingManager: nowPlayingManager,
                showNowPlaying: { selectedTab = .nowPlaying }
            )
            if let error = shuffleViewModel.lastError {
                shuffleFailureMessage = error.message
            }
        }
    }

    /// Only one browse tab is alive at a time. Each screen renders its own
    /// copy of the shared category header (`LibraryBrowseHeaderRows`) as the
    /// first rows of its own list — passed the same binding and shuffle
    /// action here — rather than this switch hosting one header above all
    /// four, so the header can never sit somewhere different depending on
    /// which tab's own loading/empty/error state is showing underneath it.
    @ViewBuilder
    private func browseContent(session: LoginViewModel.AuthSession) -> some View {
        switch selectedBrowseTab {
        case .artists:
            ArtistListView(
                serverURL: session.serverURL,
                userId: session.userId,
                accessToken: session.accessToken,
                selectedCategory: $selectedBrowseTab,
                shuffleAction: { shuffleAllSongs(session: session) }
            )
        case .albums:
            AllAlbumListView(
                serverURL: session.serverURL,
                userId: session.userId,
                accessToken: session.accessToken,
                selectedCategory: $selectedBrowseTab,
                shuffleAction: { shuffleAllSongs(session: session) }
            )
        case .songs:
            AllTrackListView(
                serverURL: session.serverURL,
                userId: session.userId,
                accessToken: session.accessToken,
                selectedCategory: $selectedBrowseTab,
                shuffleAction: { shuffleAllSongs(session: session) }
            )
        case .genres:
            GenreListView(
                serverURL: session.serverURL,
                userId: session.userId,
                accessToken: session.accessToken,
                selectedCategory: $selectedBrowseTab,
                shuffleAction: { shuffleAllSongs(session: session) }
            )
        }
    }
}

#Preview {
    RootView(didResetCorruptData: .constant(false))
        .modelContainer(for: [ServerConfiguration.self, CachedArtist.self, BetaDownloadItem.self], inMemory: true)
}
