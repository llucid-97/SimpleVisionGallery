# Target audience: agents. Inject proof hooks only into a task-owned generated-data copy.
from pathlib import Path
import shutil, hashlib, json, subprocess, os, uuid
here=Path(__file__).resolve().parent
root=Path(os.environ.get('GALLERY_FIXTURE_SOURCE',str(here.parents[1]))).resolve()
out=here/'fixture'
if out.exists(): shutil.rmtree(out)  # task-owned derived fixture only
out.mkdir()
shutil.copytree(root/'SimpleVisionGallery',out/'SimpleVisionGallery')
fixture_app=(here/'FixtureApp.swift').read_text()
if os.environ.get('GALLERY_REQUIRE_PHOTOS_AUTH') == '1':
    needle='            await manager.requestAuthorization()'
    assert fixture_app.count(needle)==1
    fixture_app=fixture_app.replace(needle, '            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { status = "PhotosPermissionMissing"; return }\n'+needle)
(out/'SimpleVisionGallery/SimpleVisionGalleryApp.swift').write_text(fixture_app)
timing=(here/'NativeAutoTimings.swift').read_text()
if os.environ.get('GALLERY_DIAGNOSTIC_SMALL') == '1':
    timing=timing.replace('state.seedPhotos(); try await wait("seed_photos", timeout: 120, until: { state.status == "PhotosSeeded-1000" })','state.seedPhotos(20); try await wait("seed_photos", timeout: 120, until: { state.status == "PhotosSeeded-20" })')
if os.environ.get('GALLERY_PHOTOS_ONLY') == '1':
    begin=timing.index('            state.unlock();')
    end=timing.index('            state.seedPhotos(',begin)
    timing=timing[:begin]+timing[end:]
    timing=timing.replace('        progress(step)\n        let end', '        progress(step)\n        let end',1)
    timing=timing.replace('while !predicate() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }', 'while !predicate() && state.status != "PhotosPermissionMissing" && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }',1)
if os.environ.get('GALLERY_VIDEO_PROOF') == '1':
    timing=timing.replace('            write(passed: true, failedStep: "")','            try await measureVaultVideo()\n            write(passed: true, failedStep: "")',1)
if os.environ.get('GALLERY_SKIP_PHOTOS') == '1':
    timing=timing.replace('            state.seedPhotos(); try await wait("seed_photos", timeout: 120, until: { state.status == "PhotosSeeded-1000" })\n            try await measurePhotos()\n','')
source_queue=(root/'SimpleVisionGallery/Gallery/GalleryDeleteQueue.swift').read_text()
if os.environ.get('GALLERY_TRANSFER_PROOF') == '1':
    assert 'func enqueueMove(item:' in source_queue
    transfer="""        state.unlock(); try await wait("unlock_transfer", until:{ state.status == "Unlocked" })
        guard let item=session.currentItem, let asset=item.photosAsset else { throw NSError(domain:"CoreContractGenerated",code:12,userInfo:["step":"transfer_photo_missing"]) }
        let sourceID=asset.localIdentifier
        let beforeFetch=PHAsset.fetchAssets(with:nil)
        let photosBefore=Set((0..<beforeFetch.count).map { beforeFetch.object(at:$0).localIdentifier })
        let destination=GalleryVaultAlbum(id:"vault-album:core-transfer",title:"Generated Transfer Destination",position:nil)
        let oldID=session.currentItem?.localIdentifier
        let vaultIDsBefore=Set(state.vault.records.map(\\.id))
        let actionStarted=CACurrentMediaTime()
        let transferProbe=DeleteFrameProbe.shared;transferProbe.arm("photos-to-vault");transferProbe.beginIfArmed()
        GalleryDeleteQueue.shared.enqueueMove(item:item,sourceAlbumID:session.sourceAlbumID,sessionID:id,
            action:.moveToVault(id:destination.id,epoch:state.vault.authEpoch,sourceAlbumID:session.sourceAlbumID),vaultDestination:destination)
        let transferReturned=CACurrentMediaTime()
        let advanced=session.currentItem?.localIdentifier != oldID
        let nextBefore=session.currentItem?.localIdentifier
        let nextWasAvailable=session.canGoNext
        if nextWasAvailable { state.store.next(id) }
        let nextAdvanced = !nextWasAvailable || session.currentItem?.localIdentifier != nextBefore
        rows.append(["case":"photos-to-vault-pending","enqueue_ms":(transferReturned-actionStarted)*1000,
                     "advanced_immediately":advanced,"next_available":nextWasAvailable,"next_advanced":nextAdvanced,
                     "pending_count":GalleryDeleteQueue.shared.pendingCount])
        flushPartial()
        Task { @MainActor in
            try? await Task.sleep(for:.seconds(21))
            let storedCounts=state.storage.proofStoredTransferCounts()
            let fields:[String:Any] = ["pending_count":GalleryDeleteQueue.shared.pendingCount,
                "photos_unresponsive":GalleryDeleteQueue.shared.photosUnresponsive,"vault_busy":state.vault.isBusy,
                "copy_pending_count":storedCounts.pending,
                "private_count":storedCounts.privateItems,
                "source_exists":PHAsset.fetchAssets(withLocalIdentifiers:[sourceID],options:nil).count > 0,
                "can_go_next":session.canGoNext]
            if let data=try? JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys,.prettyPrinted]) {
                try? data.write(to:state.documents.appendingPathComponent("transfer-watchdog.json"),options:.atomic)
            }
        }
        try await wait("photos_to_vault_drain",timeout:90,until:{ GalleryDeleteQueue.shared.pendingCount == 0 })
        transferProbe.finish()
        try await wait("photos_to_vault_frame",until:{ transferProbe.result.hasPrefix("photos-to-vault=") })
        let moved=state.vault.records.filter { $0.sourceIdentifier == sourceID && $0.state == .privateItem }
        let newIDs=Set(state.vault.records.map(\\.id)).subtracting(vaultIDsBefore)
        let afterFetch=PHAsset.fetchAssets(with:nil)
        let photosAfter=Set((0..<afterFetch.count).map { afterFetch.object(at:$0).localIdentifier })
        guard photosBefore.subtracting(photosAfter) == Set([sourceID]), photosAfter.subtracting(photosBefore).isEmpty, moved.count == 1 && newIDs == Set(moved.map(\\.id)), PHAsset.fetchAssets(withLocalIdentifiers:[sourceID],options:nil).count == 0 else { throw NSError(domain:"CoreContractGenerated",code:13,userInfo:["step":"photos_to_vault_exact_target"]) }
        rows.append(["case":"photos-to-vault","enqueue_ms":(transferReturned-actionStarted)*1000,"advanced_immediately":advanced,"exact_target_moved":true,"frame":transferProbe.result])
"""
    timing=timing.replace('        // GENERATED_TRANSFER_PROOF',transfer)
if 'func enqueueMove(item:' in source_queue:
    before="""        let task = Task { try await state.vault.move(recordID: current.id, from: source, to: destination) }
        let afterSubmit = CACurrentMediaTime()
        let advancedImmediately = session.currentItem?.localIdentifier != oldID
        var failure = false
        do { try await task.value } catch { failure = true }"""
    after="""        GalleryDeleteQueue.shared.enqueueMove(item: .vault(current), sourceAlbumID: source, sessionID: id,
            action: .moveToVault(id: destination.id, epoch: state.vault.authEpoch, sourceAlbumID: source), vaultDestination: destination)
        let afterSubmit = CACurrentMediaTime()
        let advancedImmediately = session.currentItem?.localIdentifier != oldID
        try await wait("queue_drain_"+label, until: { GalleryDeleteQueue.shared.pendingCount == 0 })
        let failure = GalleryDeleteQueue.shared.errorMessage != nil"""
    assert timing.count(before)==1
    timing=timing.replace(before,after,1)
(out/'SimpleVisionGallery/NativeAutoTimings.swift').write_text(timing)
project=(here/'project.yml').read_text().replace('com.llucid.nonblocking-delete-measurement','com.llucid.gallery-core-contracts-generated').replace('../measurement.entitlements','../measurement.entitlements')
(out/'project.yml').write_text(project)

def replace(path,a,b):
 s=path.read_text(); n=s.count(a)
 if n!=1: raise RuntimeError(f'Expected one anchor in {path.name}, got {n}: {a[:80]}')
 path.write_text(s.replace(a,b,1))

g=out/'SimpleVisionGallery/Gallery'
p=g/'GalleryVaultStorage.swift'
run_id=uuid.uuid4().hex
s=p.read_text().replace('com.llucid.simplevisiongallery.privatevault.v1','com.llucid.gallery-core-contracts-generated.v1').replace('"PrivateVault"','"CoreContractsGeneratedVault-'+run_id+'"').replace('"PrivateVaultLeases"','"CoreContractsGeneratedLeases-'+run_id+'"')
ext=(here/'VaultFixtureHooks.swift.txt').read_text()
p.write_text(s+'\n'+ext+'\n'+(here/'VaultVideoHooks.swift.txt').read_text())
shutil.copy(here/'generated-contract-video.mp4',out/'SimpleVisionGallery/generated-contract-video.mp4')
p=g/'GalleryVaultService.swift'
service='''    func proofPublishGeneratedRecords() { records = storage.records }
    func proofUnlockGeneratedRecords() async throws {
        try await storage.proofUnlockGeneratedRecords()
        authEpoch = UUID()
        isUnlocked = true
        records = storage.records
        unreadableRecordCount = storage.unreadableRecordCount
    }

'''
replace(p,'    private nonisolated static func onMainSync(',service+'    private nonisolated static func onMainSync(')
if os.environ.get('GALLERY_PROFILE_PUBLISH') == '1':
 def profile_method(path, signature, timer):
  source=path.read_text();start=source.index(signature)+len(signature);depth=1;i=start
  while depth:
   depth += (source[i]=='{')-(source[i]=='}');i+=1
  path.write_text(source[:start]+'\n        DeleteFrameProbe.shared.'+timer+' {\n'+source[start:i-1]+'        }\n    '+source[i-1:])
 profile_method(g/'GalleryManager.swift','private func vaultRecordsDidChange(_ records: [GalleryVaultRecord]) {','measureManagerPublish')
 profile_method(g/'GalleryViewerStore.swift','private func updateVaultPlaylists(_ records: [GalleryVaultRecord], mutatedIDs: Set<UUID>? = nil,\n                                      preparedIndex: GalleryVaultIndex? = nil) {','measureStorePublish')
 pservice=g/'GalleryVaultService.swift'
 replace(pservice, '        records = storage.records\n    }\n\n    func proofPublishGeneratedRecords()', '        DeleteFrameProbe.shared.measureSynchronousPublish { records = storage.records }\n    }\n\n    func proofPublishGeneratedRecords()')
p=g/'GalleryViewerMedia.swift'
replace(p,'import AVFoundation', 'import AVFoundation\nimport QuartzCore')
replace(p,'    func load(asset: PHAsset, spatialEnabled: Bool) async {', '    func proofHasPrefetched(_ key: String) -> Bool { GallerySceneCache.shared.hasPrefetched(key, owner: prefetchOwnerID) }\n\n    func load(asset: PHAsset, spatialEnabled: Bool) async {')
replace(p,'    static func video(_ item: GalleryMediaItem) async throws -> GalleryPreparedVideo {', '    static func video(_ item: GalleryMediaItem) async throws -> GalleryPreparedVideo {\n        if CoreTrace.shared.delayVaultVideo, item.vaultRecord != nil {\n            CoreTrace.shared.delayedVaultVideoStarted = true\n            try await Task.sleep(for: .seconds(1))\n        }')
replace(p,'        let requestedKey = GallerySceneCache.key(for: asset)', '        let requestedKey = GallerySceneCache.key(for: asset)\n        CoreTrace.shared.didEnter(key: requestedKey)')
replace(p,'        cancelCurrent(releaseImage: preparedKey != requestedKey)', '        let proofCancelStarted = CACurrentMediaTime()\n        cancelCurrent(releaseImage: preparedKey != requestedKey)\n        CoreTrace.shared.didCancel(key: requestedKey, started: proofCancelStarted)')
replace(p,'            defer { promoted?.cancel() }', '            defer { promoted?.cancel() }\n            CoreTrace.shared.didStartTask(key: requestedKey)')
if 'private func presentImage(' in p.read_text():
 replace(p,'            let entity = Entity()\n            entity.components.set(component)', '            let proofEntityStarted = CACurrentMediaTime()\n            let entity = Entity()\n            entity.components.set(component)\n            CoreTrace.shared.didSetEntity(key: key, started: proofEntityStarted)')
 replace(p,'                presentImage(ready, key: requestedKey, spatialEnabled: spatialEnabled)', '                CoreTrace.shared.didStartTask(key: requestedKey)\n                presentImage(ready, key: requestedKey, spatialEnabled: spatialEnabled)')
 replace(p,'            self.fallbackImage = image.fallback\n        }\n    }\n\n    fileprivate static func videoAspectRatio', '            self.fallbackImage = image.fallback\n        }\n        CoreTrace.shared.loadEnd(key: key, success: self.imageEntity != nil || self.fallbackImage != nil, owner: ObjectIdentifier(self))\n    }\n\n    fileprivate static func videoAspectRatio')
 replace(p,'                presentVideo(ready, token: token)\n                isLoading = false', '                CoreTrace.shared.didStartTask(key: requestedKey)\n                presentVideo(ready, token: token)\n                isLoading = false')
 replace(p,'        else { self.resumePlaybackWhenActive = true }\n    }\n', '        else { self.resumePlaybackWhenActive = true }\n        if let key = self.currentKey { CoreTrace.shared.loadEnd(key: key, success: self.player != nil, owner: ObjectIdentifier(self)) }\n    }\n')
else:
 replace(p,'                        let entity = Entity()\n                        entity.components.set(component)', '                        let proofEntityStarted = CACurrentMediaTime()\n                        let entity = Entity()\n                        entity.components.set(component)\n                        CoreTrace.shared.didSetEntity(key: requestedKey, started: proofEntityStarted)')
replace(p,'        let promoted = prefetchKey == requestedKey ? prefetchTask : nil', '        let promoted = prefetchKey == requestedKey ? prefetchTask : nil\n        CoreTrace.shared.loadStart(key: requestedKey, mode: warmed != nil ? "retained" : (promoted != nil ? "promoted" : "foreground"))')
replace(p,'            if self.generation == token {\n                self.isLoading = false','            if self.generation == token {\n                CoreTrace.shared.loadEnd(key: requestedKey, success: self.imageEntity != nil || self.fallbackImage != nil || self.player != nil, owner: ObjectIdentifier(self))\n                self.isLoading = false')
replace(p,'                        self.prefetched.insert(key)\n                    } else {','                        self.prefetched.insert(key)\n                        CoreTrace.shared.didPrefetch(key: key)\n                    } else {')
p=g/'GalleryViewerView.swift'
needle='.accessibilityIdentifier("gallery-viewer-media")'
replace(p,needle,needle+'\n                    .onAppear { CoreTrace.shared.register(session: session.id, media: media) }\n                    .onDisappear { CoreTrace.shared.unregister(session: session.id) }\n                    .onChange(of: media.imageEntity != nil || media.fallbackImage != nil, initial: true) { _, ready in\n                        if ready { NativeAutoTimings.shared.readySessions.insert(session.id) }\n                    }')
# Generated test app may safely use a dedicated scene namespace.
p=g/'GalleryViewerWindows.swift';s=p.read_text().replace('"gallery-viewer"','"core-contract-viewer-v1"').replace('"gallery-viewer-pair"','"core-contract-pair-v1"');p.write_text(s)
files=sorted((root/'SimpleVisionGallery').rglob('*.swift'))
record={str(f.relative_to(root)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}
(here/'source-snapshot.json').write_text(json.dumps(dict(head=os.environ.get('GALLERY_FIXTURE_REVISION') or subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),sha256=record),indent=2)+'\n')
print('Prepared fresh-source fixture:',len(files),'Swift files')
