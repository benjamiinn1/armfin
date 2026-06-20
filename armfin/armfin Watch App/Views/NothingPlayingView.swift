import SwiftUI
import SwiftData

struct NothingPlayingView: View {
    let hasOfflineContent: Bool
    var shuffleDownloadsAction: (() -> Void)? = nil
    var isDownloadsLoading: Bool = false
    var errorMessage: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            if hasOfflineContent {
                shuffleDownloadsButton
            } else {
                idleLayout
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }

    private var shuffleDownloadsButton: some View {
        Button {
            shuffleDownloadsAction?()
        } label: {
            HStack(spacing: 6) {
                if isDownloadsLoading {
                    ProgressView()
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "shuffle")
                        .font(.system(size: 11))
                }
                Text("Shuffle Downloads")
                    .font(.caption2)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(isDownloadsLoading)
        .padding(.horizontal, 16)
        .accessibilityLabel("Shuffle Downloads")
    }

    private var idleLayout: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.2))
            Text("Nothing playing")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}
