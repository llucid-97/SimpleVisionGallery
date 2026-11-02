#if os(visionOS)
import CoreLocation
import Foundation
@preconcurrency import Photos
import UniformTypeIdentifiers

/// PhotoKit-only operations. Persistent storage never contains a PHAsset or a Photos token.
nonisolated enum GalleryVaultPhotoLibrary {
    struct Prepared: @unchecked Sendable {
        let record: GalleryVaultRecord
        let resources: [PHAssetResource]
    }

    static func requireFullAccess() throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw GalleryVaultTransferError.fullAccessRequired
        }
    }

    static func prepare(_ asset: PHAsset, sourceAlbumID: String?, sourcePosition: Int?) throws -> Prepared {
        try requireFullAccess()
        guard asset.mediaType == .image || asset.mediaType == .video,
              asset.canPerform(.delete) else { throw GalleryVaultTransferError.unsupportedItem }
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { throw GalleryVaultTransferError.missingResources }
        // PhotoKit does not promise a complete editing-history round trip for adjustment resources.
        // Keep the Photos original until that case can be restored without loss.
        let editingTypes: Set<PHAssetResourceType> = [.fullSizePhoto, .fullSizeVideo, .adjustmentData,
            .adjustmentBasePhoto, .fullSizePairedVideo, .adjustmentBasePairedVideo, .adjustmentBaseVideo]
        guard !resources.contains(where: { editingTypes.contains($0.type) }),
              PHAssetCreationRequest.supportsAssetResourceTypes(resources.map { NSNumber(value: $0.type.rawValue) })
        else { throw GalleryVaultTransferError.unsupportedResources }
        let parents = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var albums: [GalleryVaultAlbum] = []
        albums.reserveCapacity(parents.count)
        for i in 0..<parents.count {
            let parent = parents.object(at: i)
            albums.append(GalleryVaultAlbum(id: parent.localIdentifier,
                title: parent.localizedTitle ?? "Album",
                position: parent.localIdentifier == sourceAlbumID ? sourcePosition : nil))
        }
        let descriptors = resources.map {
            GalleryVaultResource(id: UUID(), type: $0.type.rawValue,
                filename: $0.originalFilename, uniformTypeIdentifier: $0.uniformTypeIdentifier)
        }
        let primaryName = descriptors.first(where: { $0.type == PHAssetResourceType.photo.rawValue || $0.type == PHAssetResourceType.video.rawValue })?.filename ?? descriptors[0].filename
        return Prepared(record: GalleryVaultRecord(id: UUID(), sourceIdentifier: asset.localIdentifier,
            filename: primaryName, mediaType: asset.mediaType.rawValue, mediaSubtypes: asset.mediaSubtypes.rawValue,
            pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, duration: asset.duration,
            creationDate: asset.creationDate, modificationDate: asset.modificationDate,
            latitude: asset.location?.coordinate.latitude, longitude: asset.location?.coordinate.longitude,
            isFavorite: asset.isFavorite, albums: albums, resources: descriptors,
            state: .copiedAwaitingDeletion, restoredIdentifier: nil), resources: resources)
    }

    static func isSameVersion(_ asset: PHAsset, as record: GalleryVaultRecord) -> Bool {
        guard asset.localIdentifier == record.sourceIdentifier, asset.canPerform(.delete),
              asset.mediaType.rawValue == record.mediaType,
              asset.mediaSubtypes.rawValue == record.mediaSubtypes,
              asset.creationDate == record.creationDate, asset.modificationDate == record.modificationDate,
              asset.isFavorite == record.isFavorite,
              asset.location?.coordinate.latitude == record.latitude,
              asset.location?.coordinate.longitude == record.longitude,
              asset.pixelWidth == record.pixelWidth, asset.pixelHeight == record.pixelHeight,
              asset.duration == record.duration else { return false }
        let now = PHAssetResource.assetResources(for: asset).map {
            "\($0.type.rawValue)\u{0}\($0.originalFilename)\u{0}\($0.uniformTypeIdentifier)"
        }.sorted()
        let before = record.resources.map {
            "\($0.type)\u{0}\($0.filename)\u{0}\($0.uniformTypeIdentifier)"
        }.sorted()
        guard now == before else { return false }
        let parents = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var currentParents = Set<String>()
        for i in 0..<parents.count { currentParents.insert(parents.object(at: i).localIdentifier) }
        return currentParents == Set(record.albums.map(\.id))
    }

    static func fetch(ids: [String]) throws -> [String: PHAsset] {
        try requireFullAccess()
        guard !ids.isEmpty else { return [:] }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var result: [String: PHAsset] = [:]
        result.reserveCapacity(fetch.count)
        for i in 0..<fetch.count { let asset = fetch.object(at: i); result[asset.localIdentifier] = asset }
        return result
    }

    static func delete(_ sources: [(PHAsset, GalleryVaultRecord)]) async throws {
        guard !sources.isEmpty else { return }
        var valid = false
        try await PHPhotoLibrary.shared().performChanges {
            // Recheck immediately before requesting deletion; PhotoKit does not offer an
            // atomic compare-and-delete if another app edits the same asset concurrently.
            let ids = sources.map { $0.1.sourceIdentifier }
            guard let live = try? fetch(ids: ids), sources.allSatisfy({ pair in
                guard let current = live[pair.1.sourceIdentifier] else { return false }
                return isSameVersion(current, as: pair.1)
            }) else { return }
            let assets = sources.compactMap { live[$0.1.sourceIdentifier] }
            guard assets.count == sources.count else { return }
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
            valid = true
        }
        guard valid else { throw GalleryVaultTransferError.changedOriginal }
    }

    static func usableParents(_ record: GalleryVaultRecord, omittingUnavailable: Bool = false) throws -> [(GalleryVaultAlbum, PHAssetCollection)] {
        let ids = record.albums.map(\.id)
        let fetched = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: ids, options: nil)
        var byID: [String: PHAssetCollection] = [:]
        for i in 0..<fetched.count { let album = fetched.object(at: i); byID[album.localIdentifier] = album }
        return try record.albums.compactMap { album in
            guard let collection = byID[album.id], collection.canPerform(.addContent) else {
                if omittingUnavailable { return nil }
                throw GalleryVaultTransferError.albumUnavailable(album.title)
            }
            return (album, collection)
        }
    }
}

nonisolated enum GalleryVaultTransferError: LocalizedError {
    case fullAccessRequired, unsupportedItem, unsupportedResources, missingResources, locked, busy
    case albumUnavailable(String), changedOriginal, missingOriginal, photoRequestFailed, interruptedRestore
    case journalFailed, importFailed, cancelled, alreadyInVault, pendingCopyUnavailable

    var errorDescription: String? {
        switch self {
        case .fullAccessRequired: return "Full Photos access is required to safely move or restore private items."
        case .unsupportedItem: return "Photos cannot delete this item, so it was left in your library."
        case .unsupportedResources: return "This item's original and edits cannot yet be restored safely; it was left in Photos."
        case .missingResources: return "Photos did not provide all files for this item. The original was kept."
        case .locked: return "Unlock the private vault to continue."
        case .busy: return "A private vault operation is already in progress."
        case .albumUnavailable(let title): return "The album ‘\(title)’ is missing or cannot be edited. The vault copy was kept."
        case .changedOriginal: return "An item changed in Photos during the move. Its original was kept."
        case .missingOriginal: return "An item could not be found in Photos. The vault copy was kept."
        case .photoRequestFailed: return "Photos could not provide the complete item. The original was kept."
        case .interruptedRestore: return "A previous restore has an uncertain result. The vault copy was kept; check Photos before trying again."
        case .journalFailed: return "The vault could not save its recovery record. The original was kept."
        case .importFailed: return "Photos could not confirm the restored item. The vault copy was kept."
        case .cancelled: return "The move was stopped."
        case .alreadyInVault: return "This photo already has a vault copy. Its original was kept."
        case .pendingCopyUnavailable: return "This saved copy is no longer waiting for removal from Photos. Nothing was discarded."
        }
    }
}
#endif
