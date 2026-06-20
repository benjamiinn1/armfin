import SwiftUI
import SwiftData

struct BetaDownloadButton: View {
    let jellyfinId: String
    var onDownloadNew: (() -> Void)? = nil

    @Query private var allBetaItems: [BetaDownloadItem]

    private var item: BetaDownloadItem? {
        allBetaItems.first { $0.jellyfinId == jellyfinId }
    }

    var body: some View {
        Button {
            handleTap()
        } label: {
            icon
                .font(.callout)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var icon: some View {
        switch item?.status {
        case nil:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.white.opacity(0.3))
        case .queued:
            Image(systemName: "clock.circle.fill")
                .foregroundStyle(.blue.opacity(0.6))
        case .downloading:
            if let item, item.totalBytes > 0 {
                CircularProgressView(progress: item.progress)
            } else {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
            }
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var accessibilityText: String {
        switch item?.status {
        case nil: return "Download"
        case .queued: return "Download Queued"
        case .downloading: return "Downloading"
        case .completed: return "Downloaded"
        case .failed: return "Download Failed"
        }
    }

    private func handleTap() {
        guard let item else {
            onDownloadNew?()
            return
        }

        switch item.status {
        case .completed:
            BetaDownloadManager.shared.removeCompleted(jellyfinId: jellyfinId)
        case .failed:
            BetaDownloadManager.shared.retry(jellyfinId: jellyfinId)
        case .queued, .downloading:
            BetaDownloadManager.shared.cancel(jellyfinId: jellyfinId)
        }
    }
}

private struct CircularProgressView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.blue.opacity(0.2), lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
    }
}
