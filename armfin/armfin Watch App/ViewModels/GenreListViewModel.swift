import Foundation

/// Drives `GenreListView`'s state machine: idle → loading → loaded/empty/error.
///
/// Same paged browse pattern as `BrowseViewModel` (Artists) and
/// `AllTracksViewModel` (Songs): fetch the music library id first, then page
/// through `/Genres`. A new genre screen is a top-level Library browse tab,
/// so it owns its own `JellyfinAPIClient` and re-resolves the library id
/// rather than depending on another view model's state.
@Observable
final class GenreListViewModel {

    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(GenreError)
    }

    enum GenreError: Equatable {
        case serverUnreachable
        case musicLibraryNotFound
        case unknown

        var message: String {
            switch self {
            case .serverUnreachable:
                return "Can't reach this server"
            case .musicLibraryNotFound:
                return "No music library found on this server"
            case .unknown:
                return "Couldn't load genres"
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var genres: [JellyfinAPIClient.GenreSummary] = []
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

    private let apiClient: JellyfinAPIClient
    private let serverURL: String
    private let userId: String
    private let accessToken: String
    private let pageSize = 50
    private var musicLibraryId: String?

    init(
        serverURL: String,
        userId: String,
        accessToken: String,
        apiClient: JellyfinAPIClient = JellyfinAPIClient()
    ) {
        self.serverURL = serverURL
        self.userId = userId
        self.accessToken = accessToken
        self.apiClient = apiClient
    }

    @MainActor
    func load() async {
        guard state != .loading else { return }
        if state == .loaded && !genres.isEmpty { return }
        state = .loading
        genres = []
        totalCount = 0
        fetchedCount = 0
        reachedEnd = false
        loadMoreError = nil

        do {
            let libId = try await apiClient.fetchMusicLibraryId(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken
            )
            musicLibraryId = libId

            let result = try await apiClient.fetchGenres(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken,
                musicLibraryId: libId,
                startIndex: 0,
                limit: pageSize
            )

            appendUnique(result.items)
            fetchedCount = result.items.count
            totalCount = result.totalRecordCount
            state = .loaded
        } catch let error as JellyfinAPIClientError {
            state = .failed(genreError(for: error))
        } catch {
            state = .failed(.unknown)
        }
    }

    @MainActor
    func loadMore() async {
        guard !isLoadingMore, hasMore, let libId = musicLibraryId else { return }
        isLoadingMore = true
        loadMoreError = nil

        do {
            let result = try await apiClient.fetchGenres(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken,
                musicLibraryId: libId,
                startIndex: fetchedCount,
                limit: pageSize
            )

            appendUnique(result.items)
            fetchedCount += result.items.count
            totalCount = result.totalRecordCount
            if result.items.isEmpty { reachedEnd = true }
        } catch {
            loadMoreError = "Couldn't load more genres"
        }

        isLoadingMore = false
    }

    /// Appends only ids not already present. `/Genres` is expected to collapse
    /// same-name genres server-side; this is a belt-and-braces fallback for a
    /// server that doesn't, mirroring `BrowseViewModel.appendUnique`.
    private func appendUnique(_ incoming: [JellyfinAPIClient.GenreSummary]) {
        var seenIds = Set(genres.map(\.id))
        var seenNames = Set(genres.map { $0.name.lowercased() })
        for item in incoming {
            let name = item.name.lowercased()
            guard seenIds.insert(item.id).inserted, seenNames.insert(name).inserted else { continue }
            genres.append(item)
        }
    }

    private func genreError(for error: JellyfinAPIClientError) -> GenreError {
        switch error {
        case .musicLibraryNotFound:
            return .musicLibraryNotFound
        case .invalidURL, .requestFailed, .unexpectedStatusCode:
            return .serverUnreachable
        case .decodingFailed:
            return .unknown
        }
    }
}