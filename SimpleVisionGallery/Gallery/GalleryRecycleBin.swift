@preconcurrency import Photos

/// Shared PhotoKit handling for the app-owned ordinary album named Recycle Bin.
@MainActor
enum GalleryRecycleBin {
    private static var moving = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []
    static let title = "Recycle Bin"

    static func isRecycleBin(_ album: GalleryAlbum) -> Bool {
        isRecycleBinTitle(album.title)
    }

    static func isRecycleBinTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(Self.title) == .orderedSame
    }

    static func existingCollection() -> PHAssetCollection? {
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var firstMatching: PHAssetCollection?
        for index in 0..<albums.count {
            let album = albums.object(at: index)
            guard isRecycleBinTitle(album.localizedTitle) else { continue }
            if album.canPerform(.addContent) { return album }
            if firstMatching == nil { firstMatching = album }
        }
        return firstMatching
    }

    /// Adds assets to the bin and removes them from their source in one Photos transaction.
    @discardableResult
    static func move(_ assets: [PHAsset], from source: PHAssetCollection) async throws -> String {
        guard !assets.isEmpty else { throw GalleryRecycleBinError.noAssets }
        if moving { await withCheckedContinuation { waiters.append($0) } }
        moving = true
        defer {
            if waiters.isEmpty { moving = false }
            else { waiters.removeFirst().resume() }
        }
        // Collections are immutable snapshots. Resolve current title/editability
        // so a rename cannot leave recycle behavior attached to the old name.
        guard let source = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [source.localIdentifier], options: nil).firstObject else {
            throw GalleryRecycleBinError.sourceNotEditable
        }
        guard !isRecycleBinTitle(source.localizedTitle) else { throw GalleryRecycleBinError.alreadyInBin }
        guard source.canPerform(.removeContent) else { throw GalleryRecycleBinError.sourceNotEditable }

        let bin = existingCollection()
        if let bin, !bin.canPerform(.addContent) { throw GalleryRecycleBinError.binNotEditable }

        var createdIdentifier: String?
        var staged = false
        try await PHPhotoLibrary.shared().performChanges {
            guard let sourceRequest = PHAssetCollectionChangeRequest(for: source) else { return }
            let binRequest: PHAssetCollectionChangeRequest
            if let bin {
                guard let request = PHAssetCollectionChangeRequest(for: bin) else { return }
                binRequest = request
            } else {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: Self.title)
                createdIdentifier = request.placeholderForCreatedAssetCollection.localIdentifier
                binRequest = request
            }
            binRequest.addAssets(assets as NSFastEnumeration)
            sourceRequest.removeAssets(assets as NSFastEnumeration)
            staged = true
        }
        guard staged else { throw GalleryRecycleBinError.changeUnavailable }
        return bin?.localIdentifier ?? createdIdentifier ?? ""
    }
}

private enum GalleryRecycleBinError: LocalizedError {
    case noAssets, alreadyInBin, sourceNotEditable, binNotEditable, changeUnavailable

    var errorDescription: String? {
        switch self {
        case .noAssets: return "Select at least one item first."
        case .alreadyInBin: return "Items are already in Recycle Bin. Review them there before permanent deletion."
        case .sourceNotEditable: return "Photos does not allow removing items from this album."
        case .binNotEditable: return "Photos does not allow adding items to Recycle Bin."
        case .changeUnavailable: return "Photos could not prepare the recycle move. Nothing was changed."
        }
    }
}
