import Foundation
#if canImport(Photos)
@preconcurrency import Photos
#endif

@MainActor
final class GalleryMoveHistory {
    static let shared = GalleryMoveHistory()
    static let limit = 3
    private static let defaultsKey = "gallery.recentMoveDestinationIDs.v1"

    private let defaults: UserDefaults
    private var destinationIDs: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        destinationIDs = Array((defaults.stringArray(forKey: Self.defaultsKey) ?? []).prefix(Self.limit))
    }

    func recordSuccessfulMove(to albumID: String) {
        guard !albumID.isEmpty else { return }
        destinationIDs.removeAll { $0 == albumID }
        destinationIDs.insert(albumID, at: 0)
        destinationIDs = Array(destinationIDs.prefix(Self.limit))
        defaults.set(destinationIDs, forKey: Self.defaultsKey)
    }

    func recentAlbums(from albums: [GalleryAlbum], excluding albumID: String?) -> [GalleryAlbum] {
        var seen = Set<String>()
        let byID = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return destinationIDs.compactMap { id in
            guard id != albumID, seen.insert(id).inserted,
                  let album = byID[id],
                  album.collection?.canPerform(.addContent) == true
            else { return nil }
            return album
        }
    }
}
