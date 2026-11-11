// Target audience: agents. Generated media only; timings do not prove headset rendering.
import Foundation
import AVFoundation
import Photos
import SwiftUI
import QuartzCore

@MainActor final class WeakViewerMedia {
    weak var value: GalleryViewerMedia?
    init(_ value: GalleryViewerMedia) { self.value=value }
}
/// Records preparation milestones so a retained hit can be separated from rendering delay.
@MainActor final class CoreTrace {
    static let shared = CoreTrace()
    var delayVaultVideo = false
    var delayedVaultVideoStarted = false
    var viewers:[UUID:WeakViewerMedia] = [:]
    func register(session:UUID,media:GalleryViewerMedia) { viewers[session]=WeakViewerMedia(media) }
    func unregister(session:UUID) { viewers.removeValue(forKey:session) }
    func hasRetained(session:UUID,key:String) -> Bool { viewers[session]?.value?.proofHasPrefetched(key) == true }
    var prefetched: Set<String> = []
    var entries: [String: Double] = [:]
    var taskStarts: [String: Double] = [:]
    var cancelDurations: [String: Double] = [:]
    var entityDurations: [String: Double] = [:]
    var starts: [String: (Double,String)] = [:]
    var finishes: [String: (Double,Bool)] = [:]
    func didEnter(key: String) { entries[key] = CACurrentMediaTime() }
    func didStartTask(key: String) { taskStarts[key] = CACurrentMediaTime() }
    func didCancel(key: String, started: Double) { cancelDurations[key] = CACurrentMediaTime()-started }
    func didSetEntity(key: String, started: Double) { entityDurations[key] = CACurrentMediaTime()-started }
    func didPrefetch(key: String) { prefetched.insert(key) }
    func loadStart(key: String, mode: String) { starts[key] = (CACurrentMediaTime(),mode) }
    func loadEnd(key: String, success: Bool, owner: ObjectIdentifier) { finishes[key] = (CACurrentMediaTime(),success) }
}

/// Runs generated native timing cases and records their frame and readiness evidence.
@MainActor final class NativeAutoTimings {
    static let shared = NativeAutoTimings()
    static let kind = "core-contracts-generated-v1"
    var readySessions = Set<UUID>()
    private var ran = false
    private let state = MeasurementState.shared
    private var rows: [[String: Any]] = []
    private func progress(_ step: String) {
        try? Data(step.utf8).write(to: state.documents.appendingPathComponent("auto-progress.txt"), options: .atomic)
    }
    private func wait(_ step: String, timeout: Int = 60, until predicate: () -> Bool) async throws {
        progress(step)
        let end = ContinuousClock.now + .seconds(timeout)
        while !predicate() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        if !predicate() { throw NSError(domain: "CoreContractGenerated", code: 1, userInfo: ["step":step]) }
    }
    /// Runs the vault and Photos sizes in order so each timing row has an initialized fixture.
    func run() async {
        guard !ran else { return }; ran = true
        // Stop on the first failed phase and preserve its fixed step name in the result.
        do {
            state.unlock(); try await wait("unlock", until: { state.status == "Unlocked" })
            state.seedVault(1000); try await wait("seed_1000", until: { state.status == "VaultSeeded-1000" })
            try await measure("vault-1000", open: { state.openVaultViewer(caseLabel: "vault-1000") })
            state.seedVault(9000, offset: 1000); try await wait("seed_10000", timeout: 120, until: { state.status == "VaultSeeded-10000" })
            try await measure("vault-10000", open: { state.openVaultViewer(caseLabel: "vault-10000") })
            state.seedPhotos(); try await wait("seed_photos", timeout: 120, until: { state.status == "PhotosSeeded-1000" })
            try await measurePhotos()
            write(passed: true, failedStep: "")
        } catch { write(passed: false, failedStep: (error as NSError).userInfo["step"] as? String ?? "system") }
    }
    /// Measures navigation and Move at one vault size, separating handoff from frame latency.
    private func measure(_ label: String, open: () -> Void) async throws {
        readySessions.removeAll(); open()
        try await wait("open_"+label, until: { state.status == "ViewerOpen-"+label })
        guard let id = state.vaultSessionIDs.first else { throw NSError(domain:"CoreContractGenerated",code:2,userInfo:["step":"no_session"]) }
        try await wait("render_"+label, until: { readySessions.contains(id) })
        guard let session = state.store.session(id), let next = session.nextItem else { throw NSError(domain:"CoreContractGenerated",code:3,userInfo:["step":"no_next"]) }
        let key = next.cacheKey
        let deadline = ContinuousClock.now + .seconds(20)
        while !CoreTrace.shared.hasRetained(session:id,key:key) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let warmed = CoreTrace.shared.hasRetained(session:id,key:key)
        let started = CACurrentMediaTime()
        let probe = DeleteFrameProbe.shared; probe.arm(label+"-navigation");probe.beginIfArmed()
        state.store.next(id)
        let nextFrameEnd = CACurrentMediaTime()
        try await wait("navigation_"+label, timeout: 30, until: { (CoreTrace.shared.finishes[key]?.0 ?? 0) >= started })
        probe.finish()
        try await wait("frame_"+label, until: { probe.result.hasPrefix(label+"-navigation=") })
        let start = CoreTrace.shared.starts[key]
        let finish = CoreTrace.shared.finishes[key]
        rows.append(["case":label+"-next", "warmed_before_navigation":warmed, "load_mode":start?.1 ?? "unknown", "ui_call_ms":(nextFrameEnd-started)*1000,
                     "media_ready_ms":((finish?.0 ?? started)-started)*1000, "media_success":finish?.1 ?? false, "frame":probe.result,
                     "action_to_load_ms":((CoreTrace.shared.entries[key] ?? started)-started)*1000,
                     "load_to_task_ms":((CoreTrace.shared.taskStarts[key] ?? started)-(CoreTrace.shared.entries[key] ?? started))*1000,
                     "cancel_current_ms":(CoreTrace.shared.cancelDurations[key] ?? 0)*1000,
                     "set_entity_ms":(CoreTrace.shared.entityDurations[key] ?? 0)*1000,
                     "model_to_first_frame_ms":((probe.proofFirstFrame ?? started)-(finish?.0 ?? started))*1000])
        guard let current = session.currentItem?.vaultRecord else { throw NSError(domain:"CoreContractGenerated",code:4,userInfo:["step":"no_vault_current"]) }
        let destination = GalleryVaultAlbum(id:"vault-album:core-contract-destination", title:"Generated Destination",position:nil)
        let source = session.sourceAlbumID
        let oldID = session.currentItem?.localIdentifier
        probe.arm(label+"-move");probe.beginIfArmed()
        let actionStarted = CACurrentMediaTime()
        let task = Task { try await state.vault.move(recordID: current.id, from: source, to: destination) }
        let afterSubmit = CACurrentMediaTime()
        let advancedImmediately = session.currentItem?.localIdentifier != oldID
        var failure = false
        do { try await task.value } catch { failure = true }
        probe.finish()
        try await wait("move_frame_"+label, until: { probe.result.hasPrefix(label+"-move=") })
        let followingKey = session.currentItem?.cacheKey ?? ""
        let nextLoad = CoreTrace.shared.entries[followingKey] ?? 0
        let nextReady = CoreTrace.shared.finishes[followingKey]?.0 ?? 0
        rows.append(["case":label+"-vault-move", "enqueue_ms":(afterSubmit-actionStarted)*1000,
                     "advanced_immediately":advancedImmediately, "failed":failure,"frame":probe.result,
                     "successor_load_mode":CoreTrace.shared.starts[followingKey]?.1 ?? "unknown",
                     "action_to_next_load_ms":nextLoad >= actionStarted ? (nextLoad-actionStarted)*1000 : -1,
                     "next_load_to_ready_ms":nextReady >= nextLoad && nextLoad > 0 ? (nextReady-nextLoad)*1000 : -1])
        NotificationCenter.default.post(name: Notification.Name("measurement-close-viewers"), object:nil)
        try await Task.sleep(for:.milliseconds(300))
    }
    /// Measures the same warm-navigation path for generated PhotoKit assets.
    private func measurePhotos() async throws {
        readySessions.removeAll(); state.openPhotosViewer()
        try await wait("open_photos", until: { state.status == "ViewerOpen-photos-1000" })
        guard let id = state.photoSessionID else { throw NSError(domain:"CoreContractGenerated",code:5,userInfo:["step":"no_photo_session"]) }
        try await wait("render_photos", until: { readySessions.contains(id) })
        guard let session = state.store.session(id), let next = session.nextItem else { throw NSError(domain:"CoreContractGenerated",code:6,userInfo:["step":"no_photo_next"]) }
        let key = next.cacheKey
        let deadline = ContinuousClock.now + .seconds(20)
        while !CoreTrace.shared.hasRetained(session:id,key:key) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let warmed = CoreTrace.shared.hasRetained(session:id,key:key)
        let started = CACurrentMediaTime()
        let probe = DeleteFrameProbe.shared; probe.arm("photos-1000-navigation");probe.beginIfArmed()
        state.store.next(id)
        let returned = CACurrentMediaTime()
        try await wait("navigation_photos", timeout: 30, until: { (CoreTrace.shared.finishes[key]?.0 ?? 0) >= started })
        probe.finish()
        try await wait("frame_photos", until: { probe.result.hasPrefix("photos-1000-navigation=") })
        let start = CoreTrace.shared.starts[key], finish = CoreTrace.shared.finishes[key]
        rows.append(["case":"photos-1000-next", "warmed_before_navigation":warmed, "load_mode":start?.1 ?? "unknown",
                     "ui_call_ms":(returned-started)*1000, "media_ready_ms":((finish?.0 ?? started)-started)*1000,
                     "media_success":finish?.1 ?? false, "frame":probe.result,
                     "action_to_load_ms":((CoreTrace.shared.entries[key] ?? started)-started)*1000,
                     "load_to_task_ms":((CoreTrace.shared.taskStarts[key] ?? started)-(CoreTrace.shared.entries[key] ?? started))*1000,
                     "cancel_current_ms":(CoreTrace.shared.cancelDurations[key] ?? 0)*1000,
                     "set_entity_ms":(CoreTrace.shared.entityDurations[key] ?? 0)*1000,
                     "model_to_first_frame_ms":((probe.proofFirstFrame ?? started)-(finish?.0 ?? started))*1000])
        flushPartial()
        // GENERATED_TRANSFER_PROOF
        NotificationCenter.default.post(name: Notification.Name("measurement-close-viewers"), object:nil)
    }
    /// Checks generated video preparation and lock cleanup so plaintext leases do not survive lock.
    private func measureVaultVideo() async throws {
        guard let url = Bundle.main.url(forResource: "generated-contract-video", withExtension: "mp4") else {
            throw NSError(domain:"CoreContractGenerated",code:7,userInfo:["step":"video_fixture_missing"])
        }
        let video = try state.storage.proofSeedGeneratedVideo(Data(contentsOf:url))
        state.vault.proofPublishGeneratedRecords()
        let item = GalleryMediaItem.vault(video), key = item.cacheKey
        let media = GalleryViewerMedia()
        media.prefetch(items:[item])
        try await wait("vault_video_prefetch", timeout:30, until:{ CoreTrace.shared.prefetched.contains(key) })
        let started = CACurrentMediaTime()
        await media.load(item:item, spatialEnabled:true)
        try await wait("vault_video_player_ready", timeout:30, until:{ media.player?.currentItem?.status == .readyToPlay })
        let loadedMS = (CACurrentMediaTime() - started) * 1000
        let mode = CoreTrace.shared.starts[key]?.1 ?? "unknown"
        let leasesBefore = try state.storage.proofPlaintextLeaseCount()
        guard leasesBefore > 0 else { throw NSError(domain:"CoreContractGenerated",code:8,userInfo:["step":"video_lease_missing"]) }
        state.vault.lock()
        try await wait("vault_video_lease_cleanup", timeout:15, until:{ ((try? state.storage.proofPlaintextLeaseCount()) ?? -1) == 0 })
        guard media.player == nil else { throw NSError(domain:"CoreContractGenerated",code:9,userInfo:["step":"video_player_survived_lock"]) }
        rows.append(["case":"vault-video-prefetch-lock", "load_mode":mode,"player_ready_ms":loadedMS,
                     "plaintext_leases_before_lock":leasesBefore,"player_cleared_on_lock":media.player == nil,
                     "remaining_plaintext_leases":try state.storage.proofPlaintextLeaseCount()])
        state.unlock(); try await wait("unlock_for_mid_prefetch_lock",until:{ state.status == "Unlocked" })
        guard let same = state.vault.records.first(where:{ $0.id == video.id }) else { throw NSError(domain:"CoreContractGenerated",code:10,userInfo:["step":"video_record_after_unlock"]) }
        CoreTrace.shared.delayVaultVideo = true
        CoreTrace.shared.delayedVaultVideoStarted = false
        CoreTrace.shared.prefetched.remove(key)
        let pendingMedia = GalleryViewerMedia()
        pendingMedia.prefetch(items:[.vault(same)])
        try await wait("video_work_started",until:{ CoreTrace.shared.delayedVaultVideoStarted })
        state.vault.lock()
        try await Task.sleep(for:.milliseconds(1200))
        let leasesAfter = try state.storage.proofPlaintextLeaseCount()
        guard leasesAfter == 0 else { throw NSError(domain:"CoreContractGenerated",code:11,userInfo:["step":"mid_prefetch_plaintext_retained"]) }
        rows.append(["case":"vault-video-lock-during-prefetch","delay_injected":true,"remaining_plaintext_leases":leasesAfter])
    }
    private func flushPartial() {
        if let data = try? JSONSerialization.data(withJSONObject:["rows":rows],options:[.prettyPrinted,.sortedKeys]) {
            try? data.write(to:state.documents.appendingPathComponent("auto-partial.json"),options:.atomic)
        }
    }
    private func write(passed: Bool, failedStep: String) {
        let data: [String:Any] = ["kind":Self.kind,"passed":passed,"failed_step":failedStep,"rows":rows,
                                  "authentication":"synthetic fixture key", "input":"production viewer plus generated media and programmatic actions"]
        if let json = try? JSONSerialization.data(withJSONObject:data,options:[.sortedKeys,.prettyPrinted]) {
            try? json.write(to:state.documents.appendingPathComponent("auto-result.json"),options:.atomic)
        }
        progress(passed ? "partial_or_passed" : "failed")
    }
}
