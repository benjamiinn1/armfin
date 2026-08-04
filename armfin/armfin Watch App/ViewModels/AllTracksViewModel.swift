import Foundation

@Observable
final class AllTracksViewModel {

    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(TrackError)
    }

    enum TrackError: Equatable {
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
                return "Couldn't load songs"
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var tracks: [JellyfinAPIClient.TrackSummary] = []
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
    let serverURL: String
    let userId: String
    let accessToken: String
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
        if state == .loaded && !tracks.isEmpty { return }
        state = .loading
        tracks = []
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

            let result = try await apiClient.fetchAllTracks(
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
            state = .failed(trackError(for: error))
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
            let result = try await apiClient.fetchAllTracks(
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
            loadMoreError = "Couldn't load more songs"
        }

        isLoadingMore = false
    }

    /// Appends only ids not already present. Jellyfin's recursive `/Items`
    /// queries can hand back a row that was already returned — the same entity
    /// reached by more than one path, or a page boundary shifting under a
    /// non-unique `SortBy` — and `ForEach` renders that as a visible duplicate.
    /// Guarding on id is correct whichever of those is happening.
    private func appendUnique(_ incoming: [JellyfinAPIClient.TrackSummary]) {
        var seen = Set(tracks.map(\.id))
        for item in incoming where seen.insert(item.id).inserted {
            tracks.append(item)
        }
    }

    private func trackError(for error: JellyfinAPIClientError) -> TrackError {
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
