import SwiftUI
import WatchKit

/// Row chrome shared by every Downloads screen. Kept in one file so the
/// list, album and artist screens can't drift apart visually or in tap-target
/// size (soul.md §3.4, §4.1).

/// Minimum row height for anything tappable in Downloads. watchOS HIG floor is
/// 38 pt; armfin uses 44 for gloved/sweaty fingers (soul.md §3.4).
let downloadsRowMinHeight: CGFloat = 44

struct DownloadedTrackRow: View {
    let item: BetaDownloadItem
    let artworkURL: URL?
    let subtitle: String

    var body: some View {
        HStack(spacing: 8) {
            JellyfinImage(url: artworkURL, icon: "music.note")
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.trackName)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "play.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        }
        .frame(minHeight: downloadsRowMinHeight)
        .contentShape(Rectangle())
    }
}

/// Navigational row for a downloaded album or artist. Deliberately carries no
/// play affordance: tapping drills in, which is the whole point of the
/// hierarchy. Playing the group is the explicit `DownloadedPlayAllRow` one
/// level down.
struct DownloadedGroupRow: View {
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let icon: String
    var isCircular: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            JellyfinImage(url: artworkURL, icon: icon, cornerRadius: isCircular ? 14 : 4)
                .frame(width: 28, height: 28)
                .clipShape(isCircular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4)))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.25))
        }
        .frame(minHeight: downloadsRowMinHeight)
        .contentShape(Rectangle())
    }
}

/// Play / shuffle affordance at the top of an album or artist's downloads.
/// Replaces the old behaviour where tapping the group row itself started
/// playback — the group row now navigates, and this is the explicit way to
/// play the whole thing.
struct DownloadedPlayAllRow: View {
    let count: Int
    /// `true` when the user asked to shuffle.
    let onPlay: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button {
                onPlay(false)
            } label: {
                Label("Play All", systemImage: "play.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, minHeight: downloadsRowMinHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                onPlay(true)
            } label: {
                Image(systemName: "shuffle")
                    .font(.footnote)
                    .foregroundStyle(.blue)
                    .frame(width: downloadsRowMinHeight, height: downloadsRowMinHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shuffle \(count) song\(count == 1 ? "" : "s")")
        }
    }
}

/// Shuffles a whole list from the top of it.
///
/// Separate from `DownloadedPlayAllRow` because the Songs tab needs no "Play
/// All" — tapping any song already queues the entire list in order from that
/// point — but had no way to shuffle at all. Styled to match the "Shuffle All"
/// rows in the online track lists.
struct DownloadedShuffleAllRow: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "shuffle")
                    .font(.footnote)
                    .foregroundStyle(.blue)
                Text("Shuffle All")
                    .font(.footnote)
                    .foregroundStyle(.blue)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: downloadsRowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shuffle all \(count) downloaded song\(count == 1 ? "" : "s")")
    }
}

struct DownloadsEmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.white.opacity(0.2))
            Text(title)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.25))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Long-press a downloaded song to remove it. This is the only removal
    /// gesture — there is deliberately no `.onDelete`.
    ///
    /// The Downloads lists live inside a paged `TabView`, which claims
    /// horizontal drags for switching pages. Swipe-to-delete lost that fight
    /// twice over: a swipe firm enough to reveal the trash also paged to the
    /// next tab, and simply paging between tabs dragged the trash can
    /// half-open on every row it passed. A long press competes with nothing.
    func removeDownloadOnLongPress(
        _ item: BetaDownloadItem,
        pending: Binding<BetaDownloadItem?>
    ) -> some View {
        onLongPressGesture {
            // Confirms the press registered, since nothing moves on screen
            // until the dialog appears.
            WKInterfaceDevice.current().play(.click)
            pending.wrappedValue = item
        }
    }

    /// Confirmation for `removeDownloadOnLongPress`. Attach once per screen.
    func removeDownloadConfirmation(item: Binding<BetaDownloadItem?>) -> some View {
        confirmationDialog(
            "Remove Download",
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: item.wrappedValue
        ) { pending in
            Button("Remove", role: .destructive) {
                BetaDownloadManager.shared.removeCompleted(jellyfinId: pending.jellyfinId)
                item.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) { item.wrappedValue = nil }
        } message: { pending in
            Text("This deletes \(pending.trackName) from this watch.")
        }
    }

    /// Surfaces a failed playback start instead of silently dropping it
    /// (soul.md §4.3). Binding is cleared when the alert is dismissed.
    func downloadStartFailureAlert(message: Binding<String?>) -> some View {
        alert(
            "Can't Play",
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            )
        ) {
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
