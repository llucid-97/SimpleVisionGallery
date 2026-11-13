from pathlib import Path
import subprocess,sys,tempfile
root=Path(sys.argv[1]) if len(sys.argv)>1 else Path.cwd()
s=(root/'SimpleVisionGallery/Gallery/GalleryViewerMedia.swift').read_text()
def block(marker):
 start=s.index(marker); b=s.index('{',start); depth=0
 for i in range(b,len(s)):
  if s[i]=='{': depth+=1
  elif s[i]=='}':
   depth-=1
   if depth==0:return s[start:i+1]
 raise ValueError(marker)
update=block('    func updatePrefetchDemand(owner:')
remove=block('    private func removeDemandKeys(') if '    private func removeDemandKeys(' in s else 'private func removeDemandKeys(where shouldRemove: (String) -> Bool) { for (owner,keys) in demands { demands[owner] = keys.filter { !shouldRemove($0) } } }'
outcome=block('    private func recordVideoPrerollOutcome(')
upgrade=block('    private func upgradeNearestVideoPreroll()')
slot_changed=block('    private func prefetchVideoSlotDidChange()')
code='''
import Foundation
enum PHAssetMediaType { case image, video }
struct GalleryMediaItem { let localIdentifier: String; let mediaType: PHAssetMediaType }
final class GalleryPreparedVideo { var hasPrerolledPlayer = false }
enum GalleryVideoPrerollOutcome { case scheduled, alreadyPrepared, slotUnavailable }
@MainActor final class GallerySceneCache {
 static let shared=GallerySceneCache()
 static let prefetchVideoSlotDidChange=Notification.Name("testVideoSlotChanged")
 static func key(for item:GalleryMediaItem)->String { item.localIdentifier }
 var video: GalleryPreparedVideo?
 var retained: Set<String> = []
 func hasPrefetched(_ key:String,owner:UUID)->Bool { retained.contains(key) }
 func prefetchedVideo(key:String,owner:UUID)->GalleryPreparedVideo? { retained.contains(key) ? video : nil }
 func scheduleVideoPreroll(_ video:GalleryPreparedVideo,key:String,owner:UUID)->GalleryVideoPrerollOutcome {
  if video.hasPrerolledPlayer { return .alreadyPrepared }
  video.hasPrerolledPlayer=true
  return .scheduled
 }
 func releaseVideoPreroll() { video?.hasPrerolledPlayer=false }
}
@MainActor final class Probe {
 struct Retained { var owners: Set<UUID> }
 static let prefetchOwnersDidChange=Notification.Name("testOwnersDidChange")
 var demands: [UUID:[String]] = [:]
 var retainedPrefetch: [String:Retained] = [:]
 var notifications = 0
 var desiredPrefetchAssets: [GalleryMediaItem] = []
 var prefetchFailures: Set<String> = []
 var prefetchVideoSlotFailures: Set<String> = []
 var attemptedVideoPrerolls: Set<String> = []
 var deferredVideoPrerolls: Set<String> = []
 var videoPrerollSlotGeneration: UInt64 = 0
 let prefetchOwnerID = UUID()
 var token: NSObjectProtocol?
 init() { token=NotificationCenter.default.addObserver(forName:Self.prefetchOwnersDidChange,object:nil,queue:nil) { [weak self] _ in MainActor.assumeIsolated { self?.notifications += 1 } } }
 func trimPrefetchRetentions() {}
 func isNearestVideo(_ key: String) -> Bool { desiredPrefetchAssets.first.map { $0.localIdentifier == key } ?? false }
 func startPrefetchIfNeeded() { upgradeNearestVideoPreroll() }
 UPDATE
 REMOVE
 OUTCOME
 UPGRADE
 SLOT_CHANGED
 func run() {
 let a=UUID(),b=UUID()
 updatePrefetchDemand(owner:a, orderedKeys:["photos:a","vault:b"])
 precondition(demands.count==1 && notifications==0)
 updatePrefetchDemand(owner:a, orderedKeys:["photos:a","vault:b"])
 precondition(notifications==0,"unchanged owner count must not notify")
 updatePrefetchDemand(owner:b, orderedKeys:["vault:c"])
 precondition(demands.count==2 && notifications==1)
 removeDemandKeys { $0.hasPrefix("vault:") }
 precondition(demands.count==1 && demands[a]==["photos:a"] && demands[b]==nil, "vault lock must drop empty owners")
 precondition(notifications==2,"capacity must be rebalanced after lock")
 updatePrefetchDemand(owner:a, orderedKeys:[])
 precondition(demands.isEmpty && notifications==2,"window close releases its share")
 let key="video-shared", firstOwner=Probe(), sibling=Probe(), sharedVideo=GalleryPreparedVideo()
 let video=GalleryMediaItem(localIdentifier:key,mediaType:.video)
 GallerySceneCache.shared.video=sharedVideo
 GallerySceneCache.shared.retained.insert(key)
 firstOwner.desiredPrefetchAssets=[video]
 sibling.desiredPrefetchAssets=[video]
 let firstOutcome=GallerySceneCache.shared.scheduleVideoPreroll(sharedVideo,key:key,owner:firstOwner.prefetchOwnerID)
 firstOwner.recordVideoPrerollOutcome(firstOutcome,key:key)
 precondition(firstOwner.attemptedVideoPrerolls.contains(key) && sharedVideo.hasPrerolledPlayer)
 sibling.upgradeNearestVideoPreroll()
 precondition(!sibling.attemptedVideoPrerolls.contains(key),"alreadyPrepared belongs to the sibling's warm reservation, not this owner's attempt")
 GallerySceneCache.shared.releaseVideoPreroll()
 sibling.prefetchVideoSlotDidChange()
 precondition(sibling.attemptedVideoPrerolls.contains(key) && sharedVideo.hasPrerolledPlayer,"slot release must let the sibling schedule the shared cached video")
 print("PASS: owner registration, stable count, vault lock, close and rebalance signal")
 }
}
@main struct Main { @MainActor static func main() { Probe().run() } }
'''.replace(' UPDATE',update).replace(' REMOVE',remove).replace(' OUTCOME',outcome).replace(' UPGRADE',upgrade).replace(' SLOT_CHANGED',slot_changed)
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'test.swift').write_text(code)
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
