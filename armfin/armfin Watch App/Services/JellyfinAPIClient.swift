//
//  JellyfinAPIClient.swift
//  armfin Watch App
//
//  Services-layer foreground JSON API client, per specs/spec.md §1.5(1).
//  Owns a single `URLSession(configuration: .default)` instance, header
//  construction (`X-Emby-Authorization`), and JSON decoding for the
//  Jellyfin calls implemented so far: pre-auth server validation
//  (`GET /System/Info/Public`), login (`POST /Users/AuthenticateByName`),
//  music library discovery (`GET /Users/{UserId}/Views`), artist listing,
//  and album-for-artist listing (both `GET /Items`).
//
//  Tracks-for-album listing and the adaptive/transcoded streaming URL
//  builder (`/Audio/{Id}/universal`) are implemented in this slice too.
//  The download URL builder (`/Audio/{Id}/stream.aac`) forces server-side
//  AAC 128kbps transcoding and is used by `BetaDownloadManager`.
//

import Foundation

/// Typed errors surfaced by `JellyfinAPIClient` in place of raw `Error`/force-unwraps.
enum JellyfinAPIClientError: Error, Equatable {
    /// The supplied server URL string could not be turned into a valid request URL.
    case invalidURL
    /// The network transport itself failed (offline, DNS failure, timeout, etc.).
    case requestFailed(String)
    /// The server responded, but not with a 2xx status code.
    case unexpectedStatusCode(Int)
    /// The response body could not be decoded into the expected shape.
    case decodingFailed
    /// `/Users/{UserId}/Views` returned no view whose `CollectionType` is
    /// `"music"` — there's nothing for `fetchArtists` to browse.
    case musicLibraryNotFound
}

// NOTE on `.musicLibraryNotFound`: the brief asks for "a new
// `JellyfinAPIClientError` case" for this condition, which is what's added
// above. However, `LoginViewModel.loginError(for:)` (explicitly out of scope
// for this sub-task — see brief) switches over `JellyfinAPIClientError`
// exhaustively with no `default:` case. Adding any new case to this enum
// makes that switch non-exhaustive, which is a hard compiler error in Swift
// for a same-module switch (regardless of `@frozen`), since
// `JellyfinAPIClientError` is a plain enum. That switch only handles errors
// thrown by `authenticate(...)` today, and `.musicLibraryNotFound` can never
// be thrown by `authenticate`, so the *runtime* behavior of
// `LoginViewModel` is unaffected by this case's existence — but the
// *build* will fail until `LoginViewModel.swift`'s switch is updated (e.g.
// adding a `default: return .unknown` arm, a one-line change). This is
// flagged in the implementation report as a cross-file consequence the
// Tester/Planner should resolve, rather than silently reverting to an
// existing case to dodge it.

/// Foreground JSON API client for Jellyfin's REST surface.
///
/// Per spec §1.5(1), this owns a single `URLSession(configuration: .default)` —
/// deliberately not `.shared` and not a background configuration, since the
/// background download pipeline is a fully separate stack
/// (`BetaDownloadManager`). Every method is a plain `async throws`
/// function: no completion handlers, no `Timer`, no `NotificationCenter`
/// observers, so there is no retain-cycle surface to manage here.
///
/// The following endpoints are implemented in this slice:
/// - `GET /System/Info/Public` — pre-auth server validation (§2.1, §2.6).
/// - `POST /Users/AuthenticateByName` — login (§2.1, §2.2).
/// - `GET /Users/{UserId}/Views` — music library discovery (§2.1, §2.3).
/// - `GET /Items` (`IncludeItemTypes=MusicArtist`) — artist listing (§2.1, §2.3).
/// - `GET /Items` (`IncludeItemTypes=MusicAlbum`, `ArtistIds=<id>`) — albums for artist (§2.1, §2.3).
/// - `GET /Items` (`IncludeItemTypes=Audio`, `ParentId=<id>`) — tracks for album (§2.1, §2.3).
/// - `/Audio/{Id}/universal` URL builder — adaptive/transcoded streaming (§2.1, §2.4).
struct JellyfinAPIClient: Sendable {

    // MARK: - Decoded response shapes (private to this file, not SwiftData models)

    /// Minimal decode of `/System/Info/Public`. Only `ServerName` is consumed
    /// today (kept for future use, e.g. displaying the server's name on the
    /// login screen); the call's main purpose pre-auth is simply "did this
    /// return 2xx and valid JSON at all".
    private struct PublicSystemInfoResponse: Decodable {
        let serverName: String?

        enum CodingKeys: String, CodingKey {
            case serverName = "ServerName"
        }
    }

    /// Decoded `/Users/AuthenticateByName` response body, per spec §2.2:
    /// ```json
    /// {
    ///   "User": { "Id": "...", "Name": "...", "ServerId": "..." },
    ///   "AccessToken": "...",
    ///   "ServerId": "..."
    /// }
    /// ```
    private struct AuthenticateByNameResponse: Decodable {
        struct UserPayload: Decodable {
            let id: String
            let name: String
            let serverId: String?

            enum CodingKeys: String, CodingKey {
                case id = "Id"
                case name = "Name"
                case serverId = "ServerId"
            }
        }

        let user: UserPayload
        let accessToken: String
        let serverId: String

        enum CodingKeys: String, CodingKey {
            case user = "User"
            case accessToken = "AccessToken"
            case serverId = "ServerId"
        }
    }

    /// Public result of a successful authentication, decoupled from the
    /// private wire-format struct above so call sites never see `Decodable`
    /// plumbing details.
    struct AuthenticationResult: Equatable, Sendable {
        let userId: String
        let username: String
        let accessToken: String
        let serverId: String
    }

    /// Decoded `/Users/{UserId}/Views` response body, per spec §2.1/§2.3 —
    /// a flat `Items[]` list of the user's library views (Movies, Music,
    /// Photos, etc.), each carrying a `CollectionType` used to find the
    /// music library client-side.
    private struct UserViewsResponse: Decodable {
        struct ViewPayload: Decodable {
            let id: String
            let name: String
            let collectionType: String?

            enum CodingKeys: String, CodingKey {
                case id = "Id"
                case name = "Name"
                case collectionType = "CollectionType"
            }
        }

        let items: [ViewPayload]

        enum CodingKeys: String, CodingKey {
            case items = "Items"
        }
    }

    /// Decoded `/Items` response body, per spec §2.3's `Items` listing shape.
    /// Used identically for artists/albums/tracks; this slice only consumes
    /// the `MusicArtist` shape via `ArtistPayload`.
    private struct ItemsResponse<Item: Decodable>: Decodable {
        let items: [Item]
        let totalRecordCount: Int
        let startIndex: Int

        enum CodingKeys: String, CodingKey {
            case items = "Items"
            case totalRecordCount = "TotalRecordCount"
            case startIndex = "StartIndex"
        }
    }

    /// Wire-format decode of a single `MusicArtist` item from `/Items`.
    private struct ArtistPayload: Decodable {
        let id: String
        let name: String
        let sortName: String?
        let imageTags: ImageTags?

        struct ImageTags: Decodable {
            let primary: String?

            enum CodingKeys: String, CodingKey {
                case primary = "Primary"
            }
        }

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
            case sortName = "SortName"
            case imageTags = "ImageTags"
        }
    }

    /// Public result of a single `/Items` artist-listing call, decoupled from
    /// the private wire-format structs above. Field shape mirrors
    /// `CachedArtist` (Models/CachedArtist.swift) so the next sub-task
    /// (wiring this into a `BrowseViewModel`) can map 1:1.
    struct ArtistSummary: Decodable, Equatable, Sendable {
        let id: String
        let name: String
        let sortName: String
        let imageTag: String?
    }

    /// Generic paged result returned by all `/Items` fetch methods.
    /// Carries the decoded items plus the metadata needed to drive
    /// infinite-scroll pagination at the ViewModel layer.
    struct PagedResult<T: Sendable>: Sendable {
        let items: [T]
        let totalRecordCount: Int
        let startIndex: Int
    }

    /// Wire-format decode of a single `MusicAlbum` item from `/Items`.
    private struct AlbumPayload: Decodable {
        let id: String
        let name: String
        let sortName: String?
        let productionYear: Int?
        let imageTags: ArtistPayload.ImageTags?
        let albumArtist: String?
        let artists: [String]?

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
            case sortName = "SortName"
            case productionYear = "ProductionYear"
            case imageTags = "ImageTags"
            case albumArtist = "AlbumArtist"
            case artists = "Artists"
        }
    }

    /// Public result of a single `/Items` album-listing call, decoupled from
    /// the private wire-format struct above. Field shape mirrors
    /// `CachedAlbum` (specs/spec.md §1.4) 1:1, the same way `ArtistSummary`
    /// mirrors `CachedArtist`.
    struct AlbumSummary: Decodable, Equatable, Sendable {
        let id: String
        let name: String
        let sortName: String
        let productionYear: Int?
        let imageTag: String?
        let artistName: String?
    }

    /// Wire-format decode of a single `Audio` item from `/Items`. Mirrors
    /// `CachedTrack`'s wire-relevant fields (specs/spec.md §1.4):
    /// `ParentIndexNumber` is the disc number, `IndexNumber` the track
    /// number, `RunTimeTicks` the duration in Jellyfin ticks. `bitrate` is
    /// nested under `MediaSources[0].Bitrate` server-side; decoded here via
    /// a minimal nested payload and surfaced as `nil` when that array is
    /// empty or the field is absent, per the brief's documented fallback.
    private struct TrackPayload: Decodable {
        let id: String
        let name: String
        let indexNumber: Int?
        let parentIndexNumber: Int?
        let runTimeTicks: Int64?
        let container: String?
        let mediaSources: [MediaSourcePayload]?
        let albumArtist: String?
        let album: String?
        let albumId: String?
        let imageTags: ArtistPayload.ImageTags?

        struct MediaSourcePayload: Decodable {
            let bitrate: Int?

            enum CodingKeys: String, CodingKey {
                case bitrate = "Bitrate"
            }
        }

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
            case indexNumber = "IndexNumber"
            case parentIndexNumber = "ParentIndexNumber"
            case runTimeTicks = "RunTimeTicks"
            case container = "Container"
            case mediaSources = "MediaSources"
            case albumArtist = "AlbumArtist"
            case album = "Album"
            case albumId = "AlbumId"
            case imageTags = "ImageTags"
        }
    }

    /// Public result of a single `/Items` track-listing call, decoupled from
    /// the private wire-format struct above. Field shape mirrors
    /// `CachedTrack` (specs/spec.md §1.4) 1:1 minus `codec`, the same way
    /// `AlbumSummary` mirrors `CachedAlbum`. `codec` is not required on this
    /// summary for this sub-task per the brief and is intentionally omitted.
    struct TrackSummary: Decodable, Equatable, Sendable {
        let id: String
        let name: String
        let indexNumber: Int?
        let discNumber: Int?
        let durationTicks: Int64
        let container: String?
        let bitrate: Int?
        let artistName: String?
        let albumName: String?
        let albumId: String?
        let imageTag: String?
    }

    // MARK: - Construction

    private let session: URLSession

    /// `DeviceId`/`Version` for the `X-Emby-Authorization` header (§2.2).
    private let deviceId: String
    private let appVersion: String

    /// Generates a stable per-device UUID on first launch and persists it in
    /// UserDefaults. Subsequent launches return the same value.
    private static let persistentDeviceId: String = {
        let key = "com.armfin.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }()

    init(
        session: URLSession = URLSession(configuration: .default),
        deviceId: String = JellyfinAPIClient.persistentDeviceId,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    ) {
        self.session = session
        self.deviceId = deviceId
        self.appVersion = appVersion
    }

    // MARK: - Pre-auth server validation

    /// Performs `GET {serverURL}/System/Info/Public` to validate that `serverURL`
    /// points at a reachable Jellyfin server, before the login form's password
    /// field is shown (§2.1, §2.6). Requires no access token.
    ///
    /// Returns `true` if the server responded with a decodable 2xx payload.
    /// Any failure is surfaced as a thrown `JellyfinAPIClientError` rather than
    /// returning `false`, so call sites can distinguish "unreachable" from
    /// "reachable but rejected" if needed later.
    func validateServer(serverURL: String) async throws -> Bool {
        let url = try endpointURL(serverURL: serverURL, path: "/System/Info/Public")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyCommonHeaders(to: &request, accessToken: nil)

        let data = try await perform(request)
        _ = try decode(PublicSystemInfoResponse.self, from: data)
        return true
    }

    // MARK: - Authentication

    /// Performs `POST {serverURL}/Users/AuthenticateByName` with `Username`/`Pw`
    /// per §2.2's request shape, returning the decoded user id, username,
    /// access token, and server id on success.
    func authenticate(serverURL: String, username: String, password: String) async throws -> AuthenticationResult {
        let url = try endpointURL(serverURL: serverURL, path: "/Users/AuthenticateByName")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(to: &request, accessToken: nil)

        let body = ["Username": username, "Pw": password]
        guard let bodyData = try? JSONEncoder().encode(body) else {
            throw JellyfinAPIClientError.decodingFailed
        }
        request.httpBody = bodyData

        let data = try await perform(request)
        let response = try decode(AuthenticateByNameResponse.self, from: data)

        return AuthenticationResult(
            userId: response.user.id,
            username: response.user.name,
            accessToken: response.accessToken,
            serverId: response.serverId
        )
    }

    // MARK: - Music library discovery

    /// Performs `GET {serverURL}/Users/{userId}/Views` to discover the
    /// authenticated user's library views, filtering client-side for the one
    /// whose `CollectionType == "music"` (§2.1, §2.3). This is the first call
    /// in this client that requires `accessToken` — both `validateServer` and
    /// `authenticate` are pre-auth.
    ///
    /// Throws `.musicLibraryNotFound` rather than returning an empty/optional
    /// string if no music view exists on the server.
    func fetchMusicLibraryId(serverURL: String, userId: String, accessToken: String) async throws -> String {
        let url = try endpointURL(serverURL: serverURL, path: "/Users/\(userId)/Views")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyCommonHeaders(to: &request, accessToken: accessToken)

        let data = try await perform(request)
        let response = try decode(UserViewsResponse.self, from: data)

        guard let musicView = response.items.first(where: { $0.collectionType == "music" }) else {
            throw JellyfinAPIClientError.musicLibraryNotFound
        }

        return musicView.id
    }

    // MARK: - Artists

    /// Performs `GET {serverURL}/Items` with `IncludeItemTypes=MusicArtist`,
    /// `Recursive=true`, `ParentId=<musicLibraryId>`, `SortBy=SortName`, and
    /// `userId=<userId>` (§2.1, §2.3), returning a single page of decoded
    /// `ArtistSummary` values.
    ///
    /// Only one page is fetched here — `startIndex`/`limit` are exposed so a
    /// future `BrowseViewModel` can paginate (§2.3's "scroll within 3 rows of
    /// the end" trigger), but implementing that scroll-driven pagination loop
    /// is explicitly out of scope for this sub-task.
    func fetchArtists(
        serverURL: String,
        userId: String,
        accessToken: String,
        musicLibraryId: String,
        startIndex: Int = 0,
        limit: Int = 50
    ) async throws -> PagedResult<ArtistSummary> {
        let url = try endpointURL(serverURL: serverURL, path: "/Items")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "IncludeItemTypes", value: "MusicArtist"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "ParentId", value: musicLibraryId),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit))
        ]

        guard let finalURL = components?.url else {
            throw JellyfinAPIClientError.invalidURL
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        applyCommonHeaders(to: &request, accessToken: accessToken)

        let data = try await perform(request)
        let response = try decode(ItemsResponse<ArtistPayload>.self, from: data)

        let items = response.items.map { payload in
            ArtistSummary(
                id: payload.id,
                name: payload.name,
                sortName: payload.sortName ?? payload.name,
                imageTag: payload.imageTags?.primary
            )
        }

        return PagedResult(
            items: items,
            totalRecordCount: response.totalRecordCount,
            startIndex: response.startIndex
        )
    }

    // MARK: - Albums

    /// Performs `GET {serverURL}/Items` with `IncludeItemTypes=MusicAlbum`,
    /// `ArtistIds=<artistId>`, `Recursive=true`, `SortBy=ProductionYear,SortName`,
    /// and `userId=<userId>` (§2.1, §2.3), returning a paged result of decoded
    /// `AlbumSummary` values for the given artist.
    func fetchAlbums(
        serverURL: String,
        userId: String,
        accessToken: String,
        artistId: String,
        startIndex: Int = 0,
        limit: Int = 50
    ) async throws -> PagedResult<AlbumSummary> {
        let url = try endpointURL(serverURL: serverURL, path: "/Items")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "ArtistIds", value: artistId),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "ProductionYear,SortName"),
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit))
        ]

        guard let finalURL = components?.url else {
            throw JellyfinAPIClientError.invalidURL
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        applyCommonHeaders(to: &request, accessToken: accessToken)

        let data = try await perform(request)
        let response = try decode(ItemsResponse<AlbumPayload>.self, from: data)

        let items = response.items.map { payload in
            AlbumSummary(
                id: payload.id,
                name: payload.name,
                sortName: payload.sortName ?? payload.name,
                productionYear: payload.productionYear,
                imageTag: payload.imageTags?.primary,
                artistName: payload.albumArtist ?? payload.artists?.first
            )
        }

        return PagedResult(
            items: items,
            totalRecordCount: response.totalRecordCount,
            startIndex: response.startIndex
        )
    }

    // MARK: - Tracks

    /// Performs `GET {serverURL}/Items` with `ParentId=<albumId>`,
    /// `IncludeItemTypes=Audio`, `Recursive=true`,
    /// `SortBy=ParentIndexNumber,IndexNumber`, and `userId=<userId>`
    /// (§2.1, §2.3), returning a paged result of decoded `TrackSummary`
    /// values for the given album.
    func fetchTracks(
        serverURL: String,
        userId: String,
        accessToken: String,
        albumId: String,
        startIndex: Int = 0,
        limit: Int = 50
    ) async throws -> PagedResult<TrackSummary> {
        let url = try endpointURL(serverURL: serverURL, path: "/Items")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "ParentId", value: albumId),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "ParentIndexNumber,IndexNumber"),
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit))
        ]

        guard let finalURL = components?.url else {
            throw JellyfinAPIClientError.invalidURL
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        applyCommonHeaders(to: &request, accessToken: accessToken)

        let data = try await perform(request)
        let response = try decode(ItemsResponse<TrackPayload>.self, from: data)

        let items = response.items.map { payload in
            TrackSummary(
                id: payload.id,
                name: payload.name,
                indexNumber: payload.indexNumber,
                discNumber: payload.parentIndexNumber,
                durationTicks: payload.runTimeTicks ?? 0,
                container: payload.container,
                bitrate: payload.mediaSources?.first?.bitrate,
                artistName: payload.albumArtist,
                albumName: payload.album,
                albumId: payload.albumId,
                imageTag: payload.imageTags?.primary
            )
        }

        return PagedResult(
            items: items,
            totalRecordCount: response.totalRecordCount,
            startIndex: response.startIndex
        )
    }

    // MARK: - All Albums (library-wide)

    /// Fetches albums across the entire music library (no artist filter),
    /// sorted by name. Used by the "Albums" tab in `HomeView`.
    func fetchAllAlbums(
        serverURL: String,
        userId: String,
        accessToken: String,
        musicLibraryId: String,
        startIndex: Int = 0,
        limit: Int = 50
    ) async throws -> PagedResult<AlbumSummary> {
        let url = try endpointURL(serverURL: serverURL, path: "/Items")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "ParentId", value: musicLibraryId),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit))
        ]

        guard let finalURL = components?.url else {
            throw JellyfinAPIClientError.invalidURL
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        applyCommonHeaders(to: &request, accessToken: accessToken)

        let data = try await perform(request)
        let response = try decode(ItemsResponse<AlbumPayload>.self, from: data)

        let items = response.items.map { payload in
            AlbumSummary(
                id: payload.id,
                name: payload.name,
                sortName: payload.sortName ?? payload.name,
                productionYear: payload.productionYear,
                imageTag: payload.imageTags?.primary,
                artistName: payload.albumArtist ?? payload.artists?.first
            )
        }

        return PagedResult(
            items: items,
            totalRecordCount: response.totalRecordCount,
            startIndex: response.startIndex
        )
    }

    // MARK: - All Tracks (library-wide)

    /// Fetches tracks across the entire music library (no album filter),
    /// sorted by name. Used by the "Songs" tab in `HomeView`.
    func fetchAllTracks(
        serverURL: String,
        userId: String,
        accessToken: String,
        musicLibraryId: String,
        startIndex: Int = 0,
        limit: Int = 50
    ) async throws -> PagedResult<TrackSummary> {
        let url = try endpointURL(serverURL: serverURL, path: "/Items")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "ParentId", value: musicLibraryId),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit))
        ]

        guard let finalURL = components?.url else {
            throw JellyfinAPIClientError.invalidURL
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        applyCommonHeaders(to: &request, accessToken: accessToken)

        let data = try await perform(request)
        let response = try decode(ItemsResponse<TrackPayload>.self, from: data)

        let items = response.items.map { payload in
            TrackSummary(
                id: payload.id,
                name: payload.name,
                indexNumber: payload.indexNumber,
                discNumber: payload.parentIndexNumber,
                durationTicks: payload.runTimeTicks ?? 0,
                container: payload.container,
                bitrate: payload.mediaSources?.first?.bitrate,
                artistName: payload.albumArtist,
                albumName: payload.album,
                albumId: payload.albumId,
                imageTag: payload.imageTags?.primary
            )
        }

        return PagedResult(
            items: items,
            totalRecordCount: response.totalRecordCount,
            startIndex: response.startIndex
        )
    }

    // MARK: - Streaming URLs

    /// Streaming bitrate ceiling: AAC 128kbps matches the download pipeline
    /// so streamed and offline playback sound identical. AirPods/watch speaker
    /// cannot benefit from anything higher.
    private static let streamingBitrate = 128_000

    /// Builds the `/Audio/{trackId}/universal` URL that forces AAC 128kbps
    /// stereo streaming — matching the download transcode profile exactly.
    /// This ensures consistent audio quality whether the user is streaming
    /// or playing a downloaded file.
    ///
    /// Returns `nil` rather than throwing if `serverURL` cannot be turned
    /// into a valid request URL — call sites already treat a missing
    /// streaming URL as "can't play this track right now".
    func streamingURL(
        serverURL: String,
        accessToken: String,
        trackId: String,
        preferDirectPlay: Bool = false
    ) -> URL? {
        guard let url = try? endpointURL(serverURL: serverURL, path: "/Audio/\(trackId)/universal") else {
            return nil
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "audioCodec", value: "aac"),
            URLQueryItem(name: "container", value: "aac"),
            URLQueryItem(name: "transcodingContainer", value: "aac"),
            URLQueryItem(name: "maxStreamingBitrate", value: String(Self.streamingBitrate)),
            URLQueryItem(name: "audioBitRate", value: String(Self.streamingBitrate)),
            URLQueryItem(name: "maxAudioChannels", value: "2"),
            URLQueryItem(name: "api_key", value: accessToken)
        ]

        if preferDirectPlay {
            queryItems.append(URLQueryItem(name: "static", value: "true"))
        }

        components?.queryItems = queryItems

        return components?.url
    }

    /// Builds an image URL for the given item ID (artist, album, or track).
    /// Uses `/Items/{itemId}/Images/Primary` with `maxWidth`/`maxHeight`
    /// capped to the rendered size (per soul.md §1: downsample on load).
    /// Appends `tag` when available for strong HTTP cache headers.
    /// Returns `nil` on a malformed `serverURL`.
    func imageURL(
        serverURL: String,
        itemId: String,
        imageType: String = "Primary",
        maxWidth: Int = 80,
        maxHeight: Int = 80,
        tag: String? = nil
    ) -> URL? {
        guard let url = try? endpointURL(serverURL: serverURL, path: "/Items/\(itemId)/Images/\(imageType)") else {
            return nil
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "maxHeight", value: String(maxHeight)),
            URLQueryItem(name: "quality", value: "80")
        ]
        if let tag {
            queryItems.append(URLQueryItem(name: "tag", value: tag))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    /// Builds a `/Audio/{trackId}/stream.aac` URL that forces server-side
    /// transcoding to AAC 128kbps stereo. Used by `BetaDownloadManager` to
    /// ensure predictable, small files land on the watch regardless of the
    /// source format (FLAC, WAV, high-bitrate AAC, etc.).
    func betaDownloadURL(
        serverURL: String,
        accessToken: String,
        trackId: String
    ) -> URL? {
        guard let url = try? endpointURL(serverURL: serverURL, path: "/Audio/\(trackId)/stream.aac") else {
            return nil
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "audioCodec", value: "aac"),
            URLQueryItem(name: "audioBitRate", value: "128000"),
            URLQueryItem(name: "maxStreamingBitrate", value: "128000"),
            URLQueryItem(name: "maxAudioChannels", value: "2"),
            URLQueryItem(name: "static", value: "false"),
            URLQueryItem(name: "api_key", value: accessToken)
        ]

        return components?.url
    }

    // MARK: - Private helpers

    /// Builds the full endpoint URL from a user-entered server URL string and
    /// a fixed API path, surfacing malformed input as `.invalidURL` rather
    /// than force-unwrapping.
    private func endpointURL(serverURL: String, path: String) throws -> URL {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw JellyfinAPIClientError.invalidURL
        }

        let withoutTrailingSlash = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let base = URL(string: withoutTrailingSlash), base.scheme != nil, base.host != nil else {
            throw JellyfinAPIClientError.invalidURL
        }

        return base.appendingPathComponent(String(path.dropFirst(path.hasPrefix("/") ? 1 : 0)))
    }

    /// Sets the `X-Emby-Authorization` header on every outgoing request per
    /// §2.2's exact format. Once authenticated, appends `, Token="<token>"` as
    /// the spec allows, rather than relying solely on a separate `X-Emby-Token`
    /// header.
    private func applyCommonHeaders(to request: inout URLRequest, accessToken: String?) {
        var headerValue = "MediaBrowser Client=\"armfin\", Device=\"Apple Watch\", DeviceId=\"\(deviceId)\", Version=\"\(appVersion)\""
        if let accessToken {
            headerValue += ", Token=\"\(accessToken)\""
        }
        request.setValue(headerValue, forHTTPHeaderField: "X-Emby-Authorization")
    }

    /// Executes `request`, mapping transport failures and non-2xx responses to
    /// `JellyfinAPIClientError` so no raw `Error` leaks to a call site.
    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw JellyfinAPIClientError.requestFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinAPIClientError.requestFailed("Non-HTTP response received.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw JellyfinAPIClientError.unexpectedStatusCode(httpResponse.statusCode)
        }

        return data
    }

    /// Decodes `data` into `T`, mapping any decoding failure to `.decodingFailed`.
    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw JellyfinAPIClientError.decodingFailed
        }
    }
}
