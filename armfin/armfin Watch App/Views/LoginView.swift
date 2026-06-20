import SwiftUI
import SwiftData

struct LoginView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = LoginViewModel()
    @State private var showLoginForm = false
    @FocusState private var focusedField: Field?

    @State private var selectedPage: LoginTab = .landing
    @State private var showForceResetConfirmation = false

    @Binding var didResetCorruptData: Bool

    @Query private var allBetaDownloads: [BetaDownloadItem]

    @Environment(\.playbackEngine) private var playbackEngine
    @Environment(\.nowPlayingManager) private var nowPlayingManager

    private var hasOfflineContent: Bool {
        allBetaDownloads.contains { $0.statusRaw == BetaDownloadStatus.completed.rawValue }
    }

    enum LoginTab: Hashable {
        case nowPlaying
        case landing
        case downloads
    }

    private enum Field {
        case serverURL
        case username
        case password
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedPage) {
                nowPlayingPage
                    .tag(LoginTab.nowPlaying)

                landingPage
                    .tag(LoginTab.landing)

                downloadsPage
                    .tag(LoginTab.downloads)
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .background(.black)
            .navigationDestination(item: signedInSessionBinding) { session in
                HomeView(
                    serverURL: session.serverURL,
                    userId: session.userId,
                    accessToken: session.accessToken,
                    onSignOut: { viewModel.signOut(context: modelContext) }
                )
            }
                .environment(\.showNowPlaying, { selectedPage = .nowPlaying })
        }
        .onChange(of: viewModel.phase) { _, newPhase in
            if case .idle = newPhase {
                showLoginForm = false
            }
        }
        .alert("Data Reset", isPresented: $didResetCorruptData) {
            Button("OK") {}
        } message: {
            Text("The app's data was corrupted and had to be reset. Please sign in again.")
        }
        .confirmationDialog(
            "Factory Reset",
            isPresented: $showForceResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Everything & Restart", role: .destructive) {
                performForceReset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all data, downloads, and cached content. You will need to sign in again.")
        }
    }

    private var signedInSessionBinding: Binding<LoginViewModel.AuthSession?> {
        Binding(
            get: {
                if case let .signedIn(session) = viewModel.phase {
                    return session
                }
                return nil
            },
            set: { _ in }
        )
    }

    // MARK: - Now Playing page (left swipe)

    private var nowPlayingPage: some View {
        Group {
            if let track = nowPlayingManager.currentTrack {
                NowPlayingView(track: track)
            } else {
                offlineNothingPlayingView
            }
        }
    }

    private var offlineNothingPlayingView: some View {
        NothingPlayingView(
            hasOfflineContent: hasOfflineContent,
            shuffleDownloadsAction: { shuffleOfflineMusic() }
        )
    }

    private func shuffleOfflineMusic() {
        let completed = allBetaDownloads.filter { $0.statusRaw == BetaDownloadStatus.completed.rawValue }
        guard !completed.isEmpty else { return }

        if !playbackEngine.isShuffleEnabled {
            playbackEngine.toggleShuffle()
        }

        let queueItems = completed.map { dl in
            QueueItem(
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

        guard let firstItem = queueItems.randomElement() else { return }
        playbackEngine.setQueue(queueItems, startingAt: firstItem.trackId)
        playbackEngine.onQueueItemChanged = { [nowPlayingManager] item in
            nowPlayingManager.setNowPlaying(track: NowPlayingTrack(
                trackId: item.trackId,
                title: item.title,
                artistName: item.artistName,
                albumName: item.albumName,
                albumId: item.albumId,
                durationSeconds: item.durationSeconds
            ))
        }

        if let dl = completed.first(where: { $0.jellyfinId == firstItem.trackId }),
           let fileName = dl.localFileName {
            let fileURL = BetaDownloadManager.downloadsDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                playbackEngine.playLocalFile(url: fileURL, trackId: firstItem.trackId)
            }
        }

        nowPlayingManager.setNowPlaying(track: NowPlayingTrack(
            trackId: firstItem.trackId,
            title: firstItem.title,
            artistName: firstItem.artistName,
            albumName: firstItem.albumName,
            albumId: firstItem.albumId,
            durationSeconds: firstItem.durationSeconds
        ))
    }

    // MARK: - Landing / Sign In page (center, default)

    private var landingPage: some View {
        Group {
            if showLoginForm {
                loginFormView
            } else {
                heroView
            }
        }
    }

    private func performForceReset() {
        playbackEngine.stop()
        nowPlayingManager.clearNowPlaying()
        ArmfinApp.nukeAllLocalData()
        viewModel.signOut()
    }

    private var heroView: some View {
        VStack(spacing: 0) {
            Spacer()

            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)

            Text("ARMFIN")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .tracking(2)
                .padding(.top, 6)

            Spacer()

            VStack(spacing: 10) {
                Button {
                    showLoginForm = true
                } label: {
                    Text("Sign In")
                        .font(.footnote)
                        .fontWeight(.medium)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Button {
                    showForceResetConfirmation = true
                } label: {
                    Text("Factory Reset")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Login Form

    private var loginFormView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button {
                        showLoginForm = false
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")

                    Spacer()

                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)

                    Spacer()
                    Color.clear.frame(width: 20, height: 20)
                }
                .padding(.bottom, 4)

                TextField("your-server:8096", text: $viewModel.serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .disabled(viewModel.isBusy || viewModel.isServerValidated)
                    .focused($focusedField, equals: .serverURL)
                    .submitLabel(.go)
                    .onSubmit {
                        Task {
                            await viewModel.validateServer()
                            if viewModel.isServerValidated {
                                focusedField = .username
                            }
                        }
                    }

                if viewModel.isServerValidated {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption2)
                        Text(viewModel.serverURL)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            viewModel.resetServerValidation()
                            focusedField = .serverURL
                        } label: {
                            Text("Edit")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    }

                    TextField("Username", text: $viewModel.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .disabled(viewModel.isBusy)
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }

                    SecureField("Password", text: $viewModel.password)
                        .disabled(viewModel.isBusy)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit {
                            Task { await viewModel.signIn(context: modelContext) }
                        }

                    Button {
                        Task { await viewModel.signIn(context: modelContext) }
                    } label: {
                        Text("Sign In")
                            .font(.footnote)
                            .fontWeight(.medium)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.username.isEmpty || viewModel.isBusy)
                } else {
                    Button {
                        Task {
                            await viewModel.validateServer()
                            if viewModel.isServerValidated {
                                focusedField = .username
                            }
                        }
                    } label: {
                        Text("Connect")
                            .font(.footnote)
                            .fontWeight(.medium)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isBusy)
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.9))
                }

                if viewModel.isBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Downloads page (right swipe)

    private var downloadsPage: some View {
        NavigationStack {
            BetaDownloadsView()
        }
    }
}

#Preview {
    LoginView(didResetCorruptData: .constant(false))
        .modelContainer(for: [ServerConfiguration.self, CachedArtist.self, BetaDownloadItem.self], inMemory: true)
}
