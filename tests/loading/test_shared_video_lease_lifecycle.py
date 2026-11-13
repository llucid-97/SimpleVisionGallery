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
parts=[block(m) for m in ['private final class GalleryPreparedVideo', '    private final class WeakVideo', '    func preparedVideo(for asset:', '    private func rememberVideo(']]
code='''
import Foundation
class AVAsset {}
enum GalleryMediaError: Error { case videoPrerollFailed }
final class GalleryPrerollCompletion {
 func finish(_ result: Result<Void,Error>) {}
 func install(_ continuation: CheckedContinuation<Void,Error>) {}
}
final class AVPlayerItem {
 enum Status { case unknown, readyToPlay, failed }
 var status: Status = .readyToPlay
 var error: Error?
 var preferredForwardBufferDuration: Double = 0
 init(asset: AVAsset) {}
}
final class AVPlayer {
 enum Status { case unknown, readyToPlay, failed }
 enum ActionAtItemEnd { case pause }
 var status: Status = .readyToPlay
 var error: Error?
 var currentItem: AVPlayerItem?
 var isMuted = false
 var volume: Float = 1
 var actionAtItemEnd: ActionAtItemEnd = .pause
 init(playerItem: AVPlayerItem) { currentItem = playerItem }
 func pause() {}
 func cancelPendingPrerolls() {}
 func replaceCurrentItem(with item: AVPlayerItem?) { currentItem = item }
 func preroll(atRate: Float, completionHandler: @escaping (Bool)->Void) { completionHandler(true) }
}
struct GalleryMediaItem {let localIdentifier:String;let vaultRecord:Bool?}
enum GalleryPrefetchedMedia {case video(GalleryPreparedVideo)}
enum GalleryViewerPreferences {static let globalPrefetchItemBudget=20}
@MainActor final class GalleryVaultStorage {static let shared=GalleryVaultStorage();var isUnlocked=true;func releasePlaintext(_ url:URL)->Bool {do {try FileManager.default.removeItem(at:url);return true}catch{return false}}}
@MainActor VIDEO
@MainActor final class Probe {
 struct Retained {var media:GalleryPrefetchedMedia;var access:UInt64}
 WEAK
 var clock:UInt64=0,completedVideos:[String:WeakVideo]=[:],retainedPrefetch:[String:Retained]=[:]
 static func key(for asset:GalleryMediaItem)->String {asset.localIdentifier}
 LOOKUP
 REMEMBER
 func run() async throws {
  let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try Data([1,2,3]).write(to:url)
  defer {try? FileManager.default.removeItem(at:url)}
  let item=GalleryMediaItem(localIdentifier:"vault-item",vaultRecord:true)
  var viewer1:GalleryPreparedVideo?=GalleryPreparedVideo(asset:AVAsset(),plaintextURL:url)
  weak var weakVideo=viewer1
  rememberVideo(viewer1!,key:item.localIdentifier)
  var viewer2:GalleryPreparedVideo?=preparedVideo(for:item,foreground:true)
  precondition(viewer2 === viewer1)
  viewer1=nil
  precondition(FileManager.default.fileExists(atPath:url.path),"second window keeps lease alive")
  viewer2=nil
  for _ in 0..<100 where FileManager.default.fileExists(atPath:url.path) {try await Task.sleep(nanoseconds:1_000_000)}
  precondition(weakVideo==nil && !FileManager.default.fileExists(atPath:url.path),"last window frees protected lease; cache is weak")
  print("PASS: shared active video, independent consumers, last consumer removes lease")
 }
}
@main struct Main {@MainActor static func main() async throws {let p=Probe();try await p.run()}}
'''.replace('VIDEO',parts[0].replace('private final class','final class',1)).replace(' WEAK',parts[1].replace('private final class','final class',1)).replace(' LOOKUP',parts[2]).replace(' REMEMBER',parts[3])
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'test.swift').write_text(code)
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
