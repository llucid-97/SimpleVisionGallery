import Foundation
@preconcurrency import Photos

/// The delete queue calls this from its detached worker task.
nonisolated enum GalleryQueuedPhotoDeletion {
    // Validate and stage one Photos transaction, retaining per-item errors for the queue.
    static func execute(_ requests: [GalleryDeleteRequest]) async -> [UUID: Error] {
        var failures: [UUID: Error] = [:]
        let photos = requests.filter {
            if case .photos = $0.target, $0.action != .putBack { return true }
            failures[$0.id] = PhotoDeleteError.unsupportedTarget
            return false
        }
        for group in Dictionary(grouping: photos, by: \.itemID).values where group.count > 1 {
            for request in group { failures[request.id] = PhotoDeleteError.duplicateAsset }
        }
        let candidates = photos.filter { failures[$0.id] == nil }
        guard !candidates.isEmpty else { return failures }

        var itemErrors: [UUID: Error] = [:]
        var staged = Set<UUID>()
        // Validate again inside the transaction because library membership can change.
        do {
            try await PHPhotoLibrary.shared().performChanges {
                var lookup = PhotoLookup()
                let bin = GalleryRecycleBin.existingCollection()
                var assets: [UUID: PHAsset] = [:]
                var sources: [String: PHAssetCollection] = [:]
                var eligible: [GalleryDeleteRequest] = []

                for request in candidates {
                    do {
                        let (asset, source) = try validate(request, lookup: &lookup, bin: bin)
                        assets[request.id] = asset
                        if let source { sources[source.localIdentifier] = source }
                        eligible.append(request)
                    } catch { itemErrors[request.id] = error }
                }
                guard !eligible.isEmpty else { return }

                let needsBin = eligible.contains { $0.action == .recycle }
                let binChange: PHAssetCollectionChangeRequest?
                if needsBin, let bin {
                    binChange = PHAssetCollectionChangeRequest(for: bin)
                } else if needsBin, eligible.contains(where: { $0.action == .recycle }) {
                    binChange = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                        withTitle: GalleryRecycleBin.title)
                } else {
                    binChange = nil
                }
                if needsBin && binChange == nil {
                    for request in eligible where request.action == .recycle {
                        itemErrors[request.id] = PhotoDeleteError.binUnavailable
                    }
                }

                var sourceChanges: [String: PHAssetCollectionChangeRequest] = [:]
                for (id, source) in sources {
                    guard let change = PHAssetCollectionChangeRequest(for: source) else {
                        for request in eligible where hasSource(request, id: id) {
                            itemErrors[request.id] = PhotoDeleteError.sourceUnavailable
                        }
                        continue
                    }
                    sourceChanges[id] = change
                }
                let stageable = eligible.filter { request in
                    guard itemErrors[request.id] == nil else { return false }
                    switch request.action {
                    case .recycle:
                        guard binChange != nil else { return false }
                        guard case .photos(_, let sourceID) = request.target, let sourceID else { return true }
                        return sourceChanges[sourceID] != nil
                    case .putBack: return false
                    case .permanent: return true
                    }
                }

                var additions: [PHAsset] = [], deletions: [PHAsset] = []
                var removals: [String: [PHAsset]] = [:]
                // Collect valid changes together while keeping individual rejection reasons.
                for request in stageable {
                    guard let asset = assets[request.id] else {
                        itemErrors[request.id] = PhotoDeleteError.assetUnavailable
                        continue
                    }
                    // Build the change for each action, rechecking permanent deletion before staging it.
                    switch request.action {
                    case .recycle:
                        additions.append(asset)
                        if case .photos(_, let sourceID) = request.target, let sourceID {
                            removals[sourceID, default: []].append(asset)
                        }
                    case .putBack: continue
                    case .permanent:
                        // Exact asset membership is checked again inside this change block.
                        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
                              let deletionBin = lookup.bin(for: request, fallback: bin),
                              GalleryRecycleBin.isRecycleBinTitle(deletionBin.localizedTitle),
                              lookup.contains(asset, in: deletionBin) else {
                            itemErrors[request.id] = PhotoDeleteError.notInBin
                            continue
                        }
                        guard asset.canPerform(.delete) else {
                            itemErrors[request.id] = PhotoDeleteError.assetNotDeletable
                            continue
                        }
                        deletions.append(asset)
                    }
                    staged.insert(request.id)
                }
                if !additions.isEmpty { binChange?.addAssets(additions as NSArray) }
                for (id, assets) in removals { sourceChanges[id]?.removeAssets(assets as NSArray) }
                if !deletions.isEmpty { PHAssetChangeRequest.deleteAssets(deletions as NSArray) }
            }
        } catch {
            // Also fail requests whose change block was never entered.
            for request in candidates where itemErrors[request.id] == nil { failures[request.id] = error }
            failures.merge(itemErrors) { _, latest in latest }
            return failures
        }

        failures.merge(itemErrors) { _, latest in latest }
        for request in candidates where !staged.contains(request.id) && failures[request.id] == nil {
            failures[request.id] = PhotoDeleteError.changeUnavailable
        }
        let permanent = candidates.filter { staged.contains($0.id) && $0.action == .permanent }
        let ids = permanent.compactMap { request -> String? in
            if case .photos(let id, _) = request.target { return id }
            return nil
        }
        if !ids.isEmpty {
            let remaining = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            let remainingIDs = Set((0..<remaining.count).map { remaining.object(at: $0).localIdentifier })
            for request in permanent {
                if case .photos(let id, _) = request.target, remainingIDs.contains(id) {
                    failures[request.id] = PhotoDeleteError.deletePostcondition
                }
            }
        }
        return failures
    }

    private static func validate(_ request: GalleryDeleteRequest, lookup: inout PhotoLookup,
                                 bin: PHAssetCollection?) throws -> (PHAsset, PHAssetCollection?) {
        guard case .photos(let id, let sourceID) = request.target, let asset = lookup.asset(id) else {
            throw PhotoDeleteError.assetUnavailable
        }
        let bin = lookup.bin(for: request, fallback: bin)
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch request.action {
        case .recycle:
            guard status == .authorized || status == .limited else { throw PhotoDeleteError.accessRequired }
        case .putBack: throw PhotoDeleteError.unsupportedTarget
        case .permanent:
            guard status == .authorized else { throw PhotoDeleteError.fullAccessRequired }
        }
        // Apply action-specific permission and membership checks before staging a change.
        switch request.action {
        case .recycle:
            guard !lookup.contains(asset, in: bin) else { throw PhotoDeleteError.alreadyInBin }
            if let bin, !bin.canPerform(.addContent) { throw PhotoDeleteError.binUnavailable }
            if let sourceID {
                guard let source = lookup.collection(sourceID),
                      !GalleryRecycleBin.isRecycleBinTitle(source.localizedTitle),
                      source.canPerform(.removeContent), lookup.contains(asset, in: source) else {
                    throw PhotoDeleteError.sourceUnavailable
                }
                return (asset, source)
            }
        case .putBack: throw PhotoDeleteError.unsupportedTarget
        case .permanent:
            guard let bin, GalleryRecycleBin.isRecycleBinTitle(bin.localizedTitle),
                  lookup.contains(asset, in: bin) else { throw PhotoDeleteError.notInBin }
            guard asset.canPerform(.delete) else { throw PhotoDeleteError.assetNotDeletable }
        }
        return (asset, nil)
    }

    private static func hasSource(_ request: GalleryDeleteRequest, id: String) -> Bool {
        guard case .photos(_, let sourceID) = request.target else { return false }
        return request.action == .recycle && sourceID == id
    }
}

/// Cache PhotoKit lookups during a transaction to reuse consistent asset and album references.
private nonisolated struct PhotoLookup {
    private var assets: [String: PHAsset] = [:]
    private var collections: [String: PHAssetCollection] = [:]
    private var memberships: [String: PHFetchResult<PHAsset>] = [:]

    mutating func asset(_ id: String) -> PHAsset? {
        if let cached = assets[id] { return cached }
        guard let fresh = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        assets[id] = fresh
        return fresh
    }
    mutating func collection(_ id: String) -> PHAssetCollection? {
        if let cached = collections[id] { return cached }
        guard let fresh = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        collections[id] = fresh
        return fresh
    }
    mutating func bin(for request: GalleryDeleteRequest, fallback: PHAssetCollection?) -> PHAssetCollection? {
        if request.action != .recycle, case .photos(_, let sourceID) = request.target, let sourceID {
            return collection(sourceID)
        }
        return fallback
    }
    mutating func contains(_ asset: PHAsset, in collection: PHAssetCollection?) -> Bool {
        guard let collection else { return false }
        let id = collection.localIdentifier
        if memberships[id] == nil { memberships[id] = PHAsset.fetchAssets(in: collection, options: nil) }
        return memberships[id]!.index(of: asset) != NSNotFound
    }
}

/// Give each rejected Photos operation a specific error that the queue can display.
private nonisolated enum PhotoDeleteError: LocalizedError, Sendable {
    case unsupportedTarget, duplicateAsset, assetUnavailable, sourceUnavailable, binUnavailable
    case alreadyInBin, notInBin, accessRequired, fullAccessRequired, assetNotDeletable
    case changeUnavailable, deletePostcondition
    var errorDescription: String? {
        // Map each failure to a useful message for the person who requested the change.
        switch self {
        case .unsupportedTarget: "Unsupported Photos deletion target."
        case .duplicateAsset: "This Photos item has more than one queued action."
        case .assetUnavailable: "This Photos item is no longer available."
        case .sourceUnavailable: "Photos no longer allows removing this item from its source album."
        case .binUnavailable: "Photos does not allow changing the Recycle Bin."
        case .alreadyInBin: "This Photos item is already in Recycle Bin."
        case .notInBin: "This Photos item is no longer in Recycle Bin."
        case .accessRequired: "Photos access is required to change this item."
        case .fullAccessRequired: "Full Photos access is required to permanently delete this item."
        case .assetNotDeletable: "Photos does not allow permanently deleting this item."
        case .changeUnavailable: "Photos could not prepare the requested change."
        case .deletePostcondition: "Photos reported deletion, but the item is still available."
        }
    }
}
