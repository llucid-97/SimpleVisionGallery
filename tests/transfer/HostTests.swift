import Foundation
import CryptoKit

@main struct TransferStorageTests {
    @MainActor static func waitFor(_ step: String) async throws {
        for _ in 0..<200 {
            if TransferProbe.seen(step) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("background step did not start: \(step)")
    }
    @MainActor static func makeRecord() -> GalleryVaultRecord {
        let resource = GalleryVaultResource(id: UUID(), type: 1, filename: "fixture.bin", uniformTypeIdentifier: "public.data")
        return GalleryVaultRecord(id: UUID(), sourceIdentifier: "generated", filename: "fixture.bin",
            mediaType: 1, mediaSubtypes: 0, pixelWidth: 1, pixelHeight: 1, duration: 0,
            creationDate: nil, modificationDate: nil, latitude: nil, longitude: nil, isFavorite: false,
            albums: [GalleryVaultAlbum(id:"generated-album", title:"Generated", position:0)],
            resources: [resource], state: .copiedAwaitingDeletion, restoredIdentifier: nil)
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-transfer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try GalleryVaultStorage(testRoot: root, testKey: SymmetricKey(size: .bits256))
        let record = makeRecord()
        storage.beginBatch()
        let create = Task { try await storage.createItemForTransfer(id: record.id) }
        try await waitFor("create")
        let start = ContinuousClock.now
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(start.duration(to: .now) < .milliseconds(150), "main actor stalled during generated staging delay")
        let item = try await create.value
        let writer = try await Task.detached { try item.writer(resourceID: record.resources[0].id) }.value
        try writer.append(Data("generated resource bytes".utf8)); try writer.finish()
        let commit = Task { try await storage.commitTransfer(record, from: item, sourceAlbums: record.albums) }
        try await waitFor("commit")
        let commitStart = ContinuousClock.now
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(commitStart.duration(to: .now) < .milliseconds(150), "main actor stalled during generated commit delay")
        try await commit.value
        var changed = record; changed.state = .privateItem
        try await storage.updateTransfer(changed)
        let changedIDs = await storage.finishTransferBatch()
        precondition(changedIDs == [record.id], "wrong transfer publication IDs")
        precondition(storage.records == [changed], "transfer did not publish final record")
        let onDisk = try await storage.authoritativeRecords()
        precondition(onDisk == [changed], "encrypted record does not match published record")
        let resourceURL = try await storage.decryptResource(recordID: record.id, resourceID: record.resources[0].id)
        let actualResource = try Data(contentsOf: resourceURL)
        precondition(actualResource == Data("generated resource bytes".utf8))
        storage.releasePlaintext(resourceURL)
        for step in ["create", "commit", "update", "batch"] {
            precondition(TransferProbe.isMain(step) == false, "\(step) unexpectedly ran on the main thread")
        }
        print("PASS transfer create/commit/update/sort run off main; exact ID, encrypted record and resource verified")

        let failed = makeRecord()
        storage.beginBatch()
        let failingItem = try await storage.createItemForTransfer(id: failed.id)
        let failingWriter = try failingItem.writer(resourceID: failed.resources[0].id)
        try failingWriter.append(Data("other resource".utf8)); try failingWriter.finish()
        TransferProbe.setFailSync(true)
        do { try await storage.commitTransfer(failed, from: failingItem); fatalError("expected post-rename sync failure") } catch {}
        TransferProbe.setFailSync(false)
        precondition(storage.record(id: failed.id) == failed, "renamed pending record not indexed after sync failure")
        let failureIDs = await storage.finishTransferBatch()
        precondition(failureIDs == [failed.id], "pending failure record not published")
        let verified = try await storage.verifyCommitted(id: failed.id)
        precondition(verified == failed, "pending record cannot be verified for retry")
        print("PASS injected post-rename sync failure preserves an indexed, retry-verifiable copy")

        let cancelled = makeRecord()
        storage.beginBatch()
        let cancelledItem = try await storage.createItemForTransfer(id: cancelled.id)
        let cancelledWriter = try cancelledItem.writer(resourceID: cancelled.resources[0].id)
        try cancelledWriter.append(Data("uncommitted resource".utf8)); try cancelledWriter.finish()
        TransferProbe.reset("commit")
        let lateCommit = Task { try await storage.commitTransfer(cancelled, from: cancelledItem) }
        try await waitFor("commit")
        storage.lock()
        do { try await lateCommit.value; fatalError("commit succeeded after lock") } catch {}
        precondition(storage.records.isEmpty && storage.record(id: cancelled.id) == nil && !storage.isUnlocked)
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("items/\(cancelled.id.uuidString)").path), "lock allowed late commit")
        print("PASS lock before commit revokes detached work and clears visible records")
    }
}
