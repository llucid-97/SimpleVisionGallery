from pathlib import Path
import subprocess,sys,tempfile
root=Path(sys.argv[1]) if len(sys.argv)>1 else Path.cwd();s=(root/'SimpleVisionGallery/Gallery/GalleryVaultStorage.swift').read_text()
def block(marker):
 start=s.index(marker);b=s.index('{',start);depth=0
 for i in range(b,len(s)):
  if s[i]=='{':depth+=1
  elif s[i]=='}':
   depth-=1
   if depth==0:return s[start:i+1]
 raise ValueError(marker)
space=block('    func speculativeResourceSpace('); release=block('    func releasePlaintext(')
h='''
import Foundation
struct Resource {let id:UUID}
struct Record {let resources:[Resource]}
enum GalleryVaultStorageError: Error {case locked,incompleteItem}
@MainActor final class Probe {
 var isUnlocked=true;var generation=UUID();var recordsByID:[UUID:Record]=[:]
 let plaintext:URL;let base:URL; var cleanupWarning:String?
 static let cleanupMessage="cleanup failed"
 init(base:URL){self.base=base;plaintext=base.appendingPathComponent("leases")}
 func itemURL(_ id:UUID)->URL {base.appendingPathComponent(id.uuidString)}
 static func isMissingFile(_ error:Error)->Bool { (error as NSError).code == NSFileNoSuchFileError }
 SPACE
 RELEASE
}
@main struct Main {
 @MainActor static func main() async throws {
  let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:base)}
  let p=Probe(base:base),id=UUID(),resource=UUID();p.recordsByID[id]=Record(resources:[Resource(id:resource)])
  let dir=p.itemURL(id);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  try Data(repeating:7,count:12345).write(to:dir.appendingPathComponent(resource.uuidString+".bin"))
  let (bytes,free)=try await p.speculativeResourceSpace(recordID:id,resourceID:resource)
  precondition(bytes==12345 && free>0)
  p.isUnlocked=false
  do {_ = try await p.speculativeResourceSpace(recordID:id,resourceID:resource);fatalError("locked lookup accepted")}catch GalleryVaultStorageError.locked{}
  try FileManager.default.createDirectory(at:p.plaintext,withIntermediateDirectories:true)
  let lease=p.plaintext.appendingPathComponent("fixture")
  try Data([1,2,3]).write(to:lease)
  precondition(p.releasePlaintext(lease) && !FileManager.default.fileExists(atPath:lease.path))
  precondition(p.releasePlaintext(lease),"missing lease counts as clean")
  precondition(!p.releasePlaintext(dir.appendingPathComponent("outside")),"never touch file outside lease directory")
  print("PASS: actual encrypted size/free-space stat, locked rejection and real lease cleanup")
 }
}
'''.replace(' SPACE',space).replace(' RELEASE',release)
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'test.swift').write_text(h)
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
