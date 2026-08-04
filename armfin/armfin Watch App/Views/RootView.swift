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
    @State private var selectedBrowseTab: BrowseTab = .artists

    @Environment(\.modelContext) private var modelContext
    @Environment(\.nowPlayingManager) private var nowPlayingManager

    enum Tab: Hashable {
        case nowPlaying
        case downloads
        case library
        case settings
    }

    enum BrowseTab: String, CaseIterable {
        case artists = "Artists"
        case albums = "Albums"
        case songs = "Songs"
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
                    browseUI(session: session)
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

    private func browseUI(session: LoginViewModel.AuthSession) -> some View {
        VStack(spacing: 0) {
            browsePicker
                .padding(.horizontal, 2)
                .padding(.top, 2)
                .padding(.bottom, 4)

            browseContent(session: session)
        }
    }

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

    /// Only one browse tab is alive at a time.
    @ViewBuilder
    private func browseContent(session: LoginViewModel.AuthSession) -> some View {
        switch selectedBrowseTab {
        case .artists:
            ArtistListView(
                serverURL: session.serverURL,
                userId: session.userId,
                accessToken: session.accessToken
            )
        case .albums:
            AllAlbumListView(
                serverURL: session.serverURL,
                userId: session.userId,
                accessToken: session.accessToken
            )
        case .songs:
            AllTrackListView(
                serverURL: session.serverURL,
                userId: session.userId,
                accessToken: session.accessToken
            )
        }
    }
}

#Preview {
    RootView(didResetCorruptData: .constant(false))
        .modelContainer(for: [ServerConfiguration.self, CachedArtist.self, BetaDownloadItem.self], inMemory: true)
}
