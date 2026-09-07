import SwiftUI
import SwiftData

struct ArtistListView: View {
    @State private var viewModel: BrowseViewModel
    @Binding private var selectedCategory: LibraryCategory
    private let shuffleAction: (() -> Void)?

    @Environment(\.networkStatusService) private var networkStatusService

    private let serverURL: String
    private let userId: String
    private let accessToken: String

    init(
        serverURL: String,
        userId: String,
        accessToken: String,
        selectedCategory: Binding<LibraryCategory>,
        shuffleAction: (() -> Void)?
    ) {
        self.serverURL = serverURL
        self.userId = userId
        self.accessToken = accessToken
        self._selectedCategory = selectedCategory
        self.shuffleAction = shuffleAction
        _viewModel = State(
            wrappedValue: BrowseViewModel(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken
            )
        )
    }

    /// The header (category dropdown + shuffle + "Connected" label) is
    /// always the first two rows of this list, in every state — loading,
    /// loaded, empty, failed, offline — so it never sits at a different
    /// height depending on what's underneath it, and lines up exactly with
    /// the same header on Downloads (`LibraryBrowseHeaderRows`).
    var body: some View {
        List {
            LibraryBrowseHeaderRows(
                selection: $selectedCategory,
                shuffleAction: shuffleAction,
                statusLabel: networkStatusService.isOffline ? "Offline" : "Connected"
            )

            content
                .offlineGate(
                    tabKey: "artists",
                    isUnreachable: viewModel.state == .failed(.serverUnreachable),
                    isLoaded: viewModel.state == .loaded,
                    showsStatusText: false,
                    onRetry: { await viewModel.load() }
                )
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.black)
        .environment(\.defaultMinListRowHeight, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
        case .loaded where viewModel.artists.isEmpty:
            emptyState
                .listRowBackground(Color.clear)
        case .loaded:
            ForEach(viewModel.artists, id: \.id) { artist in
                artistRow(artist)
                    .listRowBackground(Color.clear)
            }

            if viewModel.hasMore {
                PaginationFooter(errorMessage: viewModel.loadMoreError) {
                    await viewModel.loadMore()
                }
            }
        case .failed(let error):
            errorState(error)
                .listRowBackground(Color.clear)
        }
    }

    private func artistRow(_ artist: JellyfinAPIClient.ArtistSummary) -> some View {
        NavigationLink {
            AlbumListView(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken,
                artistId: artist.id,
                artistName: artist.name
            )
        } label: {
            HStack(spacing: 10) {
                JellyfinImage(
                    url: JellyfinAPIClient.imageURL(
                        serverURL: serverURL,
                        itemId: artist.id,
                        maxWidth: 56,
                        maxHeight: 56,
                        tag: artist.imageTag
                    ),
                    icon: "music.mic",
                    cornerRadius: 14
                )
                .frame(width: 28, height: 28)
                .clipShape(Circle())

                Text(artist.name)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.mic")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.2))
            Text("No artists found")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ error: BrowseViewModel.BrowseError) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(.red.opacity(0.6))
            Text(error.message)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    NavigationStack {
        ArtistListView(
            serverURL: "https://example.com",
            userId: "user-id",
            accessToken: "token",
            selectedCategory: .constant(.artists),
            shuffleAction: nil
        )
    }
    .modelContainer(for: [BetaDownloadItem.self], inMemory: true)
}
