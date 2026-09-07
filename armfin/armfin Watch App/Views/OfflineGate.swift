import SwiftUI

/// Shared offline-detection bridge + UI for the Library browse views
/// (`ArtistListView`, `AllAlbumListView`, `AllTrackListView`, `AlbumListView`,
/// `TrackListView`). Each of those views has its own `@Observable` view model
/// with a structurally similar but not identical `State`/error enum, so this
/// modifier is parameterized by closures/booleans the caller derives from its
/// own `viewModel.state`, rather than being generic over a concrete
/// view-model type.
///
/// Session-scoped "has this tab already failed" bookkeeping lives in
/// `NetworkStatusService` (injected, `ArmfinApp`-lifetime), keyed by
/// `tabKey` — never in this view's own `@State`. Browse views are recreated
/// by SwiftUI on every tab switch (`HomeView`'s `@ViewBuilder switch`) and
/// navigation push/pop, so per-view `@State` does not survive a revisit;
/// `NetworkStatusService` does.
struct OfflineGate: ViewModifier {
    /// Stable identity for the screen this gate is attached to — e.g.
    /// `"artists"` for the singleton Artists tab, or `"album:\(albumId)"`
    /// for a specific album's track list. Must be unique per distinct
    /// browse screen so one tab's failure doesn't suppress another's first
    /// attempt.
    let tabKey: String

    /// `true` when the attached view's own `viewModel.state` is currently
    /// `.failed(.serverUnreachable)` (caller's own error enum — this modifier
    /// doesn't know its shape, the caller maps it to this Bool).
    let isUnreachable: Bool

    /// `true` when the attached view's own `viewModel.state` is currently
    /// `.loaded` (any loaded state, empty or not).
    let isLoaded: Bool

    /// Calls the real fetch again — `viewModel.load()` at the call site.
    let onRetry: () async -> Void

    /// `false` when the caller already surfaces connectivity status of its
    /// own — the Library browse tabs' "Connected"/"Offline" status label —
    /// so the offline icon and explanation text aren't repeated; only the
    /// two actions show. `true` (the default) for the drill-down screens
    /// (`AlbumListView`, `TrackListView`, `GenreTrackListView`), which have
    /// no such label and still need the full explanation.
    var showsStatusText: Bool = true

    @Environment(\.networkStatusService) private var networkStatusService
    @Environment(\.showDownloads) private var showDownloads

    /// Durable, session-scoped record — survives this view being torn down
    /// and recreated by tab switches / navigation push-pop, unlike any
    /// `@State` declared on the view itself or on this modifier.
    private var alreadyFailedThisSession: Bool {
        networkStatusService.hasFailed(tabKey: tabKey)
    }

    func body(content viewContent: Content) -> some View {
        Group {
            // Trust the durable per-tab record first: a freshly recreated
            // view's own `viewModel.state` starts back at `.idle` even when
            // this tab already failed last time it was visible, so
            // `isUnreachable` alone (a snapshot of the *new* view model)
            // can't be the gate — it would show a stale loading spinner
            // forever instead of the offline state. Once the caller's own
            // state reports `.loaded`, that's authoritative and clears it.
            if alreadyFailedThisSession, !isLoaded {
                offlineState
            } else {
                viewContent
            }
        }
        .task {
            guard !alreadyFailedThisSession else { return }
            await onRetry()
        }
        .onChange(of: isUnreachable) { _, unreachable in
            if unreachable {
                networkStatusService.markFailed(tabKey: tabKey)
                networkStatusService.reportUnreachable()
            }
        }
        .onChange(of: isLoaded) { _, loaded in
            if loaded {
                networkStatusService.clearFailed(tabKey: tabKey)
                networkStatusService.reportReachable()
            }
        }
    }

    /// Compact by necessity: this renders below the category picker bar, so
    /// it only has what's left of a watch screen after the clock and that
    /// bar. Two short lines instead of a full sentence, and the two actions
    /// side by side instead of stacked — stacked 44pt buttons plus a
    /// multi-line sentence didn't fit and forced the system to compress and
    /// overlap them (the bug this replaces).
    private var offlineState: some View {
        VStack(spacing: 4) {
            if showsStatusText {
                Image(systemName: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.4))
                Text("Offline")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text("Can't reach server")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            HStack(spacing: 6) {
                Button {
                    showDownloads()
                } label: {
                    Text("Downloads")
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .frame(minHeight: 44)

                Button {
                    networkStatusService.clearFailed(tabKey: tabKey)
                    Task { await onRetry() }
                } label: {
                    Text("Retry")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
            }
            .padding(.top, showsStatusText ? 4 : 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        // Harmless where this renders full-screen (the drill-down screens
        // that apply `.offlineGate` at the top of their `body`); needed
        // where it renders as List row content instead (the four Library
        // browse tabs, so the shared header above it stays put) — without
        // it the row falls back to the List's default row background
        // instead of blending into the screen's black.
        .listRowBackground(Color.clear)
    }
}

extension View {
    /// Wraps this browse view's content with the shared offline-detection
    /// bridge and UI. See `OfflineGate` for parameter semantics.
    ///
    /// Replaces a per-view `.task { await viewModel.load() }` call — the
    /// caller must NOT also attach its own `.task` that calls `load()`,
    /// or the fetch would fire twice on first appearance.
    func offlineGate(
        tabKey: String,
        isUnreachable: Bool,
        isLoaded: Bool,
        showsStatusText: Bool = true,
        onRetry: @escaping () async -> Void
    ) -> some View {
        modifier(OfflineGate(
            tabKey: tabKey,
            isUnreachable: isUnreachable,
            isLoaded: isLoaded,
            onRetry: onRetry,
            showsStatusText: showsStatusText
        ))
    }
}
