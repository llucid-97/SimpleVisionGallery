#!/usr/bin/env python3
"""Extract current vault storage into a temporary macOS host test program."""

from __future__ import annotations

import re
from pathlib import Path
import tempfile
import subprocess


ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SOURCE = ROOT / "SimpleVisionGallery/Gallery/GalleryVaultStorage.swift"
MODELS = ROOT / "SimpleVisionGallery/Gallery/GalleryVaultModels.swift"


def transformed_storage() -> str:
    source = SOURCE.read_text()
    marker = "    private func preloadManifest() {"
    if marker not in source:
        raise RuntimeError("Storage initializer insertion point moved")
    initializer = """    // Test-only injection: the production singleton/keychain/authentication path is not used.
    init(testRoot: URL, testKey: SymmetricKey) throws {
        root = testRoot
        items = testRoot.appendingPathComponent("items", isDirectory: true)
        staging = testRoot.appendingPathComponent("staging", isDirectory: true)
        plaintext = testRoot.appendingPathComponent("plaintext", isDirectory: true)
        try Self.prepareDirectory(root)
        try Self.prepareDirectory(items)
        try Self.prepareDirectory(staging)
        try Self.prepareDirectory(plaintext)
        session = GalleryVaultSession(key: testKey)
        isUnlocked = true
    }

"""
    source = source.replace(marker, initializer + marker, 1)
    # visionOS file-protection attributes are unavailable on macOS host tests.
    source = re.sub(r"attributes: \[\.protectionKey: FileProtectionType\.complete\]", "attributes: [:]", source)
    source = re.sub(r"FileManager\.default\.setAttributes\(\[\.protectionKey: FileProtectionType\.complete\],", "FileManager.default.setAttributes([:],", source)
    source = source.replace(".completeFileProtection", ".atomic")
    if "FileProtectionType" in source or ".protectionKey" in source:
        raise RuntimeError("Host file-protection adaptation was incomplete")
    gate = "                    } catch { break }\n                }\n            }"
    if source.count(gate) != 1:
        raise RuntimeError("Mutation-loop interruption point moved")
    source = source.replace(gate,
        """                    } catch { break }
                }
            // Test-only pause: let the host test revoke the session after item one.
            if index == 0 && ProcessInfo.processInfo.environment["SVG_TEST_INTERRUPT_DELAY"] == "1" {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            }
""", 1)
    probes = [
        ('let item = try await Task.detached(priority: .userInitiated) {', 'create'),
        ('let outcome: (Date?, Error?) = try await Task.detached(priority: .userInitiated) {', 'commit'),
        ('let date = try await Task.detached(priority: .userInitiated) {', 'update'),
        ('        await Task.detached(priority: .userInitiated) {\n            try? session.withKey { key in\n                state.sortedRecords', 'batch'),
    ]
    for needle, label in probes:
        assert source.count(needle) == 1, (needle, source.count(needle))
        if label == 'batch':
            replacement = needle.replace('            try? session.withKey', f'            TransferProbe.hit("{label}")\n            try? await Task.sleep(nanoseconds: 200_000_000)\n            try? session.withKey')
        else:
            replacement = needle + f'\n            TransferProbe.hit("{label}")\n            try await Task.sleep(nanoseconds: 200_000_000)'
        source = source.replace(needle, replacement, 1)
        if label != 'batch':
            start = source.index(replacement) + len(replacement)
            point = source.index('            try session.withKey', start)
            source = source[:point] + source[point:].replace('            try session.withKey', '            return try session.withKey', 1)
    needle = 'do { try Self.syncDirectory(parent); return (date, nil) }'
    assert source.count(needle) == 1
    source = source.replace(needle, 'do { if TransferProbe.shouldFailSync() { throw CocoaError(.fileWriteUnknown) }; try Self.syncDirectory(parent); return (date, nil) }', 1)
    return source


def run_test(tmp: Path) -> int:
    generated = tmp / "VaultStorageHostTests.generated.swift"
    generated.write_text(
        MODELS.read_text()
        + "\n"
        + """import Foundation
import CryptoKit

nonisolated enum TransferProbe {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var hits: [String: Bool] = [:]
    private nonisolated(unsafe) static var failSync = false
    static func hit(_ name: String) { lock.lock(); hits[name] = Thread.isMainThread; lock.unlock() }
    static func seen(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return hits[name] != nil }
    static func isMain(_ name: String) -> Bool? { lock.lock(); defer { lock.unlock() }; return hits[name] }
    static func reset(_ name: String) { lock.lock(); hits.removeValue(forKey: name); lock.unlock() }
    static func setFailSync(_ value: Bool) { lock.lock(); failSync = value; lock.unlock() }
    static func shouldFailSync() -> Bool { lock.lock(); defer { lock.unlock() }; return failSync }
}

extension Notification.Name {
    static let galleryVaultWillLock = Notification.Name("galleryVaultWillLock")
    static let galleryVaultDidLock = Notification.Name("galleryVaultDidLock")
}

nonisolated enum GalleryVaultTransferError: Error {
    case interruptedRestore, notInRecycleBin, invalidVaultDestination
}

nonisolated enum GalleryVaultMutationWarning: Error { case directorySyncUnconfirmed, cleanupPending }

nonisolated enum GalleryRecycleBin {
    static func isRecycleBinTitle(_ title: String) -> Bool {
        title.caseInsensitiveCompare("Recycle Bin") == .orderedSame
    }
}

nonisolated enum GalleryVaultMutation: Sendable {
    case recycle(UUID), putBack(UUID), delete(UUID), move(UUID, sourceAlbumID: String?, destination: GalleryVaultAlbum)
    var id: UUID {
        switch self {
        case .recycle(let id), .putBack(let id), .delete(let id), .move(let id, _, _): id
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

"""
        + transformed_storage()
        + "\n"
        + (HERE / "HostTests.swift").read_text()
    )
    executable = tmp / "vault-storage-host-tests"
    command = [
        "swiftc",
        "-swift-version",
        "6",
        "-parse-as-library",
        str(generated),
        "-o",
        str(executable),
    ]
    built = subprocess.run(command, cwd=ROOT)
    if built.returncode:
        return built.returncode
    environment = dict(__import__("os").environ)
    environment["SVG_TEST_INTERRUPT_DELAY"] = "1"
    return subprocess.run([str(executable)], cwd=ROOT, env=environment).returncode


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="gallery-transfer-host-") as tmp:
        raise SystemExit(run_test(Path(tmp)))
