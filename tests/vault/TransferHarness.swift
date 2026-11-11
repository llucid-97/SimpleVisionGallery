import Foundation
import CoreLocation

@main struct Test {
    @MainActor static func start(_ names: [String]) async throws -> [PHAsset] {
        let service = GalleryVaultService.shared
        service.lock()
        GalleryVaultStorage.shared.reset()
        FakePhotos.reset()
        let items = names.map { PHAsset($0, bytes: Data("bytes-\($0)".utf8), parents: ["album", "other"]) }
        for item in items { FakePhotos.assets[item.localIdentifier] = item }
        try await service.unlock()
        return items
    }
    @MainActor static func waitFor(_ id: String) async throws {
        for _ in 0..<100 {
            if FakePhotos.hasStarted(id) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Timed out waiting for resource \(id)")
    }
    @MainActor static func main() async throws {
        let service = GalleryVaultService.shared
        do {
            let items = try await start(["queued"])
            var waits: [Bool] = []
            var beganAfterCopy = false
            let result = try await service.moveQueuedToVault(asset: items[0], destination: nil, sourceAlbumID: "album", epoch: service.authEpoch) { waiting in
                waits.append(waiting)
                if waiting { beganAfterCopy = !GalleryVaultStorage.shared.durable.isEmpty && FakePhotos.deleteCalls.isEmpty }
            }
            precondition(result.deleted == 1 && waits == [true, false, false] && beganAfterCopy,
                "watchdog must start after encrypted copy and bracket the Photos delete")
            precondition(Set(service.records.first!.albums.map(\.id)) == Set(["album", "other"]),
                "no-destination move must keep all source memberships")
            print("PASS queued transfer preserves parent albums and brackets Photos wait")
        }
        do {
            let items = try await start(["reject"])
            FakePhotos.failDelete = true
            var waits: [Bool] = []
            let result = try await service.moveQueuedToVault(asset: items[0], destination: nil, sourceAlbumID: nil, epoch: service.authEpoch) { waits.append($0) }
            precondition(result.deleted == 0 && FakePhotos.assets["reject"] != nil && waits == [true, false, false],
                "Photos failure must clear the watchdog and keep the original")
            print("PASS queued transfer clears watchdog on Photos rejection")
        }
        do {
            let items = try await start(["a", "b", "c", "d"])
            FakePhotos.failCopyID = "c"
            let result = try await service.moveToVault(assets: items)
            precondition(result.copied == 2 && result.deleted == 2 && result.message?.contains("Not enough device storage") == true)
            precondition(FakePhotos.deleteCalls == [["a", "b"]])
            precondition(FakePhotos.assets["a"] == nil && FakePhotos.assets["b"] == nil && FakePhotos.assets["c"] != nil && FakePhotos.assets["d"] != nil)
            precondition(Set(service.records.map(\.sourceIdentifier)) == Set(["a", "b"]))
            print("PASS space failure commits only copied prefix in one delete")
        }
        do {
            let items = try await start(["a", "b", "c"])
            GalleryVaultStorage.shared.failCommitSource = "b"
            let result = try await service.moveToVault(assets: items)
            precondition(result.copied == 1 && result.deleted == 1 && result.message != nil)
            precondition(FakePhotos.deleteCalls == [["a"]] && FakePhotos.assets["b"] != nil && FakePhotos.assets["c"] != nil)
            print("PASS failed journal commit never deletes its original")
        }
        do {
            service.lock()
            let storage = GalleryVaultStorage.shared
            storage.reset()
            FakePhotos.reset()
            storage.lockAtUnlockReturn = true
            do { try await service.unlock(); fatalError("unlock published after storage return race") } catch {}
            precondition(!service.isUnlocked && !storage.isUnlocked && service.records.isEmpty && service.error == nil)
            print("PASS lock at storage return prevents unlock publication")
        }
        do {
            service.lock()
            let storage = GalleryVaultStorage.shared
            storage.reset()
            FakePhotos.reset()
            let item = PHAsset("missing")
            let staged = try GalleryVaultPhotoLibrary.prepare(item, sourceAlbumID: nil, sourcePosition: nil).record
            storage.durable[staged.id] = staged
            storage.lockAtEndBatch = true
            do { try await service.unlock(); fatalError("unlock published after reconcile race") } catch {}
            precondition(!service.isUnlocked && !storage.isUnlocked && service.records.isEmpty && service.error == nil)
            print("PASS lock at reconcile return prevents records publication")
        }
        do {
            let items = try await start(["a"])
            FakePhotos.delayedID = "a"
            let task = Task { try await service.moveToVault(assets: items) }
            try await waitFor("a")
            items[0].modificationDate = Date(timeIntervalSince1970: 222222)
            let result = try await task.value
            precondition(result.copied == 1 && result.deleted == 0 && result.message != nil)
            precondition(FakePhotos.deleteCalls.isEmpty && FakePhotos.assets["a"] != nil)
            precondition(service.records.first?.state == .copiedAwaitingDeletion)
            print("PASS edited source is not deleted")
        }
        do {
            let items = try await start(["a"])
            FakePhotos.delayedID = "a"
            let task = Task { try await service.moveToVault(assets: items) }
            try await waitFor("a")
            items[0].isFavorite = true
            let result = try await task.value
            precondition(result.copied == 1 && result.deleted == 0 && FakePhotos.assets["a"] != nil)
            let pendingID = service.records[0].id
            try await service.discardPendingCopies(recordIDs: [pendingID])
            precondition(service.records.isEmpty && FakePhotos.assets["a"] != nil)
            FakePhotos.delayedID = nil
            let fresh = try await service.moveToVault(assets: items)
            precondition(fresh.deleted == 1 && FakePhotos.assets["a"] == nil)
            print("PASS favorite change preserves original; explicit discard permits fresh copy")
        }
        do {
            let items = try await start(["a"])
            FakePhotos.delayedID = "a"
            let task = Task { try await service.moveToVault(assets: items) }
            try await waitFor("a")
            items[0].location = CLLocation(latitude: 51.5, longitude: -0.1)
            let result = try await task.value
            precondition(result.copied == 1 && result.deleted == 0 && FakePhotos.assets["a"] != nil)
            print("PASS location change with unchanged modification date preserves original")
        }
        do {
            let items = try await start(["a"])
            FakePhotos.failDelete = true
            _ = try await service.moveToVault(assets: items)
            let id = service.records[0].id
            FakePhotos.assets.removeValue(forKey: "a")
            do { try await service.discardPendingCopies(recordIDs: [id]); fatalError("discarded only copy") } catch {}
            precondition(GalleryVaultStorage.shared.record(id: id) != nil)
            print("PASS discard refuses missing Photos original")
        }
        do {
            let items = try await start(["a"])
            _ = try await service.moveToVault(assets: items)
            let id = service.records[0].id
            FakePhotos.unavailableParents = ["other"]
            do { try await service.restore(recordID: id); fatalError("missing parent restored without explicit fallback") } catch {}
            precondition(GalleryVaultStorage.shared.record(id: id) != nil && FakePhotos.assets.isEmpty)
            try await service.restore(recordID: id, omittingUnavailableAlbums: true)
            precondition(GalleryVaultStorage.shared.record(id: id) == nil && FakePhotos.assets.count == 1)
            let restored = FakePhotos.assets.values.first!
            precondition(restored.parents == ["album"] && restored.resources[0].bytes == Data("bytes-a".utf8))
            print("PASS non-editable album blocks default restore; explicit fallback keeps available parent and bytes")
        }
        do {
            let items = try await start(["a"])
            _ = try await service.moveToVault(assets: items)
            let id = service.records[0].id
            FakePhotos.missingParents = ["other"]
            try await service.restore(recordID: id)
            let createdAlbum = FakePhotos.albumTitles.first { $0.value == "other" }!.key
            precondition(GalleryVaultStorage.shared.record(id: id) == nil)
            precondition(Set(FakePhotos.assets.values.first!.parents) == Set(["album", createdAlbum]))
            print("PASS deleted album is recreated and verified by its new ID")
        }
        do {
            service.lock()
            let storage = GalleryVaultStorage.shared
            storage.reset()
            FakePhotos.reset()
            storage.unreadableRecordCount = 2
            try await service.unlock()
            precondition(service.unreadableRecordCount == 2)
            service.lock()
            precondition(service.unreadableRecordCount == 0)
            print("PASS unreadable count published only while unlocked")
        }
        do {
            service.lock()
            let storage = GalleryVaultStorage.shared
            storage.reset()
            FakePhotos.reset()
            let damagedAsset = PHAsset("gone")
            let damaged = try GalleryVaultPhotoLibrary.prepare(damagedAsset, sourceAlbumID: nil, sourcePosition: nil).record
            var healthy = try GalleryVaultPhotoLibrary.prepare(PHAsset("healthy"), sourceAlbumID: nil, sourcePosition: nil).record
            healthy.state = .privateItem
            storage.durable[damaged.id] = damaged
            storage.durable[healthy.id] = healthy
            storage.failVerifyIDs.insert(damaged.id)
            try await service.unlock()
            precondition(service.isUnlocked && service.unreadableRecordCount == 1)
            precondition(service.records.contains { $0.id == healthy.id && $0.state == .privateItem })
            precondition(storage.record(id: damaged.id)?.state == .copiedAwaitingDeletion)
            print("PASS damaged pending record is retained without blocking healthy unlock")
        }
        do {
            _ = try await start(["a"])
            let storage = GalleryVaultStorage.shared
            storage.simulatedCleanupFailure = true
            service.lock()
            precondition(!service.isUnlocked && service.records.isEmpty && service.error == "Private media cleanup failed.")
            storage.simulatedCleanupFailure = false
            service.lock()
            precondition(service.error == nil)
            print("PASS failed lock cleanup surfaces a warning without unlocking")
        }
        do {
            let items = try await start(["a", "b", "c"])
            FakePhotos.delayedID = "c"
            let task = Task { try await service.moveToVault(assets: items) }
            try await waitFor("c")
            service.cancel()
            let result = try await task.value
            precondition(result.copied == 2 && result.deleted == 2 && result.message != nil)
            precondition(FakePhotos.deleteCalls == [["a", "b"]] && FakePhotos.assets["c"] != nil)
            print("PASS cancel commits only copied prefix")
        }
        do {
            let items = try await start(["a", "b"])
            FakePhotos.failDelete = true
            let result = try await service.moveToVault(assets: items)
            precondition(result.copied == 2 && result.deleted == 0 && result.message != nil)
            precondition(FakePhotos.assets.count == 2 && service.records.allSatisfy { $0.state == .copiedAwaitingDeletion })
            FakePhotos.failDelete = false
            let retried = try await service.retryPendingDeletion()
            precondition(retried.deleted == 2 && FakePhotos.assets.isEmpty && FakePhotos.deleteCalls.count == 2)
            precondition(service.records.allSatisfy { $0.state == .privateItem })
            print("PASS delete failure preserves sources and retry")
        }
        do {
            let items = try await start(["a"])
            _ = try await service.moveToVault(assets: items)
            let id = service.records[0].id
            let observer = RestoreObserver()
            let token = NotificationCenter.default.addObserver(forName: .galleryVaultDidRestoreItem, object: nil, queue: nil) { note in
                MainActor.assumeIsolated {
                    guard let record = note.userInfo?["record"] as? GalleryVaultRecord,
                          let restoredID = note.userInfo?["restoredIdentifier"] as? String else { return }
                    observer.recordIDs.append(record.id)
                    observer.restoredIDs.append(restoredID)
                    observer.archiveWasPresent.append(GalleryVaultStorage.shared.record(id: record.id) != nil)
                }
            }
            defer { NotificationCenter.default.removeObserver(token) }
            try await service.restore(recordID: id)
            precondition(observer.recordIDs == [id] && observer.restoredIDs.count == 1 && observer.archiveWasPresent == [true])
            precondition(FakePhotos.assets[observer.restoredIDs[0]] != nil && GalleryVaultStorage.shared.record(id: id) == nil)
            print("PASS verified restore notifies listeners before archive removal")
        }
        do {
            let items = try await start(["a"])
            _ = try await service.moveToVault(assets: items)
            let id = service.records[0].id
            FakePhotos.failImport = true
            do { try await service.restore(recordID: id); fatalError("import unexpectedly succeeded") } catch {}
            let afterFailure = GalleryVaultStorage.shared.record(id: id)!
            precondition(afterFailure.state == .privateItem && afterFailure.restoredIdentifier == nil)
            FakePhotos.failImport = false
            try await service.restore(recordID: id)
            precondition(GalleryVaultStorage.shared.record(id: id) == nil && FakePhotos.assets.count == 1)
            let created = FakePhotos.assets.values.first!
            precondition(Set(created.parents) == Set(["album", "other"]) && created.resources[0].bytes == Data("bytes-a".utf8))
            print("PASS failed import can retry and preserves bytes and parent albums")
        }
        do {
            let items = try await start(["a"])
            _ = try await service.moveToVault(assets: items)
            let id = service.records[0].id
            FakePhotos.missingParents = ["other"]
            FakePhotos.cancelImportAfterCommit = true
            do { try await service.restore(recordID: id); fatalError("injected cancellation unexpectedly succeeded") } catch {}
            precondition(GalleryVaultStorage.shared.record(id: id)?.state == .restoring)
            precondition(FakePhotos.assets.count == 1 && FakePhotos.creationCalls == 1)
            let replacement = FakePhotos.albumTitles.first { $0.value == "other" }!.key
            precondition(GalleryVaultStorage.shared.record(id: id)!.albums.contains { $0.id == replacement })
            FakePhotos.cancelImportAfterCommit = false
            try await service.restore(recordID: id)
            precondition(GalleryVaultStorage.shared.record(id: id) == nil && FakePhotos.assets.count == 1 && FakePhotos.creationCalls == 1)
            precondition(FakePhotos.albumTitles.count == 1 && FakePhotos.assets.values.first!.parents.contains(replacement))
            print("PASS uncertain committed restore verifies recreated album without duplicate")
        }
        do {
            let items = try await start(["a"])
            _ = try await service.moveToVault(assets: items)
            let id = service.records[0].id
            FakePhotos.cancelImportBeforeCommit = true
            do { try await service.restore(recordID: id); fatalError("injected cancellation unexpectedly succeeded") } catch {}
            precondition(GalleryVaultStorage.shared.record(id: id)?.state == .restoring && FakePhotos.creationCalls == 1)
            FakePhotos.cancelImportBeforeCommit = false
            do { try await service.restore(recordID: id); fatalError("ambiguous restore retried creation") } catch {}
            precondition(GalleryVaultStorage.shared.record(id: id)?.state == .restoring && FakePhotos.assets.isEmpty && FakePhotos.creationCalls == 1)
            print("PASS uncertain missing restore never creates a duplicate")
        }
        do {
            service.lock()
            let storage = GalleryVaultStorage.shared
            storage.reset()
            FakePhotos.reset()
            storage.delayUnlock = true
            let task = Task { try await service.unlock() }
            for _ in 0..<100 {
                if storage.pendingUnlock != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard let continuation = storage.pendingUnlock else { fatalError("unlock did not start") }
            NotificationCenter.default.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
            continuation.resume()
            do { try await task.value; fatalError("late unlock succeeded") } catch {}
            precondition(!service.isUnlocked && !storage.isUnlocked && service.records.isEmpty && service.error == nil)
            print("PASS device lock invalidates pending unlock")
        }
        do {
            let items = try await start(["a"])
            FakePhotos.delayedID = "a"
            let task = Task { try await service.moveToVault(assets: items) }
            try await waitFor("a")
            service.lock()
            do { _ = try await task.value; fatalError("lock did not stop copy") } catch {}
            precondition(FakePhotos.deleteCalls.isEmpty && FakePhotos.assets["a"] != nil && !service.isUnlocked && service.records.isEmpty)
            try await Task.sleep(nanoseconds: 500_000_000)
            precondition(FakePhotos.deleteCalls.isEmpty && service.records.isEmpty)
            print("PASS lock fences late PhotoKit callback")
        }
    }
}

@MainActor final class RestoreObserver {
    var recordIDs: [UUID] = []
    var restoredIDs: [String] = []
    var archiveWasPresent: [Bool] = []
}
