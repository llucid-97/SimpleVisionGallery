// Shared, lazy slideshow snapshots. Photos remains the owner of all media.
import Foundation

/// Tracks removed positions without copying a large album into an array of assets.
nonisolated struct GalleryPlaylistIndex {
    let originalCount: Int
    private(set) var removed = IndexSet()

    var count: Int { originalCount - removed.count }

    func position(of index: Int) -> Int {
        index - removed.count(in: 0..<index)
    }

    func index(at position: Int) -> Int? {
        guard position >= 0, position < count else { return nil }
        var low = position
        var high = originalCount - 1
        while low < high {
            let middle = low + (high - low) / 2
            let liveThroughMiddle = middle + 1 - removed.count(in: 0..<(middle + 1))
            if liveThroughMiddle > position { high = middle } else { low = middle + 1 }
        }
        return low
    }

    func survivingCursor(_ cursor: Int?) -> Int? {
        guard let cursor, count > 0 else { return nil }
        if !removed.contains(cursor) { return cursor }
        return index(at: min(position(of: cursor), count - 1))
    }

    mutating func remove(_ indexes: IndexSet) {
        removed.formUnion(indexes.intersection(IndexSet(integersIn: 0..<originalCount)))
    }
}

#if os(visionOS)
import Combine
@preconcurrency import Photos

@MainActor
struct GalleryViewerSnapshot {
    let id: UUID
    let album: GalleryAlbum
    let fetch: PHFetchResult<PHAsset>
    let displayOrder: [Int]?
}

@MainActor
fileprivate final class GalleryViewerPlaylist {
    var snapshot: GalleryViewerSnapshot
    var index: GalleryPlaylistIndex
    private var needsFreshMetadata = false
    private let displayIndexBySource: [Int: Int]?
    private let metadataCache: NSCache<NSString, PHAsset> = {
        let cache = NSCache<NSString, PHAsset>()
        cache.countLimit = 16
        return cache
    }()
    var changeGeneration = UUID()

    init(_ snapshot: GalleryViewerSnapshot) {
        self.snapshot = snapshot
        index = GalleryPlaylistIndex(originalCount: snapshot.displayOrder?.count ?? snapshot.fetch.count)
        displayIndexBySource = snapshot.displayOrder.map { order in
            Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        }
    }

    func displayIndex(forSource sourceIndex: Int) -> Int? {
        if let displayIndexBySource { return displayIndexBySource[sourceIndex] }
        return sourceIndex < index.originalCount ? sourceIndex : nil
    }

    func asset(at displayIndex: Int) -> PHAsset {
        let sourceIndex = snapshot.displayOrder?[displayIndex] ?? displayIndex
        let original = snapshot.fetch.object(at: sourceIndex)
        guard needsFreshMetadata else { return original }
        let key = original.localIdentifier as NSString
        if let cached = metadataCache.object(forKey: key) { return cached }
        let current = PHAsset.fetchAssets(withLocalIdentifiers: [original.localIdentifier], options: nil).firstObject ?? original
        metadataCache.setObject(current, forKey: key)
        return current
    }

    func invalidateMetadata() {
        needsFreshMetadata = true
        metadataCache.removeAllObjects()
    }

}

@MainActor
final class GalleryViewerSession: ObservableObject, Identifiable {
    let id = UUID()
    fileprivate let playlist: GalleryViewerPlaylist
    @Published fileprivate(set) var cursor: Int?
    @Published fileprivate(set) var revision = 0

    fileprivate init(playlist: GalleryViewerPlaylist, cursor: Int) {
        self.playlist = playlist
        self.cursor = playlist.index.survivingCursor(cursor)
    }

    var albumID: String { playlist.snapshot.album.id }
    var albumTitle: String { playlist.snapshot.album.title }
    var canRemoveFromSourceAlbum: Bool {
        let album = playlist.snapshot.album
        return album.virtualScope == nil && album.collection?.canPerform(.removeContent) == true
    }
    var currentAsset: PHAsset? { cursor.map { playlist.asset(at: $0) } }
    /// Resolve only the next live item in the frozen display order; never scan the album.
    var nextAsset: PHAsset? {
        guard let cursor,
              let next = playlist.index.index(at: playlist.index.position(of: cursor) + 1)
        else { return nil }
        return playlist.asset(at: next)
    }
    /// Resolve only the requested lookahead, preserving order and stopping at the last item.
    func upcomingAssets(limit: Int) -> [PHAsset] {
        guard let cursor, limit > 0 else { return [] }
        let currentPosition = playlist.index.position(of: cursor)
        let available = min(limit, playlist.index.count - currentPosition - 1)
        guard available > 0 else { return [] }
        var assets: [PHAsset] = []
        assets.reserveCapacity(available)
        for offset in 1...available {
            if let next = playlist.index.index(at: currentPosition + offset) {
                assets.append(playlist.asset(at: next))
            }
        }
        return assets
    }

    /// Resolve a bounded lookbehind in nearest-first order without scanning older pages.
    func precedingAssets(limit: Int) -> [PHAsset] {
        guard let cursor, limit > 0 else { return [] }
        let currentPosition = playlist.index.position(of: cursor)
        let available = min(limit, currentPosition)
        guard available > 0 else { return [] }
        var assets: [PHAsset] = []
        assets.reserveCapacity(available)
        for offset in 1...available {
            if let previous = playlist.index.index(at: currentPosition - offset) {
                assets.append(playlist.asset(at: previous))
            }
        }
        return assets
    }

    var count: Int { playlist.index.count }
    var position: Int { cursor.map { playlist.index.position(of: $0) + 1 } ?? 0 }
    var canGoPrevious: Bool { position > 1 }
    var canGoNext: Bool { position > 0 && position < count }
}

@MainActor
final class GalleryViewerStore: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = GalleryViewerStore()
    @Published private(set) var sessions: [UUID: GalleryViewerSession] = [:]
    @Published private(set) var albums: [GalleryAlbum] = []
    @Published private(set) var isPerformingOperation = false
    private var playlists: [UUID: GalleryViewerPlaylist] = [:]
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var albumRefreshGeneration = UUID()
    private var membershipSubscription: AnyCancellable?

    private override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
        membershipSubscription = GalleryVirtualLibraryIndex.shared.$revision.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            let index = GalleryVirtualLibraryIndex.shared
            self.removeVirtualIDs(index.removedFromPhotos, scope: .photos)
            self.removeVirtualIDs(index.removedFromUnfiled, scope: .unfiled)
        }
    }

    func createSession(from manager: GalleryManager, at displayIndex: Int) -> UUID? {
        guard let snapshot = manager.viewerSnapshot(),
              displayIndex >= 0, displayIndex < (snapshot.displayOrder?.count ?? snapshot.fetch.count) else { return nil }
        let playlist = playlists[snapshot.id] ?? GalleryViewerPlaylist(snapshot)
        playlists[snapshot.id] = playlist
        guard !playlist.index.removed.contains(displayIndex) else { return nil }
        let session = GalleryViewerSession(playlist: playlist, cursor: displayIndex)
        sessions[session.id] = session
        albums = manager.albums
        return session.id
    }

    func session(_ id: UUID) -> GalleryViewerSession? { sessions[id] }

    func duplicateSession(_ id: UUID) -> UUID? {
        guard let original = sessions[id], let cursor = original.cursor else { return nil }
        let duplicate = GalleryViewerSession(playlist: original.playlist, cursor: cursor)
        sessions[duplicate.id] = duplicate
        return duplicate.id
    }

    func next(_ id: UUID) { navigate(id, offset: 1) }
    func previous(_ id: UUID) { navigate(id, offset: -1) }

    private func navigate(_ id: UUID, offset: Int) {
        guard let session = sessions[id], let cursor = session.cursor,
              let next = session.playlist.index.index(at: session.playlist.index.position(of: cursor) + offset)
        else { return }
        objectWillChange.send()
        session.cursor = next
    }

    func disposeSession(_ id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        let snapshotID = session.playlist.snapshot.id
        if !sessions.values.contains(where: { $0.playlist.snapshot.id == snapshotID }) {
            session.playlist.changeGeneration = UUID()
            playlists.removeValue(forKey: snapshotID)
        }
    }

    func refreshAlbums() async {
        let generation = UUID()
        albumRefreshGeneration = generation
        let fetch = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var result: [GalleryAlbum] = albums.filter { $0.virtualScope != nil }
        for index in 0..<fetch.count {
            let collection = fetch.object(at: index)
            result.append(GalleryAlbum(id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Album", assetCount: 0,
                collection: collection, coverAsset: nil))
            if index.isMultiple(of: 128) {
                await Task.yield()
                guard albumRefreshGeneration == generation else { return }
            }
        }
        let sorted = result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let byID = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        for playlist in playlists.values {
            guard let refreshed = byID[playlist.snapshot.album.id] else { continue }
            guard playlist.snapshot.album.title != refreshed.title else { continue }
            playlist.snapshot = GalleryViewerSnapshot(
                id: playlist.snapshot.id,
                album: refreshed,
                fetch: playlist.snapshot.fetch,
                displayOrder: playlist.snapshot.displayOrder
            )
            notify(playlist)
        }
        albums = sorted
    }

    func updateAlbumTitle(id: String, title: String) {
        for playlist in playlists.values where playlist.snapshot.album.id == id {
            let old = playlist.snapshot.album
            let renamed = GalleryAlbum(
                id: old.id, title: title, assetCount: old.assetCount,
                collection: old.collection, coverAsset: old.coverAsset, virtualScope: old.virtualScope
            )
            playlist.snapshot = GalleryViewerSnapshot(
                id: playlist.snapshot.id,
                album: renamed,
                fetch: playlist.snapshot.fetch,
                displayOrder: playlist.snapshot.displayOrder
            )
            notify(playlist)
        }
        albums = albums.map { album in
            guard album.id == id else { return album }
            return GalleryAlbum(id: album.id, title: title, assetCount: album.assetCount,
                collection: album.collection, coverAsset: album.coverAsset, virtualScope: album.virtualScope)
        }
    }

    func move(_ id: UUID, to destination: GalleryAlbum, expectedAssetID: String? = nil) async throws {
        guard let collection = destination.collection, destination.virtualScope == nil else {
            throw ViewerMutationError.destinationNotEditable
        }
        try await mutate(id, destination: collection, newAlbumName: nil, recycling: false, expectedAssetID: expectedAssetID)
    }

    func move(_ id: UUID, toNewAlbumNamed name: String, expectedAssetID: String? = nil) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ViewerMutationError.emptyName }
        try await mutate(id, destination: nil, newAlbumName: name, recycling: false, expectedAssetID: expectedAssetID)
    }

    func recycle(_ id: UUID, expectedAssetID: String? = nil) async throws {
        try await mutate(id, destination: nil, newAlbumName: nil, recycling: true, expectedAssetID: expectedAssetID)
    }

    /// Removes the current item from its real source album without deleting it
    /// from Photos or placing it in Recycle Bin.
    func removeFromSourceAlbum(sessionID: UUID, expectedAssetID: String) async throws {
        guard let session = sessions[sessionID], let asset = session.currentAsset else { throw ViewerMutationError.noAsset }
        guard asset.localIdentifier == expectedAssetID else { return }
        guard session.playlist.snapshot.album.virtualScope == nil else { throw ViewerMutationError.sourceNotEditable }
        await acquireMutation()
        defer { releaseMutation() }
        guard let live = sessions[sessionID], live.currentAsset?.localIdentifier == expectedAssetID else { return }
        guard let source = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [session.albumID], options: nil).firstObject,
              source.canPerform(.removeContent) else { throw ViewerMutationError.sourceNotEditable }
        var staged = false
        try await PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: source) else { return }
            request.removeAssets([asset] as NSArray)
            staged = true
        }
        guard staged else { throw ViewerMutationError.changeUnavailable }
        GalleryVirtualLibraryIndex.shared.applyLocalMembershipDelta(assetIDs: [asset.localIdentifier], removedAlbumID: source.localIdentifier)
        synchronizeVirtualMembershipAfterMutation(assets: [asset], addedToAlbum: false,
            recycling: false, removedFromSource: true)
        removeFromAlbum(source.localIdentifier, assets: [asset])
        await refreshAlbums()
    }

    // Capture the requested asset before waiting: a second tap must not act on the next slide.
    private func mutate(_ id: UUID, destination: PHAssetCollection?, newAlbumName: String?, recycling: Bool, expectedAssetID: String?) async throws {
        guard let session = sessions[id], let asset = session.currentAsset else { throw ViewerMutationError.noAsset }
        guard expectedAssetID == nil || expectedAssetID == asset.localIdentifier else { return }
        let sourceAlbum = session.playlist.snapshot.album
        let sourceID = session.albumID
        await acquireMutation()
        defer { releaseMutation() }
        guard let liveSession = sessions[id], liveSession.currentAsset?.localIdentifier == asset.localIdentifier else { return }
        let source: PHAssetCollection?
        if sourceAlbum.virtualScope == nil {
            guard let realSource = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [sourceID], options: nil).firstObject,
                  realSource.canPerform(.removeContent) else { throw ViewerMutationError.sourceNotEditable }
            source = realSource
        } else {
            source = nil
        }

        if recycling && (sourceAlbum.virtualScope == .recycleBin || (source.map { GalleryRecycleBin.isRecycleBinTitle($0.localizedTitle) } ?? false)) {
            guard let source else { throw ViewerMutationError.assetNoLongerInBin }
            try await deleteFromRecycleBin(asset, source: source)
            removeFromAllAlbums(assets: [asset])
            GalleryVirtualLibraryIndex.shared.applyLocalMembershipDelta(assetIDs: [asset.localIdentifier], deletedAssetIDs: [asset.localIdentifier])
            await refreshAlbums()
            return
        }

        if recycling {
            try await GalleryRecycleBin.move([asset], from: source)
            GalleryVirtualLibraryIndex.shared.applyLocalMembershipDelta(assetIDs: [asset.localIdentifier], addedAlbumID: GalleryRecycleBin.existingCollection()?.localIdentifier, removedAlbumID: source?.localIdentifier)
            synchronizeVirtualMembershipAfterMutation(assets: [asset], addedToAlbum: false,
                recycling: true, removedFromSource: source != nil)
            if let source { removeFromAlbum(source.localIdentifier, assets: [asset]) }
            await refreshAlbums()
            return
        }

        let target = destination
        let createName = newAlbumName
        if let target, target.localIdentifier == source?.localIdentifier { return }
        if let target, !target.canPerform(.addContent) { throw ViewerMutationError.destinationNotEditable }
        var staged = false
        var createdIdentifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            let sourceRequest = source.flatMap { PHAssetCollectionChangeRequest(for: $0) }
            guard source == nil || sourceRequest != nil else { return }
            let destinationRequest: PHAssetCollectionChangeRequest
            if let target {
                guard let request = PHAssetCollectionChangeRequest(for: target) else { return }
                destinationRequest = request
            } else if let createName {
                destinationRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: createName)
                createdIdentifier = destinationRequest.placeholderForCreatedAssetCollection.localIdentifier
            } else { return }
            destinationRequest.addAssets([asset] as NSArray)
            sourceRequest?.removeAssets([asset] as NSArray)
            staged = true
        }
        guard staged else { throw ViewerMutationError.changeUnavailable }
        let destinationID = target?.localIdentifier ?? createdIdentifier
        GalleryVirtualLibraryIndex.shared.applyLocalMembershipDelta(assetIDs: [asset.localIdentifier], addedAlbumID: destinationID, removedAlbumID: source?.localIdentifier)
        let destinationIsBin = destinationID == GalleryRecycleBin.existingCollection()?.localIdentifier
        synchronizeVirtualMembershipAfterMutation(assets: [asset], addedToAlbum: true,
            recycling: destinationIsBin, removedFromSource: source != nil)
        if let source { removeFromAlbum(source.localIdentifier, assets: [asset]) }
        if let destinationID = target?.localIdentifier ?? createdIdentifier {
            GalleryMoveHistory.shared.recordSuccessfulMove(to: destinationID)
        }
        await refreshAlbums()
    }

    private func deleteFromRecycleBin(_ asset: PHAsset, source: PHAssetCollection) async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw ViewerMutationError.fullPhotoAccessRequired
        }
        let currentBinAssets = PHAsset.fetchAssets(in: source, options: nil)
        guard currentBinAssets.index(of: asset) != NSNotFound else { throw ViewerMutationError.assetNoLongerInBin }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil)
        guard fetched.count == 1, let current = fetched.firstObject else { throw ViewerMutationError.assetNoLongerExists }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets([current] as NSArray)
        }
        let survivors = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil)
        guard survivors.count == 0 else { throw ViewerMutationError.deletionPostconditionFailed }
    }

    private func acquireMutation() async {
        if isPerformingOperation {
            await withCheckedContinuation { mutationWaiters.append($0) }
        } else { isPerformingOperation = true }
    }

    private func releaseMutation() {
        if mutationWaiters.isEmpty { isPerformingOperation = false }
        else { mutationWaiters.removeFirst().resume() }
    }

    /// Called after either the gallery grid or a viewer completes a PhotoKit move.
    func removeFromAlbum(_ albumID: String, assets: [PHAsset]) {
        for playlist in playlists.values where playlist.snapshot.album.id == albumID {
            var sourceRemovals = IndexSet()
            for asset in assets {
                let sourceIndex = playlist.snapshot.fetch.index(of: asset)
                if sourceIndex != NSNotFound { sourceRemovals.insert(sourceIndex) }
            }
            var removed = sourceRemovals
            if let order = playlist.snapshot.displayOrder, !sourceRemovals.isEmpty {
                removed = IndexSet()
                for (displayIndex, sourceIndex) in order.enumerated() where sourceRemovals.contains(sourceIndex) {
                    removed.insert(displayIndex)
                }
            }
            applyRemovals(removed, to: playlist)
        }
    }

    /// Permanent deletion removes the exact identifiers from every open frozen playlist.
    func removeFromAllAlbums(assets: [PHAsset]) {
        let identifiers = Set(assets.map(\.localIdentifier))
        guard !identifiers.isEmpty else { return }
        for playlist in playlists.values {
            var sourceRemovals = IndexSet()
            for asset in assets {
                let index = playlist.snapshot.fetch.index(of: asset)
                if index != NSNotFound { sourceRemovals.insert(index) }
            }
            guard !sourceRemovals.isEmpty else { continue }
            var displayRemovals = sourceRemovals
            if let order = playlist.snapshot.displayOrder {
                displayRemovals = IndexSet()
                for (displayIndex, sourceIndex) in order.enumerated() where sourceRemovals.contains(sourceIndex) {
                    displayRemovals.insert(displayIndex)
                }
            }
            applyRemovals(displayRemovals, to: playlist)
        }
    }

    /// Applies the known local membership effect to frozen virtual playlists by
    /// looking up only the changed assets. The shared index remains responsible
    /// for PhotoKit's cumulative membership counts and later external deltas.
    func synchronizeVirtualMembershipAfterMutation(assets: [PHAsset], addedToAlbum: Bool,
                                                   recycling: Bool, removedFromSource: Bool) {
        GalleryVirtualLibraryIndex.shared.invalidate()
        let identifiers = Set(assets.map(\.localIdentifier))
        guard !identifiers.isEmpty else { return }
        for playlist in playlists.values {
            guard let scope = playlist.snapshot.album.virtualScope else { continue }
            let shouldRemove: Bool
            switch scope {
            case .photos: shouldRemove = recycling
            case .unfiled: shouldRemove = addedToAlbum || recycling
            case .recycleBin: shouldRemove = false
            }
            guard shouldRemove else { continue }
            var displayRemovals = IndexSet()
            for asset in assets {
                guard identifiers.contains(asset.localIdentifier) else { continue }
                let sourceIndex = playlist.snapshot.fetch.index(of: asset)
                guard sourceIndex != NSNotFound else { continue }
                let displayIndex: Int
                if playlist.snapshot.displayOrder != nil {
                    guard let found = playlist.displayIndex(forSource: sourceIndex) else { continue }
                    displayIndex = found
                } else { displayIndex = sourceIndex }
                displayRemovals.insert(displayIndex)
            }
            applyRemovals(displayRemovals, to: playlist)
        }
    }

    private func applyRemovals(_ removed: IndexSet, to playlist: GalleryViewerPlaylist) {
        guard !removed.subtracting(playlist.index.removed).isEmpty else { return }
        playlist.index.remove(removed)
        notify(playlist)
    }

    private func notify(_ playlist: GalleryViewerPlaylist) {
        objectWillChange.send()
        for session in sessions.values where session.playlist === playlist {
            session.cursor = playlist.index.survivingCursor(session.cursor)
            session.revision += 1
        }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in await self?.handleChange(changeInstance) }
    }

    private func handleChange(_ change: PHChange) async {
        // Let the shared membership observer consume this same PhotoKit change
        // before applying its exact-ID removal deltas to virtual sessions.
        await Task.yield()
        let index = GalleryVirtualLibraryIndex.shared
        let removedPhotos = index.removedFromPhotos
        let removedUnfiled = index.removedFromUnfiled
        if !removedPhotos.isEmpty { removeVirtualIDs(removedPhotos, scope: .photos) }
        if !removedUnfiled.isEmpty { removeVirtualIDs(removedUnfiled, scope: .unfiled) }
        // Each fetch remains frozen at opening time; deltas are therefore cumulative.
        for playlist in Array(playlists.values) {
            let snapshot = playlist.snapshot
            if let collection = snapshot.album.collection,
               change.changeDetails(for: collection)?.objectWasDeleted == true {
                applyRemovals(IndexSet(integersIn: 0..<snapshot.fetch.count), to: playlist)
                continue
            }
            guard let details = change.changeDetails(for: snapshot.fetch) else { continue }
            let generation = UUID()
            playlist.changeGeneration = generation
            var sourceRemovals = details.removedIndexes ?? IndexSet()
            if !details.hasIncrementalChanges {
                // Rare full reset (for example, access changes): bounded batches keep swipes responsive.
                var survivors = Set<String>()
                let latest = details.fetchResultAfterChanges
                for index in 0..<latest.count {
                    survivors.insert(latest.object(at: index).localIdentifier)
                    if index.isMultiple(of: 512) { await Task.yield() }
                    guard playlist.changeGeneration == generation else { break }
                }
                guard playlist.changeGeneration == generation else { continue }
                for index in 0..<snapshot.fetch.count {
                    if !survivors.contains(snapshot.fetch.object(at: index).localIdentifier) { sourceRemovals.insert(index) }
                    if index.isMultiple(of: 512) { await Task.yield() }
                    guard playlist.changeGeneration == generation else { break }
                }
            }
            guard playlist.changeGeneration == generation else { continue }
            var removed = IndexSet()
            // A single integer pass handles arbitrarily sorted snapshots without asset materialization.
            if let order = snapshot.displayOrder, !sourceRemovals.isEmpty {
                for (displayIndex, sourceIndex) in order.enumerated() where sourceRemovals.contains(sourceIndex) {
                    removed.insert(displayIndex)
                }
            } else { removed = sourceRemovals }
            playlist.invalidateMetadata()
            applyRemovals(removed, to: playlist)
        }
    }

    private func removeVirtualIDs(_ identifiers: Set<String>, scope: GalleryVirtualScope) {
        guard !identifiers.isEmpty else { return }
        // Membership changes preserve assets. Resolve only their IDs, then use each
        // frozen fetch's source indexes; the shared current fetch may have shifted.
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
        for playlist in playlists.values where playlist.snapshot.album.virtualScope == scope {
            var displayRemovals = IndexSet()
            for i in 0..<assets.count {
                let sourceIndex = playlist.snapshot.fetch.index(of: assets.object(at: i))
                guard sourceIndex != NSNotFound,
                      let displayIndex = playlist.displayIndex(forSource: sourceIndex) else { continue }
                displayRemovals.insert(displayIndex)
            }
            if !displayRemovals.isEmpty { applyRemovals(displayRemovals, to: playlist) }
        }
    }

}

private enum ViewerMutationError: LocalizedError {
    case noAsset, emptyName, sourceNotEditable, destinationNotEditable, changeUnavailable
    case fullPhotoAccessRequired, assetNoLongerInBin, assetNoLongerExists
    case deletionPostconditionFailed
    var errorDescription: String? {
        switch self {
        case .noAsset: return "This slideshow has no current item."
        case .emptyName: return "Enter an album name."
        case .sourceNotEditable: return "Photos does not allow moving items out of this album."
        case .destinationNotEditable: return "Photos does not allow adding items to that album."
        case .changeUnavailable: return "Photos could not prepare this move. Please try again."
        case .fullPhotoAccessRequired: return "Full Photos access is required to permanently delete this item."
        case .assetNoLongerInBin: return "This item is no longer in Recycle Bin. Nothing was deleted."
        case .assetNoLongerExists: return "This item is no longer available in Photos. Nothing was deleted."
        case .deletionPostconditionFailed: return "Photos accepted the deletion request, but the item is still in the library. Review before retrying."
        }
    }
}
#endif
