import AVFoundation
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A write-only encrypted queue. The vault key never leaves the containing app.
nonisolated enum GalleryVaultInbox {
    static let group = "group.com.llucid.simplevisiongallery"
    private static let magic = Data("SVGSHARE1".utf8)
    private static let chunkSize = 512 * 1024
    private static let keyInfo = Data("SimpleVisionGallery vault share key v1".utf8)

    struct Input: Sendable {
        let url: URL
        let filename: String
        let typeIdentifier: String
    }

    struct Metadata: Codable, Sendable {
        let id: UUID
        let filename: String
        let typeIdentifier: String
        let width: Int
        let height: Int
        let duration: Double
    }

    enum InboxError: LocalizedError {
        case unavailable, incompatibleKey, damaged, empty
        case importFailures(Int, String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "Open Gallery and unlock Private Vault once before sharing to it."
            case .incompatibleKey: "The queued vault shares belong to a different vault key. They were kept."
            case .damaged: "A queued vault share could not be authenticated. It was kept."
            case .empty: "The shared file is empty."
            case let .importFailures(count, detail): "\(count) shared item\(count == 1 ? "" : "s") could not be imported. \(detail)"
            }
        }
    }

    static func container() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw InboxError.unavailable
        }
        return url.appendingPathComponent("VaultInbox", isDirectory: true)
    }

    static func privateKey(vaultKey: SymmetricKey) throws -> Curve25519.KeyAgreement.PrivateKey {
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: vaultKey,
            salt: Data("SVG intake key".utf8), info: keyInfo, outputByteCount: 32)
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: derived.withUnsafeBytes { Data($0) })
    }

    static func publishPublicKey(_ key: Data, in folder: URL? = nil) throws {
        let folder = try folder ?? container()
        #if os(visionOS)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        #else
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #endif
        var protectedFolder = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedFolder.setResourceValues(values)
        let url = folder.appendingPathComponent("public-key")
        if let existing = try? Data(contentsOf: url), existing != key {
            // Never strand queued ciphertext by silently rotating its recipient key.
            if try batchFiles(in: folder).contains(where: { !$0.isEmpty }) { throw InboxError.incompatibleKey }
        }
        #if os(visionOS)
        try key.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try key.write(to: url, options: .atomic)
        #endif
    }

    static func availablePublicKey() throws -> Data {
        try availablePublicKey(in: container())
    }

    static func availablePublicKey(in folder: URL) throws -> Data {
        guard let key = try? Data(contentsOf: folder.appendingPathComponent("public-key")),
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: key)) != nil else {
            throw InboxError.unavailable
        }
        return key
    }

    /// Returns false when the batch was published but its parent-directory sync was not confirmed.
    @discardableResult static func save(items: [Input]) async throws -> Bool {
        try await save(items: items, in: container())
    }

    @discardableResult static func save(items: [Input], in folder: URL) async throws -> Bool {
        guard !items.isEmpty else { throw InboxError.empty }
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: availablePublicKey(in: folder))
        let lease = try GalleryLeasedStaging.create(in: folder, prefix: ".staging-")
        let staging = lease.directory
        let marker = GalleryLeasedStaging.marker(for: staging)
        let batchID = String(staging.lastPathComponent.dropFirst(".staging-".count))
        let destination = folder.appendingPathComponent("batch-" + batchID, isDirectory: true)
        defer { try? lease.lease.close() }
        do {
            for item in items {
                try Task<Never, Never>.checkCancellation()
                let id = UUID()
                let metadata = try await inspect(item, id: id)
                try encrypt(item.url, metadata: metadata, recipient: publicKey,
                    to: staging.appendingPathComponent(id.uuidString + ".vaultshare"))
            }
            try syncDirectory(staging)
            guard rename(staging.path, destination.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            try? FileManager.default.removeItem(at: marker)
            // Once rename succeeds the batch exists: never report it as retryable and duplicate it.
            do { try syncDirectory(folder); return true } catch { return false }
        } catch {
            do {
                try FileManager.default.removeItem(at: staging)
                try? FileManager.default.removeItem(at: marker)
            } catch { } // Keep the marker if protected-data cleanup must wait for unlock.
            throw error
        }
    }

    private static func inspect(_ item: Input, id: UUID) async throws -> Metadata {
        var width = 0, height = 0
        var duration = 0.0
        if let type = UTType(item.typeIdentifier), type.conforms(to: .image),
           let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            if let orientation = props[kCGImagePropertyOrientation] as? Int, [5, 6, 7, 8].contains(orientation) {
                swap(&width, &height)
            }
        } else if let type = UTType(item.typeIdentifier), type.conforms(to: .movie) {
            let asset = AVURLAsset(url: item.url)
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let size = try await track.load(.naturalSize).applying(track.load(.preferredTransform))
                if size.width.isFinite && size.height.isFinite && abs(size.width) < 1_000_000 && abs(size.height) < 1_000_000 {
                    width = Int(abs(size.width).rounded())
                    height = Int(abs(size.height).rounded())
                }
            }
            let seconds = try await asset.load(.duration).seconds
            if seconds.isFinite && seconds >= 0 { duration = seconds }
        }
        return Metadata(id: id, filename: (item.filename as NSString).lastPathComponent,
            typeIdentifier: item.typeIdentifier, width: width, height: height, duration: duration)
    }

    private static func sharedKey(privateKey: Curve25519.KeyAgreement.PrivateKey,
                                  publicKey: Curve25519.KeyAgreement.PublicKey, id: UUID) throws -> SymmetricKey {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(id.uuidString.utf8),
            sharedInfo: keyInfo, outputByteCount: 32)
    }

    private static func aad(id: UUID, index: UInt64, size: UInt32) -> Data {
        var output = Data(id.uuidString.utf8)
        var number = index.bigEndian, length = size.bigEndian
        withUnsafeBytes(of: &number) { output.append(contentsOf: $0) }
        withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
        return output
    }

    private static func writeFrame(_ bytes: Data, id: UUID, index: UInt64, key: SymmetricKey, to file: FileHandle) throws {
        let size = UInt32(bytes.count)
        var prefix = size.bigEndian
        try withUnsafeBytes(of: &prefix) { try file.write(contentsOf: Data($0)) }
        guard let sealed = try AES.GCM.seal(bytes, using: key, authenticating: aad(id: id, index: index, size: size)).combined else {
            throw InboxError.damaged
        }
        try file.write(contentsOf: sealed)
    }

    private static func encrypt(_ source: URL, metadata: Metadata, recipient: Curve25519.KeyAgreement.PublicKey, to target: URL) throws {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let key = try sharedKey(privateKey: ephemeral, publicKey: recipient, id: metadata.id)
        let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close(); try? output.close() }
        #if os(visionOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: target.path)
        #endif
        try output.write(contentsOf: magic)
        try output.write(contentsOf: ephemeral.publicKey.rawRepresentation)
        let encoded = try JSONEncoder().encode(metadata)
        guard !encoded.isEmpty && encoded.count <= 16384 else { throw InboxError.damaged }
        try writeFrame(encoded, id: metadata.id, index: 0, key: key, to: output)
        var index: UInt64 = 1, total: UInt64 = 0
        while let bytes = try input.read(upToCount: chunkSize), !bytes.isEmpty {
            try Task<Never, Never>.checkCancellation()
            try writeFrame(bytes, id: metadata.id, index: index, key: key, to: output)
            total += UInt64(bytes.count)
            index += 1
        }
        guard total > 0 else { throw InboxError.empty }
        try writeFrame(Data(), id: metadata.id, index: index, key: key, to: output)
        try output.synchronize()
    }

    static func batchFiles(in folder: URL? = nil) throws -> [[URL]] {
        let folder = try folder ?? container()
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        try GalleryLeasedStaging.removeAbandoned(in: folder, prefix: ".staging-")
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("batch-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { batch in
                try FileManager.default.contentsOfDirectory(at: batch, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "vaultshare" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
    }

    static func read(_ url: URL, privateKey: () throws -> Curve25519.KeyAgreement.PrivateKey,
                     metadata: (Metadata) throws -> Void, append: (Data) throws -> Void) throws {
        guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { throw InboxError.damaged }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try readExactly(magic.count, file) == magic else { throw InboxError.damaged }
        let sender = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: readExactly(32, file))
        var index: UInt64 = 0, total: UInt64 = 0
        while true {
            let length = try readExactly(4, file).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length <= chunkSize, index != 0 || (length > 0 && length <= 16384) else { throw InboxError.damaged }
            let encoded = try readExactly(Int(length) + 28, file)
            let key = try sharedKey(privateKey: privateKey(), publicKey: sender, id: id)
            let bytes: Data
            do { bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: encoded), using: key,
                authenticating: aad(id: id, index: index, size: length)) }
            catch { throw InboxError.damaged }
            if index == 0 {
                let value = try JSONDecoder().decode(Metadata.self, from: bytes)
                guard value.id == id, !["", ".", "..", "/"].contains(value.filename),
                      value.width >= 0, value.width < 1_000_000, value.height >= 0, value.height < 1_000_000,
                      value.duration.isFinite, value.duration >= 0,
                      (value.filename as NSString).lastPathComponent == value.filename,
                      let type = UTType(value.typeIdentifier), type.conforms(to: .image) || type.conforms(to: .movie)
                else { throw InboxError.damaged }
                try metadata(value)
            } else if length == 0 {
                guard total > 0, (try file.read(upToCount: 1) ?? Data()).isEmpty else { throw InboxError.damaged }
                return
            } else {
                try append(bytes)
                total += UInt64(bytes.count)
            }
            guard index < UInt64.max else { throw InboxError.damaged }
            index += 1
        }
    }

    private static func readExactly(_ count: Int, _ file: FileHandle) throws -> Data {
        var output = Data()
        while output.count < count {
            guard let part = try file.read(upToCount: count - output.count), !part.isEmpty else { throw InboxError.damaged }
            output.append(part)
        }
        return output
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
