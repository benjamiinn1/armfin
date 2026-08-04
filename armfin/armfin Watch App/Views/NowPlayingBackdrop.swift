import SwiftUI

/// Full-bleed album art behind the Now Playing screen.
///
/// Its only input is the resolved artwork URL, deliberately, and that is the
/// half of the arrangement that keeps this screen cheap. The other half is
/// that `PlaybackProgressRing` reads elapsed time itself rather than being
/// handed it: if the 1 Hz snapshot were read in `NowPlayingView.body`, every
/// tick would re-run this view too — a `fileExists` check and a full-screen
/// image decode once per second, which is exactly what soul.md §2.3 forbids.
/// As built, the backdrop draws once per track and then sits still.
///
/// This is a deliberate, user-requested departure from soul.md §3.1's pure
/// black rule, which was written for the list and browse screens. The scrim
/// below keeps most of the panel dark — both so white text stays legible over
/// arbitrary cover art, and so the OLED cost stays closer to black than to a
/// fully lit screen.
struct NowPlayingBackdrop: View {
    let artworkURL: URL?

    var body: some View {
        ZStack {
            // Base layer, so a missing or still-loading image is black rather
            // than whatever the parent happens to be.
            Color.black

            JellyfinImage(url: artworkURL, cornerRadius: 0, placeholder: .blank)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            scrim
        }
        .ignoresSafeArea()
    }

    /// Weighted to follow the content: the title, artist and transport are all
    /// bottom-anchored, so the lower half carries the darkening and the middle
    /// is left as clear as it can be. The top stop is not zero because the
    /// system clock and the download button sit up there, and neither can be
    /// given a shadow from here.
    ///
    /// Tuned against light cover art — dark art needs far less help, so erring
    /// heavy is the safe direction.
    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.50), location: 0.00),
                .init(color: .black.opacity(0.26), location: 0.22),
                .init(color: .black.opacity(0.34), location: 0.50),
                .init(color: .black.opacity(0.88), location: 1.00)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
