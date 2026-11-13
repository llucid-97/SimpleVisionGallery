# Target audience: developers. Production shared-media behavior with generated fixtures.
from pathlib import Path
import subprocess,sys,tempfile
root=Path(sys.argv[1]) if len(sys.argv)>1 else Path.cwd();s=(root/'SimpleVisionGallery/Gallery/GalleryViewerMedia.swift').read_text()
def block(marker):
 start=s.index(marker);b=s.index('{',start);depth=0
 for i in range(b,len(s)):
  if s[i]=='{':depth+=1
  elif s[i]=='}':
   depth-=1
   if depth==0:return s[start:i+1]
 raise ValueError(marker)
methods='\n'.join(block(m) for m in ['    func preparedImage(for asset:', '    func preparedVideo(for asset:', '    private func rememberVideo(', '    private func clearSources(', '    private func clearPhotos()', '    private func clearVault()'])
code='''
import Foundation
struct GalleryMediaItem {let localIdentifier:String;let vaultRecord:Bool?
 static func sourceIdentifier(forCacheKey key:String)->String? {
  var value=key
  for suffix in [":scene",":original",":video"] where value.hasSuffix(suffix) { value.removeLast(suffix.count);break }
  guard let separator=value.lastIndex(of:":") else {return nil}
  return String(value[..<separator])
 }
}
struct GalleryPreparedImage {let marker:String}
@MainActor final class GalleryPreparedVideo {let isVault:Bool;var isForeground=false;init(_ v:Bool){isVault=v};func promote(){isForeground=true}}
enum GalleryPrefetchedMedia {case video(GalleryPreparedVideo)}
@MainActor final class GalleryVaultStorage {static let shared=GalleryVaultStorage();var isUnlocked=true}
enum GalleryViewerPreferences {static let globalPrefetchItemBudget=20}
final class FakeTask {func cancel(){}}
@MainActor final class Probe {
 struct Entry {var image:GalleryPreparedImage;var access:UInt64}
 struct Pending {var task=FakeTask()}
 struct Retained {var media:GalleryPrefetchedMedia;var owners:Set<UUID>;var access:UInt64}
 final class WeakVideo {weak var video:GalleryPreparedVideo?;var access:UInt64;init(_ v:GalleryPreparedVideo,access:UInt64){video=v;self.access=access}}
 var entries:[String:Entry]=[:],pending:[String:Pending]=[:],pendingVideos:[String:Pending]=[:]
 var completedVideos:[String:WeakVideo]=[:],retainedPrefetch:[String:Retained]=[:]
 var demands:[UUID:[String]]=[:],hiddenSourceGenerations:[String:UUID]=[:]
 var clock:UInt64=0,vaultGeneration=UUID(),photosGeneration=UUID();var vaultVideoReservation:(key:String,id:UUID)?
 var videoPrerollReservation:(key:String,id:UUID)?
 static func key(for asset:GalleryMediaItem)->String {asset.localIdentifier}
 func removeDemandKeys(where predicate:(String)->Bool){}
 func releaseVaultVideoReservation(key:String){vaultVideoReservation=nil}
 func clearSpeculativeVideoPreroll(){videoPrerollReservation=nil}
 METHODS
 func run() {
  let photo=GalleryMediaItem(localIdentifier:"photo",vaultRecord:nil),vault=GalleryMediaItem(localIdentifier:"vault:test",vaultRecord:true)
  entries["photo:scene"]=Entry(image:GalleryPreparedImage(marker:"scene"),access:0)
  precondition(preparedImage(for:photo,spatial:false)?.marker=="scene" && entries["photo:scene"]!.access>0)
  entries["vault:test:scene"]=Entry(image:GalleryPreparedImage(marker:"private"),access:0)
  GalleryVaultStorage.shared.isUnlocked=false
  precondition(preparedImage(for:vault,spatial:true)==nil,"locked private image must not escape")
  GalleryVaultStorage.shared.isUnlocked=true
  let owner=UUID();var held:GalleryPreparedVideo?=GalleryPreparedVideo(true); weak var weakHeld=held
  rememberVideo(held!,key:"vault:test")
  retainedPrefetch["vault:test"]=Retained(media:.video(held!),owners:[owner],access:0)
  precondition(preparedVideo(for:vault,foreground:true) === held && held!.isForeground && retainedPrefetch["vault:test"] == nil)
  held=nil
  precondition(weakHeld == nil && preparedVideo(for:vault,foreground:true)==nil,"weak entry must not extend video/lease lifetime")
  var photos:[GalleryPreparedVideo]=[]
  for i in 0..<21 {let v=GalleryPreparedVideo(false);photos.append(v);rememberVideo(v,key:"photo\\(i)")}
  precondition(completedVideos.count==20 && completedVideos["photo0"]==nil,"weak entries bounded and oldest pruned")
  let keep=GalleryPreparedVideo(false),remove=GalleryPreparedVideo(false)
  rememberVideo(keep,key:"other:1");rememberVideo(remove,key:"photo:1")
  clearSources(["photo"])
  precondition(completedVideos["photo:1"]==nil && completedVideos["other:1"] != nil,"hiding one Photos source must only purge its cache")
  clearPhotos();precondition(completedVideos.isEmpty && entries["photo:scene"]==nil)
  let v=GalleryPreparedVideo(true);rememberVideo(v,key:"vault:test");clearVault()
  precondition(completedVideos.isEmpty && entries["vault:test:scene"]==nil,"lock removes private weak and image cache entries")
  print("PASS: shared image cache, weak video reuse and final release, 20-key limit, access revoke and lock purge")
 }
}
@main struct Main {@MainActor static func main(){Probe().run()}}
'''.replace(' METHODS',methods)
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'test.swift').write_text(code)
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
