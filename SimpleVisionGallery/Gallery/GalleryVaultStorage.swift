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

/// Holding this lock through each cryptographic operation makes lock() a key revocation barrier.
nonisolated final class GalleryVaultSession: @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?

    init(key: SymmetricKey) { self.key = key }

    func withKey<T>(_ body: (SymmetricKey) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let key else { throw GalleryVaultStorageError.locked }
        return try body(key)
    }

    func revoke() {
        lock.lock()
        key = nil
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
    @Published private(set) var unreadableRecordCount = 0
    @Published private(set) var cleanupWarning: String?
    private var recordsByID: [UUID: GalleryVaultRecord] = [:]
    private var idsBySource: [String: UUID] = [:]
    private var batchDepth = 0
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
            let scan = try await Task.detached {
                // A staged item is never eligible for Photos deletion until its directory is committed.
                // Stale interrupted exports therefore contain no unique user data.
                if let entries = try? FileManager.default.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil) {
                    for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
                        try? FileManager.default.removeItem(at: entry)
                    }
                }
                return try Self.readRecords(in: itemDirectory, session: newSession)
            }.value
            guard generation == expectedGeneration else { throw GalleryVaultStorageError.locked }
            let loaded = scan.records
            recordsByID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            idsBySource = [:]
            for record in loaded { idsBySource[record.sourceIdentifier] = record.id }
            records = loaded.sorted { $0.id.uuidString < $1.id.uuidString }
            unreadableRecordCount = scan.unreadable
            isUnlocked = true
        } catch {
            newSession.revoke()
            if session === newSession { session = nil }
            throw error
        }
    }

    func lock() {
        generation = UUID()
        isUnlocked = false
        session?.revoke()
        session = nil
        records.removeAll(keepingCapacity: false)
        unreadableRecordCount = 0
        recordsByID.removeAll(keepingCapacity: false)
        idsBySource.removeAll(keepingCapacity: false)
        batchDepth = 0
        recordsChanged = false
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

    func commit(_ record: GalleryVaultRecord, from item: GalleryVaultStagingItem) throws {
        guard let session, isUnlocked else { throw GalleryVaultStorageError.locked }
        guard record.id == item.id, item.belongs(to: session), record.state == .copiedAwaitingDeletion,
              !record.resources.isEmpty,
              Set(record.resources.map(\.id)).count == record.resources.count,
              item.verifiedResources() == Set(record.resources.map(\.id)) else {
            throw GalleryVaultStorageError.incompleteItem
        }
        try session.withKey { _ in () }
        guard !FileManager.default.fileExists(atPath: itemURL(record.id).path) else { throw GalleryVaultStorageError.duplicateItem }
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
        publishChangesIfNeeded()
        try Self.syncDirectory(items)
    }

    func update(_ record: GalleryVaultRecord) throws {
        guard let session, isUnlocked else { throw GalleryVaultStorageError.locked }
        guard let previous = recordsByID[record.id] else { throw GalleryVaultStorageError.corruptRecord }
        try Self.writeRecord(record, in: itemURL(record.id), session: session)
        try Self.syncDirectory(itemURL(record.id))
        if previous.sourceIdentifier != record.sourceIdentifier { idsBySource.removeValue(forKey: previous.sourceIdentifier) }
        recordsByID[record.id] = record
        idsBySource[record.sourceIdentifier] = record.id
        publishChangesIfNeeded()
    }

    func remove(id: UUID) throws {
        guard let session, isUnlocked else { throw GalleryVaultStorageError.locked }
        try session.withKey { _ in () }
        try FileManager.default.removeItem(at: itemURL(id))
        try Self.syncDirectory(items)
        if let old = recordsByID.removeValue(forKey: id) { idsBySource.removeValue(forKey: old.sourceIdentifier) }
        publishChangesIfNeeded()
    }

    func record(id: UUID) -> GalleryVaultRecord? { recordsByID[id] }
    func record(sourceIdentifier: String) -> GalleryVaultRecord? {
        idsBySource[sourceIdentifier].flatMap { recordsByID[$0] }
    }

    func beginBatch() { batchDepth += 1 }
    func endBatch() {
        guard batchDepth > 0 else { return }
        batchDepth -= 1
        if batchDepth == 0, recordsChanged { publishChangesIfNeeded() }
    }

    private func publishChangesIfNeeded() {
        recordsChanged = true
        guard batchDepth == 0 else { return }
        records = recordsByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        recordsChanged = false
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
        let record = try await Task.detached {
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
            return record
        }.value
        guard generation == expectedGeneration, isUnlocked else { throw GalleryVaultStorageError.locked }
        recordsByID[id] = record
        idsBySource[record.sourceIdentifier] = id
        publishChangesIfNeeded()
        return record
    }

    func releasePlaintext(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == plaintext.standardizedFileURL else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch {
            if !Self.isMissingFile(error) { cleanupWarning = Self.cleanupMessage }
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

    private nonisolated static func writeRecord(_ record: GalleryVaultRecord, in directory: URL, session: GalleryVaultSession) throws {
        let data = try JSONEncoder().encode(record)
        let sealed = try session.withKey { key in
            try AES.GCM.seal(data, using: key, authenticating: Data(record.id.uuidString.utf8)).combined
        }
        guard let sealed else { throw GalleryVaultStorageError.corruptRecord }
        let temp = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        let destination = directory.appendingPathComponent("record.enc")
        defer { try? FileManager.default.removeItem(at: temp) }
        try sealed.write(to: temp, options: [.completeFileProtection])
        let handle = try FileHandle(forWritingTo: temp)
        try handle.synchronize()
        try handle.close()
        let stored = try Data(contentsOf: temp)
        let verified = try session.withKey { key in
            let box = try AES.GCM.SealedBox(combined: stored)
            let bytes = try AES.GCM.open(box, using: key, authenticating: Data(record.id.uuidString.utf8))
            return try JSONDecoder().decode(GalleryVaultRecord.self, from: bytes)
        }
        guard verified == record else { throw GalleryVaultStorageError.corruptRecord }
        guard rename(temp.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
        }
    }

    private nonisolated static func readRecords(in directory: URL, session: GalleryVaultSession) throws -> (records: [GalleryVaultRecord], unreadable: Int) {
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var records: [GalleryVaultRecord] = []
        var unreadable = 0
        for entry in entries {
            try session.withKey { _ in () }
            guard let id = UUID(uuidString: entry.lastPathComponent) else {
                unreadable += 1
                continue
            }
            do {
                records.append(try readRecord(in: entry, id: id, session: session))
            } catch GalleryVaultStorageError.locked {
                throw GalleryVaultStorageError.locked
            } catch {
                // Preserve the damaged entry for recovery; it is never eligible for deletion.
                unreadable += 1
            }
        }
        return (records, unreadable)
    }

    private nonisolated static func readRecord(in directory: URL, id: UUID, session: GalleryVaultSession) throws -> GalleryVaultRecord {
        let bytes = try Data(contentsOf: directory.appendingPathComponent("record.enc"))
        do {
            let record = try session.withKey { key in
                let box = try AES.GCM.SealedBox(combined: bytes)
                let data = try AES.GCM.open(box, using: key, authenticating: Data(id.uuidString.utf8))
                return try JSONDecoder().decode(GalleryVaultRecord.self, from: data)
            }
            guard record.id == id else { throw GalleryVaultStorageError.corruptRecord }
            return record
        } catch GalleryVaultStorageError.locked { throw GalleryVaultStorageError.locked }
        catch { throw GalleryVaultStorageError.corruptRecord }
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
