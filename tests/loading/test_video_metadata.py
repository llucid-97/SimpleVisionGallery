from pathlib import Path
import subprocess,sys,tempfile
root=Path(sys.argv[1]) if len(sys.argv)>1 else Path.cwd();s=(root/'SimpleVisionGallery/Gallery/GalleryViewerMedia.swift').read_text()
marker='    private static func prepareVideo(';start=s.index(marker);b=s.index('{',start);depth=0
for i in range(b,len(s)):
 if s[i]=='{':depth+=1
 elif s[i]=='}':
  depth-=1
  if depth==0: method=s[start:i+1];break
code='''
import Foundation
enum Characteristic {case containsStereoMultiviewVideo}
@MainActor final class Asset {var calls=0;let stereo:Bool;init(_ stereo:Bool){self.stereo=stereo}
 func loadTracks(withMediaCharacteristic value:Characteristic) async throws -> [Int] {calls += 1;return stereo ? [1]:[]}
}
@MainActor final class GalleryPreparedVideo {let asset:Asset;var isSpatialVideo=false;var aspectRatio:Double?;init(_ asset:Asset){self.asset=asset}}
@MainActor enum GalleryViewerMedia {static var calls=0;static func videoAspectRatio(_ asset:Asset) async -> Double? {calls+=1;return 1.5}}
@MainActor enum Request {
 METHOD
 static func run() async throws {
  let stereo=Asset(true), result=try await prepareVideo(GalleryPreparedVideo(stereo),spatialHint:false)
  precondition(result.isSpatialVideo && result.aspectRatio==1.5 && stereo.calls==1 && GalleryViewerMedia.calls==1)
  let hinted=Asset(false), result2=try await prepareVideo(GalleryPreparedVideo(hinted),spatialHint:true)
  precondition(result2.isSpatialVideo && result2.aspectRatio==1.5 && hinted.calls==0 && GalleryViewerMedia.calls==2)
  let mono=Asset(false), result3=try await prepareVideo(GalleryPreparedVideo(mono),spatialHint:false)
  precondition(!result3.isSpatialVideo && result3.aspectRatio==1.5 && mono.calls==1 && GalleryViewerMedia.calls==3)
  print("PASS: prepared metadata for detected stereo, spatial hint and mono")
 }
}
@main struct Main {@MainActor static func main() async throws {try await Request.run()}}
'''.replace(' METHOD',method)
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'test.swift').write_text(code)
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
