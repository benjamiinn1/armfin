import SwiftUI
import SwiftData

struct ArtistListView: View {
    @State private var viewModel: BrowseViewModel

    private let serverURL: String
    private let userId: String
    private let accessToken: String
    private let apiClient = JellyfinAPIClient()

    init(serverURL: String, userId: String, accessToken: String) {
        self.serverURL = serverURL
        self.userId = userId
        self.accessToken = accessToken
        _viewModel = State(
            wrappedValue: BrowseViewModel(
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
            case .loaded where viewModel.artists.isEmpty:
                emptyState
            case .loaded:
                artistList
            case .failed(let error):
                errorState(error)
            }
        }
        .background(.black)
        .offlineGate(
            tabKey: "artists",
            isUnreachable: viewModel.state == .failed(.serverUnreachable),
            isLoaded: viewModel.state == .loaded,
            onRetry: { await viewModel.load() }
        )
    }

    private var artistList: some View {
        List {
            ForEach(viewModel.artists, id: \.id) { artist in
                artistRow(artist)
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
                    url: apiClient.imageURL(
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
        ArtistListView(serverURL: "https://example.com", userId: "user-id", accessToken: "token")
    }
    .modelContainer(for: [BetaDownloadItem.self], inMemory: true)
}
