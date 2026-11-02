
@main struct VaultStorageCoreTests {
    static func expectFailure(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { print("PASS \(name): \(error)"); return }
        throw NSError(domain: "expected failure: \(name)", code: 1)
    }

    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("svg-vault-test-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let session = GalleryVaultSession(key: key)
        let sourceID = UUID()
        let cipher = directory.appendingPathComponent("encrypted.bin")
        let data = Data((0..<(2 * 1024 * 1024 + 333)).map { UInt8($0 % 251) })
        let writer = try GalleryVaultResourceWriter(id: sourceID, url: cipher, session: session)
        try writer.append(data.subdata(in: 0..<1333))
        try writer.append(data.subdata(in: 1333..<data.count))
        try writer.finish()
        precondition(writer.isVerified)
        let result = directory.appendingPathComponent("restored.bin")
        fm.createFile(atPath: result.path, contents: nil)
        let sink = try FileHandle(forWritingTo: result)
        try GalleryVaultCipher.decrypt(cipher, to: sink, id: sourceID, session: session)
        try sink.close()
        let roundTrip = try Data(contentsOf: result)
        precondition(roundTrip == data)
        print("PASS streamed 2 MiB resource, split input and full verify")
        let original = try Data(contentsOf: cipher)
        let altered = directory.appendingPathComponent("altered.bin")
        var bytes = original; bytes[bytes.count / 2] ^= 1
        try bytes.write(to: altered)
        try expectFailure("tamper", { try GalleryVaultCipher.decrypt(altered, to: nil, id: sourceID, session: session) })
        try original.dropLast().write(to: altered)
        try expectFailure("truncated final frame", { try GalleryVaultCipher.decrypt(altered, to: nil, id: sourceID, session: session) })
        try (original + Data([5])).write(to: altered)
        try expectFailure("trailing data", { try GalleryVaultCipher.decrypt(altered, to: nil, id: sourceID, session: session) })
        let header = GalleryVaultCipher.magic.count
        let frameSize = 4 + GalleryVaultCipher.chunkSize + 28
        let reordered = original.subdata(in: 0..<header)
            + original.subdata(in: header + frameSize..<header + 2 * frameSize)
            + original.subdata(in: header..<header + frameSize)
            + original.subdata(in: header + 2 * frameSize..<original.count)
        try reordered.write(to: altered)
        try expectFailure("reordered chunks", { try GalleryVaultCipher.decrypt(altered, to: nil, id: sourceID, session: session) })
        try expectFailure("wrong key", { try GalleryVaultCipher.decrypt(cipher, to: nil, id: sourceID, session: GalleryVaultSession(key: SymmetricKey(size: .bits256))) })
        try expectFailure("wrong resource ID", { try GalleryVaultCipher.decrypt(cipher, to: nil, id: UUID(), session: session) })
        let empty = try GalleryVaultResourceWriter(id: UUID(), url: directory.appendingPathComponent("empty.bin"), session: session)
        try expectFailure("empty resource", { try empty.finish() })
        precondition(!empty.isVerified)
        let unfinished = try GalleryVaultResourceWriter(id: UUID(), url: directory.appendingPathComponent("unfinished.bin"), session: session)
        try unfinished.append(Data("private".utf8))
        session.revoke()
        try expectFailure("lock during in-flight write", { try unfinished.finish() })
        precondition(!unfinished.isVerified)
        try expectFailure("lock during read", { try GalleryVaultCipher.decrypt(cipher, to: nil, id: sourceID, session: session) })
        print("ALL STORAGE CORE CHECKS PASSED")
    }
}
