import Darwin
import Foundation

/// An atomic file lock identifies live staging work across share-extension processes.
nonisolated enum GalleryLeasedStaging {
    private static let markerSuffix = ".active"

    static func create(in root: URL, prefix: String) throws -> (directory: URL, lease: FileHandle) {
        try removeAbandoned(in: root, prefix: prefix)
        let name = prefix + UUID().uuidString
        let marker = root.appendingPathComponent(name + markerSuffix)
        // The lock and marker become visible atomically; no scavenger can observe an unlocked live marker.
        let descriptor = open(marker.path, O_RDWR | O_CREAT | O_EXCL | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW,
                              S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let lease = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let directory = root.appendingPathComponent(name, isDirectory: true)
        do {
            #if os(visionOS)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.protectionKey: FileProtectionType.complete])
            #else
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            #endif
            return (directory, lease)
        } catch {
            try? FileManager.default.removeItem(at: marker)
            try? lease.close()
            throw error
        }
    }

    static func removeAbandoned(in root: URL, prefix: String) throws {
        let manager = FileManager.default
        for marker in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let name = marker.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(markerSuffix) else { continue }
            let directoryName = String(name.dropLast(markerSuffix.count))
            guard UUID(uuidString: String(directoryName.dropFirst(prefix.count))) != nil else { continue }
            // Process death releases this lock. A live writer's marker stays locked.
            let descriptor = open(marker.path, O_RDWR | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }
            let directory = root.appendingPathComponent(directoryName, isDirectory: true)
            do {
                if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
                try manager.removeItem(at: marker)
            } catch { }
            close(descriptor)
        }
    }

    static func marker(for directory: URL) -> URL {
        directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + markerSuffix)
    }
}
