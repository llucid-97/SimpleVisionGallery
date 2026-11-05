import Foundation

nonisolated enum GalleryDeleteAction: Sendable { case recycle, permanent, putBack }

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
        active = waiting
        waiting.removeAll(keepingCapacity: true)
        return active
    }
    mutating func finish(failed: Set<UUID>) -> [GalleryDeleteRequest] {
        let failures = active.filter { failed.contains($0.id) }
        for request in active { identifiers.remove(request.itemID) }
        active.removeAll(keepingCapacity: true)
        return failures
    }
    mutating func cancelVault() -> [GalleryDeleteRequest] {
        let cancelled = (active + waiting).filter(\.isVault)
        active.removeAll(where: \.isVault)
        waiting.removeAll(where: \.isVault)
        for request in cancelled { identifiers.remove(request.itemID) }
        return cancelled
    }
}

#if os(visionOS)
import Combine
import OSLog
@preconcurrency import Photos

@MainActor
final class GalleryDeleteQueue: ObservableObject {
    static let shared = GalleryDeleteQueue()
    @Published private(set) var pendingCount = 0
    @Published private(set) var photosUnresponsive = false
    @Published private(set) var errorMessage: String?
    private var fifo = GalleryDeleteFIFO()
    private var worker: Task<Void, Never>?
    private var lockObserver: AnyCancellable?
    private(set) var pendingPhotoAssets: [String: PHAsset] = [:]
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
    func enqueuePhotos(_ assets: [PHAsset], sourceAlbumID: String?, permanently: Bool) {
        for asset in assets {
            enqueue(.init(target: .photos(asset.localIdentifier, sourceAlbumID: sourceAlbumID),
                action: permanently ? .permanent : .recycle, sessionID: nil), asset: asset, publishing: false)
        }
        pendingCount = fifo.identifiers.count
    }

    private func enqueue(_ request: GalleryDeleteRequest, asset: PHAsset? = nil, publishing: Bool = true) {
        guard fifo.append(request) else { return } // Sibling taps on an already pending item coalesce.
        if let asset { pendingPhotoAssets[asset.localIdentifier] = asset }
        GalleryViewerStore.shared.stageQueuedDelete(request, asset: asset)
        if publishing { pendingCount = fifo.identifiers.count }
        guard worker == nil else { return }
        worker = Task { [weak self] in
            // Coalesce taps without delaying the immediate playlist handoff.
            try? await Task.sleep(for: .milliseconds(40))
            await self?.drain()
        }
    }

    private func drain() async {
        while !fifo.waiting.isEmpty {
            let batch = fifo.takeBatch()
            let photos = batch.filter { !$0.isVault }
            let vault = batch.filter(\.isVault)
            var failures: [UUID: Error] = [:]
            // Each batch owns distinct items. Independent backing-store changes commute;
            // preserve capture order within each store and finish results in capture order.
            if batch.first?.isVault == true {
                failures.merge(await executeVault(vault)) { _, new in new }
                failures.merge(await executePhotos(photos)) { _, new in new }
            } else {
                failures.merge(await executePhotos(photos)) { _, new in new }
                failures.merge(await executeVault(vault)) { _, new in new }
            }
            for request in batch where fifo.active.contains(where: { $0.id == request.id }) {
                let error = failures[request.id]
                GalleryViewerStore.shared.finishQueuedDelete(request, succeeded: error == nil)
                if error == nil, !request.isVault {
                    NotificationCenter.default.post(name: .galleryQueuedPhotoDeleteCommitted,
                        object: nil, userInfo: ["request": request])
                }
                if let error { errorMessage = error.localizedDescription }
                pendingPhotoAssets.removeValue(forKey: request.itemID)
            }
            _ = fifo.finish(failed: Set(failures.keys))
            pendingCount = fifo.identifiers.count
        }
        worker = nil
    }

    private func executePhotos(_ requests: [GalleryDeleteRequest]) async -> [UUID: Error] {
        guard !requests.isEmpty else { return [:] }
        let watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.photosUnresponsive = true
            Self.log.notice("photos_pending pending_count=\(self.pendingCount, privacy: .public)")
        }
        defer { watchdog.cancel(); photosUnresponsive = false }
        return await GalleryViewerStore.shared.performQueuedPhotoDeletes(requests)
    }

    private func executeVault(_ requests: [GalleryDeleteRequest]) async -> [UUID: Error] {
        guard !requests.isEmpty else { return [:] }
        var errors: [UUID: Error] = [:]
        // Epochs may differ only if lock/unlock happened while a Photos prompt was open.
        for epoch in Set(requests.compactMap { if case .vault(_, let epoch) = $0.target { return epoch }; return nil }) {
            let group = requests.filter { if case .vault(_, let value) = $0.target { return value == epoch }; return false }
            let mutations: [GalleryVaultMutation] = group.compactMap { request in
                guard case .vault(let id, _) = request.target else { return nil }
                switch request.action {
                case .recycle: return .recycle(id)
                case .putBack: return .putBack(id)
                case .permanent: return .delete(id)
                }
            }
            let results = await GalleryVaultService.shared.applyQueuedMutations(mutations, epoch: epoch)
            if let warning = results.compactMap(\.warning).first {
                errorMessage = "The item changed, but saving it could not be confirmed. " + warning.localizedDescription
            }
            let byID = Dictionary(results.map { ($0.id, $0.error) }, uniquingKeysWith: { _, latest in latest })
            for request in group {
                if case .vault(let id, _) = request.target, let error = byID[id] ?? nil { errors[request.id] = error }
            }
        }
        return errors
    }
}

extension Notification.Name {
    static let galleryQueuedPhotoDeleteCommitted = Notification.Name("GalleryQueuedPhotoDeleteCommitted")
}
#endif
