import Foundation

/// Single source of truth for "is the app currently treating the Jellyfin
/// server as offline." This is purely reactive — it is set from the outcome
/// of an actual attempted Jellyfin API call (see `BrowseViewModel.load()` and
/// its sibling view models), never from `NWPathMonitor` or any other
/// interface-level signal. An interface being "up" (Wi-Fi connected) cannot
/// distinguish "server down, Wi-Fi fine" from "everything is fine," so that
/// signal is deliberately not used here.
///
/// Lives for the lifetime of `ArmfinApp` (constructed once, injected via
/// `\.networkStatusService`), which makes it the natural home for
/// session-scoped "has this specific browse tab already failed once"
/// bookkeeping too — individual browse views are torn down and recreated by
/// SwiftUI on every tab switch or navigation push/pop, so per-view `@State`
/// cannot durably remember "I already saw `.serverUnreachable` this
/// session." This service can, because it outlives those views.
@MainActor
@Observable
final class NetworkStatusService {

    private(set) var isOffline: Bool = false

    /// Identifiers of browse tabs/screens (see `OfflineGate.tabKey`) that
    /// have already observed a `.serverUnreachable` failure this session.
    /// Keyed per screen identity — not global — so a different tab that
    /// hasn't attempted its own fetch yet still gets exactly one attempt,
    /// even while this flag is globally `isOffline`.
    private var failedTabKeys: Set<String> = []

    func reportUnreachable() {
        isOffline = true
    }

    func reportReachable() {
        isOffline = false
    }

    /// Whether `tabKey` has already observed `.serverUnreachable` this
    /// session. While `true`, that tab's `.task` should not re-attempt a
    /// fetch on reappearance — only an explicit Retry clears it.
    func hasFailed(tabKey: String) -> Bool {
        failedTabKeys.contains(tabKey)
    }

    func markFailed(tabKey: String) {
        failedTabKeys.insert(tabKey)
    }

    func clearFailed(tabKey: String) {
        failedTabKeys.remove(tabKey)
    }
}
