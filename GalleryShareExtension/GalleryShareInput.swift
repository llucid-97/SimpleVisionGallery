import Darwin
import Foundation
import UniformTypeIdentifiers

struct StagedShare: Sendable {
    let url: URL
    let type: UTType
    let filename: String
}

enum GalleryShareInput {
    static func preferredType(for provider: NSItemProvider) -> UTType? {
        let types = provider.registeredTypeIdentifiers
            .compactMap { UTType($0) }
            .filter { $0.conforms(to: .image) || $0.conforms(to: .movie) }
        return types.first { $0 != .image && $0 != .movie } ?? types.first
    }

    // NSItemProvider's temporary representation is copied before its callback returns.
    static func copyRepresentation(from provider: NSItemProvider, type: UTType, to directory: URL, fallbackName: String) async throws -> StagedShare {
        let suggestedName = provider.suggestedName.flatMap(safeFilename)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StagedShare, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { source, error in
                if let error { continuation.resume(throwing: error); return }
                guard let source else {
                    continuation.resume(throwing: NSError(domain: "GalleryShareExtension", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The shared file was unavailable."]))
                    return
                }
                do {
                    let sourceName = safeFilename(source.lastPathComponent)
                    let proposedName = suggestedName ?? sourceName ?? fallbackName
                    let name: String
                    if (proposedName as NSString).pathExtension.isEmpty, let fileExtension = type.preferredFilenameExtension {
                        name = "\(proposedName).\(fileExtension)"
                    } else {
                        name = proposedName
                    }
                    let destination = directory.appendingPathComponent(UUID().uuidString + "-" + name)
                    try copyProtected(source, to: destination)
                    continuation.resume(returning: StagedShare(url: destination, type: type, filename: name))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated static func stagingDirectory(in root: URL = FileManager.default.temporaryDirectory) throws -> (URL, FileHandle) {
        let staging = try GalleryLeasedStaging.create(in: root, prefix: "GalleryIncoming-")
        return (staging.directory, staging.lease)
    }

    nonisolated static func removeAbandonedStaging(in root: URL) throws {
        try GalleryLeasedStaging.removeAbandoned(in: root, prefix: "GalleryIncoming-")
    }

    nonisolated private static func copyProtected(_ source: URL, to destination: URL) throws {
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }
        do {
            // Protect the file before writing any supplied media bytes.
            #if os(visionOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
            #endif
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                try output.write(contentsOf: bytes)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func safeFilename(_ name: String) -> String? {
        let component = (name as NSString).lastPathComponent
        guard !component.isEmpty, component != ".", component != "..", component != "/" else { return nil }
        return component
    }
}
