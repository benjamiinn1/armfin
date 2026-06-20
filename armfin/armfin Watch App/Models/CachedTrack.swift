//
//  CachedTrack.swift
//  armfin Watch App
//
//  SwiftData model caching a Jellyfin `Audio` item for offline-capable
//  rendering of `TrackListView`/`NowPlayingView`, per specs/spec.md §1.4.
//
//  `album` is the inverse side of `CachedAlbum.tracks`.
//

import Foundation
import SwiftData

@Model
final class CachedTrack {
    @Attribute(.unique) var id: String   // Jellyfin item GUID
    var name: String
    var indexNumber: Int?
    var discNumber: Int?
    var durationTicks: Int64        // Jellyfin ticks: 10,000,000 ticks/sec
    var container: String?
    var codec: String?
    var bitrate: Int?
    var lastPlayedDate: Date?       // drives LRU eviction, see spec.md §5.1
    var lastRefreshed: Date
    var album: CachedAlbum?

    var runtimeSeconds: Double { Double(durationTicks) / 10_000_000 }

    init(id: String, name: String, indexNumber: Int? = nil, discNumber: Int? = nil,
         durationTicks: Int64, container: String? = nil, codec: String? = nil,
         bitrate: Int? = nil, lastRefreshed: Date = .now) {
        self.id = id
        self.name = name
        self.indexNumber = indexNumber
        self.discNumber = discNumber
        self.durationTicks = durationTicks
        self.container = container
        self.codec = codec
        self.bitrate = bitrate
        self.lastRefreshed = lastRefreshed
    }
}
