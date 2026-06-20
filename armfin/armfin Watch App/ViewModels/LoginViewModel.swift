//
//  LoginViewModel.swift
//  armfin Watch App
//
//  ViewModel layer for LoginView, per specs/spec.md §2.6. Owns the form's
//  text state and the two-step "validate server, then authenticate" flow
//  against `JellyfinAPIClient`. On success, persists the access token via
//  `KeychainStore` and inserts a `ServerConfiguration` row into the
//  SwiftData `ModelContext` supplied by the caller.
//
//  No `Timer`/polling/timeout is used anywhere here: watchOS text entry can
//  involve scribble, dictation, or wrist-to-iPhone keyboard handoff, all of
//  which can legitimately take longer than on-device typing, so the model
//  never races the user's input against a clock (§2.6).
//

import Foundation
import SwiftData

/// Drives `LoginView`'s state machine: idle text entry → server validation →
/// (on success) credential entry → authentication → success/failure.
@Observable
final class LoginViewModel {

    /// Discrete phases of the login flow. `LoginView` reads this to decide
    /// which fields are visible/enabled and which inline message to show.
    enum Phase: Equatable {
        case idle
        case validatingServer
        case serverValidated
        case authenticating
        case signedIn(AuthSession)
        case failed(LoginError)
    }

    /// The minimal session payload `LoginView` needs to construct a
    /// `BrowseViewModel` after a successful `signIn()`, carried on
    /// `Phase.signedIn` so navigation is keyed off the existing state
    /// machine rather than a new ad-hoc boolean.
    struct AuthSession: Equatable, Hashable {
        let serverURL: String
        let userId: String
        let accessToken: String
    }

    /// User-facing failure modes the spec explicitly distinguishes
    /// (§2.6, §4.2): unreachable server, rejected credentials, plus
    /// a protocol-specific hint when ATS is the likely blocker.
    enum LoginError: Equatable {
        case serverUnreachable
        case httpNotAllowedForPublicHost
        case invalidCredentials
        case unknown

        var message: String {
            switch self {
            case .serverUnreachable:
                return "Can't reach this server"
            case .httpNotAllowedForPublicHost:
                return "Remote servers require https://. Update the URL or use a VPN for local access."
            case .invalidCredentials:
                return "Incorrect username or password"
            case .unknown:
                return "Something went wrong. Please try again."
            }
        }
    }

    // MARK: - Form state

    var serverURL: String = ""
    var username: String = ""
    var password: String = ""

    // MARK: - Flow state

    private(set) var phase: Phase = .idle

    /// `true` once `/System/Info/Public` has succeeded for the current
    /// `serverURL` — `LoginView` gates the username/password fields on this.
    var isServerValidated: Bool {
        switch phase {
        case .serverValidated, .authenticating, .signedIn:
            return true
        case .failed:
            // Once credentials are rejected, the server itself is still
            // known-good — keep the credential fields visible so the user
            // can correct a typo without re-entering the server URL.
            return lastValidatedServerURL != nil
        case .idle, .validatingServer:
            return false
        }
    }

    var isBusy: Bool {
        phase == .validatingServer || phase == .authenticating
    }

    var errorMessage: String? {
        if case let .failed(error) = phase {
            return error.message
        }
        return nil
    }

    /// The server URL that last passed validation, used to detect whether
    /// the user has edited the field since validating (which should require
    /// re-validation before exposing credential fields again).
    private var lastValidatedServerURL: String?

    // MARK: - Dependencies

    private let apiClient: JellyfinAPIClient
    private let keychainStore: KeychainStore

    init(apiClient: JellyfinAPIClient = JellyfinAPIClient(), keychainStore: KeychainStore = KeychainStore()) {
        self.apiClient = apiClient
        self.keychainStore = keychainStore
        restoreSessionIfAvailable()
    }

    /// On launch, check the Keychain for a previously-saved session. If
    /// valid credentials exist, skip the login form entirely and go
    /// straight to the signed-in state. This is the standard "stay signed
    /// in" behavior — credentials persist across app restarts until the
    /// user explicitly signs out.
    private func restoreSessionIfAvailable() {
        guard let credentials = try? keychainStore.retrieve() else { return }
        phase = .signedIn(
            AuthSession(
                serverURL: credentials.serverURL,
                userId: credentials.userId,
                accessToken: credentials.accessToken
            )
        )
    }

    // MARK: - Actions

    /// Step 1: validate the entered server URL against `/System/Info/Public`.
    /// On success, reveals the username/password fields. On failure, shows
    /// the "Can't reach this server" inline error per §2.6.
    @MainActor
    func validateServer() async {
        let normalizedURL = Self.normalizeServerURL(serverURL)
        guard !normalizedURL.isEmpty else { return }

        serverURL = normalizedURL

        phase = .validatingServer

        do {
            _ = try await apiClient.validateServer(serverURL: normalizedURL)
            lastValidatedServerURL = normalizedURL
            phase = .serverValidated
        } catch {
            lastValidatedServerURL = nil
            if Self.isPublicHTTP(normalizedURL) {
                phase = .failed(.httpNotAllowedForPublicHost)
            } else {
                phase = .failed(.serverUnreachable)
            }
        }
    }

    /// Step 2: authenticate with the validated server using the entered
    /// username/password. On success, persists credentials to the Keychain
    /// and inserts a `ServerConfiguration` into `context`. On failure, shows
    /// the "Incorrect username or password" inline error per §2.6/§4.2.
    @MainActor
    func signIn(context: ModelContext) async {
        guard isServerValidated else { return }

        let trimmedURL = lastValidatedServerURL ?? Self.normalizeServerURL(serverURL)
        let enteredUsername = username
        let enteredPassword = password

        guard !enteredUsername.isEmpty else { return }

        phase = .authenticating

        do {
            let result = try await apiClient.authenticate(
                serverURL: trimmedURL,
                username: enteredUsername,
                password: enteredPassword
            )

            try keychainStore.save(
                serverURL: trimmedURL,
                userId: result.userId,
                accessToken: result.accessToken
            )

            password = ""

            let existingDescriptor = FetchDescriptor<ServerConfiguration>()
            if let existing = try? context.fetch(existingDescriptor) {
                for old in existing {
                    context.delete(old)
                }
            }

            let configuration = ServerConfiguration(
                serverURL: trimmedURL,
                userId: result.userId,
                username: result.username,
                serverName: serverNameFallback(forServerURL: trimmedURL)
            )
            context.insert(configuration)

            phase = .signedIn(
                AuthSession(
                    serverURL: trimmedURL,
                    userId: result.userId,
                    accessToken: result.accessToken
                )
            )
        } catch let error as JellyfinAPIClientError {
            phase = .failed(loginError(for: error))
        } catch {
            // KeychainStore failures and anything else unexpected.
            phase = .failed(.unknown)
        }
    }

    // MARK: - Server re-edit

    /// Drops back to idle so the user can change the server URL without
    /// clearing credentials they've already typed.
    @MainActor
    func resetServerValidation() {
        lastValidatedServerURL = nil
        phase = .idle
    }

    // MARK: - Sign Out

    @MainActor
    func signOut(context: ModelContext? = nil) {
        try? keychainStore.delete()

        if let context {
            let descriptor = FetchDescriptor<ServerConfiguration>()
            if let configs = try? context.fetch(descriptor) {
                for config in configs {
                    context.delete(config)
                }
                try? context.save()
            }
        }

        phase = .idle
        username = ""
        password = ""
        lastValidatedServerURL = nil
    }

    // MARK: - Private helpers

    /// Maps a thrown `JellyfinAPIClientError` from `authenticate` to the
    /// appropriate user-facing `LoginError`. A non-2xx status from
    /// `/Users/AuthenticateByName` (typically 401) means bad credentials;
    /// anything transport-level means the server became unreachable mid-flow.
    private func loginError(for error: JellyfinAPIClientError) -> LoginError {
        switch error {
        case .unexpectedStatusCode:
            return .invalidCredentials
        case .invalidURL, .requestFailed:
            return .serverUnreachable
        case .decodingFailed, .musicLibraryNotFound:
            // `.musicLibraryNotFound` is only ever thrown by
            // `fetchMusicLibraryId`, which this flow never calls — it's
            // included here solely so this switch stays exhaustive over all
            // `JellyfinAPIClientError` cases. If it were ever reachable, it
            // would represent a server-side condition unrelated to the
            // entered credentials, same bucket as `.decodingFailed`.
            return .unknown
        }
    }

    /// `validateServer` doesn't surface a server display name today, so fall
    /// back to the host portion of the URL for `ServerConfiguration.serverName`.
    private func serverNameFallback(forServerURL serverURL: String) -> String {
        URL(string: serverURL)?.host ?? serverURL
    }

    // MARK: - URL normalization

    /// Cleans up a user-entered server URL for watch-friendly input:
    /// - Strips whitespace and trailing slashes
    /// - If no scheme, auto-prepends `http://` for private/local IPs,
    ///   `https://` for everything else
    /// - Lowercases the scheme
    static func normalizeServerURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }

        while s.hasSuffix("/") { s = String(s.dropLast()) }

        let hasScheme = s.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil

        if !hasScheme {
            let hostPart = s.components(separatedBy: ":").first ?? s
            if isPrivateOrLocal(hostPart) {
                s = "http://" + s
            } else {
                s = "https://" + s
            }
        } else {
            // Lowercase an existing scheme (Http:// → http://)
            if let range = s.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) {
                s = s[range].lowercased() + s[range.upperBound...]
            }
        }

        return s
    }

    /// Returns `true` when `host` is a private-range IP, loopback, or
    /// `.local` hostname — the cases `NSAllowsLocalNetworking` covers.
    private static func isPrivateOrLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }

        let parts = host.split(separator: ".").compactMap { UInt16($0) }
        guard parts.count == 4 else { return false }

        let (a, b) = (parts[0], parts[1])
        // 10.x.x.x, 172.16-31.x.x, 192.168.x.x, 127.x.x.x, 169.254.x.x
        return a == 10
            || (a == 172 && (16...31).contains(b))
            || (a == 192 && b == 168)
            || a == 127
            || (a == 169 && b == 254)
    }

    /// Returns `true` when the URL uses plain `http://` against a
    /// non-private host — the scenario ATS's `NSAllowsLocalNetworking`
    /// will block, producing a transport error indistinguishable from
    /// "server unreachable" without this check.
    static func isPublicHTTP(_ url: String) -> Bool {
        guard let parsed = URL(string: url),
              parsed.scheme?.lowercased() == "http",
              let host = parsed.host else { return false }
        return !isPrivateOrLocal(host)
    }
}
