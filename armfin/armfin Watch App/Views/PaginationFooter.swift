import SwiftUI

/// Trailing row of a paginated browse list: a spinner that triggers the next
/// page as it scrolls into view, or a retry row once a page has failed.
///
/// The retry branch is the point of this view. Previously a failed `loadMore`
/// was swallowed and the spinner stayed on screen — indistinguishable from a
/// slow request, and unable to recover on its own, because `.onAppear` won't
/// fire again until the row leaves the screen and comes back (soul.md §4.3).
struct PaginationFooter: View {
    let errorMessage: String?
    let loadMore: () async -> Void

    var body: some View {
        Group {
            if let errorMessage {
                Button {
                    Task { await loadMore() }
                } label: {
                    VStack(spacing: 2) {
                        Text(errorMessage)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                        Text("Tap to retry")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .onAppear {
                        Task { await loadMore() }
                    }
            }
        }
        .listRowBackground(Color.clear)
    }
}
