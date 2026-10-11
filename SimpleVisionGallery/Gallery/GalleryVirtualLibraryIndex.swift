import Combine
import Foundation
@preconcurrency import Photos

nonisolated enum GalleryVirtualScope: String, Sendable {
    case photos
    case unfiled
    case recycleBin

    var virtualID: String { "gallery.virtual.\(rawValue)" }

    var title: String {
        switch self {
        case .photos: "Photos"
        case .unfiled: "Unfiled"
        case .recycleBin: "Recycle Bin"
        }
    }
}

nonisolated enum GalleryVirtualMediaFilter: String, Sendable {
    case all
    case photos
    case videos
}

nonisolated struct GalleryVirtualMediaCounts: Sendable {
    let photos: Int
    let videos: Int
}

nonisolated private struct GalleryVirtualSnapshotKey: Hashable, Sendable {
    let scope: GalleryVirtualScope
    let mediaFilter: GalleryVirtualMediaFilter
}

@MainActor
struct GalleryVirtualLibrarySnapshot {
    let fetch: PHFetchResult<PHAsset>
    /// Source indexes into `fetch`, in Photos order.
    let displayOrder: [Int]
    let photoCount: Int
    let videoCount: Int
}

/// One in-session membership index shared by the grid and all viewer windows.
@MainActor
final class GalleryVirtualLibraryIndex: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = GalleryVirtualLibraryIndex()

    @Published private(set) var revision = 0
    @Published private(set) var removedFromPhotos: Set<String> = []
    @Published private(set) var removedFromUnfiled: Set<String> = []

    private struct AlbumRecord {
        var fetch: PHFetchResult<PHAsset>
        var ids: Set<String>
        var isBin: Bool
        var title: String?
    }

    private var assetFetch: PHFetchResult<PHAsset>?
    private var collectionFetch: PHFetchResult<PHAssetCollection>?
    private var albums: [String: AlbumRecord] = [:]
    private var assetIDs: [String] = []
    private var assetIsVideo: [Bool] = []
    private var indexByID: [String: Int] = [:]
    private var albumRefCounts: [String: Int] = [:]
    private var binRefCounts: [String: Int] = [:]
    private var canonicalBinID: String?
    private var snapshots: [GalleryVirtualSnapshotKey: GalleryVirtualLibrarySnapshot] = [:]
    private var buildGeneration = 0
    private var membershipGeneration = 0
    private var buildTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var needsFullRefresh = false
    private var snapshotNeedsRebuild = false
    private var observing = false
    private var authorized = false

    private override init() { super.init() }

    func snapshot(
        for scope: GalleryVirtualScope,
        mediaFilter: GalleryVirtualMediaFilter = .all
    ) async -> GalleryVirtualLibrarySnapshot {
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        let hasAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
            || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
        guard hasAccess else {
            authorized = false
            reset()
            return GalleryVirtualLibrarySnapshot(fetch: emptyFetch(), displayOrder: [], photoCount: 0, videoCount: 0)
        }
        if !authorized {
            authorized = true
            reset()
        }
        let key = GalleryVirtualSnapshotKey(scope: scope, mediaFilter: mediaFilter)
        if let snapshot = snapshots[key] { return snapshot }
        if assetFetch == nil {
            if let buildTask {
                await buildTask.value
            } else {
                let task = Task { @MainActor in await self.buildInitialIndex() }
                buildTask = task
                await task.value
                buildTask = nil
            }
        }
        if let snapshot = snapshots[key] { return snapshot }
        let result = GalleryVirtualLibrarySnapshot(fetch: assetFetch ?? emptyFetch(), displayOrder: [], photoCount: 0, videoCount: 0)
        snapshots[key] = result
        return result
    }

    func mediaCounts(for scope: GalleryVirtualScope) -> GalleryVirtualMediaCounts {
        let snapshot = snapshots[GalleryVirtualSnapshotKey(scope: scope, mediaFilter: .all)]
        return GalleryVirtualMediaCounts(photos: snapshot?.photoCount ?? 0, videos: snapshot?.videoCount ?? 0)
    }

    /// Call after a local Photos mutation; PhotoKit's observer supplies incremental details.
    func invalidate() {
        // Generic invalidation preserves the current snapshot until PhotoKit supplies deltas.
        // Call applyLocalMembershipDelta when the mutation's IDs and album IDs are known.
    }

    /// Applies a known local album move immediately. The Photos observer remains registered;
    /// membership sets make its later duplicate delta idempotent.
    func applyLocalMembershipDelta(
        assetIDs changedIDs: Set<String>,
        addedAlbumID: String? = nil,
        removedAlbumID: String? = nil,
        deletedAssetIDs: Set<String> = []
    ) {
        guard assetFetch != nil, !changedIDs.isEmpty else { return }
        membershipGeneration &+= 1
        var touched = Set<String>()
        if let removedAlbumID, var record = albums[removedAlbumID] {
            for id in changedIDs where record.ids.remove(id) != nil {
                decrement(id, bin: record.isBin)
                touched.insert(id)
            }
            albums[removedAlbumID] = record
        }
        if let addedAlbumID {
            if albums[addedAlbumID] == nil,
               let collection = PHAssetCollection.fetchAssetCollections(
                    withLocalIdentifiers: [addedAlbumID], options: nil
               ).firstObject,
               collection.assetCollectionType == .album,
               collection.assetCollectionSubtype == .albumRegular {
                let memberFetch = PHAsset.fetchAssets(in: collection, options: nil)
                let isBin = GalleryRecycleBin.existingCollection()?.localIdentifier == addedAlbumID
                albums[addedAlbumID] = AlbumRecord(
                    fetch: memberFetch, ids: [], isBin: isBin, title: collection.localizedTitle
                )
                if isBin { canonicalBinID = addedAlbumID }
            }
            if var record = albums[addedAlbumID] {
                for id in changedIDs where record.ids.insert(id).inserted {
                    increment(id, bin: record.isBin)
                    touched.insert(id)
                }
                albums[addedAlbumID] = record
            }
        }
        updateSnapshots(for: touched)

        guard !deletedAssetIDs.isEmpty else { return }
        for id in deletedAssetIDs {
            for key in Array(albums.keys) {
                guard var record = albums[key], record.ids.remove(id) != nil else { continue }
                decrement(id, bin: record.isBin)
                albums[key] = record
            }
        }
        // Permanent deletion is uncommon. Refresh only the global fetch and compact index;
        // ordinary moves never take this path or scan album contents.
        assetFetch = Self.fetchAllImageAndVideoAssets()
        rebuildAssetIDMap(assetFetch!)
        rebuildSnapshots()
    }

    /// Resolves a Photos local identifier to the current shared-fetch source index.
    func sourceIndex(forAssetID id: String) -> Int? { indexByID[id] }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let previous = changeTask
        changeTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            guard self.assetFetch != nil else {
                self.needsFullRefresh = true
                return
            }
            await self.apply(changeInstance)
        }
    }

    private func buildInitialIndex() async {
        buildGeneration += 1
        let generation = buildGeneration
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType IN %@", [PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue])
        let fetch = PHAsset.fetchAssets(with: options)
        let collectionOptions = PHFetchOptions()
        collectionOptions.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: collectionOptions)
        let selectedBinID = GalleryRecycleBin.existingCollection()?.localIdentifier
        let built = await Task.detached(priority: .utility) {
            var ids: [String] = []
            var isVideo: [Bool] = []
            ids.reserveCapacity(fetch.count)
            isVideo.reserveCapacity(fetch.count)
            for i in 0..<fetch.count {
                let asset = fetch.object(at: i)
                ids.append(asset.localIdentifier)
                isVideo.append(asset.mediaType == .video)
            }
            var albumValues: [(String, PHFetchResult<PHAsset>, Set<String>, Bool, String?)] = []
            var albumCounts: [String: Int] = [:]
            var binCounts: [String: Int] = [:]
            for i in 0..<collections.count {
                let collection = collections.object(at: i)
                guard collection.assetCollectionType == .album,
                      collection.assetCollectionSubtype == .albumRegular else { continue }
                let memberFetch = PHAsset.fetchAssets(in: collection, options: nil)
                var members = Set<String>()
                members.reserveCapacity(memberFetch.count)
                for j in 0..<memberFetch.count { members.insert(memberFetch.object(at: j).localIdentifier) }
                let isBin = collection.localIdentifier == selectedBinID
                albumValues.append((collection.localIdentifier, memberFetch, members, isBin, collection.localizedTitle))
                for id in members {
                    albumCounts[id, default: 0] += 1
                    if isBin { binCounts[id, default: 0] += 1 }
                }
            }
            var orders: [GalleryVirtualScope: [GalleryVirtualMediaFilter: [Int]]] = [:]
            for scope in [GalleryVirtualScope.photos, .unfiled, .recycleBin] {
                var all: [Int] = []
                var photos: [Int] = []
                var videos: [Int] = []
                all.reserveCapacity(ids.count)
                photos.reserveCapacity(ids.count)
                videos.reserveCapacity(ids.count)
                for (index, id) in ids.enumerated() {
                    let included: Bool
                    switch scope {
                    case .photos: included = (binCounts[id] ?? 0) == 0
                    case .unfiled: included = (albumCounts[id] ?? 0) == 0
                    case .recycleBin: included = (binCounts[id] ?? 0) > 0
                    }
                    if included {
                        all.append(index)
                        if isVideo[index] { videos.append(index) }
                        else { photos.append(index) }
                    }
                }
                orders[scope] = [.all: all, .photos: photos, .videos: videos]
            }
            return (ids, isVideo, albumValues, albumCounts, binCounts, orders)
        }.value
        guard generation == buildGeneration else { return }
        if needsFullRefresh {
            needsFullRefresh = false
            await buildInitialIndex()
            return
        }
        assetFetch = fetch
        collectionFetch = collections
        canonicalBinID = selectedBinID
        assetIDs = built.0
        assetIsVideo = built.1
        indexByID = Dictionary(uniqueKeysWithValues: built.0.enumerated().map { ($1, $0) })
        albums.removeAll(keepingCapacity: true)
        albumRefCounts = built.3
        binRefCounts = built.4
        for (id, memberFetch, members, isBin, title) in built.2 {
            albums[id] = AlbumRecord(fetch: memberFetch, ids: members, isBin: isBin, title: title)
        }
        snapshots.removeAll(keepingCapacity: true)
        for (scope, filteredOrders) in built.5 {
            let photos = filteredOrders[.photos]?.count ?? 0
            let videos = filteredOrders[.videos]?.count ?? 0
            for (mediaFilter, order) in filteredOrders {
                snapshots[GalleryVirtualSnapshotKey(scope: scope, mediaFilter: mediaFilter)] = GalleryVirtualLibrarySnapshot(
                    fetch: fetch, displayOrder: order, photoCount: photos, videoCount: videos
                )
            }
        }
        removedFromPhotos = []
        removedFromUnfiled = []
        revision &+= 1
    }

    private func apply(_ change: PHChange) async {
        guard let oldFetch = assetFetch else { return }
        membershipGeneration &+= 1
        guard let assetDetails = change.changeDetails(for: oldFetch) else {
            let touched = await applyAlbumDeltas(change)
            if snapshotNeedsRebuild {
                snapshotNeedsRebuild = false
                await rebuildSnapshotsOffMain(removedCandidateIDs: touched)
            } else {
                updateSnapshots(for: touched)
            }
            return
        }
        let updatedFetch = assetDetails.fetchResultAfterChanges
        if assetDetails.hasIncrementalChanges {
            let priorIndexByID = indexByID
            // Asset insertion/deletion changes source indexes. Rebuild the compact ID map only
            // when the global collection itself changes; ordinary album moves stay incremental.
            if !(assetDetails.insertedIndexes?.isEmpty ?? true)
                || !(assetDetails.removedIndexes?.isEmpty ?? true) {
                assetFetch = updatedFetch
                rebuildAssetIDMap(updatedFetch)
            } else {
                assetFetch = updatedFetch
            }
            let touched = await applyAlbumDeltas(change)
            let globalIndexesChanged = !(assetDetails.insertedIndexes?.isEmpty ?? true)
                || !(assetDetails.removedIndexes?.isEmpty ?? true)
            if globalIndexesChanged || snapshotNeedsRebuild {
                snapshotNeedsRebuild = false
                await rebuildSnapshotsOffMain(
                    removedCandidateIDs: touched,
                    priorIndexByID: globalIndexesChanged ? priorIndexByID : nil
                )
            } else {
                updateSnapshots(for: touched)
            }
        } else {
            assetFetch = updatedFetch
            rebuildAssetIDMap(updatedFetch)
            await rebuildAllAlbumsOffMain()
            await rebuildSnapshotsOffMain()
        }
    }

    @discardableResult
    private func applyAlbumDeltas(_ change: PHChange) async -> Set<String> {
        var touched = Set<String>()
        guard let collectionFetch else { return touched }
        if let collectionDetails = change.changeDetails(for: collectionFetch) {
            let after = collectionDetails.fetchResultAfterChanges
            if !collectionDetails.hasIncrementalChanges {
                self.collectionFetch = after
                await rebuildAllAlbumsOffMain()
                snapshotNeedsRebuild = true
                return []
            }
            let inserted = collectionDetails.insertedIndexes ?? IndexSet()
            let removed = collectionDetails.removedIndexes ?? IndexSet()
            let changed = collectionDetails.changedIndexes ?? IndexSet()
            var membershipChanged = false
            self.collectionFetch = after
            if !inserted.isEmpty || !removed.isEmpty || !changed.isEmpty {
                // Process only collections whose membership or title changed. New album
                // members are scanned off-main; existing cached album contents stay untouched.
                for index in removed {
                    guard index < collectionFetch.count else { continue }
                    let id = collectionFetch.object(at: index).localIdentifier
                    guard let record = albums.removeValue(forKey: id) else { continue }
                    for assetID in record.ids {
                        decrement(assetID, bin: record.isBin)
                        touched.insert(assetID)
                    }
                    membershipChanged = membershipChanged || !record.ids.isEmpty
                }
                for index in inserted where index < after.count {
                    let collection = after.object(at: index)
                    guard collection.assetCollectionType == .album,
                          collection.assetCollectionSubtype == .albumRegular else { continue }
                    let fetch = PHAsset.fetchAssets(in: collection, options: nil)
                    if var existing = albums[collection.localIdentifier] {
                        existing.fetch = fetch
                        existing.title = collection.localizedTitle
                        albums[collection.localIdentifier] = existing
                    } else {
                        let ids = await Task.detached(priority: .utility) { Self.ids(in: fetch) }.value
                        albums[collection.localIdentifier] = AlbumRecord(
                            fetch: fetch, ids: ids, isBin: false, title: collection.localizedTitle
                        )
                        for assetID in ids {
                            increment(assetID, bin: false)
                            touched.insert(assetID)
                        }
                        membershipChanged = membershipChanged || !ids.isEmpty
                    }
                }
                for index in changed where index < after.count {
                    let collection = after.object(at: index)
                    guard var record = albums[collection.localIdentifier] else { continue }
                    record.title = collection.localizedTitle
                    albums[collection.localIdentifier] = record
                }
                let nextBinID = GalleryRecycleBin.existingCollection()?.localIdentifier
                if nextBinID != canonicalBinID {
                    for key in Array(albums.keys) {
                        guard var record = albums[key] else { continue }
                        let shouldBeBin = key == nextBinID
                        if record.isBin != shouldBeBin {
                            for assetID in record.ids {
                                if shouldBeBin { incrementBin(assetID) }
                                else { decrementBin(assetID) }
                                touched.insert(assetID)
                            }
                            membershipChanged = membershipChanged || !record.ids.isEmpty
                            record.isBin = shouldBeBin
                            albums[key] = record
                        }
                    }
                    canonicalBinID = nextBinID
                }
                snapshotNeedsRebuild = snapshotNeedsRebuild || membershipChanged
            }
        }
        for key in Array(albums.keys) {
            guard var record = albums[key],
                  let details = change.changeDetails(for: record.fetch) else { continue }
            let after = details.fetchResultAfterChanges
            if details.hasIncrementalChanges {
                for index in details.removedIndexes ?? IndexSet() {
                    let removed = record.fetch.object(at: index).localIdentifier
                    if record.ids.remove(removed) != nil {
                        decrement(removed, bin: record.isBin)
                        touched.insert(removed)
                    }
                }
                for index in details.insertedIndexes ?? IndexSet() {
                    let added = after.object(at: index).localIdentifier
                    if record.ids.insert(added).inserted {
                        increment(added, bin: record.isBin)
                        touched.insert(added)
                    }
                }
            } else {
                let next = Self.ids(in: after)
                for removed in record.ids.subtracting(next) {
                    decrement(removed, bin: record.isBin)
                    touched.insert(removed)
                }
                for added in next.subtracting(record.ids) {
                    increment(added, bin: record.isBin)
                    touched.insert(added)
                }
                record.ids = next
            }
            record.fetch = after
            albums[key] = record
        }
        return touched
    }

    private func rebuildAllAlbumsOffMain() async {
        guard let collectionFetch else { return }
        let selectedBinID = GalleryRecycleBin.existingCollection()?.localIdentifier
        let built = await Task.detached(priority: .utility) {
            var values: [(String, PHFetchResult<PHAsset>, Set<String>, Bool, String?)] = []
            var albumCounts: [String: Int] = [:]
            var binCounts: [String: Int] = [:]
            for index in 0..<collectionFetch.count {
                let collection = collectionFetch.object(at: index)
                guard collection.assetCollectionType == .album,
                      collection.assetCollectionSubtype == .albumRegular else { continue }
                let fetch = PHAsset.fetchAssets(in: collection, options: nil)
                let ids = Self.ids(in: fetch)
                let isBin = collection.localIdentifier == selectedBinID
                values.append((collection.localIdentifier, fetch, ids, isBin, collection.localizedTitle))
                for id in ids {
                    albumCounts[id, default: 0] += 1
                    if isBin { binCounts[id, default: 0] += 1 }
                }
            }
            return (values, albumCounts, binCounts)
        }.value
        canonicalBinID = selectedBinID
        albums.removeAll(keepingCapacity: true)
        for (id, fetch, ids, isBin, title) in built.0 {
            albums[id] = AlbumRecord(fetch: fetch, ids: ids, isBin: isBin, title: title)
        }
        albumRefCounts = built.1
        binRefCounts = built.2
    }

    private func rebuildAssetIDMap(_ fetch: PHFetchResult<PHAsset>) {
        assetIDs.removeAll(keepingCapacity: true)
        assetIsVideo.removeAll(keepingCapacity: true)
        assetIDs.reserveCapacity(fetch.count)
        for i in 0..<fetch.count {
            let asset = fetch.object(at: i)
            assetIDs.append(asset.localIdentifier)
            assetIsVideo.append(asset.mediaType == .video)
        }
        indexByID = Dictionary(uniqueKeysWithValues: assetIDs.enumerated().map { ($1, $0) })
    }

    private func rebuildSnapshots() {
        guard let fetch = assetFetch else { return }
        snapshots.removeAll(keepingCapacity: true)
        for scope in [GalleryVirtualScope.photos, .unfiled, .recycleBin] {
            var all: [Int] = []
            var photos: [Int] = []
            var videos: [Int] = []
            all.reserveCapacity(assetIDs.count)
            photos.reserveCapacity(assetIDs.count)
            videos.reserveCapacity(assetIDs.count)
            for (index, id) in assetIDs.enumerated() {
                let included: Bool
                switch scope {
                case .photos: included = (binRefCounts[id] ?? 0) == 0
                case .unfiled: included = (albumRefCounts[id] ?? 0) == 0
                case .recycleBin: included = (binRefCounts[id] ?? 0) > 0
                }
                if included {
                    all.append(index)
                    if assetIsVideo[index] { videos.append(index) }
                    else { photos.append(index) }
                }
            }
            let photoCount = photos.count
            let videoCount = videos.count
            let orders: [GalleryVirtualMediaFilter: [Int]] = [
                .all: all, .photos: photos, .videos: videos,
            ]
            for (mediaFilter, order) in orders {
                snapshots[GalleryVirtualSnapshotKey(scope: scope, mediaFilter: mediaFilter)] = GalleryVirtualLibrarySnapshot(
                    fetch: fetch, displayOrder: order, photoCount: photoCount, videoCount: videoCount
                )
            }
        }
        // Exact membership-removal deltas are published by updateSnapshots(for:), which
        // retains the prior source indexes. A global index shift invalidates that comparison.
        removedFromPhotos = []
        removedFromUnfiled = []
        revision &+= 1
    }

    private func rebuildSnapshotsOffMain(
        removedCandidateIDs: Set<String> = [],
        priorIndexByID: [String: Int]? = nil
    ) async {
        guard let fetch = assetFetch else { return }
        let generation = membershipGeneration
        let ids = assetIDs
        let isVideo = assetIsVideo
        let albumCounts = albumRefCounts
        let recycleCounts = binRefCounts
        let oldPhotos = snapshots[GalleryVirtualSnapshotKey(scope: .photos, mediaFilter: .all)]?.displayOrder ?? []
        let oldUnfiled = snapshots[GalleryVirtualSnapshotKey(scope: .unfiled, mediaFilter: .all)]?.displayOrder ?? []
        let candidateIndexes = removedCandidateIDs.map { id in
            (id, priorIndexByID?[id] ?? indexByID[id], indexByID[id])
        }
        let orders = await Task.detached(priority: .utility) {
            Self.makeSnapshotOrders(
                assetIDs: ids, assetIsVideo: isVideo,
                albumRefCounts: albumCounts, binRefCounts: recycleCounts
            )
        }.value
        guard generation == membershipGeneration else {
            await rebuildSnapshotsOffMain(
                removedCandidateIDs: removedCandidateIDs,
                priorIndexByID: priorIndexByID
            )
            return
        }
        snapshots.removeAll(keepingCapacity: true)
        for (scope, filteredOrders) in orders {
            let photoCount = filteredOrders[.photos]?.count ?? 0
            let videoCount = filteredOrders[.videos]?.count ?? 0
            for (mediaFilter, order) in filteredOrders {
                snapshots[GalleryVirtualSnapshotKey(scope: scope, mediaFilter: mediaFilter)] = GalleryVirtualLibrarySnapshot(
                    fetch: fetch, displayOrder: order,
                    photoCount: photoCount, videoCount: videoCount
                )
            }
        }
        let newPhotos = Set(orders[.photos]?[.all] ?? [])
        let newUnfiled = Set(orders[.unfiled]?[.all] ?? [])
        removedFromPhotos = Set(candidateIndexes.compactMap { id, oldIndex, newIndex in
            let wasIncluded = oldIndex.map { oldPhotos.binarySearch($0).isFound } ?? false
            let isIncluded = newIndex.map { newPhotos.contains($0) } ?? false
            return wasIncluded && !isIncluded ? id : nil
        })
        removedFromUnfiled = Set(candidateIndexes.compactMap { id, oldIndex, newIndex in
            let wasIncluded = oldIndex.map { oldUnfiled.binarySearch($0).isFound } ?? false
            let isIncluded = newIndex.map { newUnfiled.contains($0) } ?? false
            return wasIncluded && !isIncluded ? id : nil
        })
        revision &+= 1
    }

    nonisolated private static func makeSnapshotOrders(
        assetIDs: [String],
        assetIsVideo: [Bool],
        albumRefCounts: [String: Int],
        binRefCounts: [String: Int]
    ) -> [GalleryVirtualScope: [GalleryVirtualMediaFilter: [Int]]] {
        var result: [GalleryVirtualScope: [GalleryVirtualMediaFilter: [Int]]] = [:]
        for scope in [GalleryVirtualScope.photos, .unfiled, .recycleBin] {
            var all: [Int] = []
            var photos: [Int] = []
            var videos: [Int] = []
            all.reserveCapacity(assetIDs.count)
            photos.reserveCapacity(assetIDs.count)
            videos.reserveCapacity(assetIDs.count)
            for (index, id) in assetIDs.enumerated() {
                let included: Bool
                switch scope {
                case .photos: included = (binRefCounts[id] ?? 0) == 0
                case .unfiled: included = (albumRefCounts[id] ?? 0) == 0
                case .recycleBin: included = (binRefCounts[id] ?? 0) > 0
                }
                guard included else { continue }
                all.append(index)
                if assetIsVideo[index] { videos.append(index) }
                else { photos.append(index) }
            }
            result[scope] = [.all: all, .photos: photos, .videos: videos]
        }
        return result
    }

    /// Album membership moves touch only the changed assets. Binary search locates each
    /// source index; no 100k-asset membership pass is needed for the common move case.
    private func updateSnapshots(for ids: Set<String>) {
        guard !ids.isEmpty, let fetch = assetFetch else { return }
        var removedPhotos = Set<String>()
        var removedUnfiled = Set<String>()
        for scope in [GalleryVirtualScope.photos, .unfiled, .recycleBin] {
            for mediaFilter in [GalleryVirtualMediaFilter.all, .photos, .videos] {
                let key = GalleryVirtualSnapshotKey(scope: scope, mediaFilter: mediaFilter)
                guard let old = snapshots[key] else { continue }
                var order = old.displayOrder
                for id in ids {
                    guard let index = indexByID[id] else { continue }
                    if mediaFilter == .photos && assetIsVideo[index] { continue }
                    if mediaFilter == .videos && !assetIsVideo[index] { continue }
                    let included: Bool
                    switch scope {
                    case .photos: included = (binRefCounts[id] ?? 0) == 0
                    case .unfiled: included = (albumRefCounts[id] ?? 0) == 0
                    case .recycleBin: included = (binRefCounts[id] ?? 0) > 0
                    }
                    let position = order.binarySearch(index)
                    if included, case let .insertionPoint(at) = position {
                        order.insert(index, at: at)
                    } else if !included, case let .found(at) = position {
                        order.remove(at: at)
                        if scope == .photos, mediaFilter == .all { removedPhotos.insert(id) }
                        if scope == .unfiled, mediaFilter == .all { removedUnfiled.insert(id) }
                    }
                }
                let photoCount = snapshots[GalleryVirtualSnapshotKey(scope: scope, mediaFilter: .photos)]?.displayOrder.count ?? 0
                let videoCount = snapshots[GalleryVirtualSnapshotKey(scope: scope, mediaFilter: .videos)]?.displayOrder.count ?? 0
                snapshots[key] = GalleryVirtualLibrarySnapshot(
                    fetch: fetch, displayOrder: order, photoCount: photoCount, videoCount: videoCount
                )
            }
        }
        for scope in [GalleryVirtualScope.photos, .unfiled, .recycleBin] {
            let photoCount = snapshots[GalleryVirtualSnapshotKey(scope: scope, mediaFilter: .photos)]?.displayOrder.count ?? 0
            let videoCount = snapshots[GalleryVirtualSnapshotKey(scope: scope, mediaFilter: .videos)]?.displayOrder.count ?? 0
            for mediaFilter in [GalleryVirtualMediaFilter.all, .photos, .videos] {
                let key = GalleryVirtualSnapshotKey(scope: scope, mediaFilter: mediaFilter)
                guard let current = snapshots[key] else { continue }
                snapshots[key] = GalleryVirtualLibrarySnapshot(
                    fetch: fetch, displayOrder: current.displayOrder,
                    photoCount: photoCount, videoCount: videoCount
                )
            }
        }
        removedFromPhotos = removedPhotos
        removedFromUnfiled = removedUnfiled
        revision &+= 1
    }

    private func increment(_ id: String, bin: Bool) {
        albumRefCounts[id, default: 0] += 1
        if bin { binRefCounts[id, default: 0] += 1 }
    }

    private func incrementBin(_ id: String) {
        binRefCounts[id, default: 0] += 1
    }

    private func decrement(_ id: String, bin: Bool) {
        if let count = albumRefCounts[id] {
            if count <= 1 { albumRefCounts.removeValue(forKey: id) }
            else { albumRefCounts[id] = count - 1 }
        }
        if bin, let count = binRefCounts[id] {
            if count <= 1 { binRefCounts.removeValue(forKey: id) }
            else { binRefCounts[id] = count - 1 }
        }
    }

    private func decrementBin(_ id: String) {
        guard let count = binRefCounts[id] else { return }
        if count <= 1 { binRefCounts.removeValue(forKey: id) }
        else { binRefCounts[id] = count - 1 }
    }

    private func reset() {
        buildGeneration += 1
        membershipGeneration &+= 1
        assetFetch = nil
        collectionFetch = nil
        albums.removeAll()
        assetIDs.removeAll()
        assetIsVideo.removeAll()
        indexByID.removeAll()
        albumRefCounts.removeAll()
        binRefCounts.removeAll()
        canonicalBinID = nil
        buildTask = nil
        needsFullRefresh = false
        snapshotNeedsRebuild = false
        snapshots.removeAll()
        removedFromPhotos = []
        removedFromUnfiled = []
        revision &+= 1
    }

    private func emptyFetch() -> PHFetchResult<PHAsset> {
        PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil)
    }

    nonisolated private static func ids(in fetch: PHFetchResult<PHAsset>) -> Set<String> {
        var ids = Set<String>()
        ids.reserveCapacity(fetch.count)
        for i in 0..<fetch.count { ids.insert(fetch.object(at: i).localIdentifier) }
        return ids
    }

    nonisolated private static func fetchAllImageAndVideoAssets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType IN %@",
            [PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue]
        )
        return PHAsset.fetchAssets(with: options)
    }
}

private extension Array where Element == Int {
    enum SearchResult {
        case found(Int), insertionPoint(Int)

        var isFound: Bool {
            if case .found = self { return true }
            return false
        }
    }

    func binarySearch(_ value: Int) -> SearchResult {
        var low = 0
        var high = count
        while low < high {
            let middle = low + (high - low) / 2
            if self[middle] < value { low = middle + 1 }
            else { high = middle }
        }
        return low < count && self[low] == value ? .found(low) : .insertionPoint(low)
    }
}
