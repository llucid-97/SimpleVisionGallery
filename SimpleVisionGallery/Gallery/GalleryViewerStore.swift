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

    /// Hand off to the same successor that committing a current-item removal would choose.
    /// At the end of the playlist, use the previous item; a sole item leaves an empty viewer.
    func cursorAfterRemoving(_ cursor: Int?) -> Int? {
        guard let cursor, count > 1, !removed.contains(cursor) else { return nil }
        let position = position(of: cursor)
        return index(at: position + 1) ?? index(at: position - 1)
    }

    mutating func restore(_ indexes: IndexSet) { removed.subtract(indexes) }

    mutating func remove(_ indexes: IndexSet) {
        removed.formUnion(indexes.intersection(IndexSet(integersIn: 0..<originalCount)))
    }
}

/// A bounded-memory permutation of live playlist positions. No photo records are copied.
nonisolated struct GalleryShuffleOrder {
    let count: Int
    let first: Int
    let seed: UInt64

    init(count: Int, first: Int, seed: UInt64 = .random(in: .min ... .max)) {
        self.count = count
        self.first = first
        self.seed = seed
    }

    func index(at position: Int) -> Int? {
        guard count > 0, position >= 0, position < count else { return nil }
        if count == 1 { return 0 }
        let shuffled = permute(position)
        if position == 0 { return first }
        return shuffled == first ? permute(0) : shuffled
    }

    private func permute(_ value: Int) -> Int {
        // A balanced Feistel network permutes a power-of-four domain; cycle walking
        // restricts it to the live count without allocating an array for a large album.
        let bits = (UInt64.bitWidth - UInt64(count - 1).leadingZeroBitCount + 1) / 2
        let mask = (UInt64(1) << bits) - 1
        func round(_ value: UInt64, _ round: UInt64) -> UInt64 {
            var x = value &+ seed &+ (round &* 0x9e3779b97f4a7c15)
            x = (x ^ (x >> 30)) &* 0xbf58476d1ce4e5b9
            x = (x ^ (x >> 27)) &* 0x94d049bb133111eb
            return (x ^ (x >> 31)) & mask
        }
        var result = UInt64(value)
        repeat {
            var left = result >> bits
            var right = result & mask
            for r in 0..<6 {
                (left, right) = (right, left ^ round(right, UInt64(r)))
            }
            result = (left << bits) | right
        } while result >= UInt64(count)
        return Int(result)
    }
}

#if os(visionOS)
import Combine
import OSLog
@preconcurrency import Photos

@MainActor
struct GalleryViewerSnapshot {
    let id: UUID
    let album: GalleryAlbum
    let fetch: PHFetchResult<PHAsset>
    let displayOrder: [Int]?
    // Carry committed grid removals into new playlists without losing pending rollback state.
    var committedNativeRemovals = IndexSet()
    var vaultRecords: [GalleryVaultRecord] = []
    var mediaFilter: GalleryMediaFilter = .all
    var mediaSearch: String = ""
    var vaultSort: GalleryAssetSortMode = .photosOrder
    var vaultSortAscending: Bool = true
    var vaultShuffleSeed = UUID()

    var nativeCount: Int { displayOrder?.count ?? fetch.count }
    var count: Int { nativeCount + vaultRecords.count }
}

@MainActor
fileprivate final class GalleryViewerPlaylist {
    var snapshot: GalleryViewerSnapshot
    var index: GalleryPlaylistIndex
    private var needsFreshMetadata = false
    private var displayIndexBySource: [Int: Int]?
    private(set) var vaultPositionByID: [UUID: Int]
    private let metadataCache: NSCache<NSString, PHAsset> = {
        let cache = NSCache<NSString, PHAsset>()
        cache.countLimit = 16
        return cache
    }()
    struct PendingRemoval { var position: Int; var confirmed = false }
    var pendingRemovals: [String: PendingRemoval] = [:]
    var changeGeneration = UUID()

    init(_ snapshot: GalleryViewerSnapshot) {
        self.snapshot = snapshot
        index = GalleryPlaylistIndex(originalCount: snapshot.count)
        index.remove(snapshot.committedNativeRemovals)
        vaultPositionByID = Dictionary(uniqueKeysWithValues: snapshot.vaultRecords.enumerated().map {
            ($1.id, snapshot.nativeCount + $0)
        })
        displayIndexBySource = snapshot.displayOrder.map { order in
            Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        }
    }

    func dropNativeFetch(_ emptyFetch: PHFetchResult<PHAsset>, album: GalleryAlbum) {
        let old = snapshot
        snapshot = GalleryViewerSnapshot(id: old.id, album: album, fetch: emptyFetch,
            displayOrder: nil, vaultRecords: old.vaultRecords, mediaFilter: old.mediaFilter,
            mediaSearch: old.mediaSearch, vaultSort: old.vaultSort,
            vaultSortAscending: old.vaultSortAscending, vaultShuffleSeed: old.vaultShuffleSeed)
        displayIndexBySource = nil
        metadataCache.removeAllObjects()
        needsFreshMetadata = false
        setVaultRecords(snapshot.vaultRecords)
        changeGeneration = UUID()
    }

    func setVaultRecords(_ records: [GalleryVaultRecord]) {
        snapshot.vaultRecords = records
        vaultPositionByID = Dictionary(uniqueKeysWithValues: records.enumerated().map {
            ($1.id, snapshot.nativeCount + $0)
        })
    }

    func displayIndex(forSource sourceIndex: Int) -> Int? {
        if let displayIndexBySource { return displayIndexBySource[sourceIndex] }
        return sourceIndex < snapshot.nativeCount ? sourceIndex : nil
    }

    func item(at displayIndex: Int) -> GalleryMediaItem? {
        guard displayIndex >= 0, displayIndex < index.originalCount, !index.removed.contains(displayIndex) else { return nil }
        if displayIndex >= snapshot.nativeCount {
            let vaultIndex = displayIndex - snapshot.nativeCount
            guard snapshot.vaultRecords.indices.contains(vaultIndex) else { return nil }
            return .vault(snapshot.vaultRecords[vaultIndex])
        }
        return .photos(asset(at: displayIndex))
    }

    private func asset(at displayIndex: Int) -> PHAsset {
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
    fileprivate var cursorGeneration = UUID()
    fileprivate var shuffleOrder: GalleryShuffleOrder?
    fileprivate var shufflePosition = 0

    fileprivate func setCursor(_ value: Int?, shufflePosition: Int? = nil) {
        guard cursor != value else { return }
        cursorGeneration = UUID()
        cursor = value
        if let shufflePosition {
            self.shufflePosition = shufflePosition
        } else {
            rebaseShuffle()
        }
    }

    fileprivate func rebaseShuffle() {
        guard shuffleOrder != nil else { return }
        // Membership changes rebuild the remaining order; never restore an old
        // optimistic cursor into a different permutation.
        cursorGeneration = UUID()
        guard let cursor, playlist.index.count > 0 else { shuffleOrder = nil; shufflePosition = 0; return }
        shuffleOrder = GalleryShuffleOrder(count: playlist.index.count, first: playlist.index.position(of: cursor))
        shufflePosition = 0
    }

    fileprivate func orderedIndex(at position: Int) -> Int? {
        let rank = shuffleOrder?.index(at: position) ?? (shuffleOrder == nil ? position : -1)
        return playlist.index.index(at: rank)
    }

    fileprivate init(playlist: GalleryViewerPlaylist, cursor: Int) {
        self.playlist = playlist
        self.cursor = playlist.index.survivingCursor(cursor)
    }

    var albumID: String { playlist.snapshot.album.id }
    var albumTitle: String { playlist.snapshot.album.title }
    var sourceAlbumID: String? { playlist.snapshot.album.virtualScope == nil ? albumID : nil }
    var canRemoveFromSourceAlbum: Bool {
        let album = playlist.snapshot.album
        return album.virtualScope == nil && album.collection?.canPerform(.removeContent) == true
    }
    var currentItem: GalleryMediaItem? { cursor.flatMap { playlist.item(at: $0) } }
    var currentAsset: PHAsset? { currentItem?.photosAsset }
    var nextItem: GalleryMediaItem? {
        guard cursor != nil,
              let next = orderedIndex(at: position)
        else { return nil }
        return playlist.item(at: next)
    }
    var nextAsset: PHAsset? { nextItem?.photosAsset }

    func upcomingItems(limit: Int) -> [GalleryMediaItem] {
        guard cursor != nil, limit > 0 else { return [] }
        let currentPosition = position - 1
        let available = min(limit, playlist.index.count - currentPosition - 1)
        guard available > 0 else { return [] }
        return (1...available).compactMap { offset in
            orderedIndex(at: currentPosition + offset).flatMap { playlist.item(at: $0) }
        }
    }

    func precedingItems(limit: Int) -> [GalleryMediaItem] {
        guard cursor != nil, limit > 0 else { return [] }
        let currentPosition = position - 1
        let available = min(limit, currentPosition)
        guard available > 0 else { return [] }
        return (1...available).compactMap { offset in
            orderedIndex(at: currentPosition - offset).flatMap { playlist.item(at: $0) }
        }
    }

    func upcomingAssets(limit: Int) -> [PHAsset] { upcomingItems(limit: limit).compactMap(\.photosAsset) }
    func precedingAssets(limit: Int) -> [PHAsset] { precedingItems(limit: limit).compactMap(\.photosAsset) }

    var count: Int { playlist.index.count }
    var position: Int { cursor.map { shuffleOrder == nil ? playlist.index.position(of: $0) + 1 : shufflePosition + 1 } ?? 0 }
    var canGoPrevious: Bool { position > 1 }
    var canGoNext: Bool { position > 0 && position < count }
}

@MainActor
final class GalleryViewerStore: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = GalleryViewerStore()
    @Published private(set) var sessions: [UUID: GalleryViewerSession] = [:]
    @Published private(set) var albums: [GalleryAlbum] = []
    private static let gateLog = Logger(subsystem: "com.llucid.simplevisiongallery", category: "viewer-gate")
    @Published private(set) var pendingPhotosSessionID: UUID?
    @Published private(set) var isPerformingOperation = false
    private var playlists: [UUID: GalleryViewerPlaylist] = [:]
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var albumRefreshGeneration = UUID()
    private var membershipSubscription: AnyCancellable?
    private var vaultSubscription: AnyCancellable?
    private var vaultTransferSubscription: AnyCancellable?
    private var albumDeletionSubscription: AnyCancellable?
    private var vaultRestoreSubscription: AnyCancellable?
    private var restoredVaultIDs: Set<UUID> = []
    private var vaultIndex = GalleryVaultIndex()
    private var queuedVaultUpdates = Set<UUID>()
    private var vaultUpdateTask: Task<Void, Never>?

    private override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
        vaultTransferSubscription = NotificationCenter.default.publisher(for: .galleryVaultDidHideItems)
            .sink { [weak self] notification in
                guard let ids = notification.userInfo?["sourceIdentifierSet"] as? Set<String>, !ids.isEmpty else { return }
                self?.removeTransferredIDs(ids)
            }
        vaultRestoreSubscription = NotificationCenter.default.publisher(for: .galleryVaultDidRestoreItem)
            .sink { [weak self] notification in
                guard let self, let record = notification.userInfo?["record"] as? GalleryVaultRecord else { return }
                self.restoredVaultIDs.insert(record.id)
                for playlist in self.playlists.values {
                    guard let position = playlist.vaultPositionByID[record.id] else { continue }
                    self.applyRemovals(IndexSet(integer: position), to: playlist)
                }
            }
        vaultSubscription = GalleryVaultService.shared.$records.combineLatest(GalleryVaultService.shared.$isUnlocked)
            .sink { [weak self] records, unlocked in
                guard let self else { return }
                let service = GalleryVaultService.shared
                if unlocked && service.isPublishingQueuedMutations {
                    self.scheduleVaultPlaylistUpdate(service.publishingMutationIDs, epoch: service.authEpoch)
                    return
                }
                self.vaultUpdateTask?.cancel()
                self.queuedVaultUpdates.removeAll()
                let visibleRecords = unlocked ? records : []
                if !self.restoredVaultIDs.isEmpty { self.restoredVaultIDs.formIntersection(Set(visibleRecords.map(\.id))) }
                self.updateVaultPlaylists(visibleRecords)
            }
        albumDeletionSubscription = NotificationCenter.default.publisher(for: .galleryAlbumWasDeleted).sink { [weak self] notification in
            if let id = notification.userInfo?["albumID"] as? String { self?.closeDeletedAlbum(id) }
        }
        membershipSubscription = GalleryVirtualLibraryIndex.shared.$revision.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            let index = GalleryVirtualLibraryIndex.shared
            self.removeVirtualIDs(index.removedFromPhotos, scope: .photos)
            self.removeVirtualIDs(index.removedFromUnfiled, scope: .unfiled)
        }
    }

    func createSession(from manager: GalleryManager, at displayIndex: Int) -> UUID? {
        guard let snapshot = manager.viewerSnapshot(),
              let displayIndex = manager.viewerIndex(forDisplayIndex: displayIndex),
              displayIndex >= 0, displayIndex < snapshot.count else { return nil }
        let playlist = playlists[snapshot.id] ?? GalleryViewerPlaylist(snapshot)
        playlists[snapshot.id] = playlist
        for request in GalleryDeleteQueue.shared.pendingRequests {
            stageQueuedDelete(request, asset: GalleryDeleteQueue.shared.pendingPhotoAssets[request.itemID], in: playlist)
        }
        guard !playlist.index.removed.contains(displayIndex) else { return nil }
        let session = GalleryViewerSession(playlist: playlist, cursor: displayIndex)
        sessions[session.id] = session
        albums = manager.albums
        return session.id
    }

    func session(_ id: UUID) -> GalleryViewerSession? { sessions[id] }

    /// Rebind surviving unlocked vault sessions to an empty Photos fetch.
    func revokePhotoAccess() {
        let emptyFetch = PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil)
        for playlist in Array(playlists.values) {
            let old = playlist.snapshot
            let oldNativeCount = old.nativeCount
            let oldRemoved = playlist.index.removed
            let remaining = old.vaultRecords.indices.filter { !oldRemoved.contains(oldNativeCount + $0) }
            if remaining.isEmpty {
                objectWillChange.send()
                for session in sessions.values.filter({ $0.playlist === playlist }) {
                    sessions.removeValue(forKey: session.id)
                }
                playlists.removeValue(forKey: old.id)
                continue
            }
            let album = old.album
            let privateTitle = old.vaultRecords.lazy.flatMap(\.albums).first(where: { $0.id == album.id })?.title
            let reboundAlbum = GalleryAlbum(id: album.id, title: privateTitle ?? album.title,
                assetCount: 0, collection: nil, coverAsset: nil, virtualScope: album.virtualScope,
                photoCount: 0, videoCount: 0)
            let cursors = sessions.values.filter { $0.playlist === playlist }.map { ($0, $0.cursor) }
            playlist.dropNativeFetch(emptyFetch, album: reboundAlbum)
            var index = GalleryPlaylistIndex(originalCount: old.vaultRecords.count)
            index.remove(IndexSet(old.vaultRecords.indices.filter { oldRemoved.contains(oldNativeCount + $0) }))
            playlist.index = index
            objectWillChange.send()
            for (session, cursor) in cursors {
                let oldVaultOffset = cursor.flatMap { $0 >= oldNativeCount ? $0 - oldNativeCount : nil }
                let desired = oldVaultOffset ?? index.index(at: 0)
                session.setCursor(index.survivingCursor(desired))
                session.rebaseShuffle()
                session.revision += 1
            }
        }
    }


    func duplicateSession(_ id: UUID) -> UUID? {
        guard let original = sessions[id], let cursor = original.cursor else { return nil }
        let duplicate = GalleryViewerSession(playlist: original.playlist, cursor: cursor)
        duplicate.shuffleOrder = original.shuffleOrder
        duplicate.shufflePosition = original.shufflePosition
        sessions[duplicate.id] = duplicate
        return duplicate.id
    }

    func next(_ id: UUID) { navigate(id, offset: 1) }
    func previous(_ id: UUID) { navigate(id, offset: -1) }

    func shuffle(_ id: UUID) {
        guard let session = sessions[id], let cursor = session.cursor, session.count > 1 else { return }
        objectWillChange.send()
        session.shuffleOrder = GalleryShuffleOrder(count: session.count,
            first: session.playlist.index.position(of: cursor))
        session.shufflePosition = 0
        session.cursorGeneration = UUID()
        session.revision += 1
    }

    private func navigate(_ id: UUID, offset: Int) {
        guard let session = sessions[id], session.cursor != nil else { return }
        let position = session.position - 1 + offset
        guard let next = session.orderedIndex(at: position) else { return }
        objectWillChange.send()
        session.setCursor(next, shufflePosition: position)
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
        let started = ProcessInfo.processInfo.systemUptime
        Self.gateLog.info("refresh_begin")
        defer { Self.gateLog.info("refresh_end duration_ms=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000), privacy: .public)") }
        Task { await GalleryVirtualLibraryIndex.shared.refreshAlbumEmptiness() }
        let generation = UUID()
        albumRefreshGeneration = generation
        let fetch = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var result: [GalleryAlbum] = albums.filter { $0.virtualScope != nil }
        for index in 0..<fetch.count {
            let collection = fetch.object(at: index)
            // Move destinations need metadata, not per-album media counts.
            result.append(GalleryAlbum(id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Album", assetCount: 0,
                collection: collection, coverAsset: nil, photoCount: 0, videoCount: 0))
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
                displayOrder: playlist.snapshot.displayOrder,
                committedNativeRemovals: playlist.snapshot.committedNativeRemovals,
                vaultRecords: playlist.snapshot.vaultRecords,
                mediaFilter: playlist.snapshot.mediaFilter,
                mediaSearch: playlist.snapshot.mediaSearch,
                vaultSort: playlist.snapshot.vaultSort,
                vaultSortAscending: playlist.snapshot.vaultSortAscending,
                vaultShuffleSeed: playlist.snapshot.vaultShuffleSeed
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
                displayOrder: playlist.snapshot.displayOrder,
                committedNativeRemovals: playlist.snapshot.committedNativeRemovals,
                vaultRecords: playlist.snapshot.vaultRecords,
                mediaFilter: playlist.snapshot.mediaFilter,
                mediaSearch: playlist.snapshot.mediaSearch,
                vaultSort: playlist.snapshot.vaultSort,
                vaultSortAscending: playlist.snapshot.vaultSortAscending,
                vaultShuffleSeed: playlist.snapshot.vaultShuffleSeed
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
        try await mutate(id, destination: collection, newAlbumName: nil, expectedAssetID: expectedAssetID)
        await refreshAlbums()
    }

    func move(_ id: UUID, toNewAlbumNamed name: String, expectedAssetID: String? = nil) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ViewerMutationError.emptyName }
        try await mutate(id, destination: nil, newAlbumName: name, expectedAssetID: expectedAssetID)
        await refreshAlbums()
    }

    /// Freeze the target before any suspension, and mask it in every open playlist.
    func stageQueuedDelete(_ request: GalleryDeleteRequest, asset: PHAsset?) {
        for playlist in playlists.values { stageQueuedDelete(request, asset: asset, in: playlist) }
    }

    /// Hide the pending item and move affected cursors so the viewer responds immediately.
    private func stageQueuedDelete(_ request: GalleryDeleteRequest, asset: PHAsset?, in playlist: GalleryViewerPlaylist) {
        let position: Int?
        switch request.target {
        case .vault(let id, _): position = playlist.vaultPositionByID[id]
        case .photos:
            let source = asset.map { playlist.snapshot.fetch.index(of: $0) } ?? NSNotFound
            position = source == NSNotFound ? nil : playlist.displayIndex(forSource: source)
        }
        guard let position, !playlist.index.removed.contains(position) else { return }
        let handoffs = sessions.values.filter { $0.playlist === playlist && $0.cursor == position }.map { session in
            let successor = session.canGoNext ? session.position : session.position - 2
            return (session, session.orderedIndex(at: successor))
        }
        playlist.pendingRemovals[request.itemID] = .init(position: position)
        playlist.index.remove(IndexSet(integer: position))
        for (session, successor) in handoffs { session.setCursor(successor) }
        notify(playlist, orderChanged: true)
    }

    /// Reconcile each playlist after the backend finishes, restoring failed removals.
    func finishQueuedDelete(_ request: GalleryDeleteRequest, succeeded: Bool) {
        // Reconcile every affected playlist so failed items can return at their saved positions.
        for playlist in playlists.values {
            guard let pending = playlist.pendingRemovals.removeValue(forKey: request.itemID) else { continue }
            let keepRemoved: Bool
            switch request.target {
            case .vault:
                let album = playlist.snapshot.album
                let inBin = album.virtualScope == .recycleBin || GalleryRecycleBin.isRecycleBinTitle(album.title)
                if case .moveToVault(_, _, let sourceID) = request.action {
                    keepRemoved = succeeded && (album.id == sourceID || (sourceID == nil && album.virtualScope == .unfiled))
                } else { keepRemoved = succeeded && request.action.keepsVaultItemHidden(inRecycleBin: inBin) }
            case .photos(_, let sourceID):
                let album = playlist.snapshot.album
                switch request.action {
                case .moveToPhotos, .removeFromAlbum:
                    keepRemoved = succeeded && (album.id == sourceID || (sourceID == nil && album.virtualScope == .unfiled))
                default:
                    keepRemoved = succeeded && (request.action == .permanent || album.id == sourceID
                        || album.virtualScope == .photos || album.virtualScope == .unfiled)
                }
            }
            if !keepRemoved && !pending.confirmed {
                playlist.index.restore(IndexSet(integer: pending.position))
                // Do not undo any navigation made while the write was pending.
                for session in sessions.values where session.playlist === playlist && session.cursor == nil {
                    session.setCursor(pending.position)
                }
                notify(playlist, orderChanged: true)
            }
        }
    }

    /// Serialize Photos deletes with moves while running the transaction away from the UI.
    func performQueuedPhotoDeletes(_ requests: [GalleryDeleteRequest], onPhotosWaitChanged: @escaping @MainActor (Bool) -> Void) async -> [UUID: Error] {
        guard !requests.isEmpty else { return [:] }
        // Serialize with existing Move transactions; the delete UI never waits on this gate.
        Self.gateLog.info("queue_acquire_begin")
        await acquireMutation()
        Self.gateLog.info("queue_acquire_end")
        let started = ProcessInfo.processInfo.systemUptime
        onPhotosWaitChanged(true)
        let result = await Task.detached(priority: .userInitiated) {
            await GalleryQueuedPhotoDeletion.execute(requests)
        }.value
        onPhotosWaitChanged(false)
        releaseMutation()
        Self.gateLog.info("queue_release duration_ms=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000), privacy: .public)")
        GalleryVirtualLibraryIndex.shared.invalidate()
        return result
    }

    /// Execute the captured Photos target without consulting the now-advanced viewer cursor.
    func performQueuedPhotoMove(_ request: GalleryDeleteRequest, onPhotosWaitChanged: @escaping @MainActor (Bool) -> Void) async -> Error? {
        await acquireMutation()
        let result: Result<GalleryQueuedPhotoMove.Result, Error>
        onPhotosWaitChanged(true)
        do {
            let value = try await Task.detached(priority: .userInitiated) {
                try await GalleryQueuedPhotoMove.execute(request)
            }.value
            result = .success(value)
        } catch { result = .failure(error) }
        onPhotosWaitChanged(false)
        releaseMutation()
        switch result {
        case .failure(let error): return error
        case .success(let value):
            guard case .photos(let id, let sourceID) = request.target else { return nil }
            GalleryVirtualLibraryIndex.shared.applyLocalMembershipDelta(assetIDs: [id],
                addedAlbumID: value.destinationID, removedAlbumID: sourceID)
            if let destinationID = value.destinationID { GalleryMoveHistory.shared.recordSuccessfulMove(to: destinationID) }
            return nil
        }
    }

    /// Removes the current item from its real source album without deleting it
    /// from Photos or placing it in Recycle Bin.
    func removeFromSourceAlbum(sessionID: UUID, expectedAssetID: String) async throws {
        guard let session = sessions[sessionID], let asset = session.currentAsset else { throw ViewerMutationError.noAsset }
        guard asset.localIdentifier == expectedAssetID else { return }
        guard session.playlist.snapshot.album.virtualScope == nil else { throw ViewerMutationError.sourceNotEditable }
        try await withMutation(sessionID: sessionID) {
            guard let live = sessions[sessionID], live.currentAsset?.localIdentifier == expectedAssetID else { return }
            guard let source = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [session.albumID], options: nil).firstObject,
                  source.canPerform(.removeContent) else { throw ViewerMutationError.sourceNotEditable }
            var staged = false
            Self.gateLog.info("remove_change_begin")
            let changeStart = ProcessInfo.processInfo.systemUptime
            try await PHPhotoLibrary.shared().performChanges {
                guard let request = PHAssetCollectionChangeRequest(for: source) else { return }
                request.removeAssets([asset] as NSArray)
                staged = true
            }
            Self.gateLog.info("remove_change_end duration_ms=\(Int((ProcessInfo.processInfo.systemUptime - changeStart) * 1000), privacy: .public)")
            guard staged else { throw ViewerMutationError.changeUnavailable }
            GalleryVirtualLibraryIndex.shared.applyLocalMembershipDelta(assetIDs: [asset.localIdentifier], removedAlbumID: source.localIdentifier)
            synchronizeVirtualMembershipAfterMutation(assets: [asset], addedToAlbum: false,
                recycling: false, removedFromSource: true)
            removeFromAlbum(source.localIdentifier, assets: [asset])
        }
        await refreshAlbums()
    }

    // Capture the requested asset before waiting: a second tap must not act on the next slide.
    private func mutate(_ id: UUID, destination: PHAssetCollection?, newAlbumName: String?, expectedAssetID: String?) async throws {
        guard let session = sessions[id], let asset = session.currentAsset else { throw ViewerMutationError.noAsset }
        guard expectedAssetID == nil || expectedAssetID == asset.localIdentifier else { return }
        let sourceAlbum = session.playlist.snapshot.album
        let sourceID = session.albumID
        try await withMutation(sessionID: id) {
            guard let liveSession = sessions[id], liveSession.currentAsset?.localIdentifier == asset.localIdentifier else { return }
            let source: PHAssetCollection?
            if sourceAlbum.virtualScope == nil {
                guard let realSource = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [sourceID], options: nil).firstObject,
                      realSource.canPerform(.removeContent) else { throw ViewerMutationError.sourceNotEditable }
                source = realSource
            } else {
                source = nil
            }

            let target = destination
            let createName = newAlbumName
            if let target, target.localIdentifier == source?.localIdentifier { return }
            if let target, !target.canPerform(.addContent) { throw ViewerMutationError.destinationNotEditable }
            var staged = false
            var createdIdentifier: String?
            Self.gateLog.info("move_change_begin")
            let changeStart = ProcessInfo.processInfo.systemUptime
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
            Self.gateLog.info("move_change_end duration_ms=\(Int((ProcessInfo.processInfo.systemUptime - changeStart) * 1000), privacy: .public)")
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
        }
    }

    private func withMutation(sessionID: UUID, _ operation: () async throws -> Void) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        Self.gateLog.info("acquire_begin")
        await acquireMutation()
        Self.gateLog.info("acquire_end duration_ms=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000), privacy: .public)")
        let acquired = ProcessInfo.processInfo.systemUptime
        let watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.pendingPhotosSessionID = sessionID
            Self.gateLog.notice("photos_pending duration_ms=\(Int((ProcessInfo.processInfo.systemUptime - acquired) * 1000), privacy: .public)")
        }
        defer {
            watchdog.cancel()
            pendingPhotosSessionID = nil
            releaseMutation()
            Self.gateLog.info("release duration_ms=\(Int((ProcessInfo.processInfo.systemUptime - acquired) * 1000), privacy: .public)")
        }
        do { try await operation() }
        catch {
            Self.gateLog.error("mutation_failed")
            throw error
        }
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
            let removed = IndexSet(sourceRemovals.compactMap { playlist.displayIndex(forSource: $0) })
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
            let displayRemovals = IndexSet(sourceRemovals.compactMap { playlist.displayIndex(forSource: $0) })
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

    /// Remove displayed and nearby items immediately, then scan frozen native fetches in bounded batches.
    /// Deleted identifiers can no longer be fetched from the live library to resolve their old indexes.
    private func removeTransferredIDs(_ identifiers: Set<String>) {
        for playlist in Array(playlists.values) {
            let snapshot = playlist.snapshot
            let nativeCount = snapshot.nativeCount
            guard nativeCount > 0 else { continue }
            var immediate = IndexSet()
            for session in sessions.values where session.playlist === playlist {
                guard session.cursor != nil else { continue }
                let position = session.position - 1
                let lower = max(0, position - 24)
                let upper = min(playlist.index.count, position + 25)
                for offset in lower..<upper {
                    guard let displayIndex = session.orderedIndex(at: offset), displayIndex < nativeCount,
                          let item = playlist.item(at: displayIndex), identifiers.contains(item.localIdentifier) else { continue }
                    immediate.insert(displayIndex)
                }
            }
            applyRemovals(immediate, to: playlist)
            Task { @MainActor [weak self, weak playlist] in
                guard let self, let playlist else { return }
                var start = 0
                while start < nativeCount {
                    guard self.playlists[snapshot.id] === playlist,
                          playlist.snapshot.nativeCount == nativeCount else { return }
                    let end = min(start + 512, nativeCount)
                    var found = IndexSet()
                    for displayIndex in start..<end where !playlist.index.removed.contains(displayIndex) {
                        let source = snapshot.displayOrder?[displayIndex] ?? displayIndex
                        if identifiers.contains(snapshot.fetch.object(at: source).localIdentifier) { found.insert(displayIndex) }
                    }
                    self.applyRemovals(found, to: playlist)
                    start = end
                    await Task.yield()
                }
            }
        }
    }

    /// Rebuild only the vault suffix. Never materialize the native Photos fetch.
    /// Removing the old suffix before releasing metadata prevents locked scenes remaining visible.
    private func scheduleVaultPlaylistUpdate(_ ids: Set<UUID>, epoch: UUID) {
        queuedVaultUpdates.formUnion(ids)
        vaultUpdateTask?.cancel()
        vaultUpdateTask = Task { @MainActor [weak self] in
            // Pending masks already advanced every viewer; give that frame time before metadata work.
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            let service = GalleryVaultService.shared
            guard let self, service.isUnlocked, service.authEpoch == epoch else { return }
            let changes = self.queuedVaultUpdates
            self.queuedVaultUpdates.removeAll()
            self.updateVaultPlaylists(service.records, mutatedIDs: changes)
            self.vaultUpdateTask = nil
        }
    }

    private func updateVaultPlaylists(_ records: [GalleryVaultRecord], mutatedIDs: Set<UUID>? = nil) {
        let service = GalleryVaultService.shared
        if service.isUnlocked, let mutatedIDs {
            vaultIndex.applyMutationChanges(mutatedIDs, records: mutatedIDs.compactMap { GalleryVaultStorage.shared.record(id: $0) })
        } else {
            vaultIndex = GalleryVaultIndex.fromPhotoLibrary(records: records, excludedIDs: restoredVaultIDs)
        }
        for playlist in Array(playlists.values) {
            let old = playlist.snapshot.vaultRecords
            let album = playlist.snapshot.album
            if album.collection == nil, album.virtualScope == nil,
               vaultIndex.albumTitles[album.id] == nil {
                objectWillChange.send()
                for session in sessions.values.filter({ $0.playlist === playlist }) {
                    sessions.removeValue(forKey: session.id)
                }
                playlists.removeValue(forKey: playlist.snapshot.id)
                continue
            }
            let nativeCount = playlist.snapshot.nativeCount
            let next = vaultIndex.records(for: playlist.snapshot.album,
                filter: playlist.snapshot.mediaFilter, search: playlist.snapshot.mediaSearch,
                sort: playlist.snapshot.vaultSort, ascending: playlist.snapshot.vaultSortAscending,
                shuffleSeed: playlist.snapshot.vaultShuffleSeed,
                preservingOrderOf: mutatedIDs != nil ? old : nil, changedIDs: mutatedIDs)
            if !next.isEmpty, old.elementsEqual(next, by: { $0.id == $1.id }) { continue }

            let associated = sessions.values.filter { $0.playlist === playlist }
            let previousCursors: [(GalleryViewerSession, Int?, UUID?, Int)] = associated.map { session in
                let oldOffset = session.cursor.map { $0 - nativeCount }
                let vaultID = oldOffset.flatMap { old.indices.contains($0) ? old[$0].id : nil }
                return (session, session.cursor, vaultID, session.cursor.map { playlist.index.position(of: $0) } ?? 0)
            }
            let oldRemoved = playlist.index.removed
            var newIndex = GalleryPlaylistIndex(originalCount: nativeCount + next.count)
            var preservedRemoved = oldRemoved.intersection(IndexSet(integersIn: 0..<nativeCount))
            let pendingPositions = Set(playlist.pendingRemovals.values.map(\.position))
            let removedVaultPositions = oldRemoved.intersection(IndexSet(integersIn: nativeCount..<(nativeCount + old.count)))
            let previouslyRemovedIDs = Set(removedVaultPositions.compactMap { position in
                pendingPositions.contains(position) ? nil : old[position - nativeCount].id
            })
            for (offset, record) in next.enumerated() where previouslyRemovedIDs.contains(record.id) {
                preservedRemoved.insert(nativeCount + offset)
            }
            newIndex.remove(preservedRemoved)
            playlist.setVaultRecords(next)
            playlist.pendingRemovals = playlist.pendingRemovals.filter { $0.value.position < nativeCount }
            for id in GalleryDeleteQueue.shared.pendingVaultIDs {
                guard let position = playlist.vaultPositionByID[id] else { continue }
                playlist.pendingRemovals["vault:\(id.uuidString)"] = .init(position: position)
                newIndex.remove(IndexSet(integer: position))
            }
            playlist.index = newIndex
            playlist.changeGeneration = UUID()
            let nextPositions = playlist.vaultPositionByID
            objectWillChange.send()
            for (session, oldCursor, vaultID, oldPosition) in previousCursors {
                let desired: Int?
                if let vaultID, let newPosition = nextPositions[vaultID] {
                    desired = newPosition
                } else if let oldCursor, oldCursor < nativeCount {
                    desired = oldCursor
                } else if newIndex.count > 0 {
                    desired = newIndex.index(at: min(oldPosition, newIndex.count - 1))
                } else {
                    desired = nil
                }
                session.setCursor(newIndex.survivingCursor(desired))
                session.rebaseShuffle()
                session.revision += 1
            }
        }
    }

    private func closeDeletedAlbum(_ albumID: String) {
        let ids = Set(sessions.values.filter { $0.albumID == albumID }.map(\.id))
        guard !ids.isEmpty else { return }
        NotificationCenter.default.post(name: .galleryViewerAlbumDeleted, object: nil, userInfo: ["sessionIDs": ids])
        for id in ids { disposeSession(id) }
    }

    private func applyRemovals(_ removed: IndexSet, to playlist: GalleryViewerPlaylist) {
        for (id, pending) in playlist.pendingRemovals where removed.contains(pending.position) {
            playlist.pendingRemovals[id]?.confirmed = true
        }
        guard !removed.subtracting(playlist.index.removed).isEmpty else { return }
        playlist.index.remove(removed)
        notify(playlist, orderChanged: true)
    }

    private func notify(_ playlist: GalleryViewerPlaylist, orderChanged: Bool = false) {
        objectWillChange.send()
        for session in sessions.values where session.playlist === playlist {
            session.setCursor(playlist.index.survivingCursor(session.cursor))
            if orderChanged { session.rebaseShuffle() }
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
                closeDeletedAlbum(snapshot.album.id)
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
            let removed = IndexSet(sourceRemovals.compactMap { playlist.displayIndex(forSource: $0) })
            // Album membership changes do not change the remaining media.
            if !details.hasIncrementalChanges || !(details.changedIndexes?.isEmpty ?? true) {
                playlist.invalidateMetadata()
            }
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
    var errorDescription: String? {
        switch self {
        case .noAsset: return "This slideshow has no current item."
        case .emptyName: return "Enter an album name."
        case .sourceNotEditable: return "Photos does not allow moving items out of this album."
        case .destinationNotEditable: return "Photos does not allow adding items to that album."
        case .changeUnavailable: return "Photos could not prepare this move. Please try again."
        }
    }
}
#endif
