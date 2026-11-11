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
code='''
import Foundation
@MainActor final class Probe {
 struct Retained { var owners: Set<UUID> }
 static let prefetchOwnersDidChange=Notification.Name("testOwnersDidChange")
 var demands: [UUID:[String]] = [:]
 var retainedPrefetch: [String:Retained] = [:]
 var notifications = 0
 var token: NSObjectProtocol?
 init() { token=NotificationCenter.default.addObserver(forName:Self.prefetchOwnersDidChange,object:nil,queue:nil) { [weak self] _ in MainActor.assumeIsolated { self?.notifications += 1 } } }
 func trimPrefetchRetentions() {}
 UPDATE
 REMOVE
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
 print("PASS: owner registration, stable count, vault lock, close and rebalance signal")
 }
}
@main struct Main { @MainActor static func main() { Probe().run() } }
'''.replace(' UPDATE',update).replace(' REMOVE',remove)
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'test.swift').write_text(code)
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
