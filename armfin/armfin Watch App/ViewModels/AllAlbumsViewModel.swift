import Foundation

@Observable
final class AllAlbumsViewModel {

    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(AlbumError)
    }

    enum AlbumError: Equatable {
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
                return "Couldn't load albums"
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var albums: [JellyfinAPIClient.AlbumSummary] = []
    private(set) var totalCount: Int = 0
    private(set) var isLoadingMore: Bool = false

    var hasMore: Bool { albums.count < totalCount }

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
        if state == .loaded && !albums.isEmpty { return }
        state = .loading
        albums = []
        totalCount = 0

        do {
            let libId = try await apiClient.fetchMusicLibraryId(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken
            )
            musicLibraryId = libId

            let result = try await apiClient.fetchAllAlbums(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken,
                musicLibraryId: libId,
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
        guard !isLoadingMore, hasMore, let libId = musicLibraryId else { return }
        isLoadingMore = true

        do {
            let result = try await apiClient.fetchAllAlbums(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken,
                musicLibraryId: libId,
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
        case .musicLibraryNotFound:
            return .musicLibraryNotFound
        case .invalidURL, .requestFailed, .unexpectedStatusCode:
            return .serverUnreachable
        case .decodingFailed:
            return .unknown
        }
    }
}
