#if os(visionOS)
import AVFoundation
import ImageIO
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

    static func prepare(_ asset: PHAsset, sourceAlbumID: String?, sourcePosition: Int?) async throws -> Prepared {
        try requireFullAccess()
        guard asset.mediaType == .image || asset.mediaType == .video,
              asset.canPerform(.delete) else { throw GalleryVaultTransferError.unsupportedItem }
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { throw GalleryVaultTransferError.missingResources }
        let edited = hasEdits(resources)
        let selected = try originals(resources, asset: asset)
        var width = asset.pixelWidth, height = asset.pixelHeight
        var duration = asset.duration
        if edited {
            let input = try await editingInput(asset)
            if asset.mediaType == .image {
                guard let url = input.fullSizeImageURL, let image = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                      let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
                else { throw GalleryVaultTransferError.missingResources }
                (width, height) = [5, 6, 7, 8].contains(input.fullSizeImageOrientation) ? (h, w) : (w, h)
            } else {
                guard let video = input.audiovisualAsset else { throw GalleryVaultTransferError.missingResources }
                let original = try await inspectVideo(video)
                (width, height, duration) = (original.width, original.height, original.duration)
            }
        }
        guard PHAssetCreationRequest.supportsAssetResourceTypes(selected.map { NSNumber(value: $0.type.rawValue) })
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
        let descriptors = selected.map {
            GalleryVaultResource(id: UUID(), type: $0.type.rawValue,
                filename: $0.originalFilename, uniformTypeIdentifier: $0.uniformTypeIdentifier)
        }
        let primaryName = descriptors.first(where: { $0.type == PHAssetResourceType.photo.rawValue || $0.type == PHAssetResourceType.video.rawValue })?.filename ?? descriptors[0].filename
        return Prepared(record: GalleryVaultRecord(id: UUID(), sourceIdentifier: asset.localIdentifier,
            filename: primaryName, mediaType: asset.mediaType.rawValue, mediaSubtypes: asset.mediaSubtypes.rawValue,
            pixelWidth: width, pixelHeight: height, duration: duration,
            creationDate: asset.creationDate, modificationDate: asset.modificationDate,
            latitude: asset.location?.coordinate.latitude, longitude: asset.location?.coordinate.longitude,
            isFavorite: asset.isFavorite, albums: albums, resources: descriptors,
            state: .copiedAwaitingDeletion, restoredIdentifier: nil), resources: selected)
    }

    static func hasEdits(_ resources: [PHAssetResource]) -> Bool {
        resources.contains { [.fullSizePhoto, .fullSizeVideo, .adjustmentData, .adjustmentBasePhoto,
            .fullSizePairedVideo, .adjustmentBasePairedVideo, .adjustmentBaseVideo].contains($0.type) }
    }

    private static func originals(_ resources: [PHAssetResource], asset: PHAsset) throws -> [PHAssetResource] {
        guard hasEdits(resources) else { return resources }
        let paired: Set<PHAssetResourceType> = [.pairedVideo, .fullSizePairedVideo, .adjustmentBasePairedVideo]
        guard !asset.mediaSubtypes.contains(.photoLive), !resources.contains(where: { paired.contains($0.type) })
        else { throw GalleryVaultTransferError.unsupportedResources }
        let originals = resources.filter { [.photo, .video, .alternatePhoto].contains($0.type) }
        let primary: PHAssetResourceType = asset.mediaType == .image ? .photo : .video
        guard originals.count == 1, originals[0].type == primary else { throw GalleryVaultTransferError.unsupportedResources }
        return originals
    }

    private static func inspectVideo(_ video: AVAsset) async throws -> (width: Int, height: Int, duration: Double) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let tracks = try await video.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { throw GalleryVaultTransferError.missingResources }
            let duration = try await video.load(.duration).seconds
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let displayed = size.applying(transform)
            try Task.checkCancellation()
            return (Int(abs(displayed.width).rounded()), Int(abs(displayed.height).rounded()), duration)
        } onCancel: { video.cancelLoading() }
    }

    static func editingInput(_ asset: PHAsset) async throws -> PHContentEditingInput {
        let request = GalleryVaultPhotoRequest<PHContentEditingInput>()
        return try await request.run { completion in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            options.canHandleAdjustmentData = { _ in true }
            let id = asset.requestContentEditingInput(with: options) { input, info in
                if let error = info[PHContentEditingInputErrorKey] as? Error { completion(.failure(error)) }
                else if let input { completion(.success(input)) }
                else { completion(.failure(GalleryVaultTransferError.photoRequestFailed)) }
            }
            return { asset.cancelContentEditingInputRequest(id) }
        }
    }

    static func isSameVersion(_ asset: PHAsset, as record: GalleryVaultRecord) -> Bool {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let selected = try? originals(resources, asset: asset) else { return false }
        let edited = hasEdits(resources)
        guard !edited || asset.modificationDate != nil else { return false }
        guard asset.localIdentifier == record.sourceIdentifier, asset.canPerform(.delete),
              asset.mediaType.rawValue == record.mediaType,
              asset.mediaSubtypes.rawValue == record.mediaSubtypes,
              asset.creationDate == record.creationDate, asset.modificationDate == record.modificationDate,
              asset.isFavorite == record.isFavorite,
              asset.location?.coordinate.latitude == record.latitude,
              asset.location?.coordinate.longitude == record.longitude,
              // Original geometry can differ from the edited render; modificationDate still guards source edits.
              (edited || (asset.pixelWidth == record.pixelWidth && asset.pixelHeight == record.pixelHeight && asset.duration == record.duration)) else { return false }
        let now = selected.map {
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

    static func usableParents(_ record: GalleryVaultRecord, omittingUnavailable: Bool = false) throws -> [(GalleryVaultAlbum, PHAssetCollection?)] {
        let albums = record.albums.filter { $0.id != GalleryVaultRecycleBin.id }
        let fetched = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: albums.map(\.id), options: nil)
        var byID: [String: PHAssetCollection] = [:]
        for i in 0..<fetched.count { let album = fetched.object(at: i); byID[album.localIdentifier] = album }
        let missingTitles = Set(albums.filter { byID[$0.id] == nil && !GalleryRecycleBin.isRecycleBinTitle($0.title) }.map(\.title))
        var replacements: [String: PHAssetCollection] = [:]
        if !missingTitles.isEmpty {
            let regular = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            for i in 0..<regular.count {
                let album = regular.object(at: i)
                if let title = album.localizedTitle, missingTitles.contains(title), album.canPerform(.addContent), replacements[title] == nil {
                    replacements[title] = album
                }
            }
        }
        return try albums.compactMap { album in
            if GalleryRecycleBin.isRecycleBinTitle(album.title) { return nil }
            if let collection = byID[album.id] {
                guard collection.canPerform(.addContent) else {
                    if omittingUnavailable { return nil }
                    throw GalleryVaultTransferError.albumUnavailable(album.title)
                }
                return (album, collection)
            }
            var resolved = album
            let collection = replacements[album.title]
            if let collection { resolved.id = collection.localIdentifier }
            return (resolved, collection)
        }
    }

}

/// Cancelling resumes the waiter even when PhotoKit never delivers its completion.
nonisolated final class GalleryVaultPhotoRequest<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var cancelRequest: (() -> Void)?
    private var finished = false
    private var cancelled = false

    func run(_ start: (@escaping (Result<Value, Error>) -> Void) -> (() -> Void)) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if finished { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                lock.unlock()
                let cancel = start { self.complete($0) }
                lock.lock()
                let cancelNow = cancelled
                if !finished { cancelRequest = cancel }
                lock.unlock()
                if cancelNow { cancel() }
            }
        } onCancel: { self.cancel() }
    }

    private func complete(_ result: Result<Value, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let waiter = continuation
        continuation = nil
        cancelRequest = nil
        lock.unlock()
        waiter?.resume(with: result)
    }

    private func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        cancelled = true
        let waiter = continuation
        let cancel = cancelRequest
        continuation = nil
        cancelRequest = nil
        lock.unlock()
        cancel?()
        waiter?.resume(throwing: CancellationError())
    }
}

nonisolated enum GalleryVaultTransferError: LocalizedError {
    case fullAccessRequired, unsupportedItem, unsupportedResources, missingResources, locked, busy
    case albumUnavailable(String), changedOriginal, missingOriginal, photoRequestFailed, interruptedRestore
    case journalFailed, importFailed, cancelled, alreadyInVault, pendingCopyUnavailable
    case notInRecycleBin, invalidVaultDestination

    var errorDescription: String? {
        switch self {
        case .notInRecycleBin: return "Only items in Private Vault's Recycle Bin can be permanently deleted."
        case .invalidVaultDestination: return "Choose a regular Private Vault album."
        case .fullAccessRequired: return "Full Photos access is required to safely move or restore private items."
        case .unsupportedItem: return "Photos cannot delete this item, so it was left in your library."
        case .unsupportedResources: return "This item's original cannot yet be restored safely; it was left in Photos."
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
