import SwiftUI
import SwiftData

/// The "Genres" Library browse tab: a paged list of every genre in the music
/// library. Tapping a genre pushes `GenreTrackListView` (songs in that genre).
/// Mirrors `ArtistListView` — the closest existing top-level list that pushes
/// a detail screen — for structure, states, styling, and the `OfflineGate`.
struct GenreListView: View {
    @State private var viewModel: GenreListViewModel
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
            wrappedValue: GenreListViewModel(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken
            )
        )
    }

    /// See `ArtistListView.body` — the header is always the first two rows
    /// of this list so it lines up exactly with every other browse screen.
    var body: some View {
        List {
            LibraryBrowseHeaderRows(
                selection: $selectedCategory,
                shuffleAction: shuffleAction,
                statusLabel: networkStatusService.isOffline ? "Offline" : "Connected"
            )

            content
                .offlineGate(
                    tabKey: "genres",
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
        case .loaded where viewModel.genres.isEmpty:
            emptyState
                .listRowBackground(Color.clear)
        case .loaded:
            ForEach(viewModel.genres, id: \.id) { genre in
                genreRow(genre)
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

    private func genreRow(_ genre: JellyfinAPIClient.GenreSummary) -> some View {
        NavigationLink {
            GenreTrackListView(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken,
                genreId: genre.id,
                genreName: genre.name
            )
        } label: {
            HStack(spacing: 10) {
                JellyfinImage(
                    url: JellyfinAPIClient.imageURL(
                        serverURL: serverURL,
                        itemId: genre.id,
                        maxWidth: 56,
                        maxHeight: 56,
                        tag: genre.imageTag
                    ),
                    icon: "music.note"
                )
                .frame(width: 28, height: 28)

                Text(genre.name)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note.list")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.2))
            Text("No genres found")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ error: GenreListViewModel.GenreError) -> some View {
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
        GenreListView(
            serverURL: "https://example.com",
            userId: "user-id",
            accessToken: "token",
            selectedCategory: .constant(.genres),
            shuffleAction: nil
        )
    }
    .modelContainer(for: [BetaDownloadItem.self], inMemory: true)
}