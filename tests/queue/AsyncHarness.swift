// Target audience: agents. These doubles do not exercise PhotoKit or vault storage.
import Foundation
struct PHAsset: Sendable { let localIdentifier: String }
struct GalleryVaultRecord: Sendable { let id: UUID }
enum GalleryMediaItem { case photos(PHAsset), vault(GalleryVaultRecord) }
nonisolated enum GalleryVaultMutation: Sendable {
    case recycle(UUID), putBack(UUID), delete(UUID)
    var id: UUID { switch self { case .recycle(let id), .putBack(let id), .delete(let id): id } }
}
nonisolated struct GalleryVaultMutationResult: Sendable { let id: UUID; let error: Error?; var warning: Error? = nil }
nonisolated enum Injected: Error { case failed, locked }
extension Notification.Name { static let galleryVaultWillLock = Notification.Name("test-vault-lock") }
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
    func lock() { isUnlocked = false; authEpoch = UUID(); NotificationCenter.default.post(name: .galleryVaultWillLock, object: nil) }
}
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
    func performQueuedPhotoDeletes(_ requests: [GalleryDeleteRequest]) async -> [UUID: Error] {
        batches.append(requests.map(\.itemID))
        try? await Task.sleep(for: .milliseconds(photoDelay))
        return Dictionary(uniqueKeysWithValues: requests.filter { failing.contains($0.itemID) }.map { ($0.id, Injected.failed as Error) })
    }
    func reset() { captured = []; completed = []; failures = []; batches = []; failing = []; photoDelay = 10 }
}
@main struct Check {
    @MainActor static func idle(_ queue: GalleryDeleteQueue) async {
        let limit = ContinuousClock.now + .seconds(10)
        while queue.pendingCount != 0 && ContinuousClock.now < limit { try? await Task.sleep(for: .milliseconds(5)) }
        precondition(queue.pendingCount == 0, "queue timed out")
    }
    @MainActor static func photo(_ id: String) {
        GalleryDeleteQueue.shared.enqueueRecycle(item: .photos(.init(localIdentifier: id)), sourceAlbumID: nil)
    }
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
        print("PASS production queue with fake Photos and vault backends")
    }
}
