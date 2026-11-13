from pathlib import Path
import subprocess,sys,tempfile
root=Path(sys.argv[1]) if len(sys.argv)>1 else Path.cwd();s=(root/'SimpleVisionGallery/Gallery/GalleryViewerMedia.swift').read_text()
start=s.index('private final class GalleryPreparedVideo');begin=s.index('{',start);depth=0
for i in range(begin,len(s)):
 if s[i]=='{':depth+=1
 elif s[i]=='}':
  depth-=1
  if depth==0: source=s[start:i+1];break
h='''
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
@MainActor final class GalleryVaultStorage {
 static let shared=GalleryVaultStorage(); var cleanupSucceeds=true; var events:[String]=[]
 func releasePlaintext(_ url:URL)->Bool { events.append("cleanup"); return cleanupSucceeds }
}
@MainActor SOURCE
@main struct Main {
 @MainActor static func main() async throws {
  let storage=GalleryVaultStorage.shared
  var video:GalleryPreparedVideo?=GalleryPreparedVideo(asset:AVAsset(),plaintextURL:URL(fileURLWithPath:"/fake"))
  video!.onPrefetchRelease = { storage.events.append("slot") }
  video=nil
  try await Task.sleep(nanoseconds:5_000_000)
  precondition(storage.events == ["cleanup","slot"],"slot is released only after plaintext cleanup")
  storage.events=[];storage.cleanupSucceeds=false
  video=GalleryPreparedVideo(asset:AVAsset(),plaintextURL:URL(fileURLWithPath:"/fake"))
  video!.onPrefetchRelease = { storage.events.append("slot") }
  video=nil
  try await Task.sleep(nanoseconds:5_000_000)
  precondition(storage.events == ["cleanup"],"failed cleanup must keep slot reserved")
  print("PASS: lease cleanup precedes slot release; failed cleanup fences new speculative lease")
 }
}
'''.replace('SOURCE',source)
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'test.swift').write_text(h)
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
