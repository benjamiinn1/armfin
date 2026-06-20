import SwiftUI
import WatchKit

/// Loads and displays a Jellyfin item image via `AsyncImage`, falling back
/// to the provided `systemName` icon on failure or while loading.
/// Supports both remote (http/https) and local (file://) URLs — local
/// files are loaded synchronously via `UIImage(contentsOfFile:)` since
/// `AsyncImage` may not reliably handle `file://` on watchOS.
struct JellyfinImage: View {
    let url: URL?
    let iconSystemName: String
    let cornerRadius: CGFloat

    init(url: URL?, icon: String = "music.note", cornerRadius: CGFloat = 4) {
        self.url = url
        self.iconSystemName = icon
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        if let url {
            if url.isFileURL, let uiImage = UIImage(contentsOfFile: url.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
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
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                placeholder
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.white.opacity(0.08))
            .overlay {
                Image(systemName: iconSystemName)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))
            }
    }
}
