import Foundation

nonisolated enum GalleryDeleteAction: Sendable, Equatable {
    case recycle, permanent, putBack
    case moveToPhotos(destinationID: String?, newName: String?)
    case moveToVault(id: String, epoch: UUID, sourceAlbumID: String?)
    case removeFromAlbum

    func keepsVaultItemHidden(inRecycleBin: Bool) -> Bool {
        switch self {
        case .recycle: !inRecycleBin
        case .putBack: inRecycleBin
        case .permanent: true
        case .moveToPhotos, .moveToVault, .removeFromAlbum: false
        }
    }
}

// Capture the target and session at the tap so later asynchronous work uses the same intent.
nonisolated struct GalleryDeleteRequest: Identifiable, Sendable {
    enum Target: Sendable {
        case photos(String, sourceAlbumID: String?)
        case vault(UUID, epoch: UUID)
    }
    let id = UUID()
    let target: Target
    let action: GalleryDeleteAction
    let sessionID: UUID?
    var itemID: String {
        switch target {
        case .photos(let id, _): id
        case .vault(let id, _): "vault:\(id.uuidString)"
        }
    }
    var isVault: Bool { if case .vault = target { return true }; return false }
    var requiresVault: Bool {
        if isVault { return true }
        if case .moveToVault = action { return true }
        return false
    }
}

/// Pending targets remain owned until their batch completes, including taps made during an await.
nonisolated struct GalleryDeleteFIFO {
    private(set) var waiting: [GalleryDeleteRequest] = []
    private(set) var active: [GalleryDeleteRequest] = []
    private(set) var identifiers = Set<String>()

    mutating func append(_ request: GalleryDeleteRequest) -> Bool {
        guard identifiers.insert(request.itemID).inserted else { return false }
        waiting.append(request)
        return true
    }
    mutating func takeBatch() -> [GalleryDeleteRequest] {
        precondition(active.isEmpty)
        guard let first = waiting.first else { return [] }
        let count = waiting.prefix { $0.isVault == first.isVault }.count
        active = Array(waiting.prefix(count))
        waiting.removeFirst(count)
        return active
    }
    mutating func finish(failed: Set<UUID>) -> [GalleryDeleteRequest] {
        let failures = active.filter { failed.contains($0.id) }
        for request in active { identifiers.remove(request.itemID) }
        active.removeAll(keepingCapacity: true)
        return failures
    }
    mutating func cancelVault() -> [GalleryDeleteRequest] {
        let cancelled = (active + waiting).filter(\.requiresVault)
        active.removeAll(where: \.requiresVault)
        waiting.removeAll(where: \.requiresVault)
        for request in cancelled { identifiers.remove(request.itemID) }
        return cancelled
    }
}

#if os(visionOS)
import Combine
import OSLog
@preconcurrency import Photos

@MainActor
// Own pending deletes and their worker so views share one ordered operation stream.
final class GalleryDeleteQueue: ObservableObject {
    static let shared = GalleryDeleteQueue()
    @Published private(set) var pendingCount = 0
    @Published private(set) var photosUnresponsive = false
    @Published private(set) var errorMessage: String?
    private var fifo = GalleryDeleteFIFO()
    private var worker: Task<Void, Never>?
    private var lockObserver: AnyCancellable?
    private final class BulkCompletion {
        var remaining: Int
        var failed = false
        let completion: @MainActor (Bool) -> Void
        init(count: Int, completion: @escaping @MainActor (Bool) -> Void) {
            remaining = count; self.completion = completion
        }
    }
    private var bulkCompletions: [UUID: BulkCompletion] = [:]
    private(set) var pendingPhotoAssets: [String: PHAsset] = [:]
    // Album titles are cleared immediately on lock, including while another request is stalled.
    private var pendingVaultDestinations: [UUID: GalleryVaultAlbum] = [:]
    private static let log = Logger(subsystem: "com.llucid.simplevisiongallery", category: "viewer-gate")

    var pendingRequests: [GalleryDeleteRequest] { fifo.active + fifo.waiting }

    var pendingVaultIDs: Set<UUID> {
        Set((fifo.active + fifo.waiting).compactMap {
            if case .vault(let id, _) = $0.target { return id }; return nil
        })
    }
    func isPending(_ identifier: String) -> Bool { fifo.identifiers.contains(identifier) }

    private init() {
        lockObserver = NotificationCenter.default.publisher(for: .galleryVaultWillLock).sink { [weak self] _ in
            guard let self else { return }
            // Queued vault requests contain IDs and an epoch, never private metadata or a key.
            for request in self.fifo.cancelVault() {
                GalleryViewerStore.shared.finishQueuedDelete(request, succeeded: false)
                self.pendingVaultDestinations.removeValue(forKey: request.id)
                self.pendingPhotoAssets.removeValue(forKey: request.itemID)
            }
            self.pendingCount = self.fifo.identifiers.count
        }
    }

    func enqueueRecycle(item: GalleryMediaItem, sourceAlbumID: String?, sessionID: UUID? = nil) {
        switch item {
        case .photos(let asset):
            enqueue(.init(target: .photos(asset.localIdentifier, sourceAlbumID: sourceAlbumID),
                action: .recycle, sessionID: sessionID), asset: asset)
        case .vault(let record): enqueueVaultRecycle(recordID: record.id, sessionID: sessionID)
        }
    }
    func enqueueVaultRecycle(recordID: UUID, sessionID: UUID? = nil) {
        enqueueVault(recordID, action: .recycle, sessionID: sessionID)
    }
    func enqueueVaultPutBack(recordID: UUID, sessionID: UUID? = nil) {
        enqueueVault(recordID, action: .putBack, sessionID: sessionID)
    }
    func enqueuePermanentVaultDelete(recordID: UUID, sessionID: UUID? = nil) {
        enqueueVault(recordID, action: .permanent, sessionID: sessionID)
    }
    private func enqueueVault(_ id: UUID, action: GalleryDeleteAction, sessionID: UUID?) {
        guard GalleryVaultService.shared.isUnlocked else { return }
        enqueue(.init(target: .vault(id, epoch: GalleryVaultService.shared.authEpoch),
            action: action, sessionID: sessionID))
    }
    func enqueuePermanentPhotosDelete(asset: PHAsset, sourceAlbumID: String?, sessionID: UUID? = nil) {
        enqueue(.init(target: .photos(asset.localIdentifier, sourceAlbumID: sourceAlbumID),
            action: .permanent, sessionID: sessionID), asset: asset)
    }
    func enqueueMove(item: GalleryMediaItem, sourceAlbumID: String?, sessionID: UUID,
                     action: GalleryDeleteAction, vaultDestination: GalleryVaultAlbum? = nil) {
        switch item {
        case .photos(let asset):
            enqueue(.init(target: .photos(asset.localIdentifier, sourceAlbumID: sourceAlbumID),
                          action: action, sessionID: sessionID), asset: asset, vaultDestination: vaultDestination)
        case .vault(let record):
            guard GalleryVaultService.shared.isUnlocked else { return }
            enqueue(.init(target: .vault(record.id, epoch: GalleryVaultService.shared.authEpoch),
                          action: action, sessionID: sessionID), vaultDestination: vaultDestination)
        }
    }
    @discardableResult
    func enqueuePhotos(_ assets: [PHAsset], sourceAlbumID: String?, permanently: Bool,
                       completion: (@MainActor (Bool) -> Void)? = nil) -> Bool {
        let ids = assets.map(\.localIdentifier)
        guard !ids.isEmpty else { return false }
        if completion != nil {
            guard Set(ids).count == ids.count,
                  ids.allSatisfy({ !fifo.identifiers.contains($0) }) else { return false }
        }
        let group = completion.map { BulkCompletion(count: assets.count, completion: $0) }
        for asset in assets {
            let request = GalleryDeleteRequest(target: .photos(asset.localIdentifier, sourceAlbumID: sourceAlbumID),
                action: permanently ? .permanent : .recycle, sessionID: nil)
            if let group { bulkCompletions[request.id] = group }
            enqueue(request, asset: asset, publishing: false)
        }
        pendingCount = fifo.identifiers.count
        return true
    }

    /// Stage each accepted target immediately and start one worker to preserve order.
    private func enqueue(_ request: GalleryDeleteRequest, asset: PHAsset? = nil, publishing: Bool = true,
                         vaultDestination: GalleryVaultAlbum? = nil) {
        guard fifo.append(request) else { return } // Sibling taps on an already pending item coalesce.
        errorMessage = nil
        if let asset { pendingPhotoAssets[asset.localIdentifier] = asset }
        if let vaultDestination { pendingVaultDestinations[request.id] = vaultDestination }
        GalleryViewerStore.shared.stageQueuedDelete(request, asset: asset)
        if publishing { pendingCount = fifo.identifiers.count }
        guard worker == nil else { return }
        worker = Task { [weak self] in
            // Coalesce taps without delaying the immediate playlist handoff.
            try? await Task.sleep(for: .milliseconds(40))
            await self?.drain()
        }
    }

    // Drain each store prefix before later requests so completion follows capture order.
    private func drain() async {
        var needsAlbumRefresh = false
        // Finalize the current prefix before accepting results from the next store.
        while !fifo.waiting.isEmpty {
            let batch = fifo.takeBatch()
            // Finish each contiguous store prefix before starting the next one.
            let failures = batch.first?.isVault == true
                ? await executeVault(batch) : await executePhotos(batch)
            for request in batch where fifo.active.contains(where: { $0.id == request.id }) {
                let error = failures[request.id]
                GalleryViewerStore.shared.finishQueuedDelete(request, succeeded: error == nil)
                if error == nil {
                    switch request.action {
                    case .moveToPhotos, .moveToVault, .removeFromAlbum: needsAlbumRefresh = true
                    default: break
                    }
                }
                if error == nil, !request.isVault {
                    NotificationCenter.default.post(name: .galleryQueuedPhotoDeleteCommitted,
                        object: nil, userInfo: ["request": request])
                }
                if let error { errorMessage = error.localizedDescription }
                pendingPhotoAssets.removeValue(forKey: request.itemID)
                pendingVaultDestinations.removeValue(forKey: request.id)
            }
            _ = fifo.finish(failed: Set(failures.keys))
            pendingCount = fifo.identifiers.count
            // Do not start the next phase of a mixed bulk operation on partial failure.
            for request in batch {
                guard let group = bulkCompletions.removeValue(forKey: request.id) else { continue }
                group.failed = group.failed || failures[request.id] != nil
                group.remaining -= 1
                if group.remaining == 0 { group.completion(!group.failed) }
            }
        }
        worker = nil
        if needsAlbumRefresh { Task { await GalleryViewerStore.shared.refreshAlbums() } }
    }

    // Keep the watchdog scoped to the Photos await so slow prompts remain visible.
    private func executePhotos(_ requests: [GalleryDeleteRequest]) async -> [UUID: Error] {
        guard !requests.isEmpty else { return [:] }
        let watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.photosUnresponsive = true
            Self.log.notice("photos_pending pending_count=\(self.pendingCount, privacy: .public)")
        }
        defer { watchdog.cancel(); photosUnresponsive = false }
        var failures: [UUID: Error] = [:]
        // Mixed delete/move batches must retain capture order through the shared gate.
        var pendingDeletes: [GalleryDeleteRequest] = []
        func flushDeletes() async {
            guard !pendingDeletes.isEmpty else { return }
            failures.merge(await GalleryViewerStore.shared.performQueuedPhotoDeletes(pendingDeletes)) { _, new in new }
            pendingDeletes.removeAll()
        }
        for request in requests {
            switch request.action {
            case .recycle, .permanent, .putBack:
                pendingDeletes.append(request)
            case .moveToPhotos, .removeFromAlbum:
                await flushDeletes()
                if let error = await GalleryViewerStore.shared.performQueuedPhotoMove(request) { failures[request.id] = error }
            case .moveToVault:
                await flushDeletes()
                if let asset = pendingPhotoAssets[request.itemID],
                   case .moveToVault(let id, let epoch, let sourceID) = request.action,
                   let destination = pendingVaultDestinations[request.id], destination.id == id {
                    do {
                        let outcome = try await GalleryVaultService.shared.moveQueuedToVault(asset: asset,
                            destination: destination, sourceAlbumID: sourceID, epoch: epoch)
                        guard outcome.deleted == 1 else { throw GalleryQueuedMoveError.notMoved }
                        GalleryMoveHistory.shared.recordSuccessfulVaultMove(to: id)
                    } catch { failures[request.id] = error }
                } else { failures[request.id] = GalleryQueuedMoveError.unavailable }
            }
        }
        await flushDeletes()
        return failures
    }

    // Submit vault changes under their captured epochs and map outcomes back to requests.
    private func executeVault(_ requests: [GalleryDeleteRequest]) async -> [UUID: Error] {
        guard !requests.isEmpty else { return [:] }
        var errors: [UUID: Error] = [:]
        // Epochs may differ only if lock/unlock happened while a Photos prompt was open.
        // Group by authorization epoch so a lock cannot authorize an older request.
        for epoch in Set(requests.compactMap { if case .vault(_, let epoch) = $0.target { return epoch }; return nil }) {
            let group = requests.filter { if case .vault(_, let value) = $0.target { return value == epoch }; return false }
            let mutations: [GalleryVaultMutation] = group.compactMap { request in
                guard case .vault(let id, _) = request.target else { return nil }
                switch request.action {
                case .recycle: return .recycle(id)
                case .putBack: return .putBack(id)
                case .permanent: return .delete(id)
                case .moveToVault(let albumID, _, let sourceID):
                    guard let destination = pendingVaultDestinations[request.id], destination.id == albumID else { return nil }
                    return .move(id, sourceAlbumID: sourceID, destination: destination)
                case .moveToPhotos, .removeFromAlbum: return nil
                }
            }
            let results = await GalleryVaultService.shared.applyQueuedMutations(mutations, epoch: epoch)
            if let warning = results.compactMap(\.warning).first {
                errorMessage = warning.localizedDescription
            }
            let byID = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            for request in group {
                guard case .vault(let id, _) = request.target else { continue }
                guard let result = byID[id] else {
                    errors[request.id] = NSError(domain: "GalleryDeleteQueue", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The vault did not confirm this change. Try again."])
                    continue
                }
                if let error = result.error { errors[request.id] = error }
                else if case .moveToVault(let albumID, _, _) = request.action {
                    GalleryMoveHistory.shared.recordSuccessfulVaultMove(to: albumID)
                }
            }
        }
        return errors
    }
}

private enum GalleryQueuedMoveError: LocalizedError {
    case unavailable, notMoved
    var errorDescription: String? {
        switch self {
        case .unavailable: "This item is no longer available to move."
        case .notMoved: "The item was not moved. Please try again."
        }
    }
}

extension Notification.Name {
    static let galleryQueuedPhotoDeleteCommitted = Notification.Name("GalleryQueuedPhotoDeleteCommitted")
}
#endif
