import SwiftUI
import SwiftData

struct SettingsView: View {
    var onSignOut: (() -> Void)?

    @Environment(\.playbackEngine) private var playbackEngine
    @Environment(\.nowPlayingManager) private var nowPlayingManager
    @Environment(\.modelContext) private var modelContext

    @Query private var allBetaDownloads: [BetaDownloadItem]

    @State private var showSignOutConfirmation = false
    @State private var showRemoveAllDownloadsConfirmation = false
    @State private var showFactoryResetConfirmation = false

    private var completedDownloadCount: Int {
        allBetaDownloads.filter { $0.statusRaw == BetaDownloadStatus.completed.rawValue }.count
    }

    var body: some View {
        List {
            Section {
                Button {
                    showSignOutConfirmation = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 24)
                        Text("Sign Out")
                            .font(.footnote)
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(Color.white.opacity(0.06))

            Section {
                Button {
                    showRemoveAllDownloadsConfirmation = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "trash")
                            .font(.footnote)
                            .foregroundStyle(.red.opacity(0.7))
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remove All Downloads")
                                .font(.footnote)
                                .foregroundStyle(.white)
                            if completedDownloadCount > 0 {
                                Text("\(completedDownloadCount) downloaded")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(completedDownloadCount == 0)
                .opacity(completedDownloadCount == 0 ? 0.4 : 1)
            }
            .listRowBackground(Color.white.opacity(0.06))

            Section {
                Button {
                    showFactoryResetConfirmation = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Factory Reset")
                                .font(.footnote)
                                .foregroundStyle(.red)
                            Text("Deletes everything")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(Color.white.opacity(0.06))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.black)
        .confirmationDialog(
            "Sign Out",
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will stop playback and sign you out.")
        }
        .confirmationDialog(
            "Remove All Downloads?",
            isPresented: $showRemoveAllDownloadsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) {
                BetaDownloadManager.shared.cancelAll()
                BetaDownloadManager.shared.removeAllCompleted()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all downloaded music files. You will need to re-download them.")
        }
        .confirmationDialog(
            "Factory Reset?",
            isPresented: $showFactoryResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                factoryReset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all downloaded music, cached data, and sign you out. This cannot be undone.")
        }
    }

    private func signOut() {
        playbackEngine.stop()
        nowPlayingManager.clearNowPlaying()

        let descriptor = FetchDescriptor<ServerConfiguration>()
        if let configs = try? modelContext.fetch(descriptor) {
            for config in configs {
                modelContext.delete(config)
            }
            try? modelContext.save()
        }

        try? KeychainStore().delete()
        onSignOut?()
    }

    private func factoryReset() {
        playbackEngine.stop()
        nowPlayingManager.clearNowPlaying()
        BetaDownloadManager.shared.cancelAll()

        ArmfinApp.nukeAllLocalData()

        let deleteTypes: [any PersistentModel.Type] = [
            BetaDownloadItem.self, CachedTrack.self, CachedAlbum.self,
            CachedArtist.self, ServerConfiguration.self
        ]
        for type in deleteTypes {
            try? modelContext.delete(model: type)
        }
        try? modelContext.save()

        onSignOut?()
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: [BetaDownloadItem.self], inMemory: true)
}
