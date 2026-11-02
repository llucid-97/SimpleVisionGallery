import Foundation

/// Identifying metadata is stored only inside an encrypted record.
nonisolated struct GalleryVaultAlbum: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var position: Int?
}

nonisolated struct GalleryVaultResource: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var type: Int
    var filename: String
    var uniformTypeIdentifier: String
}

nonisolated struct GalleryVaultRecord: Codable, Equatable, Sendable, Identifiable {
    nonisolated enum State: String, Codable, Sendable {
        case copiedAwaitingDeletion
        case privateItem
        case restoring
    }

    var id: UUID
    var sourceIdentifier: String
    var filename: String
    var mediaType: Int
    var mediaSubtypes: UInt
    var pixelWidth: Int
    var pixelHeight: Int
    var duration: Double
    var creationDate: Date?
    var modificationDate: Date?
    var latitude: Double?
    var longitude: Double?
    var isFavorite: Bool
    var albums: [GalleryVaultAlbum]
    var resources: [GalleryVaultResource]
    var state: State
    var restoredIdentifier: String?
}
