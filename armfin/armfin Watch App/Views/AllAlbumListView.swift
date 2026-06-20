import SwiftUI
import SwiftData

struct AllAlbumListView: View {
    @State private var viewModel: AllAlbumsViewModel

    private let serverURL: String
    private let userId: String
    private let accessToken: String
    private let apiClient = JellyfinAPIClient()

    init(serverURL: String, userId: String, accessToken: String) {
        self.serverURL = serverURL
        self.userId = userId
        self.accessToken = accessToken
        _viewModel = State(
            wrappedValue: AllAlbumsViewModel(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken
            )
        )
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded where viewModel.albums.isEmpty:
                emptyState
            case .loaded:
                albumList
            case .failed(let error):
                errorState(error)
            }
        }
        .background(.black)
        .offlineGate(
            tabKey: "all-albums",
            isUnreachable: viewModel.state == .failed(.serverUnreachable),
            isLoaded: viewModel.state == .loaded,
            onRetry: { await viewModel.load() }
        )
    }

    private var albumList: some View {
        List {
            ForEach(viewModel.albums, id: \.id) { album in
                albumRow(album)
                    .listRowBackground(Color.clear)
            }

            if viewModel.hasMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .onAppear {
                        Task { await viewModel.loadMore() }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.black)
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
                        url: apiClient.imageURL(
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
        AllAlbumListView(serverURL: "https://example.com", userId: "user-id", accessToken: "token")
    }
    .modelContainer(for: [BetaDownloadItem.self], inMemory: true)
}
