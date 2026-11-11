// Target audience: developers. Exercise exact capture and confirmation before queued transfer.
import Foundation
final class PHAsset { let localIdentifier: String; init(_ id: String) { localIdentifier = id } }
struct PHFetchResult<T> {}
struct GalleryVaultAlbum { let id: String; let title: String; let position: Int? }
struct GalleryVaultTransferOutcome {}
enum GalleryVaultTransferError: Error { case locked }
enum GalleryMediaItem { case photos(PHAsset) }
enum GalleryDeleteAction { case moveToVault(id: String?, epoch: UUID, sourceAlbumID: String?) }
@MainActor final class GalleryVaultService {
 static let shared = GalleryVaultService()
 var isUnlocked = false; var authEpoch = UUID(); var unlockCalls = 0
 func unlock() async throws { unlockCalls += 1; isUnlocked = true; authEpoch = UUID() }
 func moveToVault(assets: [PHAsset], destination: GalleryVaultAlbum?, sourceAlbumID: String?) async throws -> GalleryVaultTransferOutcome { .init() }
 func moveToVault(fetch: PHFetchResult<PHAsset>, sourceAlbumID: String?) async throws -> GalleryVaultTransferOutcome { .init() }
}
@MainActor final class GalleryDeleteQueue {
 static let shared = GalleryDeleteQueue()
 var captured: [(String, String?, UUID)] = []
 func enqueueMove(item: GalleryMediaItem, sourceAlbumID: String?, sessionID: UUID, action: GalleryDeleteAction, vaultDestination: GalleryVaultAlbum?) {
  guard case .photos(let asset) = item else { return }
  captured.append((asset.localIdentifier, vaultDestination?.id, sessionID))
 }
}
// PRODUCTION_REQUEST

@main struct Check {
 @MainActor static func main() async throws {
  let vault = GalleryVaultService.shared, queue = GalleryDeleteQueue.shared
  let item = PHAsset("first"), session = UUID()
  let locked = GalleryVaultTransferRequest.queuedItem(item, destination: nil, sourceAlbumID: "source", sessionID: session)
  precondition(queue.captured.isEmpty && vault.unlockCalls == 0, "creating and cancelling must change nothing")
  var failure: Error?
  locked.confirmQueued { failure = $0 }
  precondition(queue.captured.isEmpty, "locked confirmation must await authentication")
  for _ in 0..<100 where queue.captured.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
  precondition(failure == nil && vault.unlockCalls == 1 && queue.captured.count == 1 && queue.captured[0].0 == "first" && queue.captured[0].1 == nil && queue.captured[0].2 == session, "locked confirmation must unlock and queue exact item with no destination")
  queue.captured = []
  let warm = GalleryVaultTransferRequest.queuedItem(item, destination: .init(id: "dest", title: "A", position: nil), sourceAlbumID: "source", sessionID: session)
  warm.confirmQueued { failure = $0 }
  precondition(failure == nil && queue.captured.count == 1 && queue.captured[0].0 == "first" && queue.captured[0].1 == "dest" && queue.captured[0].2 == session, "unlocked confirmation must enqueue exact capture synchronously")
  queue.captured = []
  let stale = GalleryVaultTransferRequest.queuedItem(item, destination: .init(id: "dest", title: "A", position: nil), sourceAlbumID: nil, sessionID: session)
  vault.isUnlocked = false; vault.authEpoch = UUID(); vault.isUnlocked = true
  stale.confirmQueued { failure = $0 }
  precondition(failure != nil && queue.captured.isEmpty && vault.unlockCalls == 1, "changed authorization must synchronously reject stale confirmation")
  failure = nil
  let staleWhileLocked = GalleryVaultTransferRequest.queuedItem(item, destination: nil, sourceAlbumID: nil, sessionID: session)
  vault.isUnlocked = false; vault.authEpoch = UUID()
  staleWhileLocked.confirmQueued { failure = $0 }
  precondition(failure != nil && queue.captured.isEmpty && vault.unlockCalls == 1, "stale locked confirmation must not prompt or enqueue")
  print("PASS production confirmation: synchronous warm enqueue, cancel, locked unlock, exact target, nil destination and stale epoch")
 }
}
