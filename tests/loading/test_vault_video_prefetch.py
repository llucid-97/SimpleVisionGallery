from pathlib import Path
import subprocess,sys,tempfile
root=Path(sys.argv[1]) if len(sys.argv)>1 else Path.cwd()
s=(root/'SimpleVisionGallery/Gallery/GalleryViewerMedia.swift').read_text()
def block(marker):
 start=s.index(marker);b=s.index('{',start);depth=0
 for i in range(b,len(s)):
  if s[i]=='{':depth+=1
  elif s[i]=='}':
   depth-=1
   if depth==0:return s[start:i+1]
 raise ValueError(marker)
markers=['private enum GalleryVaultVideoBudget', '    private func releaseVaultVideoReservation(', '    func video(for asset:', '    private func releaseVideo(', '    func takePrefetched(']
parts=[block(x) for x in markers]
h='''
import Foundation
BUDGET
nonisolated enum GalleryMediaError: Error { case missingMedia, prefetchBudgetExceeded, prefetchVideoSlotUnavailable }
struct Resource { let id: UUID }
struct Record { let id: UUID; let resource: Resource }
struct GalleryMediaItem { let localIdentifier: String; let vaultRecord: Record?; var cacheKey: String { localIdentifier } }
enum GalleryVaultResourceSelection { static func displayResource(for record: Record)->Resource? { record.resource } }
@MainActor final class GalleryVaultStorage {
 static let shared=GalleryVaultStorage(); var isUnlocked=true; var cleanupWarning: String?; var bytes: Int64=100; var available: Int64=1024*1024*1024
 func speculativeResourceSpace(recordID: UUID,resourceID: UUID) async throws -> (Int64,Int64) { (bytes,available) }
}
@MainActor final class GalleryPreparedVideo { var onPrefetchRelease: (@MainActor () -> Void)?; var isVault=true; var isForeground=false; func promote() { isForeground=true; onPrefetchRelease?(); onPrefetchRelease=nil } }
enum GalleryPrefetchedMedia { case video(GalleryPreparedVideo) }
@MainActor enum GalleryVaultMediaRequest {
 static var count=0
 static var cleanupFailure=false
 static func video(_ item:GalleryMediaItem) async throws -> GalleryPreparedVideo { count += 1; if cleanupFailure { GalleryVaultStorage.shared.cleanupWarning = "cleanup failed"; throw GalleryMediaError.missingMedia }; try await Task.sleep(nanoseconds: 10_000_000); return GalleryPreparedVideo() }
}
@MainActor final class Gate { func acquire(key:String,foreground:Bool) async throws {} ;func release(){}; func promote(key:String){} }
enum GalleryMediaRequest { static func value<T>(of t:Task<T,Error>) async throws -> T { try await t.value } }
@MainActor final class Probe {
 struct Retained { var media: GalleryPrefetchedMedia; var access: UInt64; var owners: Set<UUID> }
 struct PendingVideo { var task: Task<GalleryPreparedVideo,Error>; var consumers: Set<UUID>; var foreground: Bool }
 static let prefetchVideoSlotDidChange=Notification.Name("videoSlotChanged")
 var vaultVideoReservation: (key:String,id:UUID)?
 var pendingVideos: [String:PendingVideo] = [:]
 var retainedPrefetch: [String:Retained] = [:]
 var clock: UInt64 = 0
 var vaultGeneration=UUID(), photosGeneration=UUID()
 var hiddenSourceGenerations: [String:UUID] = [:]
 let generationGate=Gate()
 static func key(for item:GalleryMediaItem)->String { item.cacheKey }
 RELEASE
 VIDEO
 RELEASE_VIDEO
 TAKE
}
@main struct Main {
 @MainActor static func main() async throws {
  let mib: Int64=1024*1024
  precondition(GalleryVaultVideoBudget.permits(encryptedBytes:256*mib,availableBytes:768*mib))
  precondition(!GalleryVaultVideoBudget.permits(encryptedBytes:256*mib+1,availableBytes:1024*mib))
  precondition(!GalleryVaultVideoBudget.permits(encryptedBytes:1,availableBytes:512*mib))
  let storage=GalleryVaultStorage.shared; let cache=Probe()
  func item(_ id:String)->GalleryMediaItem { GalleryMediaItem(localIdentifier:id,vaultRecord:Record(id:UUID(),resource:Resource(id:UUID()))) }
  let a=item("a"), b=item("b")
  storage.bytes=257*mib
  do { _ = try await cache.video(for:a,foreground:false); fatalError("oversize accepted") } catch GalleryMediaError.prefetchBudgetExceeded {}
  precondition(cache.vaultVideoReservation == nil && GalleryVaultMediaRequest.count==0, "oversized video must never decrypt")
  storage.bytes=100
  let first=try await cache.video(for:a,foreground:false)
  precondition(cache.vaultVideoReservation != nil && GalleryVaultMediaRequest.count==1)
  let ownerA=UUID(),ownerB=UUID()
  cache.retainedPrefetch["a"]=Probe.Retained(media:.video(first),access:0,owners:[ownerA,ownerB])
  let shared=try await cache.video(for:a,foreground:false)
  precondition(shared === first && GalleryVaultMediaRequest.count==1,"another window must reuse retained video")
  do { _ = try await cache.video(for:b,foreground:false); fatalError("second slot accepted") } catch GalleryMediaError.prefetchVideoSlotUnavailable {}
  precondition(GalleryVaultMediaRequest.count==1)
  _=cache.takePrefetched(key:"a",owner:ownerA)
  precondition(first.isForeground && cache.retainedPrefetch["a"] == nil && cache.vaultVideoReservation == nil,"promotion must remove other speculative owners before releasing the quota")
  let second=try await cache.video(for:b,foreground:false)
  precondition(cache.vaultVideoReservation != nil && GalleryVaultMediaRequest.count==2)
  second.promote(); precondition(cache.vaultVideoReservation == nil)
  let c=item("c")
  let stale=Task<GalleryPreparedVideo,Error> { try await Task.sleep(nanoseconds:10_000_000); return GalleryPreparedVideo() }
  stale.cancel()
  cache.pendingVideos["c:video"]=Probe.PendingVideo(task:stale,consumers:[UUID()],foreground:false)
  _ = try await cache.video(for:c,foreground:true)
  let joined=item("joined")
  let speculative=Task { try await cache.video(for:joined,foreground:false) }
  while cache.vaultVideoReservation == nil { await Task.yield() }
  let foreground=Task { try await cache.video(for:joined,foreground:true) }
  let warmResult=try await speculative.value
  let foregroundResult=try await foreground.value
  precondition(warmResult === foregroundResult && warmResult.isForeground && cache.vaultVideoReservation == nil,"joined foreground must mark shared result before other consumers can retain it")
  GalleryVaultMediaRequest.cleanupFailure=true
  do { _ = try await cache.video(for:item("dirty"),foreground:false); fatalError("injected cleanup failure not raised") } catch GalleryMediaError.missingMedia {}
  precondition(cache.vaultVideoReservation != nil,"failed plaintext cleanup must keep the speculative slot occupied")
  print("PASS: size/free-space edges, reject before decrypt, one slot, promotion, reuse, canceled-task replacement, failed-cleanup fence")
 }
}
'''.replace('BUDGET',parts[0]).replace(' RELEASE_VIDEO',parts[3]).replace(' RELEASE',parts[1]).replace(' VIDEO',parts[2]).replace(' TAKE',parts[4])
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'test.swift').write_text(h)
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
