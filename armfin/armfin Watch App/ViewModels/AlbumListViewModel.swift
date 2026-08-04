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

    /// Driven by how many rows the server has handed back, not how many are
    /// on screen. `appendUnique` can drop duplicates, and a `hasMore` pinned
    /// to the displayed count would then stay true forever, re-requesting the
    /// same overlapping page on every scroll.
    var hasMore: Bool { !reachedEnd && fetchedCount < totalCount }

    /// Server-side offset for the next page.
    private var fetchedCount = 0

    /// Set when a page comes back empty, so a `totalCount` that disagrees with
    /// what the server will actually return can't drive an endless loop.
    private var reachedEnd = false

    /// Non-nil when the last `loadMore` failed. The list footer renders it as
    /// a retry row — swallowing the error left an indistinguishable spinner
    /// spinning forever (soul.md §4.3).
    private(set) var loadMoreError: String?
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
        fetchedCount = 0
        reachedEnd = false
        loadMoreError = nil

        do {
            let result = try await apiClient.fetchAlbums(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken,
                artistId: artistId,
                startIndex: 0,
                limit: pageSize
            )

            appendUnique(result.items)
            fetchedCount = result.items.count
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
        loadMoreError = nil

        do {
            let result = try await apiClient.fetchAlbums(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken,
                artistId: artistId,
                startIndex: fetchedCount,
                limit: pageSize
            )

            appendUnique(result.items)
            fetchedCount += result.items.count
            totalCount = result.totalRecordCount
            if result.items.isEmpty { reachedEnd = true }
        } catch {
            loadMoreError = "Couldn't load more albums"
        }

        isLoadingMore = false
    }

    /// Appends only ids not already present. Jellyfin's recursive `/Items`
    /// queries can hand back a row that was already returned — the same entity
    /// reached by more than one path, or a page boundary shifting under a
    /// non-unique `SortBy` — and `ForEach` renders that as a visible duplicate.
    /// Guarding on id is correct whichever of those is happening.
    private func appendUnique(_ incoming: [JellyfinAPIClient.AlbumSummary]) {
        var seen = Set(albums.map(\.id))
        for item in incoming where seen.insert(item.id).inserted {
            albums.append(item)
        }
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
