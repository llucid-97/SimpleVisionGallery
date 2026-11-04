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
}

nonisolated enum GalleryVaultSkipReason: String, CaseIterable, Hashable, Sendable {
    case unsupportedItem = "Photos cannot remove this media"
    case unsupportedResources = "Originals and edits cannot yet be restored safely"
    case unavailableResource = "Photos could not provide complete files"
    case damagedCopy = "Saved files could not be verified"
    case alreadySaved = "Already in the vault"
}

/// The service owns a single operation and publishes only complete vault snapshots.
@MainActor
final class GalleryVaultService: ObservableObject {
    static let shared = GalleryVaultService()
    @Published private(set) var isUnlocked = false
    @Published private(set) var authEpoch = UUID()
    @Published private(set) var records: [GalleryVaultRecord] = []
    @Published private(set) var unreadableRecordCount = 0
    @Published private(set) var isBusy = false
    @Published private(set) var progress: GalleryVaultProgress?
    @Published private(set) var error: String?

    private let storage = GalleryVaultStorage.shared
    private var wantsCancel = false
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
        defer { isBusy = false }
        do {
            try await storage.unlock()
            guard authEpoch == attemptEpoch, storage.isUnlocked else { throw GalleryVaultTransferError.locked }
            let epoch = UUID()
            unlockedEpoch = epoch
            authEpoch = epoch
            isUnlocked = true
            // A deletion can commit just before the app terminates. Resolve it only
            // with full library access, and never delete an existing source here.
            let unreadablePending = try await reconcilePendingAfterUnlock()
            guard isCurrent(epoch), storage.isUnlocked else { throw GalleryVaultTransferError.locked }
            records = storage.records
            unreadableRecordCount = storage.unreadableRecordCount + unreadablePending
        } catch {
            let wasLockedDuringAttempt = authEpoch != (unlockedEpoch ?? attemptEpoch)
            records = []
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
        activeStream?.cancel()
        authEpoch = UUID()
        isUnlocked = false
        records = []
        unreadableRecordCount = 0
        progress = nil
        error = nil
        storage.lock()
        error = storage.cleanupWarning
    }

    func cancel() {
        wantsCancel = true
        activeStream?.cancel()
    }

    @discardableResult
    func moveToVault(fetch: PHFetchResult<PHAsset>, sourceAlbumID: String? = nil) async throws -> GalleryVaultTransferOutcome {
        try await move(count: fetch.count, sourceAlbumID: sourceAlbumID) { fetch.object(at: $0) }
    }

    @discardableResult
    func moveToVault(assets: [PHAsset]) async throws -> GalleryVaultTransferOutcome {
        try await move(count: assets.count, sourceAlbumID: nil) { assets[$0] }
    }

    private func move(count: Int, sourceAlbumID: String?, assetAt: (Int) -> PHAsset) async throws -> GalleryVaultTransferOutcome {
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
                    let record = try await storage.verifyCommitted(id: existing.id)
                    guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
                    candidates.append(record)
                    reused += 1
                } else {
                    if storage.record(sourceIdentifier: asset.localIdentifier) != nil {
                        throw GalleryVaultTransferError.alreadyInVault
                    }
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        try GalleryVaultPhotoLibrary.prepare(asset, sourceAlbumID: sourceAlbumID, sourcePosition: index)
                    }.value
                    guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
                    let item = try storage.createItem(id: prepared.record.id)
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
                        try storage.commit(prepared.record, from: item)
                        // A successful commit already verified the bytes; the source is never touched on a thrown commit.
                        candidates.append(prepared.record)
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
        let detail = [stopMessage, result.message].compactMap { $0 }.joined(separator: " ")
        return .init(copied: copied, deleted: result.deleted, message: detail.isEmpty ? nil : detail,
            reused: reused, notMoved: count - result.deleted, skipped: skipped)
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
            reused: verified.count, notMoved: pending.count - result.deleted, skipped: skipped)
    }

    private func deleteConfirmed(_ candidates: [GalleryVaultRecord], epoch: UUID) async throws -> (deleted: Int, message: String?) {
        guard !candidates.isEmpty else { return (0, nil) }
        progress = .init(phase: "Checking Photos", processed: 0, total: candidates.count, detail: nil)
        let ids = candidates.map(\.sourceIdentifier)
        let live = try await Task.detached(priority: .userInitiated) { try GalleryVaultPhotoLibrary.fetch(ids: ids) }.value
        guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
        let classified = await Task.detached(priority: .userInitiated) {
            var current: [(PHAsset, GalleryVaultRecord)] = []
            var absent: [GalleryVaultRecord] = []
            var changed = 0
            for record in candidates {
                guard let asset = live[record.sourceIdentifier] else { absent.append(record); continue }
                if GalleryVaultPhotoLibrary.isSameVersion(asset, as: record) { current.append((asset, record)) }
                else { changed += 1 }
            }
            return (current, absent, changed)
        }.value
        guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
        let current = classified.0
        let alreadyAbsent = classified.1
        let changed = classified.2
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
                return (alreadyAbsent.count, "Photos did not delete the originals. Verified vault copies were kept; you can retry. \(error.localizedDescription)")
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
        return (current.count + alreadyAbsent.count, changed > 0 ? "\(changed) changed items were left in Photos with their vault copies for review." : nil)
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
        for var record in missing {
            do { _ = try await storage.verifyCommitted(id: record.id) }
            catch {
                guard isUnlocked else { throw GalleryVaultTransferError.locked }
                unreadable += 1
                continue
            }
            guard isUnlocked else { throw GalleryVaultTransferError.locked }
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
        try await verifyRestored(created, record: verifiedRecord, parents: parents, sourceHashes: sourceHashes, epoch: epoch)
        guard isCurrent(epoch) else { throw GalleryVaultTransferError.locked }
        NotificationCenter.default.post(name: .galleryVaultDidRestoreItem, object: nil,
            userInfo: ["record": verifiedRecord, "restoredIdentifier": restoredID])
        try storage.remove(id: record.id)
    }

    private func importAsset(_ record: GalleryVaultRecord, leases: [URL], parents: [(GalleryVaultAlbum, PHAssetCollection)], epoch: UUID) async throws -> String {
        var createdIdentifier: String?
        var transactionError: Error?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                var requests: [(GalleryVaultAlbum, PHAssetCollectionChangeRequest, Int)] = []
                for (album, collection) in parents {
                    let fetch = PHAsset.fetchAssets(in: collection, options: nil)
                    guard let request = PHAssetCollectionChangeRequest(for: collection, assets: fetch) else {
                        transactionError = GalleryVaultTransferError.albumUnavailable(album.title); return
                    }
                    requests.append((album, request, fetch.count))
                }
                let creation = PHAssetCreationRequest.forAsset()
                guard let placeholder = creation.placeholderForCreatedAsset else { transactionError = GalleryVaultTransferError.importFailed; return }
                let identifier = placeholder.localIdentifier
                // Persist the placeholder before Photos can commit. A missing ID after a crash
                // stays in recovery instead of creating a duplicate import.
                do {
                    try Self.onMainSync {
                        guard self.isCurrent(epoch), var staged = self.storage.record(id: record.id) else { throw GalleryVaultTransferError.locked }
                        staged.state = .restoring
                        staged.restoredIdentifier = identifier
                        try self.storage.update(staged)
                    }
                } catch { transactionError = error; return }
                createdIdentifier = identifier
                creation.creationDate = record.creationDate
                creation.isFavorite = record.isFavorite
                if let latitude = record.latitude, let longitude = record.longitude {
                    creation.location = CLLocation(latitude: latitude, longitude: longitude)
                }
                for (descriptor, url) in zip(record.resources, leases) {
                    guard let type = PHAssetResourceType(rawValue: descriptor.type) else { transactionError = GalleryVaultTransferError.unsupportedResources; return }
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
                try? storage.update(staged)
            }
            throw error
        }
        if let transactionError { throw transactionError }
        guard let createdIdentifier else { throw GalleryVaultTransferError.importFailed }
        return createdIdentifier
    }

    private func verifyRestored(_ asset: PHAsset, record: GalleryVaultRecord,
        parents: [(GalleryVaultAlbum, PHAssetCollection)], sourceHashes: [SHA256.Digest], epoch: UUID) async throws {
        guard asset.mediaType.rawValue == record.mediaType,
              asset.pixelWidth == record.pixelWidth, asset.pixelHeight == record.pixelHeight,
              asset.creationDate == record.creationDate, asset.isFavorite == record.isFavorite else { throw GalleryVaultTransferError.importFailed }
        let containing = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var parentIDs = Set<String>()
        for i in 0..<containing.count { parentIDs.insert(containing.object(at: i).localIdentifier) }
        guard Set(parents.map { $0.0.id }).isSubset(of: parentIDs) else { throw GalleryVaultTransferError.importFailed }
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

    private func beginOperation() throws {
        guard isUnlocked else { throw GalleryVaultTransferError.locked }
        guard !isBusy else { throw GalleryVaultTransferError.busy }
        try GalleryVaultPhotoLibrary.requireFullAccess()
        isBusy = true
        wantsCancel = false
        error = nil
    }

    private func endOperation() { activeStream = nil; isBusy = false }
    private func isCurrent(_ epoch: UUID) -> Bool { isUnlocked && authEpoch == epoch }
    private func publishIfCurrent(_ epoch: UUID) { if isCurrent(epoch) { records = storage.records } }

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
