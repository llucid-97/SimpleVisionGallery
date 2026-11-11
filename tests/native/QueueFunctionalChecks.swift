// Target audience: agents. Generated data only; exercises production queues and real PhotoKit.
import Foundation
import SwiftUI
import Combine
import Photos
import CryptoKit

private enum QueueProofFailure: Error { case check(String) }
private func requireQueueProof(_ value: Bool, _ step: String) throws {
    if !value { throw QueueProofFailure.check(step) }
}

@MainActor final class QueueFunctionalChecks: ObservableObject {
    static let shared = QueueFunctionalChecks()
    @Published var status = "NotStarted"
    private let state = MeasurementState.shared
    private let queue = GalleryDeleteQueue.shared
    private var sessions: [UUID] = []
    private var lockTargets: [UUID] = []
    private var binnedBeforeLock = Set<UUID>()
    private var report: [String: Any] = [:]

    private func writeReport() {
        let url = state.documents.appendingPathComponent("queue-functional-report.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
        }
    }
    private func check(_ value: Bool, _ step: String) throws {
        try requireQueueProof(value, step)
        report[step] = true
        writeReport()
    }
    private func photosIDs(_ fetch: PHFetchResult<PHAsset>) -> Set<String> {
        Set((0..<fetch.count).map { fetch.object(at: $0).localIdentifier })
    }
    private func binPhotosIDs() -> Set<String> {
        guard let bin = GalleryRecycleBin.existingCollection() else { return [] }
        return photosIDs(PHAsset.fetchAssets(in: bin, options: nil))
    }
    private func records() -> [UUID: GalleryVaultRecord] {
        Dictionary(uniqueKeysWithValues: state.vault.records.map { ($0.id, $0) })
    }
    private func waitForQueue() async throws {
        let limit = ContinuousClock.now + .seconds(30)
        while queue.pendingCount > 0 && ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(queue.pendingCount == 0, "queue_drained")
    }
    private func failed(_ error: Error) {
        if case QueueProofFailure.check(let step) = error { status = "Failed-" + step }
        else { status = "Failed-system-code-\((error as NSError).code)" }
        report["status"] = status
        writeReport()
    }

    func prepareWindows() {
        status = "PreparingWindows"
        Task {
            do {
                await state.manager.openLibrarySection(.photos)
                let seedDeadline = ContinuousClock.now + .seconds(30)
                while ContinuousClock.now < seedDeadline {
                    if let snapshot = state.manager.viewerSnapshot(),
                       state.seededPhotoIDs.isSubset(of: photosIDs(snapshot.fetch)) { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard let initial = state.manager.viewerSnapshot(),
                      state.seededPhotoIDs.isSubset(of: photosIDs(initial.fetch)) else {
                    throw QueueProofFailure.check("seeded_photos_visible_before_viewer")
                }
                guard let first = state.store.createSession(from: state.manager, at: 0),
                      let second = state.store.duplicateSession(first) else {
                    throw QueueProofFailure.check("sessions_created")
                }
                sessions = [first, second]
                if let next=state.store.session(first)?.nextItem { CoreTrace.shared.delayedImageKey=next.cacheKey }
                for id in sessions {
                    let value = GalleryViewerWindows.shared.makeWindow(sessionIDs: [id])
                    NotificationCenter.default.post(name: Notification.Name("measurement-open-viewer"), object: value)
                }
                status = "WindowsReady"
            } catch { failed(error) }
        }
    }

    func run() {
        status = "RunningMixed20"
        Task {
            do {
                guard sessions.count == 2, let first = state.store.session(sessions[0]),
                      let second = state.store.session(sessions[1]) else {
                    throw QueueProofFailure.check("sessions_live")
                }
                let windowsDeadline = ContinuousClock.now + .seconds(10)
                while state.store.session(sessions[0]) != nil,
                      GalleryViewerWindows.shared.proofAttachedCount(for: Set(sessions)) != 2,
                      ContinuousClock.now < windowsDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                try check(GalleryViewerWindows.shared.proofAttachedCount(for: Set(sessions)) == 2,
                    "two_native_window_scenes_attached")
                guard let sharedNext=first.nextItem, second.nextItem?.cacheKey == sharedNext.cacheKey else {
                    throw QueueProofFailure.check("two_windows_same_next")
                }
                let sharedKey=sharedNext.cacheKey
                let inflightDeadline=ContinuousClock.now + .seconds(15)
                while !CoreTrace.shared.delayedImageStarted && ContinuousClock.now < inflightDeadline {
                    try await Task.sleep(for:.milliseconds(10))
                }
                try check(CoreTrace.shared.delayedImageStarted,"two_windows_prefetch_in_flight")
                CoreTrace.shared.finishedOwners[sharedKey]=[]
                state.store.next(first.id);state.store.next(second.id)
                let readyDeadline=ContinuousClock.now + .seconds(20)
                while (CoreTrace.shared.finishedOwners[sharedKey]?.count ?? 0) < 2 && ContinuousClock.now < readyDeadline {
                    try await Task.sleep(for:.milliseconds(10))
                }
                try check((CoreTrace.shared.finishedOwners[sharedKey]?.count ?? 0) == 2 &&
                    first.currentItem?.cacheKey == sharedKey && second.currentItem?.cacheKey == sharedKey,
                    "two_windows_same_inflight_result")
                CoreTrace.shared.delayedImageKey=nil
                state.store.previous(first.id);state.store.previous(second.id)
                state.store.shuffle(second.id)
                let initialGrid = state.manager.totalAssetCount
                let initialSession = first.count
                let settleDeadline = ContinuousClock.now + .seconds(5)
                while state.manager.totalAssetCount != first.count && ContinuousClock.now < settleDeadline {
                    try await Task.sleep(for:.milliseconds(20))
                }
                if let sessionSnapshot=state.store.proofSnapshotForSession(first.id),
                   let managerSnapshot=state.manager.viewerSnapshot() {
                    let sessionIDs = photosIDs(sessionSnapshot.fetch)
                    let managerIDs = photosIDs(managerSnapshot.fetch)
                    let onlyManager = managerIDs.subtracting(sessionIDs)
                    report["manager_only_count"] = onlyManager.count
                    report["manager_only_equals_new_seed"] = onlyManager == state.seededPhotoIDs
                    report["manager_seeded_overlap"] = onlyManager.intersection(state.seededPhotoIDs).count
                    report["session_only_count"] = sessionIDs.subtracting(managerIDs).count

                    report["session_native_on_attach"] = sessionSnapshot.nativeCount
                    report["session_vault_on_attach"] = sessionSnapshot.vaultRecords.count
                    report["manager_native_on_attach"] = managerSnapshot.nativeCount
                    report["manager_vault_on_attach"] = managerSnapshot.vaultRecords.count
                    report["snapshot_ids_equal"] = sessionSnapshot.id == managerSnapshot.id
                }
                report["grid_on_attach"] = initialGrid
                report["session_on_attach"] = initialSession
                report["grid_after_settle"] = state.manager.totalAssetCount
                report["session_after_settle"] = first.count
                if let freshSnapshot = state.manager.viewerSnapshot() {
                    report["fresh_snapshot_count"] = freshSnapshot.count
                    report["fresh_snapshot_native_count"] = freshSnapshot.nativeCount
                    report["fresh_snapshot_vault_count"] = freshSnapshot.vaultRecords.count
                }
                writeReport()
                let before = records()
                let bytes = try state.storage.proofResourceHashes()
                let allPhotos = photosIDs(PHAsset.fetchAssets(with: nil))
                let binBefore = binPhotosIDs()
                let countBefore = first.count
                report["session_before"] = countBefore
                report["grid_before"] = state.manager.totalAssetCount
                report["grid_is_photos_scope"] = state.manager.selectedAlbum?.virtualScope == .photos
                report["vault_before_count"] = state.vault.records.count
                writeReport()
                let vaultTargets = state.vault.records.filter {
                    $0.state == .privateItem && !GalleryVaultRecycleBin.contains($0) && !$0.resources.isEmpty
                }.prefix(10).map(\.id)
                try check(vaultTargets.count == 10, "ten_real_vault_targets")
                var photoTargets: [String] = []
                let shuffledNext = second.nextItem?.localIdentifier
                for (offset, vaultID) in vaultTargets.enumerated() {
                    guard let item = first.currentItem, let asset = item.photosAsset else {
                        throw QueueProofFailure.check("photo_target_visible")
                    }
                    photoTargets.append(asset.localIdentifier)
                    queue.enqueueRecycle(item: item, sourceAlbumID: nil, sessionID: first.id)
                    if offset == 0 {
                        try check(second.currentItem?.localIdentifier == shuffledNext,
                            "shuffled_successor_preserved")
                    }
                    queue.enqueueVaultRecycle(recordID: vaultID)
                }
                try check(queue.pendingCount == 20, "twenty_pending_no_drops")
                try check(first.count == countBefore - 20 && second.count == countBefore - 20,
                    "both_sessions_hide_twenty_pending")
                report["session_after_staging"] = first.count
                report["grid_after_staging"] = state.manager.totalAssetCount
                report["pending_photos_count"] = queue.pendingRequests.filter { !$0.isVault }.count
                report["pending_vault_count"] = queue.pendingVaultIDs.count
                writeReport()
                try check(state.manager.totalAssetCount == countBefore - 20,
                    "grid_hides_twenty_pending")
                let pending = Set(photoTargets + vaultTargets.map { "vault:\($0.uuidString)" })
                try check(!pending.contains(first.currentItem?.localIdentifier ?? "")
                    && !pending.contains(second.currentItem?.localIdentifier ?? ""), "both_cursors_advance")
                var shuffledSeen = Set<String>()
                for _ in 0..<40 {
                    guard let item = second.currentItem else { throw QueueProofFailure.check("shuffle_rank_live") }
                    try check(shuffledSeen.insert(item.localIdentifier).inserted, "shuffle_no_repeat")
                    if second.canGoNext { state.store.next(second.id) } else { break }
                }
                await Task.yield()
                try await waitForQueue()
                let after = records()
                let changed = Set(before.keys.filter { before[$0] != after[$0] })
                try check(changed == Set(vaultTargets) && Set(before.keys) == Set(after.keys),
                    "exact_ten_vault_records_changed")
                try check(vaultTargets.allSatisfy { after[$0].map(GalleryVaultRecycleBin.contains) == true },
                    "vault_targets_binned")
                try check(photosIDs(PHAsset.fetchAssets(with: nil)) == allPhotos, "photos_library_ids_unchanged")
                try check(binPhotosIDs().subtracting(binBefore) == Set(photoTargets), "exact_ten_photos_binned")
                try check(try state.storage.proofResourceHashes() == bytes, "encrypted_resource_bytes_unchanged")
                report["mixed_targets"] = photoTargets + vaultTargets.map { "vault:\($0.uuidString)" }
                report["vault_ids_before"] = before.keys.map(\.uuidString).sorted()
                report["vault_ids_after"] = after.keys.map(\.uuidString).sorted()
                report["photos_ids_before"] = allPhotos.sorted()
                report["photos_ids_after"] = photosIDs(PHAsset.fetchAssets(with: nil)).sorted()
                writeReport()

                // Real review plan contains both stores; leaving it unconfirmed changes nothing.
                await state.manager.openLibrarySection(.recycleBin)
                let reviewDeadline = ContinuousClock.now + .seconds(10)
                while state.manager.totalAssetCount < vaultTargets.count && ContinuousClock.now < reviewDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard let entire = await state.manager.prepareEntireRecycleBinDeletionReview() else {
                    throw QueueProofFailure.check("entire_bin_review_created")
                }
                try check(Set(entire.vaultCandidates.map(\.id)).isSuperset(of: Set(vaultTargets)) &&
                    Set(entire.localIdentifiers).isSuperset(of: Set(photoTargets)), "entire_bin_freezes_both_stores")
                let canceledRecords = records(), canceledPhotos = photosIDs(PHAsset.fetchAssets(with: nil))
                try await Task.sleep(for: .milliseconds(50))
                try check(records() == canceledRecords && photosIDs(PHAsset.fetchAssets(with: nil)) == canceledPhotos,
                    "cancelled_review_changes_nothing")
                state.manager.clearSelection(silent:true)
                guard let chosenIndex=(0..<state.manager.totalAssetCount).first(where:{ state.manager.mediaItem(at:$0)?.vaultRecord?.id == vaultTargets[0] }) else {
                    throw QueueProofFailure.check("vault_bin_item_in_grid")
                }
                state.manager.handleShortTap(index:chosenIndex)
                guard let frozen=state.manager.prepareDeletionReview(), frozen.vaultCandidates.map(\.id) == [vaultTargets[0]], frozen.candidates.isEmpty else {
                    throw QueueProofFailure.check("single_vault_review")
                }
                guard let newlyBinned=state.vault.records.first(where:{ $0.state == .privateItem && !GalleryVaultRecycleBin.contains($0) })?.id else {
                    throw QueueProofFailure.check("extra_bin_target")
                }
                queue.enqueueVaultRecycle(recordID:newlyBinned)
                try await waitForQueue()
                let beforeConfirm=records()
                await state.manager.deleteSelectionFromLibrary(review:frozen)
                try await waitForQueue()
                let afterConfirm=records()
                try check(Set(beforeConfirm.keys).subtracting(afterConfirm.keys) == Set([vaultTargets[0]]) &&
                    afterConfirm[newlyBinned].map(GalleryVaultRecycleBin.contains) == true &&
                    photosIDs(PHAsset.fetchAssets(with:nil)) == allPhotos, "confirmed_vault_review_removes_only_frozen_id")
                try await Task.sleep(for:.milliseconds(50))
                state.manager.clearSelection(silent:true)
                guard let lockIndex=(0..<state.manager.totalAssetCount).first(where:{state.manager.mediaItem(at:$0)?.vaultRecord?.id == newlyBinned}) else {
                    throw QueueProofFailure.check("extra_bin_item_visible")
                }
                state.manager.handleShortTap(index:lockIndex)
                guard let lockReview=state.manager.prepareDeletionReview() else { throw QueueProofFailure.check("lock_review_created") }
                state.vault.lock()
                await state.manager.deleteSelectionFromLibrary(review:lockReview)
                state.unlock()
                let unlockDeadline=ContinuousClock.now + .seconds(20)
                while state.status != "Unlocked" && ContinuousClock.now < unlockDeadline { try await Task.sleep(for:.milliseconds(20)) }
                try check(state.status == "Unlocked" && state.vault.records.contains(where:{$0.id == newlyBinned}), "locked_review_removes_nothing")
                // This fixture uses a uniquely named Photos bin. Remove only its own generated
                // assets from that album, leaving every Photos asset itself intact.
                guard let generatedBin = GalleryRecycleBin.existingCollection() else { throw QueueProofFailure.check("generated_bin_exists") }
                let binFetch=PHAsset.fetchAssets(in:generatedBin,options:nil)
                let ownBinIDs=photosIDs(binFetch)
                try check(ownBinIDs == Set(photoTargets), "generated_bin_contains_only_test_photos")
                let ownPhotos=PHAsset.fetchAssets(withLocalIdentifiers:photoTargets,options:nil)
                let ownAssets=(0..<ownPhotos.count).map { ownPhotos.object(at:$0) }
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCollectionChangeRequest(for:generatedBin)?.removeAssets(ownAssets as NSArray)
                }
                try check(binPhotosIDs().isEmpty && photosIDs(PHAsset.fetchAssets(with:nil)) == allPhotos,
                    "remove_generated_bin_membership_keeps_all_photos")
                await state.manager.openLibrarySection(.recycleBin)
                try await Task.sleep(for:.milliseconds(100))
                guard let vaultOnlyPlan=await state.manager.prepareEntireRecycleBinDeletionReview(), vaultOnlyPlan.candidates.isEmpty else {
                    throw QueueProofFailure.check("vault_only_entire_bin_plan")
                }
                let frozenIDs=Set(vaultOnlyPlan.vaultCandidates.map(\.id))
                try check(frozenIDs.contains(newlyBinned) && frozenIDs.count == vaultTargets.count, "vault_only_entire_bin_frozen_ids")
                guard let afterFreeze=state.vault.records.first(where:{ $0.state == .privateItem && !GalleryVaultRecycleBin.contains($0) })?.id else {
                    throw QueueProofFailure.check("post_freeze_vault_target")
                }
                queue.enqueueVaultRecycle(recordID:afterFreeze)
                try await waitForQueue()
                let beforeEntire=Set(records().keys)
                await state.manager.deleteSelectionFromLibrary(review:vaultOnlyPlan)
                try await waitForQueue()
                let afterEntire=records()
                try check(beforeEntire.subtracting(afterEntire.keys) == frozenIDs &&
                    afterEntire[afterFreeze].map(GalleryVaultRecycleBin.contains) == true &&
                    photosIDs(PHAsset.fetchAssets(with:nil)) == allPhotos,
                    "confirmed_entire_vault_bin_deletes_frozen_only")
                await state.manager.openLibrarySection(.photos)

                // Keep a second manager's frozen fetch while the real Photos transaction commits.
                do {
                    let freshManager = GalleryManager()
                    await freshManager.openLibrarySection(.photos)
                    freshManager.proofHoldPhotoRefresh(true)
                    defer { freshManager.proofHoldPhotoRefresh(false) }
                    guard let item = first.currentItem, let raceAsset = item.photosAsset else {
                        throw QueueProofFailure.check("fresh_viewer_photo_target")
                    }
                    queue.enqueueRecycle(item: item, sourceAlbumID: nil, sessionID: first.id)
                    try await waitForQueue()
                    guard let stale = freshManager.viewerSnapshot() else {
                        throw QueueProofFailure.check("fresh_viewer_snapshot_ready")
                    }
                    try check(stale.fetch.index(of: raceAsset) != NSNotFound,
                        "fresh_viewer_test_fetch_is_stale")
                    guard let newID = state.store.createSession(from: freshManager, at: 0),
                          let fresh = state.store.session(newID) else {
                        throw QueueProofFailure.check("fresh_viewer_session_created")
                    }
                    let visible = Set(([fresh.currentItem].compactMap { $0 } + fresh.upcomingItems(limit: fresh.count))
                        .map(\.localIdentifier))
                    let grid = Set((0..<freshManager.totalAssetCount).compactMap { freshManager.mediaItem(at: $0)?.localIdentifier })
                    try check(!visible.contains(raceAsset.localIdentifier) && visible == grid,
                        "fresh_viewer_excludes_committed_photo_and_matches_grid")
                    state.store.disposeSession(newID)
                }

                status = "RunningFailure"
                let failureTargets = state.vault.records.filter {
                    $0.state == .privateItem && !GalleryVaultRecycleBin.contains($0)
                }.prefix(10)
                let failedID = Array(failureTargets)[4].id
                let failureBefore = records()
                try state.storage.proofDamageRecord(failedID)
                for record in failureTargets { queue.enqueueVaultRecycle(recordID: record.id) }
                try await waitForQueue()
                let failureAfter = records()
                let expectedChanged = Set(failureTargets.map(\.id)).subtracting([failedID])
                try check(Set(failureBefore.keys.filter { failureBefore[$0] != failureAfter[$0] }) == expectedChanged,
                    "only_nine_healthy_items_commit")
                try check(failureAfter[failedID] == failureBefore[failedID] && queue.errorMessage != nil,
                    "failed_item_returns_with_error")
                try check(state.manager.vaultRecords(in: state.manager.selectedAlbum!).contains { $0.id == failedID },
                    "failed_item_visible_in_grid")
                try state.storage.update(failureBefore[failedID]!)
                state.vault.proofPublishGeneratedRecords()

                status = "RunningLock"
                lockTargets = state.vault.records.filter {
                    $0.state == .privateItem && !GalleryVaultRecycleBin.contains($0)
                }.prefix(20).map(\.id)
                try check(lockTargets.count == 20, "twenty_lock_targets")
                binnedBeforeLock = Set(state.vault.records.filter(GalleryVaultRecycleBin.contains).map(\.id))
                for id in lockTargets { queue.enqueueVaultRecycle(recordID: id) }
                let deadline = ContinuousClock.now + .seconds(5)
                while !state.vault.isBusy && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(1))
                }
                try check(state.vault.isBusy, "lock_during_active_batch")
                try await Task.sleep(for: .milliseconds(30))
                state.vault.lock()
                try check(state.vault.records.isEmpty && state.storage.records.isEmpty,
                    "lock_clears_published_records")
                try check(queue.pendingVaultIDs.isEmpty, "lock_cancels_unprocessed_requests")
                let settled = ContinuousClock.now + .seconds(5)
                while state.vault.isBusy && ContinuousClock.now < settled {
                    try await Task.sleep(for: .milliseconds(10))
                }
                try check(!state.vault.isBusy, "locked_worker_finishes")
                status = "LockedReadyForUnlock"
            } catch { failed(error) }
        }
    }

    func verifyAfterUnlock() {
        do {
            let newlyBinned = Set(state.vault.records.filter(GalleryVaultRecycleBin.contains).map(\.id))
                .subtracting(binnedBeforeLock)
            try check(newlyBinned == Set(lockTargets.prefix(1)), "lock_commits_only_complete_prefix")
            let unprocessed = Set(lockTargets.dropFirst())
            try check(state.vault.records.filter { unprocessed.contains($0.id) }
                .allSatisfy { !GalleryVaultRecycleBin.contains($0) }, "unprocessed_items_remain")
            report["lock_committed_count"] = newlyBinned.count
            report["lock_remaining_count"] = unprocessed.count
            report["status"] = "Passed"
            writeReport()
            status = "Passed"
        } catch { failed(error) }
    }
}
