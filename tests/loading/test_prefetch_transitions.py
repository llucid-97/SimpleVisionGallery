from pathlib import Path
import subprocess,sys,tempfile
root = Path(sys.argv[1]) if len(sys.argv)>1 else Path.cwd()
s=(root/'SimpleVisionGallery/Gallery/GalleryViewerMedia.swift').read_text()
def block(marker):
    start=s.index(marker); b=s.index('{',start); depth=0
    for i in range(b,len(s)):
        if s[i]=='{': depth+=1
        elif s[i]=='}':
            depth-=1
            if depth==0:return s[start:i+1]
    raise ValueError(marker)
method=block('    func prefetch(items assets:')
rebalanced=block('    private func prefetchOwnersDidChange()') if '    private func prefetchOwnersDidChange()' in s else ''
harness='''
import Foundation
struct GalleryMediaItem {
 let localIdentifier: String
 var mediaType: PHAssetMediaType = .image
 var cacheKey: String { localIdentifier }
}
enum PHAssetMediaType { case image, video }
enum GalleryViewerPreferences { static let globalPrefetchItemBudget = 20 }
@MainActor final class GallerySceneCache {
 static let shared = GallerySceneCache()
 var prefetchOwnerCount = 1
 var demands: [UUID: [String]] = [:]
 var retainedVideos: [String: Set<UUID>] = [:]
 static func key(for item: GalleryMediaItem) -> String { item.cacheKey }
 func updatePrefetchDemand(owner: UUID, orderedKeys: [String]) {
  if orderedKeys.isEmpty { demands.removeValue(forKey: owner) }
  else { demands[owner] = orderedKeys }
  for key in Array(retainedVideos.keys) where !orderedKeys.contains(key) {
   retainedVideos[key]?.remove(owner)
   if retainedVideos[key]?.isEmpty == true { retainedVideos.removeValue(forKey: key) }
  }
 }
 func retainVideo(_ key: String, owner: UUID) { retainedVideos[key, default: []].insert(owner) }
}
@MainActor final class Probe {
 var desiredPrefetchAssets: [GalleryMediaItem] = []
 var requestedPrefetchAssets: [GalleryMediaItem] = []
 var requestedExcludingCurrent: GalleryMediaItem?
 var requestedPreserving: GalleryMediaItem?
 var lastPrefetchOwnerCount = 1
 var prefetched: Set<String> = []
 var prefetchFailures: Set<String> = []
 var prefetchVideoSlotFailures: Set<String> = []
 var attemptedVideoPrerolls: Set<String> = []
 var deferredVideoPrerolls: Set<String> = []
 let prefetchOwnerID = UUID()
 var currentKey: String?
 var prefetchKey: String?
 var cancelled = 0
 var scheduled = 0
 func cancelPrefetchWork() { prefetchKey=nil; cancelled += 1 }
 func startPrefetchIfNeeded() { scheduled += 1 }
 METHOD
 REBALANCE
 func run() {
  let A=GalleryMediaItem(localIdentifier:"A"), B=GalleryMediaItem(localIdentifier:"B"), C=GalleryMediaItem(localIdentifier:"C")
  prefetch(items:[A,B]); prefetchFailures.insert("A")
  prefetch(items:[A,B]); precondition(!prefetchFailures.contains("A"),"explicit identical demand must retry")
  prefetchFailures.insert("A")
  prefetch(items:[B,A,C]); precondition(!prefetchFailures.contains("A"),"new ordered demand must retry transient failure")
  prefetchFailures.insert("A"); GallerySceneCache.shared.prefetchOwnerCount=2
  TEST_REBALANCE
  prefetch(items:[A,B]); prefetchFailures.insert("A")
  prefetch(items:[]); precondition(prefetchFailures.isEmpty, "close clears failures")
  prefetch(items:[A,B]); precondition(!prefetchFailures.contains("A"), "reopen may retry")
  let videoA=GalleryMediaItem(localIdentifier:"video-A",mediaType:.video)
  let videoB=GalleryMediaItem(localIdentifier:"video-B",mediaType:.video)
  let videoOwner=Probe()
  videoOwner.prefetch(items:[videoA,videoB])
  precondition(GallerySceneCache.shared.demands[videoOwner.prefetchOwnerID]==["video-A"],"only the nearest video should be demanded")
  GallerySceneCache.shared.retainVideo("video-A",owner:videoOwner.prefetchOwnerID)
  videoOwner.prefetch(items:[videoB,videoA])
  precondition(GallerySceneCache.shared.demands[videoOwner.prefetchOwnerID]==["video-B"]
    && GallerySceneCache.shared.retainedVideos["video-A"]==nil,"reorder should evict the stale same-window video reservation")
  let sibling=UUID()
  GallerySceneCache.shared.updatePrefetchDemand(owner:sibling,orderedKeys:["video-A"])
  GallerySceneCache.shared.retainVideo("video-A",owner:sibling)
  videoOwner.prefetch(items:[videoA,videoB])
  GallerySceneCache.shared.retainVideo("video-A",owner:videoOwner.prefetchOwnerID)
  videoOwner.prefetch(items:[videoB,videoA])
  precondition(GallerySceneCache.shared.demands[sibling]==["video-A"]
    && GallerySceneCache.shared.retainedVideos["video-A"]==[sibling],"reordering one window must preserve a sibling's nearest video")
  let selectedOwner=Probe()
  selectedOwner.prefetch(items:[videoB,videoA],preserving:videoA)
  precondition(GallerySceneCache.shared.demands[selectedOwner.prefetchOwnerID]==["video-A","video-B"],"preserved current video stays available for handoff alongside the nearest successor")
  print("PASS: explicit refresh, navigation/reorder retry, capacity rebalance, close/reopen")
 }
}
@main struct Main { @MainActor static func main() { Probe().run() } }
'''.replace(' METHOD',method).replace(' REBALANCE',rebalanced).replace('  TEST_REBALANCE', '  prefetchOwnersDidChange(); precondition(!prefetchFailures.contains("A") && cancelled > 0,"changed capacity must cancel stale budget and retry")' if rebalanced else '  preconditionFailure("owner-capacity rebalance missing")')
with tempfile.TemporaryDirectory() as t:
 p=Path(t); (p/'test.swift').write_text(harness)
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
