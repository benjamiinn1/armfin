import Foundation

@Observable
final class AlbumListViewModel {

    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(AlbumError)
    }

    enum AlbumError: Equatable {
        case serverUnreachable
        case unknown

        var message: String {
            switch self {
            case .serverUnreachable:
                return "Can't reach this server"
            case .unknown:
                return "Couldn't load albums"
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var albums: [JellyfinAPIClient.AlbumSummary] = []
    private(set) var totalCount: Int = 0
    private(set) var isLoadingMore: Bool = false

    var hasMore: Bool { albums.count < totalCount }
    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private let apiClient: JellyfinAPIClient
    private let serverURL: String
    private let userId: String
    private let accessToken: String
    private let artistId: String
    private let pageSize = 50

    let artistName: String

    init(
        serverURL: String,
        userId: String,
        accessToken: String,
        artistId: String,
        artistName: String,
        apiClient: JellyfinAPIClient = JellyfinAPIClient()
    ) {
        self.serverURL = serverURL
        self.userId = userId
        self.accessToken = accessToken
        self.artistId = artistId
        self.artistName = artistName
        self.apiClient = apiClient
    }

    @MainActor
    func load() async {
        // Allow re-entry from `.failed` so an explicit Retry can re-attempt
        // the real fetch; `.idle` is the normal first-appearance entry point
        // and `.loaded`/`.loading` are guarded to avoid redundant fetches.
        guard state == .idle || isFailed else { return }
        state = .loading
        albums = []
        totalCount = 0

        do {
            let result = try await apiClient.fetchAlbums(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken,
                artistId: artistId,
                startIndex: 0,
                limit: pageSize
            )

            albums = result.items
            totalCount = result.totalRecordCount
            state = .loaded
        } catch let error as JellyfinAPIClientError {
            state = .failed(albumError(for: error))
        } catch {
            state = .failed(.unknown)
        }
    }

    @MainActor
    func loadMore() async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true

        do {
            let result = try await apiClient.fetchAlbums(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken,
                artistId: artistId,
                startIndex: albums.count,
                limit: pageSize
            )

            albums.append(contentsOf: result.items)
            totalCount = result.totalRecordCount
        } catch {
            // Silently fail on load-more — existing items remain visible.
        }

        isLoadingMore = false
    }

    private func albumError(for error: JellyfinAPIClientError) -> AlbumError {
        switch error {
        case .invalidURL, .requestFailed, .unexpectedStatusCode:
            return .serverUnreachable
        case .decodingFailed:
            return .unknown
        default:
            return .unknown
        }
    }
}
