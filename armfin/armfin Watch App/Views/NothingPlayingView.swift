import SwiftUI
import SwiftData

struct NothingPlayingView: View {
    var errorMessage: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            idleLayout

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
