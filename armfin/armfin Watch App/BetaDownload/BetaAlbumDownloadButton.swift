import SwiftUI
import SwiftData

struct BetaAlbumDownloadButton: View {
    let albumId: String
    let albumName: String
    let artistName: String
    let serverURL: String
    let userId: String
    let accessToken: String

    @Query private var allBetaItems: [BetaDownloadItem]

    @State private var showRemoveConfirmation = false
    @State private var isDownloading = false

    private var albumItems: [BetaDownloadItem] {
        allBetaItems.filter { $0.albumId == albumId }
    }

    private var state: AlbumDownloadState {
        guard !albumItems.isEmpty else { return .none }

        let completed = albumItems.filter { $0.status == .completed }.count
        let active = albumItems.filter { $0.status == .queued || $0.status == .downloading }.count

        if active > 0 { return .downloading }
        if completed == albumItems.count { return .completed }
        if completed > 0 { return .partial }
        return .mixed
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
        .disabled(isDownloading)
        .accessibilityLabel(accessibilityText)
        .confirmationDialog(
            "Remove Album Downloads",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) {
                BetaDownloadManager.shared.removeAlbumDownloads(albumId: albumId)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all downloaded files for \(albumName).")
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .none:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.white.opacity(0.3))
        case .downloading:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .partial:
            Image(systemName: "arrow.down.circle.dotted")
                .foregroundStyle(.blue.opacity(0.6))
        case .mixed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var accessibilityText: String {
        switch state {
        case .none: return "Download Album"
        case .downloading: return "Album Downloading"
        case .completed: return "Album Downloaded"
        case .partial: return "Album Partially Downloaded"
        case .mixed: return "Album Download Issues"
        }
    }

    private func handleTap() {
        switch state {
        case .none, .mixed:
            isDownloading = true
            Task {
                await BetaDownloadManager.shared.downloadAlbum(
                    albumId: albumId,
                    albumName: albumName,
                    artistName: artistName,
                    serverURL: serverURL,
                    userId: userId,
                    accessToken: accessToken
                )
                isDownloading = false
            }
        case .completed, .partial:
            showRemoveConfirmation = true
        case .downloading:
            BetaDownloadManager.shared.removeAlbumDownloads(albumId: albumId)
        }
    }
}
