//
//  TrackListViewModel.swift
//  armfin Watch App
//
//  ViewModel layer for TrackListView. Owns a `JellyfinAPIClient` and
//  drives `fetchTracks` for a single page of `TrackSummary` values
//  scoped to one album.
//
//  State machine: idle → loading → loaded/empty/error, scoped to a
//  single `albumId` supplied at `init`.
//

import Foundation

/// Drives `TrackListView`'s state machine: idle → loading → loaded/empty/error.
@Observable
final class TrackListViewModel {

    /// Discrete load states `TrackListView` reads to decide what to render.
    /// `.loaded([])` and `.loaded(nonEmptyArray)` are deliberately the same
    /// case — `TrackListView` distinguishes "empty" from "has rows" by
    /// inspecting the array, mirroring `AlbumListViewModel.State`.
    enum State: Equatable {
        case idle
        case loading
        case loaded([JellyfinAPIClient.TrackSummary])
        case failed(TrackError)
    }

    /// User-facing failure modes surfaced by `load()`. Never a raw `Error`
    /// across the View boundary. `fetchTracks` only ever throws
    /// `.invalidURL`/`.requestFailed`/`.unexpectedStatusCode`/`.decodingFailed`
    /// (never `.musicLibraryNotFound`, which is only thrown by
    /// `fetchMusicLibraryId`), so this mapper has at most those four arms.
    enum TrackError: Equatable {
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

    /// Convenience accessor for `TrackListView` — empty when `state` isn't
    /// `.loaded`, so the view can render rows without re-deriving this from
    /// `state` itself.
    var tracks: [JellyfinAPIClient.TrackSummary] {
        if case let .loaded(tracks) = state {
            return tracks
        }
        return []
    }

    private let apiClient: JellyfinAPIClient
    let serverURL: String
    let userId: String
    let accessToken: String
    let albumId: String

    /// The album's display name, exposed for `TrackListView`'s navigation
    /// title.
    let albumName: String

    /// The artist's display name, threaded through from `AlbumListView` (it
    /// already holds this for its own navigation title) so a tapped track's
    /// `NowPlayingMetadata.artistName` can be populated without a second
    /// network round-trip. Not used for this view's own navigation title —
    /// `albumName` still drives that, unchanged.
    let artistName: String

    init(
        serverURL: String,
        userId: String,
        accessToken: String,
        albumId: String,
        albumName: String,
        artistName: String,
        apiClient: JellyfinAPIClient = JellyfinAPIClient()
    ) {
        self.serverURL = serverURL
        self.userId = userId
        self.accessToken = accessToken
        self.albumId = albumId
        self.albumName = albumName
        self.artistName = artistName
        self.apiClient = apiClient
    }

    @MainActor
    func load() async {
        state = .loading

        do {
            let result = try await apiClient.fetchTracks(
                serverURL: serverURL,
                userId: userId,
                accessToken: accessToken,
                albumId: albumId
            )

            state = .loaded(result.items)
        } catch let error as JellyfinAPIClientError {
            state = .failed(trackError(for: error))
        } catch {
            state = .failed(.unknown)
        }
    }

    // MARK: - Private helpers

    /// Maps a thrown `JellyfinAPIClientError` to the appropriate user-facing
    /// `TrackError`. `.musicLibraryNotFound` can never be thrown by
    /// `fetchTracks`, so it is deliberately omitted from this switch.
    private func trackError(for error: JellyfinAPIClientError) -> TrackError {
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
