//
//  CachedAlbum.swift
//  armfin Watch App
//
//  SwiftData model caching a Jellyfin `MusicAlbum` item for offline-capable
//  rendering of `AlbumListView`, per specs/spec.md §1.4.
//
//  `artist` is the inverse side of `CachedArtist.albums`; `tracks` cascades
//  to `CachedTrack` via its own `inverse` declaration of this relationship.
//

import Foundation
import SwiftData

@Model
final class CachedAlbum {
    @Attribute(.unique) var id: String   // Jellyfin item GUID
    var name: String
    var sortName: String
    var productionYear: Int?
    var imageTag: String?
    var lastRefreshed: Date
    var artist: CachedArtist?

    @Relationship(deleteRule: .cascade, inverse: \CachedTrack.album)
    var tracks: [CachedTrack] = []

    init(id: String, name: String, sortName: String, productionYear: Int? = nil,
         imageTag: String? = nil, lastRefreshed: Date = .now) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.productionYear = productionYear
        self.imageTag = imageTag
        self.lastRefreshed = lastRefreshed
    }
}
