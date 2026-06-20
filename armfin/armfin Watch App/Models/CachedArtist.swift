//
//  CachedArtist.swift
//  armfin Watch App
//
//  SwiftData model caching a Jellyfin `MusicArtist` item for offline-capable
//  rendering of `ArtistListView`, per specs/spec.md §1.4.
//
//  The `albums` relationship below is live: deleting a `CachedArtist`
//  cascades to delete its `CachedAlbum` rows, mirrored by `CachedAlbum`'s
//  own `inverse` declaration of this relationship.
//

import Foundation
import SwiftData

@Model
final class CachedArtist {
    @Attribute(.unique) var id: String   // Jellyfin item GUID
    var name: String
    var sortName: String
    var imageTag: String?
    var lastRefreshed: Date

    @Relationship(deleteRule: .cascade, inverse: \CachedAlbum.artist)
    var albums: [CachedAlbum] = []

    init(id: String, name: String, sortName: String, imageTag: String? = nil, lastRefreshed: Date = .now) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.imageTag = imageTag
        self.lastRefreshed = lastRefreshed
    }
}
