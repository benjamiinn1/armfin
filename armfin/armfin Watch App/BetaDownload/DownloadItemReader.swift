import SwiftUI
import SwiftData

/// Reads the download row for exactly one track and hands it to `content`.
///
/// Replaces the pattern of querying every `BetaDownloadItem` and scanning the
/// array for a match — that cost O(all downloads) per view body, once per
/// visible row in a track list and once per second on Now Playing while audio
/// plays (soul.md §1.1, §2.3). The predicate pushes the match into SwiftData.
///
/// A `@Query`'s descriptor is captured at init, so a caller whose track id can
/// change under a stable view identity — Now Playing, as the queue advances —
/// must attach `.id(trackId)` to force a fresh fetch.
struct DownloadItemReader<Content: View>: View {
    @Query private var matches: [BetaDownloadItem]

    private let content: (BetaDownloadItem?) -> Content

    init(jellyfinId: String, @ViewBuilder content: @escaping (BetaDownloadItem?) -> Content) {
        _matches = Query(
            filter: #Predicate<BetaDownloadItem> { $0.jellyfinId == jellyfinId }
        )
        self.content = content
    }

    var body: some View {
        content(matches.first)
    }
}
