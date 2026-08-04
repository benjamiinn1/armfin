import SwiftUI
import WatchKit

/// What to draw when there is no artwork to draw.
enum JellyfinImagePlaceholder {
    /// A faint rounded tile with the fallback icon. Correct at row and grid
    /// size, where it reads as "art goes here".
    case tile
    /// Nothing at all. Required for the full-screen Now Playing backdrop: at
    /// that size the tile's `white.opacity(0.08)` fill stops being a hint and
    /// becomes a lit dark-gray screen, which soul.md §3.1 exists to prevent.
    case blank
}

/// Loads and displays a Jellyfin item image via `AsyncImage`, falling back
/// to the provided `systemName` icon on failure or while loading.
/// Supports both remote (http/https) and local (file://) URLs — local
/// files are loaded synchronously via `UIImage(contentsOfFile:)` since
/// `AsyncImage` may not reliably handle `file://` on watchOS.
struct JellyfinImage: View {
    let url: URL?
    let iconSystemName: String
    let cornerRadius: CGFloat
    let placeholderStyle: JellyfinImagePlaceholder

    init(
        url: URL?,
        icon: String = "music.note",
        cornerRadius: CGFloat = 4,
        placeholder: JellyfinImagePlaceholder = .tile
    ) {
        self.url = url
        self.iconSystemName = icon
        self.cornerRadius = cornerRadius
        self.placeholderStyle = placeholder
    }

    var body: some View {
        if let url {
            if url.isFileURL, let uiImage = UIImage(contentsOfFile: url.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .artworkClip(cornerRadius: cornerRadius)
            } else if !url.isFileURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        placeholder
                    }
                }
                .artworkClip(cornerRadius: cornerRadius)
            } else {
                placeholder
            }
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch placeholderStyle {
        case .tile:
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.white.opacity(0.08))
                .overlay {
                    Image(systemName: iconSystemName)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                }
        case .blank:
            Color.black
        }
    }
}

private extension View {
    /// A zero corner radius means "fill the frame", so clip to bounds rather
    /// than masking with a degenerate rounded rectangle.
    @ViewBuilder
    func artworkClip(cornerRadius: CGFloat) -> some View {
        if cornerRadius > 0 {
            clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            clipped()
        }
    }
}
