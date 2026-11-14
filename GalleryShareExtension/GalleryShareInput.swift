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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StagedShare, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { source, error in
                if let error { continuation.resume(throwing: error); return }
                guard let source else {
                    continuation.resume(throwing: NSError(domain: "GalleryShareExtension", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The shared file was unavailable."]))
                    return
                }
                do {
                    let proposedName = source.lastPathComponent
                    let safeName = (proposedName as NSString).lastPathComponent
                    let name = safeName.isEmpty ? fallbackName : safeName
                    let destination = directory.appendingPathComponent(UUID().uuidString + "-" + name)
                    try FileManager.default.copyItem(at: source, to: destination)
                    continuation.resume(returning: StagedShare(url: destination, type: type, filename: name))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
