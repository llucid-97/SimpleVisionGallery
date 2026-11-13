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
methods='\n'.join(block(m) for m in ['    func prefetch(items assets:', '    private func startPrefetchIfNeeded()', '    func setSceneActive(_ active:'])
code='''
import Foundation
struct GalleryMediaItem { let localIdentifier: String; var mediaType: PHAssetMediaType = .image }
enum PHAssetMediaType { case image, video }
final class GalleryPreparedVideo {}
enum GalleryPrefetchedMedia { case image, video(GalleryPreparedVideo) }
enum GalleryVideoPrerollOutcome: Equatable { case scheduled, alreadyPrepared, slotUnavailable }
enum GalleryMediaError: Error { case prefetchVideoSlotUnavailable, transient }
struct GalleryViewerPreferences { static let globalPrefetchItemBudget=20 }
@MainActor final class GalleryPrefetchPriority {}
@MainActor final class GallerySceneCache {
 static let shared=GallerySceneCache(); var prefetchOwnerCount=1; var vaultVideoSlotAvailable=true; var videoPrerollSlotAvailable=true; var retained:Set<String>=[]
 static func key(for item:GalleryMediaItem)->String {item.localIdentifier}
 func updatePrefetchDemand(owner:UUID,orderedKeys:[String]) { retained.formIntersection(orderedKeys) }
 func retainPrefetched(_ media:GalleryPrefetchedMedia,key:String,owner:UUID)->Bool { retained.insert(key); return true }
 func scheduleVideoPreroll(_ video:GalleryPreparedVideo,key:String)->GalleryVideoPrerollOutcome { .scheduled }
}
@MainActor final class Player { var timeControlStatus: Status = .paused; enum Status {case paused,playing}; func pause(){};func play(){} }
@MainActor final class Probe {
 var desiredPrefetchAssets:[GalleryMediaItem]=[],requestedPrefetchAssets:[GalleryMediaItem]=[]
 var requestedExcludingCurrent:GalleryMediaItem?, requestedPreserving:GalleryMediaItem?
 var prefetched:Set<String>=[], prefetchFailures:Set<String>=[],prefetchVideoSlotFailures:Set<String>=[]
 var attemptedVideoPrerolls:Set<String>=[],deferredVideoPrerolls:Set<String>=[]
 let prefetchOwnerID=UUID();var currentKey:String?,prefetchKey:String?
 var prefetchTask:Task<GalleryPrefetchedMedia,Error>?,prefetchCoordinator:Task<Void,Never>?
 var prefetchGeneration=UUID(),prefetchPriority:GalleryPrefetchPriority?,videoPrerollSlotGeneration:UInt64=0
 var lastPrefetchOwnerCount=1,isSceneActive=true,isLoading=false,isPresentationCovered=false,resumePlaybackWhenActive=false
 var player:Player?
 var attempts:[String:Int]=[:];var failOnce:Set<String>=[];var failAlways:Set<String>=[]
 func upgradeNearestVideoPreroll() {}
 func isNearestVideo(_ key:String)->Bool { false }
 func cancelPrefetchWork() {prefetchGeneration=UUID();prefetchCoordinator?.cancel();prefetchCoordinator=nil;prefetchTask?.cancel();prefetchTask=nil;prefetchKey=nil}
 func nextPrefetchRequest()->(String,Task<GalleryPrefetchedMedia,Error>)? {
  guard isSceneActive && !isLoading else {return nil}
  guard let key=desiredPrefetchAssets.map(\\.localIdentifier).first(where: {!prefetchFailures.contains($0) && !GallerySceneCache.shared.retained.contains($0)}) else{return nil}
  let t=Task<GalleryPrefetchedMedia,Error> { @MainActor in
   self.attempts[key,default:0]+=1
   if self.failOnce.remove(key) != nil || self.failAlways.contains(key) {throw GalleryMediaError.transient}
   return .image
  }
  prefetchTask=t;prefetchKey=key;return(key,t)
 }
 METHODS
 func waitIdle() async throws {
  for _ in 0..<100 {if prefetchCoordinator == nil{return};try await Task.sleep(nanoseconds:1_000_000)}
  fatalError("coordinator did not settle")
 }
 func run() async throws {
  let a=GalleryMediaItem(localIdentifier:"transient"),b=GalleryMediaItem(localIdentifier:"permanent"),c=GalleryMediaItem(localIdentifier:"reactivate")
  failOnce.insert("transient");prefetch(items:[a]);try await waitIdle()
  precondition(attempts["transient"]==1 && prefetchFailures.contains("transient"))
  try await Task.sleep(nanoseconds:20_000_000)
  precondition(attempts["transient"]==1,"no unbounded automatic retry")
  prefetch(items:[a]);try await waitIdle()
  precondition(attempts["transient"]==2 && GallerySceneCache.shared.retained.contains("transient"),"same-demand explicit refresh must recover")
  failAlways.insert("permanent");prefetch(items:[b]);try await waitIdle()
  try await Task.sleep(nanoseconds:20_000_000)
  precondition(attempts["permanent"]==1,"permanent failure must not spin")
  failOnce.insert("reactivate");prefetch(items:[c]);try await waitIdle()
  precondition(attempts["reactivate"]==1)
  setSceneActive(false);setSceneActive(true);try await waitIdle()
  precondition(attempts["reactivate"]==2 && GallerySceneCache.shared.retained.contains("reactivate"),"reactivation must retry once")
  print("PASS: real coordinator; unchanged refresh retry; permanent failure no spin; reactivation retry")
 }
}
@main struct Main { @MainActor static func main() async throws {let probe=Probe();try await probe.run()} }
'''.replace(' METHODS',methods)
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'test.swift').write_text(code)
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
