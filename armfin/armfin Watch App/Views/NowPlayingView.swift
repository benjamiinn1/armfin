import SwiftUI
import SwiftData
import WatchKit

struct NowPlayingView: View {
    let initialTrack: NowPlayingTrack

    @Environment(\.playbackEngine) private var playbackEngine
    @Environment(\.nowPlayingManager) private var nowPlayingManager

    @State private var showRemoveConfirmation = false

    private var track: NowPlayingTrack {
        nowPlayingManager.currentTrack ?? initialTrack
    }

    init(track: NowPlayingTrack) {
        self.initialTrack = track
    }

    /// Local-cache-first artwork resolution, mirroring
    /// `BetaDownloadsView.albumArtURL(albumId:)`. When this track is playing
    /// from a completed download, `PlaybackEngine` resolved it to the local
    /// audio file — so prefer the matching locally cached artwork (written
    /// by `BetaDownloadManager` alongside the audio) over the remote
    /// `track.artworkURL`, falling back to remote if no cached file exists
    /// (e.g. the track completed before this artwork-caching feature shipped).
    private var resolvedArtworkURL: URL? {
        guard let albumId = track.albumId, !albumId.isEmpty else {
            return track.artworkURL
        }

        let cachedFile = BetaDownloadManager.artworkFileURL(forAlbumId: albumId)
        if FileManager.default.fileExists(atPath: cachedFile.path) {
            return cachedFile
        }

        return track.artworkURL
    }

    /// Read live from the engine, which is `@Observable`, so the transport
    /// controls always reflect what the player is actually doing. Reading a
    /// republished copy off `NowPlayingManager` is what made this screen lie.
    private var playbackState: PlaybackState {
        playbackEngine.currentState
    }

    private var isPlaying: Bool {
        playbackState == .playing
    }

    private var isBuffering: Bool {
        playbackState == .loading
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)

            artworkSection

            Spacer().frame(height: 12)

            metadataText

            if let errorMessage = playbackErrorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }

            Spacer()

            transportControls

            Spacer(minLength: 12)
        }
        .background { VolumeControl().allowsHitTesting(false).opacity(0) }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                downloadToggleButton
            }
        }
        .confirmationDialog(
            "Remove Download",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                removeDownload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete the downloaded file.")
        }
    }

    // MARK: - Artwork

    private var artworkSection: some View {
        // `JellyfinImage` already branches on file:// vs remote vs nil —
        // reusing it here (instead of the view's own AsyncImage) is what
        // makes the local-cache-first artwork in `resolvedArtworkURL` work
        // with no new decoding logic.
        JellyfinImage(url: resolvedArtworkURL, icon: "music.note", cornerRadius: 12)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 100, maxHeight: 100)
            .overlay {
                if isBuffering {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.black.opacity(0.4))
                    ProgressView()
                        .tint(.white)
                }
            }
    }

    // MARK: - Metadata

    private var metadataText: some View {
        VStack(spacing: 3) {
            Text(track.title)
                .font(.body)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .lineLimit(2)

            Text(track.artistName)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
    }

    // MARK: - Transport

    private var transportControls: some View {
        HStack(spacing: 28) {
            Button {
                WKInterfaceDevice.current().play(.click)
                playbackEngine.returnToPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.body)
                    .contentShape(Rectangle())
                    .frame(width: 50, height: 50)
            }
            .buttonStyle(TransportButtonStyle())
            .accessibilityLabel("Previous Track")

            Button {
                WKInterfaceDevice.current().play(.click)
                playbackEngine.togglePlayPause()
            } label: {
                Group {
                    if isBuffering {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                }
                .frame(width: 56, height: 56)
                .background(Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(TransportButtonStyle())
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            Button {
                WKInterfaceDevice.current().play(.click)
                playbackEngine.advanceToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.body)
                    .contentShape(Rectangle())
                    .frame(width: 50, height: 50)
            }
            .buttonStyle(TransportButtonStyle())
            .accessibilityLabel("Next Track")
        }
        .foregroundStyle(.white)
    }

    // MARK: - Download toggle (toolbar)

    /// `.id(track.trackId)` is required, not cosmetic: `DownloadItemReader`
    /// captures its predicate at init, so without a fresh view identity the
    /// button would keep showing the previous track's download state as the
    /// queue advances.
    private var downloadToggleButton: some View {
        DownloadItemReader(jellyfinId: track.trackId) { item in
            downloadToggleButton(status: item?.status)
        }
        .id(track.trackId)
    }

    private func downloadToggleButton(status betaDownloadStatus: BetaDownloadStatus?) -> some View {
        Button {
            toggleBetaDownload(status: betaDownloadStatus)
        } label: {
            Group {
                switch betaDownloadStatus {
                case nil:
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.white.opacity(0.5))
                case .queued:
                    Image(systemName: "clock.circle.fill")
                        .foregroundStyle(.blue.opacity(0.7))
                case .downloading:
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .font(.system(size: 15))
            .frame(width: 44, height: 44)
        }
        .accessibilityLabel(betaDownloadAccessibilityLabel(for: betaDownloadStatus))
    }

    private func betaDownloadAccessibilityLabel(for status: BetaDownloadStatus?) -> String {
        switch status {
        case nil: return "Download Track"
        case .queued: return "Download Queued"
        case .downloading: return "Downloading"
        case .completed: return "Remove Download"
        case .failed: return "Download Failed, Retry"
        }
    }


    private func toggleBetaDownload(status betaDownloadStatus: BetaDownloadStatus?) {
        switch betaDownloadStatus {
        case .queued, .downloading:
            BetaDownloadManager.shared.cancel(jellyfinId: track.trackId)
            return
        case .completed:
            showRemoveConfirmation = true
            return
        case .failed:
            BetaDownloadManager.shared.retry(jellyfinId: track.trackId)
            return
        case nil:
            break
        }

        BetaDownloadManager.shared.download(track: TrackInfo(
            jellyfinId: track.trackId,
            trackName: track.title,
            artistName: track.artistName,
            albumName: track.albumName,
            albumId: track.albumId ?? "",
            durationTicks: Int64(track.durationSeconds * 10_000_000),
            indexNumber: track.indexNumber,
            discNumber: track.discNumber
        ))
    }

    private func removeDownload() {
        BetaDownloadManager.shared.removeCompleted(jellyfinId: track.trackId)
    }

    private var playbackErrorMessage: String? {
        if case .failed(let message) = playbackState {
            return message
        }
        return nil
    }
}

// MARK: - Transport Button Style

private struct TransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
    }
}

#Preview {
    NowPlayingView(
        track: NowPlayingTrack(
            trackId: "track-id",
            title: "Example Track",
            artistName: "Example Artist",
            albumName: "Example Album",
            durationSeconds: 180
        )
    )
    .modelContainer(for: [BetaDownloadItem.self], inMemory: true)
}
