#!/usr/bin/env python3
"""Check the shipped vault cipher on macOS without Photos access.

The visionOS protected-file attribute is skipped on the host; native simulator
integration checks cover that platform attribute separately. Crypto and IO stay real.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / "SimpleVisionGallery/Gallery/GalleryVaultStorage.swift").read_text()
marker = "@MainActor\nfinal class GalleryVaultStorage: ObservableObject {"
assert source.count(marker) == 1, "vault storage boundary changed"
core = source.split(marker, 1)[0]
# Applying visionOS complete-file protection to an unsigned macOS CLI can make
# its own file unreadable. Skip only that platform attribute in this host test.
attribute = "try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)"
assert core.count(attribute) == 1, "protected-file creation changed"
core = core.replace(attribute, "_ = url", 1)
harness = (root / "tests/vault/StorageCipherHarness.swift").read_text()
with tempfile.TemporaryDirectory(prefix="gallery-vault-cipher-") as directory:
    work = Path(directory)
    unit = work / "CipherUnderTest.swift"
    unit.write_text(core + harness)
    binary = work / "cipher-test"
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5",
                    "-default-isolation", "MainActor", str(unit), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
