import SwiftUI
import SwiftData
import WatchKit

struct NowPlayingView: View {
    let initialTrack: NowPlayingTrack

    @Environment(\.playbackEngine) private var playbackEngine
    @Environment(\.nowPlayingManager) private var nowPlayingManager

    @State private var showRemoveConfirmation = false

    /// Resolved off the render path in `.task(id:)` — see `loadArtwork`.
    @State private var artworkURL: URL?

    private var track: NowPlayingTrack {
        nowPlayingManager.currentTrack ?? initialTrack
    }

    init(track: NowPlayingTrack) {
        self.initialTrack = track
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

    /// Metadata and transport are bottom-anchored as one block, so everything
    /// above them is uninterrupted album art. The single leading `Spacer` is
    /// what does it — a trailing one would centre the block instead, which is
    /// what this screen used to do.
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            metadataText

            if let errorMessage = playbackErrorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
                    .shadow(color: .black, radius: 2)
            }

            Spacer().frame(height: 6)

            transportControls
        }
        .padding(.horizontal, 4)
        .padding(.bottom, Self.indexStripOverhang)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Chained rather than nested so `VolumeControl` keeps a stable place in
        // the view tree: its representable schedules a delayed `focus()` on
        // creation, and re-making it would break Digital Crown volume.
        .background { VolumeControl().allowsHitTesting(false).opacity(0) }
        .background { NowPlayingBackdrop(artworkURL: artworkURL) }
        .task(id: track.trackId) { loadArtwork() }
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

    /// Local-cache-first artwork resolution, run once per track instead of on
    /// every body pass.
    ///
    /// When this track is playing from a completed download, `PlaybackEngine`
    /// resolved it to the local audio file — so prefer the matching locally
    /// cached artwork (written by `BetaDownloadManager` alongside the audio)
    /// over the remote `track.artworkURL`, falling back to remote if no cached
    /// file exists (e.g. the track completed before artwork caching shipped).
    ///
    /// This does a `fileExists` check, which is why it lives here and not in a
    /// computed property the body reads: the body now re-runs about once a
    /// second while playing (soul.md §2.3 — no file I/O on the render path).
    private func loadArtwork() {
        let track = self.track

        guard let albumId = track.albumId, !albumId.isEmpty else {
            artworkURL = track.artworkURL
            return
        }

        let cachedFile = BetaDownloadManager.artworkFileURL(forAlbumId: albumId)
        artworkURL = FileManager.default.fileExists(atPath: cachedFile.path)
            ? cachedFile
            : track.artworkURL
    }

    // MARK: - Metadata

    private var metadataText: some View {
        VStack(spacing: 2) {
            Text(track.title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(2)

            Text(track.artistName)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
        // Cover art is arbitrary; the scrim alone can't guarantee contrast
        // against a bright or busy top edge.
        .shadow(color: .black.opacity(0.8), radius: 3)
    }

    // MARK: - Transport

    /// Flexible gaps, fixed diameters. The three buttons need 144 pt between
    /// them; a 40 mm watch is 162 pt wide and this view is inset by 4 on each
    /// side, leaving 154. Fixed spacing tuned on a 49 mm Ultra would clip
    /// there, so the spacers give up their width instead of the tap targets
    /// (soul.md §3.4).
    private var transportControls: some View {
        HStack(spacing: 0) {
            transportButton(
                icon: "backward.fill",
                accessibilityLabel: "Previous Track",
                action: playbackEngine.returnToPrevious
            )

            Spacer(minLength: 4)

            playPauseButton

            Spacer(minLength: 4)

            transportButton(
                icon: "forward.fill",
                accessibilityLabel: "Next Track",
                action: playbackEngine.advanceToNext
            )
        }
        .foregroundStyle(.white)
    }

    /// Skip buttons. The dark disc is what makes a white glyph legible over
    /// unknown artwork — a bare glyph disappears against a light cover.
    private func transportButton(
        icon: String,
        accessibilityLabel: String,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button {
            WKInterfaceDevice.current().play(.click)
            action()
        } label: {
            Image(systemName: icon)
                .font(.body)
                .frame(width: Self.skipButtonDiameter, height: Self.skipButtonDiameter)
                .background(Color.black.opacity(0.35), in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }

    private var playPauseButton: some View {
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
            .frame(width: Self.playButtonDiameter, height: Self.playButtonDiameter)
            .background(Color.black.opacity(0.35), in: Circle())
            .overlay {
                // Reads elapsed time itself, so its 1 Hz updates redraw the
                // ring alone — not this button, and not the artwork behind it.
                PlaybackProgressRing(durationSeconds: track.durationSeconds)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle())
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    /// 44 pt is armfin's tap-target floor (soul.md §3.4), so these double as
    /// both the visual and the hit size.
    private static let skipButtonDiameter: CGFloat = 44
    private static let playButtonDiameter: CGFloat = 56

    /// How far the metadata + transport block is pushed past the bottom of the
    /// page's content area, so it sits just above the paged `TabView`'s index
    /// dots instead of a full strip's width above them.
    ///
    /// Negative padding rather than `.ignoresSafeArea(edges: .bottom)`, which
    /// does nothing in this container. The proof is on screen: the backdrop
    /// already asks to ignore the safe area, and a square cover still renders
    /// uncropped and exactly filling the content area. Had the modifier taken
    /// effect, `.aspectRatio(contentMode: .fill)` would have laid that square
    /// out taller than the screen is wide and cropped its left and right
    /// edges. It doesn't, so the strip is not reachable that way.
    ///
    /// Tuned by eye on a 49 mm Ultra: far enough down to sit just above the
    /// index dots, and no further — the progress ring's lower arc reaches the
    /// dots first, so it is what sets the floor here, not the button's edge.
    private static let indexStripOverhang: CGFloat = -26

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
                    Image(systemName: "arrow.down")
                        .foregroundStyle(.white.opacity(0.7))
                case .queued:
                    Image(systemName: "clock")
                        .foregroundStyle(.blue)
                case .downloading:
                    Image(systemName: "arrow.down")
                        .foregroundStyle(.blue)
                case .completed:
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark")
                        .foregroundStyle(.red)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            // A filled disc instead of a `.circle.fill` glyph: it reads at a
            // smaller size, matches the transport buttons, and holds contrast
            // over artwork. The outer frame keeps the 44 pt tap target that
            // the 28 pt disc would otherwise give up (soul.md §3.4).
            .frame(width: 28, height: 28)
            .background(Color.black.opacity(0.45), in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
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

// MARK: - Progress Ring

/// The song's position, drawn around the play/pause button.
///
/// Reads `nowPlayingManager` itself rather than taking elapsed time as a
/// parameter. That is the whole point of the type: Observation registers the
/// 1 Hz dependency here, so a tick redraws this ring instead of the artwork
/// backdrop and the rest of the screen with it.
///
/// Elapsed time is already published at 1 Hz by the existing periodic time
/// observer, so this adds no new timer (soul.md §2.1). It steps once a second
/// with no animation — a one-second interpolation would be a continuous
/// animation loop for the entire length of every track (soul.md §3.2).
private struct PlaybackProgressRing: View {
    let durationSeconds: Double

    @Environment(\.nowPlayingManager) private var nowPlayingManager

    private static let lineWidth: CGFloat = 3

    /// Clamped because elapsed time can briefly exceed the incoming track's
    /// duration when the queue advances: the snapshot is stamped before the
    /// new item is in the player, so for up to a second it still holds the
    /// outgoing track's position.
    private var progress: Double {
        let elapsed = nowPlayingManager.nowPlayingSnapshot.elapsedTime
        guard elapsed.isFinite else { return 0 }
        return min(max(elapsed / durationSeconds, 0), 1)
    }

    var body: some View {
        // No duration means nothing to measure against — a track that never
        // reported one would otherwise sit at an empty ring forever, which
        // reads as a stalled track rather than an unknown length.
        if durationSeconds > 0 {
            ring
        }
    }

    private var ring: some View {
        ZStack {
            Circle()
                .inset(by: Self.lineWidth / 2)
                .stroke(Color.white.opacity(0.25), lineWidth: Self.lineWidth)

            Circle()
                .inset(by: Self.lineWidth / 2)
                .trim(from: 0, to: progress)
                .stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)
                )
                // Start at 12 o'clock rather than 3 o'clock.
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
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
