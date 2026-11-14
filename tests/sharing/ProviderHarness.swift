// Target audience: developers and release agents.
import Foundation
import UniformTypeIdentifiers

@main
enum ProviderHarness {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GalleryProviderHarness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data("generated image fixture bytes".utf8)
        let source = root.appendingPathComponent("fixture.heic")
        try payload.write(to: source)
        let temporarySource = root.appendingPathComponent("temporary-123.heic")
        try FileManager.default.copyItem(at: source, to: temporarySource)
        let success = provider(type: .heic, result: .success(temporarySource), removeAfterCallback: true)
        guard let type = GalleryShareInput.preferredType(for: success), type == .heic else {
            fatalError("Provider did not retain its concrete HEIC type")
        }
        let destination = root.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let copied = try await GalleryShareInput.copyRepresentation(from: success, type: type, to: destination, fallbackName: "fallback.heic")
        let copiedBytes = try Data(contentsOf: copied.url)
        precondition(copiedBytes == payload, "Copied bytes differ from the provider file")
        precondition(copied.filename == "temporary-123.heic", "Original filename was not retained")
        precondition(!FileManager.default.fileExists(atPath: temporarySource.path), "Provider temporary source was not removed after callback")
        let sourceBytes = try Data(contentsOf: source)
        precondition(sourceBytes == payload, "The source item must remain untouched")

        let named = provider(type: .heic, result: .success(source), suggestedName: "Holiday.heic")
        let namedCopy = try await GalleryShareInput.copyRepresentation(from: named, type: .heic, to: destination, fallbackName: "fallback.heic")
        precondition(namedCopy.filename == "Holiday.heic", "Provider suggested name was not retained")
        let namedBytes = try Data(contentsOf: namedCopy.url)
        precondition(namedBytes == payload, "Suggested filename changed the source bytes")

        let extensionless = provider(type: .heic, result: .success(source), suggestedName: "Holiday")
        let extensionlessCopy = try await GalleryShareInput.copyRepresentation(from: extensionless, type: .heic, to: destination, fallbackName: "fallback.heic")
        precondition(extensionlessCopy.filename == "Holiday.heic", "Representation extension was not appended")

        let emptyName = provider(type: .heic, result: .success(source), suggestedName: "")
        let emptyNameCopy = try await GalleryShareInput.copyRepresentation(from: emptyName, type: .heic, to: destination, fallbackName: "fallback.heic")
        precondition(emptyNameCopy.filename == "fixture.heic", "Empty suggested name must fall back to the source name")

        let broadFirst = provider(broadType: .image, concreteType: .heic, result: .success(source))
        precondition(GalleryShareInput.preferredType(for: broadFirst) == .heic,
            "A broad image declaration must not replace the concrete source type")

        let missing = provider(type: .jpeg, result: .success(nil))
        do {
            _ = try await GalleryShareInput.copyRepresentation(from: missing, type: .jpeg, to: destination, fallbackName: "fallback.jpg")
            fatalError("A missing representation should fail")
        } catch { }

        let failure = NSError(domain: "ProviderHarness", code: 7)
        let errored = provider(type: .jpeg, result: .failure(failure))
        do {
            _ = try await GalleryShareInput.copyRepresentation(from: errored, type: .jpeg, to: destination, fallbackName: "fallback.jpg")
            fatalError("A provider error should propagate")
        } catch {
            precondition(!error.localizedDescription.isEmpty, "Provider error had no usable explanation")
        }

        let unsupported = NSItemProvider(object: NSString(string: "text only"))
        precondition(GalleryShareInput.preferredType(for: unsupported) == nil, "Unsupported text provider was accepted")
        print("Provider callback harness passed: concrete type, in-callback file copy, bytes/name, missing URL, provider error, unsupported type")
    }

    private static func provider(type: UTType, result: Result<URL?, Error>, suggestedName: String? = nil, removeAfterCallback: Bool = false) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = suggestedName
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let representation: URL?
            do { representation = try result.get() } catch { representation = nil }
            completion(representation, false, result.failure)
            if removeAfterCallback, let representation { try? FileManager.default.removeItem(at: representation) }
            return Progress(totalUnitCount: 1)
        }
        return provider
    }

    private static func provider(broadType: UTType, concreteType: UTType, result: Result<URL?, Error>) -> NSItemProvider {
        let provider = NSItemProvider()
        for type in [broadType, concreteType] {
            provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
                completion(try? result.get(), false, result.failure)
                return Progress(totalUnitCount: 1)
            }
        }
        return provider
    }
}

private extension Result where Failure == Error {
    var failure: Error? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
