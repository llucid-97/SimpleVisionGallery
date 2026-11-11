// Target audience: agents. These doubles do not exercise PhotoKit or vault storage.
import Foundation
struct PHAsset: Sendable { let localIdentifier: String }
struct GalleryVaultRecord: Sendable { let id: UUID }
struct GalleryVaultAlbum: Sendable { let id: String; let title: String; let position: Int? }
struct GalleryVaultTransferOutcome: Sendable { let deleted: Int }
@MainActor final class GalleryMoveHistory {
    static let shared = GalleryMoveHistory()
    func recordSuccessfulVaultMove(to: String) {}
}
enum GalleryMediaItem { case photos(PHAsset), vault(GalleryVaultRecord) }
nonisolated enum GalleryVaultMutation: Sendable {
    case recycle(UUID), putBack(UUID), delete(UUID), move(UUID, sourceAlbumID: String?, destination: GalleryVaultAlbum)
    var id: UUID { switch self { case .recycle(let id), .putBack(let id), .delete(let id), .move(let id, _, _): id } }
}
nonisolated struct GalleryVaultMutationResult: Sendable { let id: UUID; let error: Error?; var warning: Error? = nil }
nonisolated enum Injected: Error { case failed, locked }
extension Notification.Name { static let galleryVaultWillLock = Notification.Name("test-vault-lock") }
/// Simulate a revocable vault so queue behavior can be tested without private storage.
@MainActor final class GalleryVaultService {
    static let shared = GalleryVaultService()
    var isUnlocked = true
    var authEpoch = UUID()
    func applyQueuedMutations(_ requests: [GalleryVaultMutation], epoch: UUID) async -> [GalleryVaultMutationResult] {
        GalleryViewerStore.shared.batches.append(requests.map { "vault:\($0.id.uuidString)" })
        try? await Task.sleep(for: .milliseconds(25))
        let error: Error? = isUnlocked && epoch == authEpoch ? nil : Injected.locked
        return requests.map { .init(id: $0.id, error: error) }
    }
    var copyDelay = 0
    var deletionDelay = 0
    var inCopy = false
    var inPhotosDelete = false
    var lastDestinationID: String?
    func moveQueuedToVault(asset: PHAsset, destination: GalleryVaultAlbum?, sourceAlbumID: String?, epoch: UUID,
                           onPhotosWaitChanged: @escaping @MainActor (Bool) -> Void) async throws -> GalleryVaultTransferOutcome {
        GalleryViewerStore.shared.batches.append(["transfer:" + asset.localIdentifier])
        guard isUnlocked, epoch == authEpoch else { throw Injected.locked }
        lastDestinationID = destination?.id
        inCopy = true
        try? await Task.sleep(for: .milliseconds(copyDelay))
        inCopy = false; inPhotosDelete = true
        onPhotosWaitChanged(true)
        try? await Task.sleep(for: .milliseconds(deletionDelay))
        onPhotosWaitChanged(false)
        inPhotosDelete = false
        return .init(deleted: 1)
    }
    func lock() { isUnlocked = false; authEpoch = UUID(); NotificationCenter.default.post(name: .galleryVaultWillLock, object: nil) }
}
/// Capture queue activity and inject Photos failures without calling PhotoKit.
@MainActor final class GalleryViewerStore {
    static let shared = GalleryViewerStore()
    var captured: [String] = []
    var completed: [String] = []
    var failures: [String] = []
    var batches: [[String]] = []
    var failing: Set<String> = []
    var photoDelay = 10
    func stageQueuedDelete(_ request: GalleryDeleteRequest, asset: PHAsset?) { captured.append(request.itemID) }
    func finishQueuedDelete(_ request: GalleryDeleteRequest, succeeded: Bool) {
        completed.append(request.itemID)
        if !succeeded { failures.append(request.itemID) }
    }
    func performQueuedPhotoDeletes(_ requests: [GalleryDeleteRequest], onPhotosWaitChanged: @escaping @MainActor (Bool) -> Void) async -> [UUID: Error] {
        batches.append(requests.map(\.itemID))
        onPhotosWaitChanged(true)
        try? await Task.sleep(for: .milliseconds(photoDelay))
        onPhotosWaitChanged(false)
        return Dictionary(uniqueKeysWithValues: requests.filter { failing.contains($0.itemID) }.map { ($0.id, Injected.failed as Error) })
    }
    func performQueuedPhotoMove(_ request: GalleryDeleteRequest, onPhotosWaitChanged: @escaping @MainActor (Bool) -> Void) async -> Error? {
        batches.append(["move:" + request.itemID])
        onPhotosWaitChanged(true)
        try? await Task.sleep(for: .milliseconds(photoDelay))
        onPhotosWaitChanged(false)
        return failing.contains(request.itemID) ? Injected.failed : nil
    }
    func refreshAlbums() async {}
    func reset() { captured = []; completed = []; failures = []; batches = []; failing = []; photoDelay = 10 }
}
/// Exercise the production queue against fakes to check ordering and recovery.
@main struct Check {
    @MainActor static func idle(_ queue: GalleryDeleteQueue) async {
        let limit = ContinuousClock.now + .seconds(10)
        while queue.pendingCount != 0 && ContinuousClock.now < limit { try? await Task.sleep(for: .milliseconds(5)) }
        precondition(queue.pendingCount == 0, "queue timed out")
    }
    @MainActor static func photo(_ id: String) {
        GalleryDeleteQueue.shared.enqueueRecycle(item: .photos(.init(localIdentifier: id)), sourceAlbumID: nil)
    }
    /// Run mixed, failure, and lock scenarios to verify the queue contract end to end.
    @MainActor static func main() async {
        let queue = GalleryDeleteQueue.shared, store = GalleryViewerStore.shared, vault = GalleryVaultService.shared
        let ids = (0..<20).map { _ in UUID() }
        for n in 0..<40 {
            if n.isMultiple(of: 2) { photo("p\(n)") } else { queue.enqueueVaultRecycle(recordID: ids[n / 2]) }
        }
        await idle(queue)
        precondition(store.completed == store.captured, "mixed requests must complete in global FIFO order")
        precondition(store.batches.count == 40 && store.batches.allSatisfy { $0.count == 1 }, "alternating stores must not merge")
        store.reset()
        let v1 = UUID(), v2 = UUID()
        photo("a"); photo("b"); queue.enqueueVaultRecycle(recordID: v1); queue.enqueueVaultRecycle(recordID: v2); photo("c")
        await idle(queue)
        precondition(store.batches.map(\.count) == [2, 2, 1], "contiguous requests should coalesce")
        precondition(store.completed == store.captured)
        store.reset()
        store.failing = ["bad"]
        let pending = UUID()
        photo("bad"); queue.enqueueVaultRecycle(recordID: pending)
        while queue.errorMessage == nil { try? await Task.sleep(for: .milliseconds(2)) }
        queue.enqueueVaultRecycle(recordID: pending)
        precondition(queue.errorMessage != nil, "duplicate request must not clear error")
        await idle(queue)
        precondition(store.failures == ["bad"] && queue.errorMessage != nil, "failure must survive later success")
        photo("new")
        precondition(queue.errorMessage == nil, "accepted request clears prior error")
        await idle(queue)
        store.reset()
        // Hold Photos A while B is cancelled and requeued, then enqueue Photos C.
        store.photoDelay = 150
        let b = UUID(), bKey = "vault:\(b.uuidString)"
        photo("A"); queue.enqueueVaultRecycle(recordID: b); photo("C")
        try? await Task.sleep(for: .milliseconds(65))
        vault.lock(); vault.isUnlocked = true
        queue.enqueueVaultRecycle(recordID: b)
        precondition(queue.isPending(bKey))
        await idle(queue)
        precondition(store.batches == [["A"], ["C"], [bKey]], "cancelled B must not move C ahead of A or merge Photos across B")
        precondition(store.completed == [bKey, "A", "C", bKey])
        store.reset()
        let old = UUID(), key = "vault:\(old.uuidString)"
        queue.enqueueVaultRecycle(recordID: old)
        try? await Task.sleep(for: .milliseconds(50))
        vault.lock(); vault.isUnlocked = true; queue.enqueueVaultRecycle(recordID: old)
        precondition(queue.isPending(key))
        try? await Task.sleep(for: .milliseconds(20))
        precondition(queue.isPending(key), "old callback must not clear requeued request")
        await idle(queue)
        precondition(store.completed == [key, key])
        store.reset()
        let moveVaultID = UUID(), epoch = vault.authEpoch
        queue.enqueueMove(item: .photos(.init(localIdentifier: "one")), sourceAlbumID: "source", sessionID: UUID(), action: .moveToPhotos(destinationID: "dest", newName: nil))
        photo("two")
        queue.enqueueMove(item: .vault(.init(id: moveVaultID)), sourceAlbumID: "source", sessionID: UUID(), action: .moveToVault(id: "dest", epoch: epoch, sourceAlbumID: "source"), vaultDestination: .init(id: "dest", title: "Destination", position: nil))
        queue.enqueueMove(item: .photos(.init(localIdentifier: "three")), sourceAlbumID: nil, sessionID: UUID(), action: .moveToVault(id: "dest", epoch: epoch, sourceAlbumID: nil), vaultDestination: .init(id: "dest", title: "Destination", position: nil))
        await idle(queue)
        precondition(store.completed == store.captured, "mixed moves and deletes must complete in capture order")
        precondition(store.batches == [["move:one"], ["two"], ["vault:" + moveVaultID.uuidString], ["transfer:three"]])
        store.reset(); store.failing = ["bad-move"]
        queue.enqueueMove(item: .photos(.init(localIdentifier: "bad-move")), sourceAlbumID: "source", sessionID: UUID(), action: .moveToPhotos(destinationID: "dest", newName: nil))
        photo("later")
        await idle(queue)
        precondition(store.failures == ["bad-move"] && store.completed == ["bad-move", "later"], "a failed move must not drop later requests")
        store.reset()
        var bulkResult: Bool? = nil
        precondition(queue.enqueuePhotos([.init(localIdentifier: "bad"), .init(localIdentifier: "ok")], sourceAlbumID: "bin", permanently: true) { bulkResult = $0 })
        store.failing = ["bad"]
        await idle(queue)
        precondition(bulkResult == false, "partial Photos failure must not authorize a following vault bulk action")
        store.reset(); store.photoDelay = 150
        photo("first")
        let oldEpoch = vault.authEpoch
        queue.enqueueMove(item: .photos(.init(localIdentifier: "private")), sourceAlbumID: nil, sessionID: UUID(),
            action: .moveToVault(id: "private-album", epoch: oldEpoch, sourceAlbumID: nil),
            vaultDestination: .init(id: "private-album", title: "Private Album", position: nil))
        try? await Task.sleep(for: .milliseconds(65))
        vault.lock(); vault.isUnlocked = true
        await idle(queue)
        precondition(!store.batches.contains(["transfer:private"]), "lock must cancel waiting Photos-to-vault moves")
        precondition(store.failures.contains("private"), "cancelled move must reappear")
        store.reset()
        var duplicateCompletionCalls = 0
        photo("duplicate")
        precondition(!queue.enqueuePhotos([.init(localIdentifier: "duplicate")], sourceAlbumID: "bin", permanently: true) { _ in duplicateCompletionCalls += 1 })
        await idle(queue)
        precondition(duplicateCompletionCalls == 0, "rejected bulk input must not call completion")
        store.reset()
        vault.copyDelay = 80; vault.deletionDelay = 100
        queue.photosWatchdogDelay = .milliseconds(20)
        let watchEpoch = vault.authEpoch
        queue.enqueueMove(item: .photos(.init(localIdentifier: "plain-vault")), sourceAlbumID: "source", sessionID: UUID(),
            action: .moveToVault(id: nil, epoch: watchEpoch, sourceAlbumID: "source"))
        while !vault.inCopy { try? await Task.sleep(for: .milliseconds(2)) }
        try? await Task.sleep(for: .milliseconds(40))
        precondition(!queue.photosUnresponsive, "encrypted copying must not start the Photos watchdog")
        while !vault.inPhotosDelete { try? await Task.sleep(for: .milliseconds(2)) }
        try? await Task.sleep(for: .milliseconds(40))
        precondition(queue.photosUnresponsive, "a stalled Photos delete must surface the watchdog")
        await idle(queue)
        precondition(!queue.photosUnresponsive && vault.lastDestinationID == nil,
                     "Photos warning must clear and no-destination move must stay no-destination")
        vault.copyDelay = 0; vault.deletionDelay = 0; queue.photosWatchdogDelay = .seconds(20)
        print("PASS production queue with fake Photos and vault backends")
    }
}
