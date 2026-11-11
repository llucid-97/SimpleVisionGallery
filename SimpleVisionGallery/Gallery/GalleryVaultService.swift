#if os(visionOS)
import Combine
import CoreLocation
import CryptoKit
import Foundation
@preconcurrency import Photos
import UniformTypeIdentifiers
import UIKit

nonisolated struct GalleryVaultProgress: Equatable, Sendable {
    let phase: String
    let processed: Int
    let total: Int
    let detail: String?
}

nonisolated struct GalleryVaultTransferOutcome: Equatable, Sendable {
    let copied: Int
    let deleted: Int
    let message: String?
    var reused = 0
    var notMoved = 0
    var skipped: [GalleryVaultSkipReason: Int] = [:]
    var editsDiscarded = 0
}

nonisolated enum GalleryVaultSkipReason: String, CaseIterable, Hashable, Sendable {
    case unsupportedItem = "Photos cannot remove this media"
    case unsupportedResources = "Original cannot yet be restored safely"
    case unavailableResource = "Photos could not provide complete files"
    case damagedCopy = "Saved files could not be verified"
    case alreadySaved = "Already in the vault"
}

nonisolated enum GalleryVaultMutation: Sendable {
    case recycle(UUID)
    case putBack(UUID)
    case delete(UUID)
    case move(UUID, sourceAlbumID: String?, destination: GalleryVaultAlbum)

    var id: UUID {
        switch self {
        case .recycle(let id), .putBack(let id), .delete(let id), .move(let id, _, _): id
        }
    }
}

nonisolated enum GalleryVaultMutationWarning: LocalizedError {
    case directorySyncUnconfirmed, cleanupPending

    var errorDescription: String? {
        switch self {
        case .directorySyncUnconfirmed: "The vault change was saved, but its final directory sync was not confirmed."
        case .cleanupPending: "The item was deleted from the vault, but encrypted cleanup is still pending. Unlock again to retry cleanup."
        }
    }
}

nonisolated struct GalleryVaultMutationResult: Sendable {
    let id: UUID
    let error: (any Error)?
    let warning: (any Error)?

    init(id: UUID, error: (any Error)?, warning: (any Error)? = nil) {
        self.id = id
        self.error = error
        self.warning = warning
    }
}

/// The service owns a single operation and publishes only complete vault snapshots.
@MainActor
final class GalleryVaultService: ObservableObject {
    static let shared = GalleryVaultService()
    @Published private(set) var isUnlocked = false
    @Published private(set) var authEpoch = UUID()
    @Published private(set) var records: [GalleryVaultRecord] = []
    private(set) var isPublishingQueuedMutations = false
    private(set) var publishingMutationIDs = Set<UUID>()
    var publishingMutationRecords: [GalleryVaultRecord] {
        guard isUnlocked else { return [] }
        return publishingMutationIDs.compactMap { storage.record(id: $0) }
    }
    @Published private(set) var pendingAlbumDeletion: GalleryVaultAlbumDeletion?
    @Published private(set) var albumDeletionRecoveryError: String?
    @Published private(set) var albumDeletionRemainingCount = 0
    var needsAlbumDeletionReview: Bool { pendingAlbumDeletion != nil || albumDeletionRecoveryError != nil }
    @Published private(set) var unreadableRecordCount = 0
    @Published private(set) var isBusy = false
    @Published var isReviewingAlbumDeletion = false
    @Published private(set) var progress: GalleryVaultProgress?
    @Published private(set) var error: String?

    private let storage = GalleryVaultStorage.shared
    private var wantsCancel = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelPreparation: (() -> Void)?
    private var activeStream: GalleryVaultPhotoStream?
    private var protectedDataObserver: NSObjectProtocol?
    private init() {
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
    }

    func unlock() async throws {
        guard !isBusy else { throw GalleryVaultTransferError.busy }
        guard !isUnlocked else { return }
        isBusy = true
        error = nil
        let attemptEpoch = authEpoch
        var unlockedEpoch: UUID?
        defer { endOperation() }
        do {
            try await storage.unlock()
            guard authEpoch == attemptEpoch, storage.isUnlocked else { throw GalleryVaultTransferError.locked }
            let epoch = UUID()
            unlockedEpoch = epoch
            authEpoch = epoch
            isUnlocked = true
            // A deletion can commit just before the app terminates. Resolve it only
            // with full library access, and never delete an existing source here.
            recoverAlbumDeletion()
            let unreadablePending = !needsAlbumDeletionReview ? try await reconcilePendingAfterUnlock() : 0
            guard isCurrent(epoch), storage.isUnlocked else { throw GalleryVaultTransferError.locked }
            records = storage.records
            unreadableRecordCount = storage.unreadableRecordCount + unreadablePending
        } catch {
            let wasLockedDuringAttempt = authEpoch != (unlockedEpoch ?? attemptEpoch)
            records = []
            pendingAlbumDeletion = nil
            albumDeletionRecoveryError = nil
            albumDeletionRemainingCount = 0
            unreadableRecordCount = 0
            isUnlocked = false
            authEpoch = UUID()
            storage.lock()
            if let warning = storage.cleanupWarning { self.error = warning }
            else if !wasLockedDuringAttempt { self.error = error.localizedDescription }
            throw error
        }
    }

    func lock() {
        wantsCancel = true
        wakeOperationWaiters()
        activeStream?.cancel()
        cancelPreparation?()
        authEpoch = UUID()
        isUnlocked = false
        records = []
        pendingAlbumDeletion = nil
        albumDeletionRecoveryError = nil
        albumDeletionRemainingCount = 0
        isReviewingAlbumDeletion = false
        unreadableRecordCount = 0
        progress = nil
        error = nil
        storage.lock()
        error = storage.cleanupWarning
    }

    func albumDestinations() async -> [GalleryVaultAlbum] {
        let snapshot = records
        return await Task.detached(priority: .userInitiated) {
            var albums: [String: GalleryVaultAlbum] = [:]
            for record in snapshot where !GalleryVaultRecycleBin.contains(record) {
                for album in record.albums where !GalleryRecycleBin.isRecycleBinTitle(album.title) {
                    albums[album.id] = GalleryVaultAlbum(id: album.id, title: album.title, position: nil)
                }
            }
            return albums.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }.value
    }

    func cancel() {
        wantsCancel = true
        activeStream?.cancel()
        cancelPreparation?()
    }

    @discardableResult
    func moveToVault(fetch: PHFetchResult<PHAsset>, sourceAlbumID: String? = nil) async throws -> GalleryVaultTransferOutcome {
        try await move(count: fetch.count, sourceAlbumID: sourceAlbumID) { fetch.object(at: $0) }
    }

    @discardableResult
    func moveToVault(assets: [PHAsset], destination: GalleryVaultAlbum? = nil, sourceAlbumID: String? = nil) async throws -> GalleryVaultTransferOutcome {
        try await move(count: assets.count, sourceAlbumID: sourceAlbumID, destination: destination) { assets[$0] }
    }

    private func move(count: Int, sourceAlbumID: String?, destination: GalleryVaultAlbum? = nil, assetAt: (Int) -> PHAsset) async throws -> GalleryVaultTransferOutcome {
        if let destination { try validateDestination(destination) }
        try beginOperation()
        let epoch = authEpoch
        storage.beginBatch()
        defer { storage.endBatch(); publishIfCurrent(epoch); endOperation() }
        var candidates: [GalleryVaultRecord] = []
        var copied = 0
        var reused = 0
        var skipped: [GalleryVaultSkipReason: Int] = [:]
        var stopMessage: String?
        progress = .init(phase: "Copying", processed: 0, total: count, detail: nil)
        for index in 0..<count {
            guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
            if wantsCancel { stopMessage = "Stopped after saving \(copied) items."; break }
            let asset = assetAt(index)
            do {
                if let existing = storage.record(sourceIdentifier: asset.localIdentifier), existing.state == .copiedAwaitingDeletion {
                    // A previously interrupted commit must be verified again before it can be deleted.
                    var record = try await storage.verifyCommitted(id: existing.id)
                    if let destination { record = try await storage.setDestination(destination, sourceAlbumID: sourceAlbumID, for: record) }
                    guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
                    candidates.append(record)
                    reused += 1
                } else {
                    if storage.record(sourceIdentifier: asset.localIdentifier) != nil {
                        throw GalleryVaultTransferError.alreadyInVault
                    }
                    let preparation = Task.detached(priority: .userInitiated) {
                        do { return try await GalleryVaultPhotoLibrary.prepare(asset, sourceAlbumID: sourceAlbumID, sourcePosition: index) }
                        catch {
                            if error is GalleryVaultTransferError || error is CancellationError || error is GalleryVaultPhotoRequestFailure { throw error }
                            throw GalleryVaultPhotoRequestFailure(underlying: error)
                        }
                    }
                    cancelPreparation = { preparation.cancel() }
                    let prepared: GalleryVaultPhotoLibrary.Prepared
                    do { prepared = try await preparation.value }
                    catch { cancelPreparation = nil; throw error }
                    cancelPreparation = nil
                    guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
                    var record = prepared.record
                    let sourceAlbums = destination == nil ? nil : record.albums
                    if let destination {
                        record.albums = GalleryVaultStorage.destinationAlbums(record.albums, destination: destination, sourceAlbumID: sourceAlbumID)
                    }
                    let item = try storage.createItem(id: record.id)
                    do {
                        for (resource, descriptor) in zip(prepared.resources, prepared.record.resources) {
                            guard isCurrent(epoch), !wantsCancel else { throw GalleryVaultTransferError.cancelled }
                            let writer = try item.writer(resourceID: descriptor.id)
                            let stream = GalleryVaultPhotoStream()
                            activeStream = stream
                            try await stream.run(resource: resource, consume: { try writer.append($0) }, finish: { try writer.finish() })
                            activeStream = nil
                        }
                        guard isCurrent(epoch), !wantsCancel else { throw GalleryVaultTransferError.cancelled }
                        try storage.commit(record, from: item, sourceAlbums: sourceAlbums)
                        // A successful commit already verified the bytes; the source is never touched on a thrown commit.
                        candidates.append(record)
                        copied += 1
                    } catch {
                        activeStream = nil
                        item.discard()
                        throw error
                    }
                }
            } catch {
                guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
                try GalleryVaultPhotoLibrary.requireFullAccess()
                if !wantsCancel, let reason = Self.skipReason(for: error) {
                    skipped[reason, default: 0] += 1
                } else {
                    stopMessage = wantsCancel ? "Stopped after saving \(copied) items." : Self.transferErrorMessage(error)
                    break
                }
            }
            if index == count - 1 || index.isMultiple(of: 16) {
                progress = .init(phase: "Copying", processed: index + 1, total: count, detail: nil)
            }
        }
        guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
        let result = try await deleteConfirmed(candidates, epoch: epoch)
        if let destination, result.deleted > 0, isCurrent(epoch) {
            GalleryMoveHistory.shared.recordSuccessfulVaultMove(to: destination.id)
        }
        let detail = [stopMessage, result.message].compactMap { $0 }.joined(separator: " ")
        return .init(copied: copied, deleted: result.deleted, message: detail.isEmpty ? nil : detail,
            reused: reused, notMoved: count - result.deleted, skipped: skipped, editsDiscarded: result.editsDiscarded)
    }

    @discardableResult
    func retryPendingDeletion() async throws -> GalleryVaultTransferOutcome {
        try beginOperation()
        let epoch = authEpoch
        let pending = storage.records.filter { $0.state == .copiedAwaitingDeletion }
        storage.beginBatch()
        defer { storage.endBatch(); publishIfCurrent(epoch); endOperation() }
        var verified: [GalleryVaultRecord] = []
        var skipped: [GalleryVaultSkipReason: Int] = [:]
        var stopped: String?
        for (index, record) in pending.enumerated() {
            guard isCurrent(epoch), !wantsCancel else { stopped = "Verification was stopped."; break }
            do { verified.append(try await storage.verifyCommitted(id: record.id)) }
            catch {
                guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
                try GalleryVaultPhotoLibrary.requireFullAccess()
                if !wantsCancel, let reason = Self.skipReason(for: error) {
                    skipped[reason, default: 0] += 1
                } else { stopped = Self.transferErrorMessage(error); break }
            }
            if index.isMultiple(of: 16) { progress = .init(phase: "Verifying", processed: index + 1, total: pending.count, detail: nil) }
        }
        guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
        let result = try await deleteConfirmed(verified, epoch: epoch)
        let detail = [stopped, result.message].compactMap { $0 }.joined(separator: " ")
        return .init(copied: 0, deleted: result.deleted, message: detail.isEmpty ? nil : detail,
            reused: verified.count, notMoved: pending.count - result.deleted, skipped: skipped, editsDiscarded: result.editsDiscarded)
    }

    private func deleteConfirmed(_ candidates: [GalleryVaultRecord], epoch: UUID) async throws -> (deleted: Int, message: String?, editsDiscarded: Int) {
        guard !candidates.isEmpty else { return (0, nil, 0) }
        progress = .init(phase: "Checking Photos", processed: 0, total: candidates.count, detail: nil)
        let sourceVersions = try await storage.sourceVersions(for: candidates)
        guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
        let ids = candidates.map(\.sourceIdentifier)
        let live = try await Task.detached(priority: .userInitiated) { try GalleryVaultPhotoLibrary.fetch(ids: ids) }.value
        guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
        let classified = await Task.detached(priority: .userInitiated) {
            var current: [(PHAsset, GalleryVaultRecord)] = []
            var absent: [GalleryVaultRecord] = []
            var changed = 0
            var editsDiscarded = 0
            for (record, source) in zip(candidates, sourceVersions) {
                guard let asset = live[record.sourceIdentifier] else { absent.append(record); continue }
                if GalleryVaultPhotoLibrary.isSameVersion(asset, as: source) {
                    current.append((asset, source))
                    if GalleryVaultPhotoLibrary.hasEdits(PHAssetResource.assetResources(for: asset)) { editsDiscarded += 1 }
                }
                else { changed += 1 }
            }
            return (current, absent, changed, editsDiscarded)
        }.value
        guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
        let current = classified.0
        let alreadyAbsent = classified.1
        let changed = classified.2
        let editsDiscarded = classified.3
        let deletedIDs = current.map { $0.1.sourceIdentifier }
        for var record in alreadyAbsent {
            record.state = .privateItem
            try storage.update(record)
        }
        guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
        if !current.isEmpty {
            progress = .init(phase: "Moving from Photos", processed: 0, total: current.count, detail: nil)
            // A single Photos transaction means a batch receives a single system delete confirmation.
            do { try await GalleryVaultPhotoLibrary.delete(current) }
            catch {
                return (alreadyAbsent.count, "Photos did not delete the originals. Verified vault copies were kept; you can retry. \(error.localizedDescription)", 0)
            }
            guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
            NotificationCenter.default.post(name: .galleryVaultDidHideItems, object: nil,
                userInfo: ["sourceIdentifiers": deletedIDs, "sourceIdentifierSet": Set(deletedIDs)])
            let deletedSet = Set(deletedIDs)
            for var record in candidates where deletedSet.contains(record.sourceIdentifier) {
                record.state = .privateItem
                try storage.update(record)
            }
        }
        if !alreadyAbsent.isEmpty {
            NotificationCenter.default.post(name: .galleryVaultDidHideItems, object: nil,
                userInfo: ["sourceIdentifiers": alreadyAbsent.map(\.sourceIdentifier), "sourceIdentifierSet": Set(alreadyAbsent.map(\.sourceIdentifier))])
        }
        return (current.count + alreadyAbsent.count, changed > 0 ? "\(changed) changed items were left in Photos with their vault copies for review." : nil,
            editsDiscarded)
    }

    private func reconcilePendingAfterUnlock() async throws -> Int {
        let pending = storage.records.filter { $0.state == .copiedAwaitingDeletion }
        guard !pending.isEmpty, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return 0 }
        let live = try await Task.detached(priority: .userInitiated) {
            try GalleryVaultPhotoLibrary.fetch(ids: pending.map(\.sourceIdentifier))
        }.value
        let missing = pending.filter { live[$0.sourceIdentifier] == nil }
        guard !missing.isEmpty else { return 0 }
        storage.beginBatch()
        defer { storage.endBatch() }
        var unreadable = 0
        var reconciled: [String] = []
        for cachedRecord in missing {
            let verified: GalleryVaultRecord
            do { verified = try await storage.verifyCommitted(id: cachedRecord.id) }
            catch {
                guard isUnlocked else { throw GalleryVaultTransferError.locked }
                unreadable += 1
                continue
            }
            guard isUnlocked else { throw GalleryVaultTransferError.locked }
            guard verified.state == .copiedAwaitingDeletion else { continue }
            var record = verified
            record.state = .privateItem
            try storage.update(record)
            reconciled.append(record.sourceIdentifier)
        }
        if !reconciled.isEmpty {
            NotificationCenter.default.post(name: .galleryVaultDidHideItems, object: nil,
                userInfo: ["sourceIdentifiers": reconciled, "sourceIdentifierSet": Set(reconciled)])
        }
        return unreadable
    }

    /// Discards a pending vault copy only after confirming the Photos original is still accessible.
    /// The user explicitly selects these IDs; this operation never deletes a Photos asset.
    func discardPendingCopies(recordIDs: [UUID]) async throws {
        try beginOperation()
        let epoch = authEpoch
        storage.beginBatch()
        defer { storage.endBatch(); publishIfCurrent(epoch); endOperation() }
        for (index, id) in recordIDs.enumerated() {
            guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
            guard !wantsCancel else { throw GalleryVaultTransferError.cancelled }
            guard let record = storage.record(id: id), record.state == .copiedAwaitingDeletion else {
                throw GalleryVaultTransferError.pendingCopyUnavailable
            }
            progress = .init(phase: "Discarding saved copies", processed: index, total: recordIDs.count, detail: nil)
            let sourceID = record.sourceIdentifier
            let exists = try await Task.detached(priority: .userInitiated) {
                try GalleryVaultPhotoLibrary.fetch(ids: [sourceID])[sourceID] != nil
            }.value
            guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
            guard !wantsCancel else { throw GalleryVaultTransferError.cancelled }
            guard exists else { throw GalleryVaultTransferError.missingOriginal }
            try storage.remove(id: id)
            progress = .init(phase: "Discarding saved copies", processed: index + 1, total: recordIDs.count, detail: nil)
        }
    }

    func restore(recordID: UUID, omittingUnavailableAlbums: Bool = false) async throws {
        try await restore(recordIDs: [recordID], omittingUnavailableAlbums: omittingUnavailableAlbums)
    }

    func delete(recordID: UUID) async throws {
        try await applyOne(.delete(recordID), epoch: authEpoch)
    }

    func recycle(recordID: UUID) async throws {
        try await applyOne(.recycle(recordID), epoch: authEpoch)
    }

    func putBack(recordID: UUID) async throws {
        try await applyOne(.putBack(recordID), epoch: authEpoch)
    }

    func move(recordID: UUID, from sourceAlbumID: String?, to destination: GalleryVaultAlbum) async throws {
        try validateDestination(destination)
        try beginOperation(requiresPhotoAccess: false)
        let epoch = authEpoch
        defer { publishIfCurrent(epoch); endOperation() }
        guard let record = try storage.authoritativeRecord(id: recordID) else { throw GalleryVaultStorageError.corruptRecord }
        guard record.state == .privateItem else { throw GalleryVaultTransferError.interruptedRestore }
        guard !GalleryVaultRecycleBin.contains(record) else { throw GalleryVaultTransferError.invalidVaultDestination }
        var updated = record
        updated.albums = GalleryVaultStorage.destinationAlbums(record.albums,
            destination: destination, sourceAlbumID: sourceAlbumID)
        try storage.update(updated)
        GalleryMoveHistory.shared.recordSuccessfulVaultMove(to: destination.id)
    }

    // Serialize queued mutations and publish only while their captured authorization remains valid.
    func applyQueuedMutations(_ mutations: [GalleryVaultMutation], epoch: UUID) async -> [GalleryVaultMutationResult] {
        guard isCurrent(epoch) else { return mutations.map { .init(id: $0.id, error: GalleryVaultTransferError.locked) } }
        await waitForIdle(epoch: epoch)
        guard isCurrent(epoch) else { return mutations.map { .init(id: $0.id, error: GalleryVaultTransferError.locked) } }
        guard !needsAlbumDeletionReview else {
            return mutations.map { .init(id: $0.id, error: GalleryAlbumDeletionError.interrupted) }
        }
        isBusy = true
        error = nil
        defer { endOperation() }
        let revision = storage.mutationRevision
        let results = await storage.applyMutations(mutations)
        if storage.mutationRevision != revision {
            publishIfCurrent(epoch, queuedMutationIDs: Set(results.filter { $0.error == nil }.map(\.id)))
        }
        return results
    }

    private func applyOne(_ mutation: GalleryVaultMutation, epoch: UUID) async throws {
        let result = await applyQueuedMutations([mutation], epoch: epoch)[0]
        if let error = result.error { throw error }
        if let warning = result.warning { self.error = warning.localizedDescription }
    }

    func moveQueuedToVault(asset: PHAsset, destination: GalleryVaultAlbum, sourceAlbumID: String?, epoch: UUID) async throws -> GalleryVaultTransferOutcome {
        await waitForIdle(epoch: epoch)
        guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
        return try await moveToVault(assets: [asset], destination: destination, sourceAlbumID: sourceAlbumID)
    }

    private func waitForIdle(epoch: UUID) async {
        while isBusy && isCurrent(epoch) {
            await withCheckedContinuation { operationWaiters.append($0) }
        }
    }

    private func wakeOperationWaiters() {
        let waiters = operationWaiters
        operationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func validateDestination(_ destination: GalleryVaultAlbum) throws {
        guard destination.id != GalleryVaultRecycleBin.id,
              !GalleryRecycleBin.isRecycleBinTitle(destination.title) else { throw GalleryVaultTransferError.invalidVaultDestination }
    }

    func restore(recordIDs: [UUID], omittingUnavailableAlbums: Bool = false) async throws {
        try beginOperation()
        let epoch = authEpoch
        storage.beginBatch()
        defer { storage.endBatch(); publishIfCurrent(epoch); endOperation() }
        for (index, id) in recordIDs.enumerated() {
            guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
            guard !wantsCancel else { throw GalleryVaultTransferError.cancelled }
            guard let record = storage.record(id: id), record.state != .copiedAwaitingDeletion else { continue }
            progress = .init(phase: "Restoring", processed: index, total: recordIDs.count, detail: record.filename)
            do { try await restoreOne(record, epoch: epoch, omittingUnavailableAlbums: omittingUnavailableAlbums) }
            catch { if isCurrent(epoch) { self.error = error.localizedDescription }; throw error }
            progress = .init(phase: "Restoring", processed: index + 1, total: recordIDs.count, detail: nil)
        }
    }

    private func restoreOne(_ record: GalleryVaultRecord, epoch: UUID, omittingUnavailableAlbums: Bool) async throws {
        try GalleryVaultPhotoLibrary.requireFullAccess()
        let verifiedRecord = try await storage.verifyCommitted(id: record.id)
        guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
        guard verifiedRecord.state != .copiedAwaitingDeletion else { throw GalleryVaultTransferError.pendingCopyUnavailable }
        let parents = try await Task.detached { try GalleryVaultPhotoLibrary.usableParents(verifiedRecord, omittingUnavailable: omittingUnavailableAlbums) }.value
        var leases: [URL] = []
        defer { for url in leases { storage.releasePlaintext(url) } }
        for resource in verifiedRecord.resources {
            guard isCurrent(epoch), !wantsCancel else { throw GalleryVaultTransferError.cancelled }
            leases.append(try await storage.decryptResource(recordID: record.id, resourceID: resource.id))
        }
        guard isCurrent(epoch), !wantsCancel else { throw GalleryVaultTransferError.cancelled }
        let sourceHashes = try await Task.detached { try leases.map(GalleryVaultPhotoStream.fileDigest) }.value
        let restoredID: String
        if verifiedRecord.state == .restoring {
            guard let identifier = verifiedRecord.restoredIdentifier else { throw GalleryVaultTransferError.interruptedRestore }
            // An absent placeholder can mean an interrupted or not-yet-visible transaction.
            // Do not create another asset while that outcome is ambiguous.
            guard try GalleryVaultPhotoLibrary.fetch(ids: [identifier])[identifier] != nil else {
                throw GalleryVaultTransferError.interruptedRestore
            }
            restoredID = identifier
        } else {
            restoredID = try await importAsset(verifiedRecord, leases: leases, parents: parents, epoch: epoch)
        }
        guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
        guard let created = try GalleryVaultPhotoLibrary.fetch(ids: [restoredID])[restoredID] else {
            throw GalleryVaultTransferError.interruptedRestore
        }
        guard let journaled = storage.record(id: record.id) else { throw GalleryVaultTransferError.interruptedRestore }
        let resolvedParents = try await Task.detached { try GalleryVaultPhotoLibrary.usableParents(journaled, omittingUnavailable: omittingUnavailableAlbums) }.value
        guard resolvedParents.allSatisfy({ $0.1 != nil }) else { throw GalleryVaultTransferError.interruptedRestore }
        try await verifyRestored(created, record: journaled, parents: resolvedParents, sourceHashes: sourceHashes, epoch: epoch)
        guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
        NotificationCenter.default.post(name: .galleryVaultDidRestoreItem, object: nil,
            userInfo: ["record": journaled, "restoredIdentifier": restoredID])
        try storage.remove(id: record.id)
    }

    private func importAsset(_ record: GalleryVaultRecord, leases: [URL], parents: [(GalleryVaultAlbum, PHAssetCollection?)], epoch: UUID) async throws -> String {
        guard leases.count == record.resources.count else { throw GalleryVaultTransferError.importFailed }
        let types = try record.resources.map { descriptor in
            guard let type = PHAssetResourceType(rawValue: descriptor.type) else { throw GalleryVaultTransferError.unsupportedResources }
            return type
        }
        var createdIdentifier: String?
        var transactionError: Error?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                var requests: [(GalleryVaultAlbum, PHAssetCollectionChangeRequest, Int)] = []
                for (album, optionalCollection) in parents {
                    guard let collection = optionalCollection else { continue }
                    let fetch = PHAsset.fetchAssets(in: collection, options: nil)
                    guard let request = PHAssetCollectionChangeRequest(for: collection, assets: fetch) else {
                        transactionError = GalleryVaultTransferError.albumUnavailable(album.title); return
                    }
                    requests.append((album, request, fetch.count))
                }
                let creation = PHAssetCreationRequest.forAsset()
                guard let placeholder = creation.placeholderForCreatedAsset else { transactionError = GalleryVaultTransferError.importFailed; return }
                let identifier = placeholder.localIdentifier
                var recreatedTitles = Set<String>()
                for (album, collection) in parents where collection == nil {
                    guard recreatedTitles.insert(album.title).inserted else { continue }
                    let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album.title)
                    var resolved = album
                    resolved.id = request.placeholderForCreatedAssetCollection.localIdentifier
                    requests.append((resolved, request, 0))
                }
                // Journal both IDs before commit; a journal failure leaves an invalid empty asset,
                // so Photos rolls back the asset and new albums together.
                do {
                    try Self.onMainSync {
                        guard self.isCurrent(epoch), var staged = self.storage.record(id: record.id) else { throw GalleryVaultTransferError.locked }
                        staged.state = .restoring
                        staged.restoredIdentifier = identifier
                        staged.albums = requests.map { $0.0 }
                        if GalleryVaultRecycleBin.contains(record) { staged.albums.append(GalleryVaultRecycleBin.album) }
                        try self.storage.update(staged)
                    }
                } catch { transactionError = error; return }
                createdIdentifier = identifier
                creation.creationDate = record.creationDate
                creation.isFavorite = record.isFavorite
                if let latitude = record.latitude, let longitude = record.longitude {
                    creation.location = CLLocation(latitude: latitude, longitude: longitude)
                }
                for (index, descriptor) in record.resources.enumerated() {
                    let type = types[index], url = leases[index]
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = descriptor.filename
                    options.uniformTypeIdentifier = descriptor.uniformTypeIdentifier
                    creation.addResource(with: type, fileURL: url, options: options)
                }
                for (album, request, count) in requests {
                    if let position = album.position {
                        request.insertAssets([placeholder] as NSArray, at: IndexSet(integer: min(max(0, position), count)))
                    } else { request.addAssets([placeholder] as NSArray) }
                }
            }
        } catch {
            // A Photos completion error definitively rolls the change back. A cancellation
            // or lock can race an in-flight transaction, so those retain the journal instead.
            if isCurrent(epoch), !Task.isCancelled, !(error is CancellationError),
               let id = createdIdentifier, var staged = storage.record(id: record.id),
               staged.state == .restoring, staged.restoredIdentifier == id {
                staged.state = .privateItem
                staged.restoredIdentifier = nil
                staged.albums = record.albums
                try? storage.update(staged)
            }
            throw error
        }
        if let transactionError { throw transactionError }
        guard let createdIdentifier else { throw GalleryVaultTransferError.importFailed }
        return createdIdentifier
    }

    private func verifyRestored(_ asset: PHAsset, record: GalleryVaultRecord,
        parents: [(GalleryVaultAlbum, PHAssetCollection?)], sourceHashes: [SHA256.Digest], epoch: UUID) async throws {
        guard asset.mediaType.rawValue == record.mediaType,
              asset.creationDate == record.creationDate, asset.isFavorite == record.isFavorite else { throw GalleryVaultTransferError.importFailed }
        let containing = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var parentIDs = Set<String>()
        for i in 0..<containing.count { parentIDs.insert(containing.object(at: i).localIdentifier) }
        guard Set(parents.map { $0.0.id }).isSubset(of: parentIDs) else { throw GalleryVaultTransferError.importFailed }
        // Exact resource-byte verification below also covers originals with different edited/spatial geometry.
        let actualResources = PHAssetResource.assetResources(for: asset)
        for (index, expected) in record.resources.enumerated() {
            guard isCurrent(epoch), !wantsCancel else { throw GalleryVaultTransferError.cancelled }
            guard let resource = actualResources.first(where: { $0.type.rawValue == expected.type && $0.originalFilename == expected.filename }) else {
                throw GalleryVaultTransferError.importFailed
            }
            let digest = GalleryVaultDigestAccumulator()
            let stream = GalleryVaultPhotoStream()
            activeStream = stream
            try await stream.run(resource: resource, consume: { digest.update($0) }, finish: {})
            activeStream = nil
            guard digest.finalize() == sourceHashes[index] else { throw GalleryVaultTransferError.importFailed }
        }
    }

    private nonisolated static func errorChain(_ error: Error) -> [NSError] {
        var chain: [NSError] = []
        var candidate: NSError? = error as NSError
        for _ in 0..<8 {
            guard let current = candidate else { break }
            chain.append(current)
            candidate = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }

    private nonisolated static func isOutOfSpace(_ error: NSError) -> Bool {
        (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC)) ||
        (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError) ||
        (error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.Code.notEnoughSpace.rawValue)
    }

    private nonisolated static func skipReason(for error: Error) -> GalleryVaultSkipReason? {
        let photosStops = Set([PHPhotosError.Code.userCancelled, .libraryVolumeOffline,
            .relinquishingLibraryBundleToWriter, .switchingSystemPhotoLibrary, .operationInterrupted,
            .accessRestricted, .accessUserDenied, .limitExceeded].map(\.rawValue))
        guard !(error is CancellationError), !errorChain(error).contains(where: {
            isOutOfSpace($0) || ($0.domain == PHPhotosErrorDomain && photosStops.contains($0.code)) ||
            ($0.domain == NSCocoaErrorDomain && $0.code == NSUserCancelledError) ||
            ($0.domain == NSURLErrorDomain && $0.code == NSURLErrorCancelled)
        }) else { return nil }
        if let failure = error as? GalleryVaultTransferError {
            switch failure {
            case .unsupportedItem: return .unsupportedItem
            case .unsupportedResources: return .unsupportedResources
            case .missingResources, .missingOriginal, .photoRequestFailed: return .unavailableResource
            case .alreadyInVault: return .alreadySaved
            default: return nil
            }
        }
        if let failure = error as? GalleryVaultStorageError {
            switch failure {
            case .corruptRecord, .corruptResource, .incompleteItem: return .damagedCopy
            default: return nil
            }
        }
        return error is GalleryVaultPhotoRequestFailure ? .unavailableResource : nil
    }

    private nonisolated static func transferErrorMessage(_ error: Error) -> String {
        if errorChain(error).contains(where: isOutOfSpace) {
            return "Not enough device storage. The original that could not be saved was kept in Photos."
        }
        return error.localizedDescription
    }

    func prepareAlbumDeletion(_ album: GalleryAlbum) async throws -> GalleryAlbumDeletionPlan {
        guard album.virtualScope == nil, !GalleryRecycleBin.isRecycleBin(album),
              album.collection == nil || album.collection?.canPerform(.delete) == true else { throw GalleryAlbumDeletionError.notDeletable }
        if album.collection != nil { try GalleryVaultPhotoLibrary.requireFullAccess() }
        if storage.hasStoredItems && !isUnlocked { try await unlock() }
        guard !isBusy else { throw GalleryVaultTransferError.busy }
        guard !needsAlbumDeletionReview else { throw GalleryAlbumDeletionError.interrupted }
        return try await albumDeletionPlan(id: album.id, title: album.title, allowMissing: album.collection == nil)
    }

    func reviewInterruptedAlbumDeletion() async throws -> GalleryAlbumDeletionPlan {
        guard isUnlocked, let intent = pendingAlbumDeletion, !intent.photosCommitted else { throw GalleryAlbumDeletionError.interrupted }
        guard !isBusy else { throw GalleryVaultTransferError.busy }
        return try await albumDeletionPlan(id: intent.plan.albumID, title: intent.plan.title, allowMissing: true)
    }

    private func recoverAlbumDeletion() {
        pendingAlbumDeletion = nil
        albumDeletionRecoveryError = nil
        albumDeletionRemainingCount = 0
        do {
            pendingAlbumDeletion = try storage.readAlbumDeletion()
            if pendingAlbumDeletion?.photosCommitted == true { try finishAlbumDeletionVaultStep() }
        } catch { albumDeletionRecoveryError = error.localizedDescription }
    }

    func retryAlbumDeletionRecovery() {
        guard isUnlocked, !isBusy else { return }
        isBusy = true
        defer { publishIfCurrent(authEpoch); endOperation() }
        recoverAlbumDeletion()
        unreadableRecordCount = storage.unreadableRecordCount
    }

    func discardUnreadableAlbumDeletion() throws {
        guard isUnlocked else { throw GalleryVaultTransferError.locked }
        guard !isBusy else { throw GalleryVaultTransferError.busy }
        guard pendingAlbumDeletion == nil, albumDeletionRecoveryError != nil else { throw GalleryAlbumDeletionError.changed }
        try storage.writeAlbumDeletion(nil)
        albumDeletionRecoveryError = nil
    }

    func finishAlbumDeletionWithoutRemainingItems() throws {
        guard isUnlocked else { throw GalleryVaultTransferError.locked }
        guard !isBusy else { throw GalleryVaultTransferError.busy }
        guard pendingAlbumDeletion?.photosCommitted == true, albumDeletionRecoveryError != nil else { throw GalleryAlbumDeletionError.interrupted }
        try storage.writeAlbumDeletion(nil)
        pendingAlbumDeletion = nil
        albumDeletionRecoveryError = nil
        albumDeletionRemainingCount = 0
    }

    func keepInterruptedAlbum() async throws {
        guard isUnlocked else { throw GalleryVaultTransferError.locked }
        guard !isBusy else { throw GalleryVaultTransferError.busy }
        guard let intent = pendingAlbumDeletion, !intent.photosCommitted else { throw GalleryAlbumDeletionError.interrupted }
        isBusy = true
        let epoch = authEpoch
        defer { endOperation() }
        if intent.plan.hadPhotosAlbum {
            try GalleryVaultPhotoLibrary.requireFullAccess()
            let exists = await Task.detached(priority: .userInitiated) {
                GalleryRecycleBin.albumExists(id: intent.plan.albumID)
            }.value
            guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
            guard exists else { throw GalleryAlbumDeletionError.photosAlreadyDeleted }
        }
        try storage.writeAlbumDeletion(nil)
        pendingAlbumDeletion = nil
        albumDeletionRecoveryError = nil
    }

    private func albumDeletionPlan(id: String, title: String, allowMissing: Bool) async throws -> GalleryAlbumDeletionPlan {
        isBusy = true
        let epoch = authEpoch, hadUnlock = isUnlocked
        defer { endOperation() }
        let actual = hadUnlock ? try await storage.authoritativeRecords() : []
        let records = actual.filter { $0.albums.contains { $0.id == id } }
        guard !records.contains(where: { $0.state == .restoring }) else { throw GalleryAlbumDeletionError.restoring }
        let photos = try await Task.detached(priority: .userInitiated) { try GalleryRecycleBin.albumDeletionSnapshot(id: id) }.value
        guard !hadUnlock || isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
        guard photos != nil || allowMissing else { throw GalleryAlbumDeletionError.changed }
        return GalleryAlbumDeletionPlan(albumID: id, title: title, hadPhotosAlbum: photos != nil,
            photoIDs: photos?.ids ?? [], sharedPhotoCount: photos?.shared ?? 0, vaultRecords: records)
    }

    func deleteAlbum(_ plan: GalleryAlbumDeletionPlan, includingItems: Bool) async throws {
        guard !isBusy else { throw GalleryVaultTransferError.busy }
        guard albumDeletionRecoveryError == nil else { throw GalleryAlbumDeletionError.interrupted }
        guard pendingAlbumDeletion == nil || (pendingAlbumDeletion?.plan.albumID == plan.albumID && pendingAlbumDeletion?.photosCommitted == false) else { throw GalleryAlbumDeletionError.interrupted }
        if plan.hadPhotosAlbum { try GalleryVaultPhotoLibrary.requireFullAccess() }
        if storage.hasStoredItems { guard isUnlocked else { throw GalleryVaultTransferError.locked } }
        isBusy = true
        let epoch = authEpoch, hadUnlock = isUnlocked
        defer { publishIfCurrent(epoch); endOperation() }
        if hadUnlock {
            let actual = try await storage.authoritativeRecords().filter { $0.albums.contains { $0.id == plan.albumID } }
            guard Dictionary(uniqueKeysWithValues: actual.map { ($0.id, $0) }) == Dictionary(uniqueKeysWithValues: plan.vaultRecords.map { ($0.id, $0) }) else { throw GalleryAlbumDeletionError.changed }
            guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
        }
        let needsJournal = !plan.vaultRecords.isEmpty || pendingAlbumDeletion != nil
        var intent = GalleryVaultAlbumDeletion(plan: plan, deleteItems: includingItems)
        if needsJournal {
            try storage.writeAlbumDeletion(intent)
            pendingAlbumDeletion = intent
        }
        do {
            if plan.hadPhotosAlbum { try await GalleryRecycleBin.deleteAlbum(plan, includingItems: includingItems) }
        } catch {
            if needsJournal && isCurrent(epoch) {
                try storage.writeAlbumDeletion(nil)
                pendingAlbumDeletion = nil
            }
            throw error
        }
        if needsJournal {
            guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
            intent.photosCommitted = true
            try storage.writeAlbumDeletion(intent)
            pendingAlbumDeletion = intent
            do { try finishAlbumDeletionVaultStep() }
            catch { albumDeletionRecoveryError = error.localizedDescription; throw error }
        }
        NotificationCenter.default.post(name: .galleryAlbumWasDeleted, object: nil, userInfo: ["albumID": plan.albumID])
    }

    private func finishAlbumDeletionVaultStep() throws {
        guard let intent = pendingAlbumDeletion, intent.photosCommitted else { throw GalleryAlbumDeletionError.interrupted }
        storage.beginBatch()
        defer { storage.endBatch() }
        let recycledIDs = intent.plan.recycledVaultIDs
        var remaining = 0
        var firstError: String?
        for original in intent.plan.vaultRecords {
            do {
                guard var record = try storage.authoritativeRecord(id: original.id),
                      record.albums.contains(where: { $0.id == intent.plan.albumID }) else { continue }
                if intent.deleteItems, recycledIDs.contains(record.id),
                   record.albums.allSatisfy({ $0.id == intent.plan.albumID }) {
                    record.albums = [GalleryVaultRecycleBin.album]
                    try storage.update(record)
                } else {
                    record.albums.removeAll { $0.id == intent.plan.albumID }
                    try storage.update(record)
                }
            } catch {
                remaining += 1
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        albumDeletionRemainingCount = remaining
        if remaining > 0 { throw GalleryAlbumDeletionError.cleanupIncomplete(remaining, firstError ?? "") }
        try storage.writeAlbumDeletion(nil)
        pendingAlbumDeletion = nil
        NotificationCenter.default.post(name: .galleryAlbumWasDeleted, object: nil, userInfo: ["albumID": intent.plan.albumID])
    }

    private func beginOperation(requiresPhotoAccess: Bool = true) throws {
        guard isUnlocked else { throw GalleryVaultTransferError.locked }
        guard !isBusy else { throw GalleryVaultTransferError.busy }
        guard !needsAlbumDeletionReview else { throw GalleryAlbumDeletionError.interrupted }
        if requiresPhotoAccess { try GalleryVaultPhotoLibrary.requireFullAccess() }
        isBusy = true
        wantsCancel = false
        error = nil
    }

    private func endOperation() {
        activeStream = nil
        isBusy = false
        wakeOperationWaiters()
    }
    private func isCurrent(_ epoch: UUID) -> Bool { isUnlocked && authEpoch == epoch }
    private func publishIfCurrent(_ epoch: UUID, queuedMutationIDs: Set<UUID>? = nil) {
        guard isCurrent(epoch), queuedMutationIDs != nil || records != storage.records else { return }
        isPublishingQueuedMutations = queuedMutationIDs != nil
        publishingMutationIDs = queuedMutationIDs ?? []
        defer { isPublishingQueuedMutations = false; publishingMutationIDs.removeAll() }
        records = storage.records
    }

    private nonisolated static func onMainSync(_ work: @escaping @MainActor () throws -> Void) throws {
        if Thread.isMainThread { try MainActor.assumeIsolated { try work() }; return }
        var result: Result<Void, Error>!
        DispatchQueue.main.sync { result = Result { try MainActor.assumeIsolated { try work() } } }
        try result.get()
    }
}

/// Only Photos provider errors are item failures; a writer's unknown storage error stops the batch.
private nonisolated struct GalleryVaultPhotoRequestFailure: CustomNSError {
    let underlying: Error
    static var errorDomain: String { "GalleryVaultPhotoRequestFailure" }
    var errorCode: Int { 1 }
    var errorUserInfo: [String: Any] {
        [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: underlying.localizedDescription]
    }
}

/// PhotoKit calls its handlers on a serial queue; no media-sized buffer is retained.
private nonisolated final class GalleryVaultPhotoStream: @unchecked Sendable {
    private let lock = NSLock()
    private var requestID: PHAssetResourceDataRequestID = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var stopped: Error?

    func run(resource: PHAssetResource, consume: @escaping (Data) throws -> Void, finish: @escaping () throws -> Void) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if let stopped { lock.unlock(); continuation.resume(throwing: stopped); return }
                self.continuation = continuation
                lock.unlock()
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                let id = PHAssetResourceManager.default().requestData(for: resource, options: options) { [weak self] data in
                    guard let self, !self.isStopped else { return }
                    do { try consume(data) } catch { self.stop(error) }
                } completionHandler: { [weak self] error in
                    guard let self else { return }
                    if let error { self.complete(.failure(GalleryVaultPhotoRequestFailure(underlying: error))); return }
                    guard !self.isStopped else { return }
                    do { try finish(); self.complete(.success(())) } catch { self.complete(.failure(error)) }
                }
                lock.lock(); requestID = id; let shouldCancel = stopped != nil; lock.unlock()
                if shouldCancel { PHAssetResourceManager.default().cancelDataRequest(id) }
            }
        }, onCancel: { self.cancel() })
    }

    func cancel() { stop(CancellationError()) }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped != nil }
    private func stop(_ error: Error) {
        lock.lock(); if stopped == nil { stopped = error }; let id = requestID; let c = continuation; continuation = nil; lock.unlock()
        if id != 0 { PHAssetResourceManager.default().cancelDataRequest(id) }
        c?.resume(throwing: error)
    }
    private func complete(_ result: Result<Void, Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(with: result)
    }
    static func fileDigest(_ url: URL) throws -> SHA256.Digest {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize()
    }
}

private nonisolated final class GalleryVaultDigestAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var hasher = SHA256()
    func update(_ data: Data) { lock.lock(); hasher.update(data: data); lock.unlock() }
    func finalize() -> SHA256.Digest { lock.lock(); defer { lock.unlock() }; return hasher.finalize() }
}
#endif
