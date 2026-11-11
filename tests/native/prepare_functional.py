# Target audience: agents. Add functional checks to a fresh production-copy fixture.
from pathlib import Path
import subprocess, shutil, uuid
here=Path(__file__).resolve().parent
subprocess.run(['python3',str(here/'prepare.py')],check=True)
a=here/'fixture/SimpleVisionGallery';g=a/'Gallery'
for source in ['FunctionalApp.swift','QueueFunctionalChecks.swift','NativeAutoQueue.swift']:
 shutil.copy(here/source,a/('SimpleVisionGalleryApp.swift' if source=='FunctionalApp.swift' else source))
(a/'NativeAutoTimings.swift').unlink()
(a/'TraceStubs.swift').write_text('''import Foundation
@MainActor final class CoreTrace {
 static let shared=CoreTrace()
 var delayVaultVideo=false
 var delayedVaultVideoStarted=false
 func register(session:UUID,media:GalleryViewerMedia) {}
 func unregister(session:UUID) {}
 var delayedImageKey:String?
 var delayedImageStarted=false
 var finishedOwners:[String:Set<ObjectIdentifier>]=[:]
 func didEnter(key:String) {}
 func didStartTask(key:String) {}
 func didCancel(key:String,started:Double) {}
 func didSetEntity(key:String,started:Double) {}
 func loadStart(key:String,mode:String) {}\n func loadEnd(key:String,success:Bool,owner:ObjectIdentifier) { if success { finishedOwners[key,default:[]].insert(owner) } }\n func didPrefetch(key:String) {}\n}
@MainActor final class NativeAutoTimings { static let shared=NativeAutoTimings(); var readySessions=Set<UUID>() }
''')
p=g/'GalleryRecycleBin.swift';s=p.read_text();needle='    nonisolated static let title = "Recycle Bin"';assert s.count(needle)==1
s=s.replace(needle,'    nonisolated static let title = "Generated Core Bin '+uuid.uuid4().hex+'"',1);p.write_text(s)
p=g/'GalleryVaultStorage.swift';s=p.read_text();needle='                    } catch { break }\n                }\n            }';assert s.count(needle)==1
s=s.replace(needle,'''                    } catch { break }
                }
                // Fixture-only delay after one completed item enables lock mid-batch.
                if index == 0 { try? await Task.sleep(for: .seconds(2)) }
            }''',1)
p.write_text(s+'\n'+(here/'VaultFunctionalHooks.swift.txt').read_text())
p=g/'GalleryManager.swift';p.write_text(p.read_text()+'\nextension GalleryManager { func proofHoldPhotoRefresh(_ hold: Bool) { vaultChanges.setBusy(hold) } }\n')
p=g/'GalleryViewerWindows.swift';s=p.read_text();needle='    func attach(';assert s.count(needle)==1;s=s.replace(needle,'''    func proofAttachedCount(for sessionIDs: Set<UUID>) -> Int {
        sceneWindows.values.filter { !sessionIDs.isDisjoint(with: $0.sessionIDs) }.count
    }

'''+needle,1);p.write_text(s)
print('Functional fixture prepared')

p=g/'GalleryViewerStore.swift'
p.write_text(p.read_text()+"""
extension GalleryViewerStore {
    func proofSnapshotForSession(_ id: UUID) -> GalleryViewerSnapshot? { sessions[id]?.playlist.snapshot }
}
""")

p=g/'GalleryViewerMedia.swift';s=p.read_text();a=s.index('    func image(for asset: GalleryMediaItem');anchor='                defer { generationGate.release() }';i=s.index(anchor,a)+len(anchor)
s=s[:i]+"\n                if CoreTrace.shared.delayedImageKey == assetKey {\n                    CoreTrace.shared.delayedImageStarted = true\n                    try await Task.sleep(for: .seconds(1))\n                }"+s[i:];p.write_text(s)
