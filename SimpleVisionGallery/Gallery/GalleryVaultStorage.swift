import Combine
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security
import UniformTypeIdentifiers

nonisolated enum GalleryVaultStorageError: LocalizedError {
    case locked, keyUnavailable, corruptRecord, corruptResource, duplicateItem, incompleteItem
    case authentication(String), io(String)

    var errorDescription: String? {
        switch self {
        case .locked: "The private vault is locked."
        case .keyUnavailable: "The vault key is unavailable. Existing vault files were preserved."
        case .corruptRecord: "A private vault record could not be authenticated."
        case .corruptResource: "A private vault file could not be authenticated."
        case .duplicateItem: "This private vault item already exists."
        case .incompleteItem: "A private vault item was not fully saved and verified."
        case .authentication(let message), .io(let message): message
        }
    }
}

/// The lease makes lock a commit and decrypted-state revocation barrier.
nonisolated final class GalleryVaultSession: @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    private var revoked = false
    private var clearMutationState: (@Sendable () -> Void)?
    private var thumbnailTotals: (count: Int, bytes: Int)?
    private var removedThumbnailRecords = Set<UUID>()

    init(key: SymmetricKey) { self.key = key }

    func withKey<T>(_ body: (SymmetricKey) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !revoked, let key else { throw GalleryVaultStorageError.locked }
        return try body(key)
    }

    func attachMutationState(clear: @escaping @Sendable () -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !revoked else { throw GalleryVaultStorageError.locked }
        clearMutationState = clear
    }

    func detachMutationState() {
        lock.lock()
        clearMutationState = nil
        lock.unlock()
    }

    var isRevoked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return revoked
    }

    func storeThumbnail(_ data: Data, recordID: UUID, at url: URL) throws {
        try withKey { key in
            guard !removedThumbnailRecords.contains(recordID) else { return }
            let manager = FileManager.default
            let directory = url.deletingLastPathComponent()
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            let box = try AES.GCM.seal(data, using: key, authenticating: Data(url.lastPathComponent.utf8))
            guard let bytes = box.combined else { return }
            let previous = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let added = previous == 0 ? 1 : 0
            if thumbnailTotals == nil || thumbnailTotals!.count + added > 2048
                || thumbnailTotals!.bytes + bytes.count - previous > 64 * 1024 * 1024 {
                let entries = try manager.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
                let dated = try entries.map { entry in
                    let values = try entry.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    return (entry, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
                }.sorted { $0.1 < $1.1 }
                var totals = (count: dated.count, bytes: dated.reduce(0) { $0 + $1.2 })
                let needsEviction = totals.count + added > 2048 || totals.bytes + bytes.count - previous > 64 * 1024 * 1024
                let countTarget = needsEviction ? 1920 : 2048
                let byteTarget = (needsEviction ? 56 : 64) * 1024 * 1024
                // Evict in batches, oldest-written first; reads do not change file dates.
                for entry in dated where entry.0 != url {
                    guard totals.count + added > countTarget || totals.bytes + bytes.count - previous > byteTarget else { break }
                    try manager.removeItem(at: entry.0)
                    totals.count -= 1
                    totals.bytes -= entry.2
                }
                thumbnailTotals = totals
            }
            try bytes.write(to: url, options: [.atomic, .completeFileProtection])
            thumbnailTotals!.count += added
            thumbnailTotals!.bytes += bytes.count - previous
        }
    }

    func removeThumbnails(recordID: UUID, urls: [URL]) throws {
        try withKey { key in try removeThumbnails(recordID: recordID, urls: urls, inMutationLease: key) }
    }

    // Remove cached thumbnails under the mutation lease and keep their totals accurate.
    func removeThumbnails(recordID: UUID, urls: [URL], inMutationLease key: SymmetricKey) throws {
        // Fence thumbnail writes already queued when the record was removed.
        removedThumbnailRecords.insert(recordID)
        // Missing files are harmless, while other removal failures must reach the caller.
        for url in urls {
            do {
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                try FileManager.default.removeItem(at: url)
                if thumbnailTotals != nil {
                    thumbnailTotals!.count -= 1
                    thumbnailTotals!.bytes -= size
                }
            } catch {
                let value = error as NSError
                let missing = value.domain == NSCocoaErrorDomain
                    && (value.code == NSFileNoSuchFileError || value.code == NSFileReadNoSuchFileError)
                    || value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT)
                if !missing { throw error }
            }
        }
        _ = key
    }

    func revoke() {
        lock.lock()
        revoked = true
        key = nil
        clearMutationState?()
        clearMutationState = nil
        thumbnailTotals = nil
        removedThumbnailRecords.removeAll()
        lock.unlock()
    }
}

/// Stream framing authenticates the resource ID, frame number, size, and final marker.
/// A file ending without its authenticated final marker is never accepted as complete.
nonisolated private enum GalleryVaultCipher {
    static let magic = Data("SVGVAULT1".utf8)
    static let chunkSize = 1024 * 1024

    static func createProtectedFile(_ url: URL) throws -> FileHandle {
        // Exclusive creation prevents an in-flight export from replacing existing bytes.
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            return handle
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    static func associatedData(id: UUID, index: UInt64, length: UInt32) -> Data {
        var data = Data(id.uuidString.utf8)
        var n = index.bigEndian
        var l = length.bigEndian
        withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &l) { data.append(contentsOf: $0) }
        return data
    }

    static func writeFrame(_ plaintext: Data, to handle: FileHandle, id: UUID, index: UInt64, session: GalleryVaultSession) throws {
        let length = UInt32(plaintext.count)
        let sealed = try session.withKey { key in
            try AES.GCM.seal(plaintext, using: key, authenticating: associatedData(id: id, index: index, length: length))
        }
        guard let bytes = sealed.combined else { throw GalleryVaultStorageError.corruptResource }
        var prefix = length.bigEndian
        try withUnsafeBytes(of: &prefix) { try handle.write(contentsOf: Data($0)) }
        try handle.write(contentsOf: bytes)
    }

    static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let part = try handle.read(upToCount: count - result.count), !part.isEmpty else {
                throw GalleryVaultStorageError.corruptResource
            }
            result.append(part)
        }
        return result
    }

    @discardableResult
    static func decrypt(_ source: URL, to destination: FileHandle?, id: UUID, session: GalleryVaultSession) throws -> UInt64 {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard try readExactly(magic.count, from: input) == magic else { throw GalleryVaultStorageError.corruptResource }
        var index: UInt64 = 0
        var total: UInt64 = 0
        while true {
            let prefix = try readExactly(4, from: input)
            let length = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length <= chunkSize else { throw GalleryVaultStorageError.corruptResource }
            let sealed = try readExactly(Int(length) + 28, from: input)
            let decoded: Data
            do {
                decoded = try session.withKey { key in
                    let box = try AES.GCM.SealedBox(combined: sealed)
                    return try AES.GCM.open(box, using: key, authenticating: associatedData(id: id, index: index, length: length))
                }
            } catch GalleryVaultStorageError.locked {
                throw GalleryVaultStorageError.locked
            } catch {
                throw GalleryVaultStorageError.corruptResource
            }
            guard decoded.count == Int(length) else { throw GalleryVaultStorageError.corruptResource }
            if length == 0 {
                guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw GalleryVaultStorageError.corruptResource }
                try session.withKey { _ in () }
                return total
            }
            try destination?.write(contentsOf: decoded)
            total += UInt64(length)
            guard index < UInt64.max else { throw GalleryVaultStorageError.corruptResource }
            index += 1
        }
    }
}

/// PhotoKit can call append from its own callback queue. Only one chunk is buffered.
nonisolated final class GalleryVaultResourceWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let id: UUID
    private let url: URL
    private let session: GalleryVaultSession
    private let handle: FileHandle
    private var pending = Data()
    private var index: UInt64 = 0
    private var totalBytes: UInt64 = 0
    private var didFinish = false
    private var failed = false

    fileprivate init(id: UUID, url: URL, session: GalleryVaultSession) throws {
        self.id = id
        self.url = url
        self.session = session
        try session.withKey { _ in () }
        handle = try GalleryVaultCipher.createProtectedFile(url)
        try handle.write(contentsOf: GalleryVaultCipher.magic)
    }

    func append(_ bytes: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish, !failed else { throw GalleryVaultStorageError.incompleteItem }
        do {
            try session.withKey { _ in () }
            var offset = 0
            while offset < bytes.count {
                let amount = min(GalleryVaultCipher.chunkSize - pending.count, bytes.count - offset)
                pending.append(bytes.subdata(in: offset..<(offset + amount)))
                offset += amount
                totalBytes += UInt64(amount)
                if pending.count == GalleryVaultCipher.chunkSize {
                    try writePending()
                }
            }
        } catch {
            failed = true
            throw error
        }
    }

    private func writePending() throws {
        guard !pending.isEmpty else { return }
        try GalleryVaultCipher.writeFrame(pending, to: handle, id: id, index: index, session: session)
        index += 1
        pending.removeAll(keepingCapacity: true)
    }

    func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish, !failed else { throw GalleryVaultStorageError.incompleteItem }
        do {
            guard totalBytes > 0 else { throw GalleryVaultStorageError.incompleteItem }
            try writePending()
            try GalleryVaultCipher.writeFrame(Data(), to: handle, id: id, index: index, session: session)
            try handle.synchronize()
            try handle.close()
            try GalleryVaultCipher.decrypt(url, to: nil, id: id, session: session)
            didFinish = true
        } catch {
            failed = true
            try? handle.close()
            throw error
        }
    }

    fileprivate var isVerified: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFinish && !failed
    }
}

nonisolated final class GalleryVaultStagingItem: @unchecked Sendable {
    private let lock = NSLock()
    fileprivate let id: UUID
    fileprivate let directory: URL
    private let session: GalleryVaultSession
    private var writers: [UUID: GalleryVaultResourceWriter] = [:]
    private var discarded = false

    fileprivate init(id: UUID, directory: URL, session: GalleryVaultSession) {
        self.id = id
        self.directory = directory
        self.session = session
    }

    func writer(resourceID: UUID) throws -> GalleryVaultResourceWriter {
        lock.lock()
        defer { lock.unlock() }
        guard !discarded, writers[resourceID] == nil else { throw GalleryVaultStorageError.duplicateItem }
        let result = try GalleryVaultResourceWriter(id: resourceID, url: resourceURL(resourceID), session: session)
        writers[resourceID] = result
        return result
    }

    fileprivate func resourceURL(_ resourceID: UUID) -> URL {
        directory.appendingPathComponent(resourceID.uuidString + ".bin", isDirectory: false)
    }

    fileprivate func verifiedResources() -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        guard !discarded else { return [] }
        let verified = Set(writers.filter { $0.value.isVerified }.keys)
        return verified.count == writers.count ? verified : []
    }

    fileprivate func belongs(to session: GalleryVaultSession) -> Bool { self.session === session }

    func discard() {
        lock.lock()
        defer { lock.unlock() }
        discarded = true
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class GalleryVaultStorage: ObservableObject {
    static let shared = GalleryVaultStorage()
    @Published private(set) var isUnlocked = false
    @Published private(set) var records: [GalleryVaultRecord] = []
    private(set) var mutationRevision: UInt = 0
    @Published private(set) var unreadableRecordCount = 0
    @Published private(set) var cleanupWarning: String?
    private var recordsByID: [UUID: GalleryVaultRecord] = [:]
    private var recordDates: [UUID: Date] = [:]
    private var manifestDirty = false
    private var manifestTask: Task<Void, Never>?
    private var manifestPreload: Task<Data?, Never>?
    private nonisolated struct ManifestEntry: Codable, Sendable {
        let record: GalleryVaultRecord
        let date: Date
    }
    private nonisolated struct MutationOutcome: Sendable {
        let id: UUID
        let error: (any Error)?
        let warning: (any Error)?
    }
    // Hold temporary batch data in one revocable object so locking can clear it.
    private nonisolated final class MutationBatchState: @unchecked Sendable {
        var mutations: [GalleryVaultMutation]
        var recordsByID: [UUID: GalleryVaultRecord]
        var idsBySource: [String: UUID]
        var recordDates: [UUID: Date]
        var outcomes: [MutationOutcome] = []
        var sortedRecords: [GalleryVaultRecord] = []
        var manifestCiphertext: Data?
        var repairedCount = 0
        var changed = false

        init(mutations: [GalleryVaultMutation], recordsByID: [UUID: GalleryVaultRecord], idsBySource: [String: UUID], recordDates: [UUID: Date]) {
            self.mutations = mutations
            self.recordsByID = recordsByID
            self.idsBySource = idsBySource
            self.recordDates = recordDates
        }

        // Drop temporary private data when the session is revoked.
        func clear() {
            mutations.removeAll(keepingCapacity: false)
            recordsByID.removeAll(keepingCapacity: false)
            idsBySource.removeAll(keepingCapacity: false)
            recordDates.removeAll(keepingCapacity: false)
            outcomes.removeAll(keepingCapacity: false)
            sortedRecords.removeAll(keepingCapacity: false)
            manifestCiphertext = nil
            repairedCount = 0
            changed = false
        }
    }
    // Private metadata in detached writes is erased by the session's lock barrier.
    private nonisolated final class TransferWriteState: @unchecked Sendable {
        var record: GalleryVaultRecord?
        var sourceAlbums: [GalleryVaultAlbum]?
        init(record: GalleryVaultRecord, sourceAlbums: [GalleryVaultAlbum]? = nil) {
            self.record = record
            self.sourceAlbums = sourceAlbums
        }
        func clear() { record = nil; sourceAlbums = nil }
    }
    private nonisolated struct MutationBatch: Sendable {
        let outcomes: [MutationOutcome]
        let recordsByID: [UUID: GalleryVaultRecord]
        let idsBySource: [String: UUID]
        let recordDates: [UUID: Date]
        let sortedRecords: [GalleryVaultRecord]
        let manifestCiphertext: Data?
        let repairedCount: Int
        let changed: Bool
    }
    private nonisolated static let manifestAAD = Data("SVGManifest1".utf8)
    private var idsBySource: [String: UUID] = [:]
    private var batchDepth = 0
    private var transferBatchChangedIDs = Set<UUID>()
    private var recordsChanged = false
    private var session: GalleryVaultSession?
    private var generation = UUID()
    private var isUnlocking = false
    private let root: URL
    private let items: URL
    private let staging: URL
    private let plaintext: URL
    private static let keychainService = "com.llucid.simplevisiongallery.privatevault.v1"
    private static let keychainAccount = "media-key"

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = appSupport.appendingPathComponent("PrivateVault", isDirectory: true)
        items = root.appendingPathComponent("items", isDirectory: true)
        staging = root.appendingPathComponent("staging", isDirectory: true)
        plaintext = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateVaultLeases", isDirectory: true)
        // A crash must never leave a decrypted playback file available on relaunch.
        try? cleanupPlaintext()
        preloadManifest()
    }

    private func preloadManifest() {
        let url = root.appendingPathComponent("manifest.enc")
        // No key or plaintext metadata is touched before device authentication.
        manifestPreload = Task.detached(priority: .utility) { try? Data(contentsOf: url) }
    }

    func unlock() async throws {
        guard !isUnlocked else { return }
        guard !isUnlocking else { throw GalleryVaultStorageError.authentication("The private vault is already unlocking.") }
        isUnlocking = true
        defer { isUnlocking = false }
        // Do not authenticate or reveal vault contents while old plaintext remains.
        try cleanupPlaintext()
        let expectedGeneration = generation
        let context = LAContext()
        var reason: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &reason) else {
            throw GalleryVaultStorageError.authentication(reason?.localizedDescription ?? "Set a device passcode to use the private vault.")
        }
        let allowed = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your private gallery")
        guard allowed, generation == expectedGeneration else { throw GalleryVaultStorageError.locked }
        let key = try Self.loadOrCreateKey(context: context, root: root)
        guard generation == expectedGeneration else { throw GalleryVaultStorageError.locked }
        let newSession = GalleryVaultSession(key: key)
        do {
            try Self.prepareDirectory(root)
            var rootValues = URLResourceValues()
            rootValues.isExcludedFromBackup = true
            var rootForValues = root
            try rootForValues.setResourceValues(rootValues)
            try Self.prepareDirectory(items)
            try Self.prepareDirectory(staging)
            try Self.syncDirectory(root)
            try Self.syncDirectory(root.deletingLastPathComponent())
            session = newSession
            let itemDirectory = items
            let stagingDirectory = staging
            let preloaded = await manifestPreload?.value
            manifestPreload = nil
            let manifestURL = root.appendingPathComponent("manifest.enc")
            // Complete protection can reject a preload while the headset is off.
            let cached = if let preloaded { preloaded } else {
                await Task.detached(priority: .userInitiated) { try? Data(contentsOf: manifestURL) }.value
            }
            let scan = try await Task.detached {
                // A staged item is never eligible for Photos deletion until its directory is committed.
                // Stale interrupted exports therefore contain no unique user data.
                if let entries = try? FileManager.default.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil) {
                    for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
                        try? FileManager.default.removeItem(at: entry)
                    }
                }
                return try Self.readRecords(in: itemDirectory, cached: cached, session: newSession)
            }.value
            guard generation == expectedGeneration else { throw GalleryVaultStorageError.locked }
            let loaded = scan.records
            recordsByID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            idsBySource = [:]
            for record in loaded { idsBySource[record.sourceIdentifier] = record.id }
            records = Self.sortedRecords(loaded)
            recordDates = scan.dates
            manifestDirty = scan.changed
            unreadableRecordCount = scan.unreadable
            isUnlocked = true
            saveManifestIfNeeded()
        } catch {
            newSession.revoke()
            if session === newSession { session = nil }
            throw error
        }
    }

    func lock() {
        generation = UUID()
        isUnlocked = false
        manifestTask?.cancel()
        manifestTask = nil
        session?.revoke()
        session = nil
        records.removeAll(keepingCapacity: false)
        unreadableRecordCount = 0
        recordsByID.removeAll(keepingCapacity: false)
        recordDates.removeAll(keepingCapacity: false)
        manifestDirty = false
        preloadManifest()
        idsBySource.removeAll(keepingCapacity: false)
        batchDepth = 0
        transferBatchChangedIDs.removeAll()
        recordsChanged = false
        mutationRevision = 0
        NotificationCenter.default.post(name: .galleryVaultWillLock, object: nil)
        try? cleanupPlaintext()
        NotificationCenter.default.post(name: .galleryVaultDidLock, object: nil)
    }

    func createItem(id: UUID) throws -> GalleryVaultStagingItem {
        guard let session, isUnlocked else { throw GalleryVaultStorageError.locked }
        let directory = staging.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path),
              !FileManager.default.fileExists(atPath: itemURL(id).path) else { throw GalleryVaultStorageError.duplicateItem }
        try Self.prepareDirectory(directory)
        try Self.syncDirectory(staging)
        return GalleryVaultStagingItem(id: id, directory: directory, session: session)
    }

    /// Create and sync the staging directory off the UI actor under the current vault session.
    func createItemForTransfer(id: UUID) async throws -> GalleryVaultStagingItem {
        guard let session, isUnlocked else { throw GalleryVaultStorageError.locked }
        let expectedGeneration = generation
        let directory = staging.appendingPathComponent(id.uuidString, isDirectory: true)
        let destination = itemURL(id)
        let stagingDirectory = staging
        let item = try await Task.detached(priority: .userInitiated) {
            try session.withKey { _ in
                guard !FileManager.default.fileExists(atPath: directory.path),
                      !FileManager.default.fileExists(atPath: destination.path) else {
                    throw GalleryVaultStorageError.duplicateItem
                }
                try Self.prepareDirectory(directory)
                try Self.syncDirectory(stagingDirectory)
                return GalleryVaultStagingItem(id: id, directory: directory, session: session)
            }
        }.value
        guard generation == expectedGeneration, isUnlocked, self.session === session else {
            await Task.detached { item.discard() }.value
            throw GalleryVaultStorageError.locked
        }
        return item
    }

    /// Seal and atomically publish a verified staging item off the UI actor while retaining a revocable session.
    func commitTransfer(_ record: GalleryVaultRecord, from item: GalleryVaultStagingItem,
                        sourceAlbums: [GalleryVaultAlbum]? = nil) async throws {
        guard let session, isUnlocked else { throw GalleryVaultStorageError.locked }
        guard record.id == item.id, item.belongs(to: session), record.state == .copiedAwaitingDeletion,
              !record.resources.isEmpty, Set(record.resources.map(\.id)).count == record.resources.count,
              item.verifiedResources() == Set(record.resources.map(\.id)) else {
            throw GalleryVaultStorageError.incompleteItem
        }
        let expectedGeneration = generation
        let itemDirectory = item.directory
        let destination = itemURL(record.id)
        let parent = items
        let state = TransferWriteState(record: record, sourceAlbums: sourceAlbums)
        try session.attachMutationState { state.clear() }
        defer { session.detachMutationState() }
        // Complete the encrypted journal and rename under the lease before indexing the record.
        let outcome: (Date?, Error?) = try await Task.detached(priority: .userInitiated) {
            try session.withKey { key in
                guard let record = state.record else { throw GalleryVaultStorageError.locked }
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw GalleryVaultStorageError.duplicateItem }
                if let sourceAlbums = state.sourceAlbums { try Self.writeSourceAlbums(sourceAlbums, in: itemDirectory, id: record.id, key: key) }
                try Self.writeRecord(record, in: itemDirectory, key: key)
                try Self.syncDirectory(itemDirectory)
                guard rename(itemDirectory.path, destination.path) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                let date = try? Self.recordDate(destination)
                do { try Self.syncDirectory(parent); return (date, nil) }
                catch { return (date, error) }
            }
        }.value
        guard generation == expectedGeneration, isUnlocked, self.session === session else { throw GalleryVaultStorageError.locked }
        // A renamed copy stays indexed even when its final directory sync failed.
        recordsByID[record.id] = record
        idsBySource[record.sourceIdentifier] = record.id
        recordDates[record.id] = outcome.0
        transferBatchChangedIDs.insert(record.id)
        manifestDirty = true
        publishChangesIfNeeded()
        if let error = outcome.1 { throw error }
    }

    func commit(_ record: GalleryVaultRecord, from item: GalleryVaultStagingItem, sourceAlbums: [GalleryVaultAlbum]? = nil) throws {
        guard let session, isUnlocked else { throw GalleryVaultStorageError.locked }
        guard record.id == item.id, item.belongs(to: session), record.state == .copiedAwaitingDeletion,
              !record.resources.isEmpty,
              Set(record.resources.map(\.id)).count == record.resources.count,
              item.verifiedResources() == Set(record.resources.map(\.id)) else {
            throw GalleryVaultStorageError.incompleteItem
        }
        try session.withKey { _ in () }
        guard !FileManager.default.fileExists(atPath: itemURL(record.id).path) else { throw GalleryVaultStorageError.duplicateItem }
        if let sourceAlbums { try Self.writeSourceAlbums(sourceAlbums, in: item.directory, id: record.id, session: session) }
        try Self.writeRecord(record, in: item.directory, session: session)
        try Self.syncDirectory(item.directory)
        // rename() on the same volume makes the item and its complete encrypted journal visible together.
        guard rename(item.directory.path, itemURL(record.id).path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: itemURL(record.id).path])
        }
        // A failed directory sync can leave the renamed copy visible in this session.
        // Index it as pending so retry verifies the same copy instead of duplicating it.
        recordsByID[record.id] = record
        idsBySource[record.sourceIdentifier] = record.id
        recordDates[record.id] = try? Self.recordDate(itemURL(record.id))
        manifestDirty = true
        publishChangesIfNeeded()
        try Self.syncDirectory(items)
    }

    var hasStoredItems: Bool {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("album-deletion.enc").path) { return true }
        do { return try !FileManager.default.contentsOfDirectory(at: items, includingPropertiesForKeys: nil).isEmpty }
        catch { return !Self.isMissingFile(error) }
    }

    func authoritativeRecords() async throws -> [GalleryVaultRecord] {
        guard let session, isUnlocked else { throw GalleryVaultStorageError.locked }
        let expectedGeneration = generation, directory = items
        let scan = try await Task.detached(priority: .userInitiated) {
            try Self.readRecords(in: directory, cached: nil, session: session)
        }.value
        guard generation == expectedGeneration, isUnlocked else { throw GalleryVaultStorageError.locked }
        guard scan.unreadable == 0 else { throw GalleryAlbumDeletionError.unreadable }
        return scan.records
    }

    func authoritativeRecord(id: UUID) throws -> GalleryVaultRecord? {
        guard let session, isUnlocked else { throw GalleryVaultStorageError.locked }
        do {
            let record = try Self.readRecord(in: itemURL(id), id: id, session: session)
            // A repaired record may have been skipped by the unlock scan.
            if recordsByID[id] == nil {
                recordsByID[id] = record
                idsBySource[record.sourceIdentifier] = id
                recordDates[id] = try? Self.recordDate(itemURL(id))
                unreadableRecordCount = max(0, unreadableRecordCount - 1)
                manifestDirty = true
                publishChangesIfNeeded()
            }
            return record
        }
        catch {
            if Self.isMissingFile(error), !FileManager.default.fileExists(atPath: itemURL(id).path) { return nil }
            throw error
        }
    }

    func readAlbumDeletion() throws -> GalleryVaultAlbumDeletion? {
        guard let session, isUnlocked else { throw GalleryVaultStorageError.locked }
        let data: Data
        do { data = try Data(contentsOf: root.appendingPathComponent("album-deletion.enc")) }
        catch { if Self.isMissingFile(error) { return nil }; throw error }
        return try session.withKey { key in
            try JSONDecoder().decode(GalleryVaultAlbumDeletion.self,
                from: AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key,
                    authenticating: Data("SVGAlbumDeletion1".utf8)))
        }
    }

    func writeAlbumDeletion(_ intent: GalleryVaultAlbumDeletion?) throws {
        guard let session, isUnlocked else { throw GalleryVaultStorageError.locked }
        let url = root.appendingPathComponent("album-deletion.enc")
        if let intent {
            let bytes = try session.withKey { key in
                try AES.GCM.seal(JSONEncoder().encode(intent), using: key,
                    authenticating: Data("SVGAlbumDeletion1".utf8)).combined
            }
            guard let bytes else { throw GalleryVaultStorageError.corruptRecord }
            try bytes.write(to: url, options: [.atomic, .completeFileProtection])
            try Self.syncFile(url)
            // Authenticate the durable intent before any Photos mutation.
            guard try readAlbumDeletion() == intent else { throw GalleryVaultStorageError.corruptRecord }
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try Self.syncDirectory(root)
    }

    func sourceAlbums(for record: GalleryVaultRecord) async throws -> [GalleryVaultAlbum] {
        (try await sourceVersions(for: [record]))[0].albums
    }

    func sourceVersions(for records: [GalleryVaultRecord]) async throws -> [GalleryVaultRecord] {
        guard let session, isUnlocked else { throw GalleryVaultStorageError.locked }
        let expectedGeneration = generation
        let directory = items
        let versions = try await Task.detached(priority: .userInitiated) {
            try records.map { record in
                let url = directory.appendingPathComponent(record.id.uuidString).appendingPathComponent("source-albums.enc")
                let data: Data
                do { data = try Data(contentsOf: url) }
                catch { if Self.isMissingFile(error) { return record }; throw error }
                do {
                    var source = record
                    source.albums = try session.withKey { key in
                        let decoded = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key,
                            authenticating: Data((record.id.uuidString + ".source-albums").utf8))
                        return try JSONDecoder().decode([GalleryVaultAlbum].self, from: decoded)
                    }
                    return source
                } catch let error as GalleryVaultStorageError { throw error }
                catch { throw GalleryVaultStorageError.corruptRecord }
            }
        }.value
        guard generation == expectedGeneration, isUnlocked else { throw GalleryVaultStorageError.locked }
        return versions
    }

    func setDestination(_ destination: GalleryVaultAlbum, sourceAlbumID: String?, for record: GalleryVaultRecord) async throws -> GalleryVaultRecord {
        let original = try await sourceAlbums(for: record)
        // Preserve the source version separately from the chosen restore memberships.
        var updated = record
        updated.albums = Self.destinationAlbums(original, destination: destination, sourceAlbumID: sourceAlbumID)
        try await updateTransfer(updated, sourceAlbums: original)
        return updated
    }

    nonisolated static func destinationAlbums(_ original: [GalleryVaultAlbum], destination: GalleryVaultAlbum, sourceAlbumID: String?) -> [GalleryVaultAlbum] {
        var albums = original.filter { $0.id != sourceAlbumID && $0.id != destination.id }
        albums.append(destination)
        return albums
    }

    /// Persist transfer journal updates off the UI actor and publish them only for the same unlocked session.
    func updateTransfer(_ record: GalleryVaultRecord, sourceAlbums: [GalleryVaultAlbum]? = nil) async throws {
        guard let session, isUnlocked else { throw GalleryVaultStorageError.locked }
        guard let previous = recordsByID[record.id] else { throw GalleryVaultStorageError.corruptRecord }
        let expectedGeneration = generation
        let directory = itemURL(record.id)
        let state = TransferWriteState(record: record, sourceAlbums: sourceAlbums)
        try session.attachMutationState { state.clear() }
        defer { session.detachMutationState() }
        // Write and sync the encrypted journal under a revocable lease before updating the index.
        let date = try await Task.detached(priority: .userInitiated) {
            try session.withKey { key in
                guard let record = state.record else { throw GalleryVaultStorageError.locked }
                if let sourceAlbums = state.sourceAlbums { try Self.writeSourceAlbums(sourceAlbums, in: directory, id: record.id, key: key) }
                try Self.writeRecord(record, in: directory, key: key)
                try Self.syncDirectory(directory)
                return try? Self.recordDate(directory)
            }
        }.value
        guard generation == expectedGeneration, isUnlocked, self.session === session else { throw GalleryVaultStorageError.locked }
        if previous.sourceIdentifier != record.sourceIdentifier { idsBySource.removeValue(forKey: previous.sourceIdentifier) }
        recordsByID[record.id] = record
        idsBySource[record.sourceIdentifier] = record.id
        recordDates[record.id] = date
        transferBatchChangedIDs.insert(record.id)
        manifestDirty = true
        publishChangesIfNeeded()
    }

    func update(_ record: GalleryVaultRecord) throws {
        guard let session, isUnlocked else { throw GalleryVaultStorageError.locked }
        guard let previous = recordsByID[record.id] else { throw GalleryVaultStorageError.corruptRecord }
        try Self.writeRecord(record, in: itemURL(record.id), session: session)
        try Self.syncDirectory(itemURL(record.id))
        if previous.sourceIdentifier != record.sourceIdentifier { idsBySource.removeValue(forKey: previous.sourceIdentifier) }
        recordsByID[record.id] = record
        idsBySource[record.sourceIdentifier] = record.id
        recordDates[record.id] = try? Self.recordDate(itemURL(record.id))
        if batchDepth > 0 { transferBatchChangedIDs.insert(record.id) }
        manifestDirty = true
        publishChangesIfNeeded()
    }

    func remove(id: UUID) throws {
        guard let session, isUnlocked else { throw GalleryVaultStorageError.locked }
        guard let record = recordsByID[id] else { throw GalleryVaultStorageError.corruptRecord }
        try session.removeThumbnails(recordID: id, urls: record.resources.map { thumbnailURL(id, $0.id) })
        try FileManager.default.removeItem(at: itemURL(id))
        try Self.syncDirectory(items)
        if let old = recordsByID.removeValue(forKey: id) { idsBySource.removeValue(forKey: old.sourceIdentifier) }
        recordDates.removeValue(forKey: id)
        if batchDepth > 0 { transferBatchChangedIDs.insert(id) }
        manifestDirty = true
        publishChangesIfNeeded()
    }

    // Apply a batch under a revocable session and publish only if its generation is current.
    func applyMutations(_ mutations: [GalleryVaultMutation]) async -> [GalleryVaultMutationResult] {
        guard let session, isUnlocked else {
            return mutations.map { .init(id: $0.id, error: GalleryVaultStorageError.locked) }
        }
        let expectedGeneration = generation
        let itemDirectory = items
        let stagingDirectory = staging
        let thumbnailDirectory = root.appendingPathComponent("thumbnails", isDirectory: true)
        let state = MutationBatchState(mutations: mutations, recordsByID: recordsByID,
            idsBySource: idsBySource, recordDates: recordDates)
        do { try session.attachMutationState { state.clear() } }
        catch { return mutations.map { .init(id: $0.id, error: GalleryVaultStorageError.locked) } }

        let mutationCount = mutations.count
        await Task.detached(priority: .userInitiated) {
            // Process each item independently so one storage error does not discard later outcomes.
            for index in 0..<mutationCount {
                if session.isRevoked { break }
                do {
                    try session.withKey { key in
                        let mutation = state.mutations[index]
                        let id = mutation.id
                        let directory = itemDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
                        var record = try Self.readRecord(in: directory, id: id, key: key)
                        let old = state.recordsByID[id]
                        guard record.state == .privateItem else { throw GalleryVaultTransferError.interruptedRestore }
                        var deleted = false
                        var itemChanged = false
                        var durabilityWarning: Error?

                        // Apply the requested mutation under the session lease and record any durability warning.
                        switch mutation {
                        case .recycle:
                            if !GalleryVaultRecycleBin.contains(record) {
                                record.albums.append(GalleryVaultRecycleBin.album)
                                try Self.writeRecord(record, in: directory, key: key)
                                do { try Self.syncDirectory(directory) } catch { durabilityWarning = GalleryVaultMutationWarning.directorySyncUnconfirmed }
                                itemChanged = true
                            }
                        case .putBack:
                            if GalleryVaultRecycleBin.contains(record) {
                                record.albums.removeAll { $0.id == GalleryVaultRecycleBin.id }
                                try Self.writeRecord(record, in: directory, key: key)
                                do { try Self.syncDirectory(directory) } catch { durabilityWarning = GalleryVaultMutationWarning.directorySyncUnconfirmed }
                                itemChanged = true
                            }
                        case .move(_, let sourceID, let destination):
                            guard !GalleryVaultRecycleBin.contains(record),
                                  destination.id != GalleryVaultRecycleBin.id,
                                  !GalleryRecycleBin.isRecycleBinTitle(destination.title) else {
                                throw GalleryVaultTransferError.invalidVaultDestination
                            }
                            if let sourceID, !record.albums.contains(where: { $0.id == sourceID }) {
                                throw NSError(domain: "GalleryVaultMove", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "This item is no longer in the source album."])
                            }
                            record.albums = Self.destinationAlbums(record.albums, destination: destination, sourceAlbumID: sourceID)
                            try Self.writeRecord(record, in: directory, key: key)
                            do { try Self.syncDirectory(directory) } catch { durabilityWarning = GalleryVaultMutationWarning.directorySyncUnconfirmed }
                            itemChanged = true
                        case .delete:
                            guard GalleryVaultRecycleBin.contains(record) else {
                                throw GalleryVaultTransferError.notInRecycleBin
                            }
                            try session.removeThumbnails(recordID: id,
                                urls: record.resources.map { thumbnailDirectory
                                    .appendingPathComponent("\(id.uuidString)-\($0.id.uuidString).enc") },
                                inMutationLease: key)
                            // Rename is the commit: a crash leaves a whole item or encrypted staging cleanup.
                            let discarded = stagingDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
                            guard rename(directory.path, discarded.path) == 0 else {
                                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                            }
                            do {
                                try Self.syncDirectory(itemDirectory)
                                try Self.syncDirectory(stagingDirectory)
                            } catch { durabilityWarning = GalleryVaultMutationWarning.directorySyncUnconfirmed }
                            do {
                                try FileManager.default.removeItem(at: discarded)
                                try Self.syncDirectory(stagingDirectory)
                            } catch { durabilityWarning = GalleryVaultMutationWarning.cleanupPending }
                            deleted = true
                            itemChanged = true

                        }

                        if deleted {
                            if let old { state.idsBySource.removeValue(forKey: old.sourceIdentifier) }
                            state.recordsByID.removeValue(forKey: id)
                            state.recordDates.removeValue(forKey: id)
                            if old == nil { state.repairedCount += 1 }
                        } else {
                            if let old, old.sourceIdentifier != record.sourceIdentifier {
                                state.idsBySource.removeValue(forKey: old.sourceIdentifier)
                            }
                            state.recordsByID[id] = record
                            state.idsBySource[record.sourceIdentifier] = id
                            if itemChanged || state.recordDates[id] == nil {
                                state.recordDates[id] = try? Self.recordDate(directory)
                            }
                            if old == nil { state.repairedCount += 1 }
                        }
                        state.changed = state.changed || itemChanged || old != record
                        state.outcomes.append(.init(id: id, error: nil, warning: durabilityWarning))
                    }
                } catch {
                    if session.isRevoked { break }
                    do {
                        try session.withKey { _ in
                            state.outcomes.append(.init(id: state.mutations[index].id, error: error, warning: nil))
                        }
                    } catch { break }
                }
            }
            guard !session.isRevoked else { return }
            try? session.withKey { key in
                guard state.changed else { return }
                let entries = state.recordsByID.values.compactMap { record in
                    state.recordDates[record.id].map { ManifestEntry(record: record, date: $0) }
                }
                state.sortedRecords = Self.sortedRecords(Array(state.recordsByID.values))
                if let plain = try? JSONEncoder().encode(entries) {
                    state.manifestCiphertext = try? AES.GCM.seal(plain, using: key,
                        authenticating: Self.manifestAAD).combined
                }
            }
        }.value

        guard isUnlocked, generation == expectedGeneration, self.session === session else {
            return mutations.map { .init(id: $0.id, error: GalleryVaultStorageError.locked) }
        }

        let output = MutationBatch(outcomes: state.outcomes,
            recordsByID: state.recordsByID, idsBySource: state.idsBySource,
            recordDates: state.recordDates, sortedRecords: state.sortedRecords,
            manifestCiphertext: state.manifestCiphertext,
            repairedCount: state.repairedCount, changed: state.changed)
        session.detachMutationState()
        guard output.changed else { return output.outcomes.map { .init(id: $0.id, error: $0.error) } }
        mutationRevision &+= 1
        recordsByID = output.recordsByID
        idsBySource = output.idsBySource
        recordDates = output.recordDates
        records = output.sortedRecords
        unreadableRecordCount = max(0, unreadableRecordCount - output.repairedCount)
        manifestDirty = true
        if let ciphertext = output.manifestCiphertext { saveManifestCiphertext(ciphertext) }
        return output.outcomes.map { .init(id: $0.id, error: $0.error, warning: $0.warning) }
    }

    func record(id: UUID) -> GalleryVaultRecord? { recordsByID[id] }
    func record(sourceIdentifier: String) -> GalleryVaultRecord? {
        idsBySource[sourceIdentifier].flatMap { recordsByID[$0] }
    }

    func beginBatch() {
        if batchDepth == 0 { transferBatchChangedIDs.removeAll() }
        batchDepth += 1
    }

    /// Sort and seal the completed transfer snapshot off the UI actor before publishing it.
    func finishTransferBatch() async -> Set<UUID> {
        guard batchDepth == 1, recordsChanged, let session, isUnlocked else {
            endBatch()
            return []
        }
        let expectedGeneration = generation
        let state = MutationBatchState(mutations: [], recordsByID: recordsByID,
            idsBySource: idsBySource, recordDates: recordDates)
        do { try session.attachMutationState { state.clear() } }
        catch { endBatch(); return [] }
        // Sort and encrypt the snapshot under the session so no plaintext batch survives lock.
        await Task.detached(priority: .userInitiated) {
            try? session.withKey { key in
                state.sortedRecords = Self.sortedRecords(Array(state.recordsByID.values))
                let entries = state.recordsByID.values.compactMap { record in
                    state.recordDates[record.id].map { ManifestEntry(record: record, date: $0) }
                }
                if let plain = try? JSONEncoder().encode(entries) {
                    state.manifestCiphertext = try? AES.GCM.seal(plain, using: key, authenticating: Self.manifestAAD).combined
                }
            }
        }.value
        guard generation == expectedGeneration, isUnlocked, self.session === session else { return [] }
        session.detachMutationState()
        batchDepth -= 1
        records = state.sortedRecords
        recordsChanged = false
        let changed = transferBatchChangedIDs
        transferBatchChangedIDs.removeAll()
        if let bytes = state.manifestCiphertext { saveManifestCiphertext(bytes) }
        return changed
    }
    func endBatch() {
        guard batchDepth > 0 else { return }
        batchDepth -= 1
        if batchDepth == 0, recordsChanged { publishChangesIfNeeded() }
    }

    private func publishChangesIfNeeded() {
        recordsChanged = true
        guard batchDepth == 0 else { return }
        records = Self.sortedRecords(Array(recordsByID.values))
        recordsChanged = false
        saveManifestIfNeeded()
    }

    private nonisolated static func sortedRecords(_ records: [GalleryVaultRecord]) -> [GalleryVaultRecord] {
        records.map { ($0.id.uuidString, $0) }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func saveManifestIfNeeded(preparedEntries: [ManifestEntry]? = nil) {
        guard manifestDirty, let session, isUnlocked else { return }
        manifestDirty = false
        let entries = preparedEntries ?? recordsByID.values.compactMap { record in
            recordDates[record.id].map { ManifestEntry(record: record, date: $0) }
        }
        let url = root.appendingPathComponent("manifest.enc")
        manifestTask?.cancel()
        manifestTask = Task.detached(priority: .utility) {
            // A failed or interrupted cache write only makes the next unlock scan the records.
            try? session.withKey { key in
                try Task.checkCancellation()
                let data = try JSONEncoder().encode(entries)
                let sealed = try AES.GCM.seal(data, using: key, authenticating: Self.manifestAAD)
                try Task.checkCancellation()
                guard let bytes = sealed.combined else { return }
                try bytes.write(to: url, options: [.atomic, .completeFileProtection])
            }
        }
    }

    /// Write the encrypted cache asynchronously so manifest persistence does not block mutations.
    private func saveManifestCiphertext(_ bytes: Data) {
        guard manifestDirty, isUnlocked else { return }
        manifestDirty = false
        let url = root.appendingPathComponent("manifest.enc")
        manifestTask?.cancel()
        manifestTask = Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()
                try bytes.write(to: url, options: [.atomic, .completeFileProtection])
            } catch { /* The manifest is only a cache; the item directory remains authoritative. */ }
        }
    }

    func thumbnail(recordID: UUID, resourceID: UUID) async throws -> Data? {
        guard let session, isUnlocked, recordsByID[recordID]?.resources.contains(where: { $0.id == resourceID }) == true else {
            throw GalleryVaultStorageError.locked
        }
        let expectedGeneration = generation
        let url = thumbnailURL(recordID, resourceID)
        let data = try await Task.detached(priority: .utility) {
            try session.withKey { key -> Data? in
                guard let bytes = try? Data(contentsOf: url) else { return nil }
                return try? AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key,
                    authenticating: Data(url.lastPathComponent.utf8))
            }
        }.value
        guard generation == expectedGeneration, isUnlocked else { throw GalleryVaultStorageError.locked }
        return data
    }

    func cacheThumbnail(_ data: Data, recordID: UUID, resourceID: UUID) async {
        guard let session, isUnlocked, data.count <= 128 * 1024 else { return }
        let url = thumbnailURL(recordID, resourceID)
        try? await Task.detached(priority: .utility) {
            try session.storeThumbnail(data, recordID: recordID, at: url)
        }.value
    }

    private func thumbnailURL(_ recordID: UUID, _ resourceID: UUID) -> URL {
        root.appendingPathComponent("thumbnails", isDirectory: true)
            .appendingPathComponent(recordID.uuidString + "-" + resourceID.uuidString + ".enc")
    }

    /// The encrypted file is an upper bound for the temporary decrypted lease.
    func speculativeResourceSpace(recordID: UUID, resourceID: UUID) async throws -> (Int64, Int64) {
        guard isUnlocked, recordsByID[recordID]?.resources.contains(where: { $0.id == resourceID }) == true else {
            throw GalleryVaultStorageError.locked
        }
        let expectedGeneration = generation
        let input = itemURL(recordID).appendingPathComponent(resourceID.uuidString + ".bin")
        let result = try await Task.detached(priority: .utility) {
            let attributes = try FileManager.default.attributesOfItem(atPath: input.path)
            guard let bytes = (attributes[.size] as? NSNumber)?.int64Value,
                  let available = try input.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage else {
                throw GalleryVaultStorageError.incompleteItem
            }
            return (bytes, available)
        }.value
        guard isUnlocked, generation == expectedGeneration else { throw GalleryVaultStorageError.locked }
        return result
    }

    func decryptResource(recordID: UUID, resourceID: UUID) async throws -> URL {
        guard let session, isUnlocked, let resource = recordsByID[recordID]?.resources.first(where: { $0.id == resourceID }) else {
            throw GalleryVaultStorageError.locked
        }
        let expectedGeneration = generation
        try Self.prepareDirectory(plaintext)
        let suffix = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension
            .flatMap { $0.range(of: "^[A-Za-z0-9]{1,12}$", options: .regularExpression) == nil ? nil : $0 }
        let output = plaintext.appendingPathComponent(UUID().uuidString + (suffix.map { "." + $0 } ?? ""), isDirectory: false)
        let input = itemURL(recordID).appendingPathComponent(resourceID.uuidString + ".bin")
        do {
            try await Task.detached {
                let handle = try GalleryVaultCipher.createProtectedFile(output)
                defer { try? handle.close() }
                try GalleryVaultCipher.decrypt(input, to: handle, id: resourceID, session: session)
                try handle.synchronize()
            }.value
            guard generation == expectedGeneration, isUnlocked else { throw GalleryVaultStorageError.locked }
            return output
        } catch {
            releasePlaintext(output)
            throw error
        }
    }

    /// Recovery must not assume a previously renamed directory reached durable storage.
    @discardableResult
    func verifyCommitted(id: UUID) async throws -> GalleryVaultRecord {
        guard let session, isUnlocked else { throw GalleryVaultStorageError.locked }
        let expectedGeneration = generation
        let directory = itemURL(id)
        let itemParent = items
        let (record, date) = try await Task.detached {
            let record = try Self.readRecord(in: directory, id: id, session: session)
            guard !record.resources.isEmpty, Set(record.resources.map(\.id)).count == record.resources.count else {
                throw GalleryVaultStorageError.incompleteItem
            }
            for resource in record.resources {
                let path = directory.appendingPathComponent(resource.id.uuidString + ".bin")
                guard try GalleryVaultCipher.decrypt(path, to: nil, id: resource.id, session: session) > 0 else {
                    throw GalleryVaultStorageError.incompleteItem
                }
                try Self.syncFile(path)
            }
            try Self.syncFile(directory.appendingPathComponent("record.enc"))
            try Self.syncDirectory(directory)
            try Self.syncDirectory(itemParent)
            try session.withKey { _ in () }
            return (record, try? Self.recordDate(directory))
        }.value
        guard generation == expectedGeneration, isUnlocked else { throw GalleryVaultStorageError.locked }
        if let old = recordsByID[id], old.sourceIdentifier != record.sourceIdentifier {
            idsBySource.removeValue(forKey: old.sourceIdentifier)
        }
        if recordsByID[id] != record {
            recordDates[id] = date
            transferBatchChangedIDs.insert(id)
            manifestDirty = true
        }
        recordsByID[id] = record
        idsBySource[record.sourceIdentifier] = id
        publishChangesIfNeeded()
        return record
    }

    @discardableResult
    func releasePlaintext(_ url: URL) -> Bool {
        guard url.deletingLastPathComponent().standardizedFileURL == plaintext.standardizedFileURL else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        }
        catch {
            if Self.isMissingFile(error) { return true }
            cleanupWarning = Self.cleanupMessage
            return false
        }
    }

    func discardPlaintext() { try? cleanupPlaintext() }

    private static let cleanupMessage = "Some temporary private files could not be removed. Restart the app or device and try again."

    private func cleanupPlaintext() throws {
        do {
            try FileManager.default.removeItem(at: plaintext)
            cleanupWarning = nil
        } catch {
            if Self.isMissingFile(error) {
                cleanupWarning = nil
                return
            }
            cleanupWarning = Self.cleanupMessage
            throw GalleryVaultStorageError.io(Self.cleanupMessage)
        }
    }

    private nonisolated static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError { return true }
        return error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    }

    private func itemURL(_ id: UUID) -> URL { items.appendingPathComponent(id.uuidString, isDirectory: true) }

    private nonisolated static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
    }

    private nonisolated static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path]) }
        defer { _ = close(fd) }
        guard fsync(fd) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path]) }
    }

    private nonisolated static func syncFile(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private nonisolated static func writeSourceAlbums(_ albums: [GalleryVaultAlbum], in directory: URL, id: UUID, session: GalleryVaultSession) throws {
        try session.withKey { key in try writeSourceAlbums(albums, in: directory, id: id, key: key) }
    }

    private nonisolated static func writeSourceAlbums(_ albums: [GalleryVaultAlbum], in directory: URL, id: UUID, key: SymmetricKey) throws {
        let aad = Data((id.uuidString + ".source-albums").utf8)
        guard let bytes = try AES.GCM.seal(JSONEncoder().encode(albums), using: key, authenticating: aad).combined else {
            throw GalleryVaultStorageError.corruptRecord
        }
        let url = directory.appendingPathComponent("source-albums.enc")
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        try syncFile(url)
        let stored = try Data(contentsOf: url)
        let verified = try JSONDecoder().decode([GalleryVaultAlbum].self,
            from: AES.GCM.open(AES.GCM.SealedBox(combined: stored), using: key, authenticating: aad))
        guard verified == albums else { throw GalleryVaultStorageError.corruptRecord }
        try syncDirectory(directory)
    }

    private nonisolated static func writeRecord(_ record: GalleryVaultRecord, in directory: URL, session: GalleryVaultSession) throws {
        try session.withKey { key in try writeRecord(record, in: directory, key: key) }
    }

    private nonisolated static func writeRecord(_ record: GalleryVaultRecord, in directory: URL, key: SymmetricKey) throws {
        let data = try JSONEncoder().encode(record)
        let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(record.id.uuidString.utf8)).combined
        guard let sealed else { throw GalleryVaultStorageError.corruptRecord }
        let temp = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        let destination = directory.appendingPathComponent("record.enc")
        defer { try? FileManager.default.removeItem(at: temp) }
        try sealed.write(to: temp, options: [.completeFileProtection])
        let handle = try FileHandle(forWritingTo: temp)
        try handle.synchronize()
        try handle.close()
        let stored = try Data(contentsOf: temp)
        let box = try AES.GCM.SealedBox(combined: stored)
        let bytes = try AES.GCM.open(box, using: key, authenticating: Data(record.id.uuidString.utf8))
        let verified = try JSONDecoder().decode(GalleryVaultRecord.self, from: bytes)
        guard verified == record else { throw GalleryVaultStorageError.corruptRecord }
        guard rename(temp.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
        }
    }

    private nonisolated static func recordDate(_ directory: URL) throws -> Date {
        guard let date = try FileManager.default.attributesOfItem(atPath: directory.path)[.modificationDate] as? Date else {
            throw GalleryVaultStorageError.corruptRecord
        }
        return date
    }

    private nonisolated static func readRecords(in directory: URL, cached: Data?, session: GalleryVaultSession) throws
        -> (records: [GalleryVaultRecord], dates: [UUID: Date], unreadable: Int, changed: Bool) {
        var cache: [UUID: ManifestEntry] = [:]
        var validCache = false
        if let cached, let entries = try? session.withKey({ key in
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: cached), using: key, authenticating: manifestAAD)
            return try JSONDecoder().decode([ManifestEntry].self, from: data)
        }) {
            validCache = true
            for entry in entries { cache[entry.record.id] = entry }
        }
        let entries = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])
        var records: [GalleryVaultRecord] = []
        records.reserveCapacity(entries.count)
        var dates: [UUID: Date] = [:]
        var unreadable = 0
        var changed = !validCache || cache.count != entries.count
        for entry in entries {
            try session.withKey { _ in () }
            guard let id = UUID(uuidString: entry.lastPathComponent) else {
                unreadable += 1
                continue
            }
            do {
                let date = try entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                if let date, let existing = cache[id], existing.date == date {
                    records.append(existing.record)
                    dates[id] = date
                } else {
                    records.append(try readRecord(in: entry, id: id, session: session))
                    dates[id] = date
                    changed = true
                }
            } catch GalleryVaultStorageError.locked {
                throw GalleryVaultStorageError.locked
            } catch {
                // Preserve the damaged entry for recovery; it is never eligible for deletion.
                unreadable += 1
                changed = true
            }
        }
        return (records, dates, unreadable, changed)
    }

    private nonisolated static func readRecord(in directory: URL, id: UUID, session: GalleryVaultSession) throws -> GalleryVaultRecord {
        try session.withKey { key in try readRecord(in: directory, id: id, key: key) }
    }

    private nonisolated static func readRecord(in directory: URL, id: UUID, key: SymmetricKey) throws -> GalleryVaultRecord {
        let bytes = try Data(contentsOf: directory.appendingPathComponent("record.enc"))
        do {
            let box = try AES.GCM.SealedBox(combined: bytes)
            let data = try AES.GCM.open(box, using: key, authenticating: Data(id.uuidString.utf8))
            let record = try JSONDecoder().decode(GalleryVaultRecord.self, from: data)
            guard record.id == id else { throw GalleryVaultStorageError.corruptRecord }
            return record
        } catch { throw GalleryVaultStorageError.corruptRecord }
    }

    private static func loadOrCreateKey(context: LAContext, root: URL) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true, kSecUseAuthenticationContext as String: context]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else {
            throw GalleryVaultStorageError.authentication("Unable to unlock the private vault (\(status)).")
        }
        // Never replace the only key for an existing vault, even after restore or corruption.
        if FileManager.default.fileExists(atPath: root.path) { throw GalleryVaultStorageError.keyUnavailable }
        var random = Data(count: 32)
        guard random.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else {
            throw GalleryVaultStorageError.io("Unable to create a secure vault key.")
        }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .userPresence, &error) else {
            throw GalleryVaultStorageError.authentication("Unable to protect the vault key.")
        }
        let insert: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessControl as String: access, kSecValueData as String: random,
            kSecUseAuthenticationContext as String: context]
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GalleryVaultStorageError.authentication("Unable to save the vault key (\(addStatus)).")
        }
        return SymmetricKey(data: random)
    }
}
