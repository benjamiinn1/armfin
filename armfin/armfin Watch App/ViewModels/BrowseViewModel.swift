import Foundation

@Observable
final class BrowseViewModel {

    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(BrowseError)
    }

    enum BrowseError: Equatable {
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
                return "Couldn't load artists"
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var artists: [JellyfinAPIClient.ArtistSummary] = []
    private(set) var totalCount: Int = 0
    private(set) var isLoadingMore: Bool = false

    var hasMore: Bool { artists.count < totalCount }

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
        if state == .loaded && !artists.isEmpty { return }
        state = .loading
        artists = []
        totalCount = 0

        do {
            let libId = try await apiClient.fetchMusicLibraryId(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken
            )
            musicLibraryId = libId

            let result = try await apiClient.fetchArtists(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken,
                musicLibraryId: libId,
                startIndex: 0,
                limit: pageSize
            )

            artists = result.items
            totalCount = result.totalRecordCount
            state = .loaded
        } catch let error as JellyfinAPIClientError {
            state = .failed(browseError(for: error))
        } catch {
            state = .failed(.unknown)
        }
    }

    @MainActor
    func loadMore() async {
        guard !isLoadingMore, hasMore, let libId = musicLibraryId else { return }
        isLoadingMore = true

        do {
            let result = try await apiClient.fetchArtists(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken,
                musicLibraryId: libId,
                startIndex: artists.count,
                limit: pageSize
            )

            artists.append(contentsOf: result.items)
            totalCount = result.totalRecordCount
        } catch {
            // Silently fail on load-more — existing items remain visible.
            // The user can scroll down again to retry.
        }

        isLoadingMore = false
    }

    private func browseError(for error: JellyfinAPIClientError) -> BrowseError {
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
