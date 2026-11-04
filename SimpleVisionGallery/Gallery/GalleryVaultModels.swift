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

/// Frozen confirmation counts and IDs; persisted only inside an encrypted operation intent.
nonisolated struct GalleryAlbumDeletionPlan: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    let albumID: String
    let title: String
    let hadPhotosAlbum: Bool
    let photoIDs: [String]
    let sharedPhotoCount: Int
    let vaultRecords: [GalleryVaultRecord]

    var permanentVaultIDs: Set<UUID> {
        Set(vaultRecords.filter { $0.albums.allSatisfy { $0.id == albumID } }.map(\.id))
    }
}

nonisolated struct GalleryVaultAlbumDeletion: Codable, Equatable, Sendable {
    let plan: GalleryAlbumDeletionPlan
    let deleteItems: Bool
    var photosCommitted = false
}

nonisolated enum GalleryAlbumDeletionError: LocalizedError {
    case changed, interrupted, unreadable, restoring, notDeletable
    var errorDescription: String? {
        switch self {
        case .changed: "The album changed. Review its current items before deleting it."
        case .interrupted: "Review the interrupted album deletion in Private Vault before continuing."
        case .unreadable: "Some vault records could not be read. The album and saved files were kept."
        case .restoring: "Finish restoring the album's private items before deleting it."
        case .notDeletable: "This album cannot be deleted."
        }
    }
}
