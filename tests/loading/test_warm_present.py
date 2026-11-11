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
load=block('    func load(item asset:')
code='''
import Foundation
struct GalleryMediaItem { let localIdentifier:String; let mediaType:Kind; let vaultRecord:Bool?; enum Kind { case video,image } }
struct GalleryPreparedImage { let attemptedSpatial:Bool; let marker:String }
final class GalleryPreparedVideo { let isSpatialVideo:Bool; let aspectRatio:Double?; init(_ spatial:Bool,_ ratio:Double?){isSpatialVideo=spatial;aspectRatio=ratio} }
enum GalleryPrefetchedMedia { case image(GalleryPreparedImage),video(GalleryPreparedVideo) }
enum GalleryMediaError:Error { case missingMedia }
@MainActor final class GalleryVaultStorage {static let shared=GalleryVaultStorage();var isUnlocked=true}
@MainActor final class GalleryPrefetchPriority {var foreground=false}
enum GalleryMediaRequest { static func value<T>(of task:Task<T,Error>) async throws -> T {try await task.value} }
@MainActor final class GallerySceneCache {
 static let shared=GallerySceneCache(); var warm:GalleryPrefetchedMedia?;var imageCalls=0,videoCalls=0
 static func key(for a:GalleryMediaItem)->String {a.localIdentifier}
 func retainPrefetched(_ media:GalleryPrefetchedMedia,key:String,owner:UUID)->Bool {true}
 func takePrefetched(key:String,owner:UUID)->GalleryPrefetchedMedia? {let value=warm;warm=nil;return value}
 func promote(asset:GalleryMediaItem){}
 func image(for asset:GalleryMediaItem,spatial:Bool) async throws->GalleryPreparedImage {imageCalls+=1;return GalleryPreparedImage(attemptedSpatial:spatial,marker:"fetched")}
 func video(for asset:GalleryMediaItem,foreground:Bool) async throws->GalleryPreparedVideo {videoCalls+=1;return GalleryPreparedVideo(false,nil)}
}
@MainActor final class Probe {
 var currentKey:String?,preparedKey:String?,prefetchKey:String?,error:String?,status:String?
 var desiredPrefetchAssets:[GalleryMediaItem]=[];var prefetched:Set<String>=[];let prefetchOwnerID=UUID()
 var prepared:GalleryPreparedImage?,currentVideo:GalleryPreparedVideo?,prefetchPriority:GalleryPrefetchPriority?
 var prefetchTask:Task<GalleryPrefetchedMedia,Error>?,activeLoad:Task<Void,Never>?
 var aspectRatio:Double?
 var generation=UUID(),isLoading=false;var imageMarker:String?,videoMetadata:(Bool,Double?)?,wasCanceled=false
 func cancelCurrent(releaseImage:Bool) {generation=UUID();activeLoad?.cancel();activeLoad=nil;if releaseImage {prepared=nil;preparedKey=nil}}
 func cancelPrefetchWork(){};func startPrefetchIfNeeded(){};func cancel(){wasCanceled=true}
 func presentImage(_ image:GalleryPreparedImage,key:String,spatialEnabled:Bool) {prepared=image;preparedKey=key;imageMarker=image.marker}
 func presentVideo(_ video:GalleryPreparedVideo,token:UUID) {currentVideo=video;videoMetadata=(video.isSpatialVideo,video.aspectRatio)}
 LOAD
 func run() async {
  let cache=GallerySceneCache.shared; let photo=GalleryMediaItem(localIdentifier:"p",mediaType:.image,vaultRecord:nil)
  cache.warm = .image(GalleryPreparedImage(attemptedSpatial:true,marker:"warm"))
  await load(item:photo,spatialEnabled:true)
  precondition(activeLoad==nil && imageMarker=="warm" && cache.imageCalls==0 && !isLoading,"warm image must complete inline without a foreground task")
  await load(item:photo,spatialEnabled:false)
  precondition(activeLoad==nil && imageMarker=="warm" && cache.imageCalls==0,"same-key prepared image must complete inline")
  let other=GalleryMediaItem(localIdentifier:"q",mediaType:.image,vaultRecord:nil)
  cache.warm = .image(GalleryPreparedImage(attemptedSpatial:false,marker:"mono"))
  await load(item:other,spatialEnabled:true)
  precondition(activeLoad != nil && cache.imageCalls==1 && imageMarker=="fetched","unprepared spatial image must use async path")
  let vid=GalleryMediaItem(localIdentifier:"v",mediaType:.video,vaultRecord:true)
  cache.warm = .video(GalleryPreparedVideo(true,1.5))
  await load(item:vid,spatialEnabled:true)
  precondition(activeLoad==nil && cache.videoCalls==0 && videoMetadata?.0==true && videoMetadata?.1==1.5,"warm video must use its prepared metadata inline")
  GalleryVaultStorage.shared.isUnlocked=false
  await load(item:vid,spatialEnabled:true)
  precondition(wasCanceled,"locked vault rejects inline presentation")
  print("PASS: actual load method, inline warm image/video, same-key reuse, async miss and locked vault")
 }
}
@main struct Main { @MainActor static func main() async {let probe=Probe();await probe.run()} }
'''.replace(' LOAD',load)
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'test.swift').write_text(code)
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
