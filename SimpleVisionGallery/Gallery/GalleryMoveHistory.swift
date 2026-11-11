import Foundation
#if canImport(Photos)
@preconcurrency import Photos
#endif

@MainActor
final class GalleryMoveHistory {
    static let shared = GalleryMoveHistory()
    static let limit = 3
    private static let defaultsKey = "gallery.recentMoveDestinations.v2"
    private static let legacyKey = "gallery.recentMoveDestinationIDs.v1"
    private static let photosPrefix = "photos:"
    private static let vaultPrefix = "vault:"

    private let defaults: UserDefaults
    private var destinations: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.stringArray(forKey: Self.defaultsKey) {
            destinations = Array(saved.prefix(Self.limit))
        } else {
            destinations = Array((defaults.stringArray(forKey: Self.legacyKey) ?? [])
                .prefix(Self.limit).map { Self.photosPrefix + $0 })
        }
    }

    func recordSuccessfulMove(to albumID: String) {
        record(Self.photosPrefix + albumID, id: albumID)
    }

    func recordSuccessfulVaultMove(to albumID: String) {
        guard albumID != GalleryVaultRecycleBin.id else { return }
        record(Self.vaultPrefix + albumID, id: albumID)
    }

    private func record(_ destination: String, id: String) {
        guard !id.isEmpty else { return }
        destinations.removeAll { $0 == destination }
        destinations.insert(destination, at: 0)
        destinations = Array(destinations.prefix(Self.limit))
        defaults.set(destinations, forKey: Self.defaultsKey)
    }

    /// Resolve saved Photos IDs against editable current albums to omit stale or reserved destinations.
    func recentAlbums(from albums: [GalleryAlbum], excluding albumID: String?) -> [GalleryAlbum] {
        var seen = Set<String>()
        let byID = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return destinations.compactMap { destination in
            guard destination.hasPrefix(Self.photosPrefix) else { return nil }
            let id = String(destination.dropFirst(Self.photosPrefix.count))
            guard id != albumID, seen.insert(id).inserted,
                  let album = byID[id], !GalleryRecycleBin.isRecycleBin(album),
                  album.collection?.canPerform(.addContent) == true
            else { return nil }
            return album
        }
    }

    /// Resolve saved vault IDs only against unlocked destinations, keeping titles out of persistent history.
    func recentVaultAlbums(from albums: [GalleryVaultAlbum], excluding albumID: String?) -> [GalleryVaultAlbum] {
        var seen = Set<String>()
        let byID = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return destinations.compactMap { destination in
            guard destination.hasPrefix(Self.vaultPrefix) else { return nil }
            let id = String(destination.dropFirst(Self.vaultPrefix.count))
            guard id != albumID, id != GalleryVaultRecycleBin.id, seen.insert(id).inserted,
                  let album = byID[id], !GalleryRecycleBin.isRecycleBinTitle(album.title)
            else { return nil }
            return album
        }
    }
}
