//
//  ServerConfiguration.swift
//  armfin Watch App
//
//  SwiftData model persisting everything a logged-in session needs to
//  render "logged in as X on server Y" without touching the Keychain, per
//  specs/spec.md §1.4 and §2.5. The access token itself is never stored
//  here — it lives exclusively in `KeychainStore`.
//
//  This model is the persistent home for a successful
//  `JellyfinAPIClient.authenticate` result (`userId`/`username`), plus the
//  server-level fields (`serverURL`/`serverName`) and session bookkeeping
//  (`lastLoginDate`/`lastValidatedDate`) that the API client itself does not
//  own. Wiring this into a `ModelContainer`/`ModelContext` (e.g. via
//  `ArmfinApp.swift`'s `.modelContainer(for:)`) is deferred to whichever
//  sub-task introduces `RootView`/`LoginView`.
//

import Foundation
import SwiftData

@Model
final class ServerConfiguration {
    @Attribute(.unique) var id: UUID
    var serverURL: String
    var userId: String
    var username: String
    var serverName: String
    var lastLoginDate: Date
    var lastValidatedDate: Date?

    init(id: UUID = UUID(), serverURL: String, userId: String, username: String,
         serverName: String, lastLoginDate: Date = .now) {
        self.id = id
        self.serverURL = serverURL
        self.userId = userId
        self.username = username
        self.serverName = serverName
        self.lastLoginDate = lastLoginDate
    }
}
