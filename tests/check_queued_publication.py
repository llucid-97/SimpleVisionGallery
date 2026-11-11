from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'SimpleVisionGallery/Gallery/GalleryVaultService.swift').read_text()
a=s.index('    private func isCurrent(_ epoch: UUID)')
b=s.index('\n    private nonisolated static func onMainSync',a)
methods=s[a:b]
code='''import Foundation
nonisolated struct GalleryVaultIndex: Sendable {
 let value: Int
 static func fromPhotoLibrary(records: [Int]) -> Self {
  precondition(!Thread.isMainThread)
  started.signal(); proceed.wait()
  return .init(value: records.first ?? -1)
 }
}
let started = DispatchSemaphore(value: 0)
let proceed = DispatchSemaphore(value: 0)
func waitForSignal(_ semaphore: DispatchSemaphore) { semaphore.wait() }
@MainActor final class Storage { var mutationRevision = 0; var records = [1] }
@MainActor final class Service {
 var isUnlocked = true; var authEpoch = UUID(); let storage = Storage()
 var records: [Int] = []; var isPublishingQueuedMutations = false
 var publishingMutationIDs = Set<UUID>(); var publishingVaultIndex: GalleryVaultIndex?
 var captured: [Int] = []
''' + methods.replace('records = storage.records','captured.append(preparedIndex?.value ?? -1); records = storage.records') + '''
 func publish(_ epoch: UUID) async { await publishQueuedIfCurrent(epoch, mutationIDs: [UUID()]) }
}
@main struct Main {
 static func main() async {
  let s = await Service(); let epoch = await s.authEpoch
  let first = Task { await s.publish(epoch) }
  await Task.detached { waitForSignal(started) }.value
  await MainActor.run { s.isUnlocked = false; s.authEpoch = UUID() }
  proceed.signal(); await first.value
  let afterLock = await s.captured; precondition(afterLock.isEmpty)
  await MainActor.run { s.isUnlocked = true }
  let nextEpoch = await s.authEpoch
  let second = Task { await s.publish(nextEpoch) }
  await Task.detached { waitForSignal(started) }.value
  await MainActor.run { s.storage.records = [2]; s.storage.mutationRevision += 1 }
  proceed.signal()
  await Task.detached { waitForSignal(started) }.value
  proceed.signal(); await second.value
  let result = await s.captured; precondition(result == [2])
  print("PASS detached preparation, lock and revision races")
 }
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d); (p/'test.swift').write_text(code)
 subprocess.run(['swiftc','-parse-as-library','-swift-version','5',str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True,timeout=30)
