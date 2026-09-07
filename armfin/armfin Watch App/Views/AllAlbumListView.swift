import SwiftUI
import SwiftData

struct AllAlbumListView: View {
    @State private var viewModel: AllAlbumsViewModel
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
            wrappedValue: AllAlbumsViewModel(
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
                    tabKey: "all-albums",
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
        case .loaded where viewModel.albums.isEmpty:
            emptyState
                .listRowBackground(Color.clear)
        case .loaded:
            ForEach(viewModel.albums, id: \.id) { album in
                albumRow(album)
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

    private func albumRow(_ album: JellyfinAPIClient.AlbumSummary) -> some View {
        HStack(spacing: 6) {
            NavigationLink {
                TrackListView(
                    serverURL: serverURL,
                    userId: userId,
                    accessToken: accessToken,
                    albumId: album.id,
                    albumName: album.name,
                    artistName: album.artistName ?? ""
                )
            } label: {
                HStack(spacing: 10) {
                    JellyfinImage(
                        url: JellyfinAPIClient.imageURL(
                            serverURL: serverURL,
                            itemId: album.id,
                            maxWidth: 56,
                            maxHeight: 56,
                            tag: album.imageTag
                        ),
                        icon: "opticaldisc"
                    )
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(album.name)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            if let artist = album.artistName {
                                Text(artist)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.35))
                                    .lineLimit(1)
                            }
                            if let year = album.productionYear {
                                Text("(\(String(year)))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.2))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            BetaAlbumDownloadButton(
                albumId: album.id,
                albumName: album.name,
                artistName: album.artistName ?? "",
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "opticaldisc")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.2))
            Text("No albums found")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ error: AllAlbumsViewModel.AlbumError) -> some View {
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
        AllAlbumListView(
            serverURL: "https://example.com",
            userId: "user-id",
            accessToken: "token",
            selectedCategory: .constant(.albums),
            shuffleAction: nil
        )
    }
    .modelContainer(for: [BetaDownloadItem.self], inMemory: true)
}
