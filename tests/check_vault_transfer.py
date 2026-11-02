#!/usr/bin/env python3
"""Run the production transfer orchestration against deterministic fake Photos and storage.

Requires macOS, Xcode's Swift compiler and the gallery checkout. These are unit tests,
not proof of PhotoKit, Keychain, filesystem durability, visual UI, or headset behavior.
"""
import argparse
import pathlib
import re
import subprocess
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument("--repo", type=pathlib.Path, default=HERE.parent)
repo = parser.parse_args().repo.resolve()
source = (repo / "SimpleVisionGallery/Gallery/GalleryVaultService.swift").read_text()
assert source.startswith("#if os(visionOS)\n") and source.rstrip().endswith("#endif"), "service platform wrapper changed"
body = source.removeprefix("#if os(visionOS)\n").rsplit("#endif", 1)[0]
for platform_import in ("@preconcurrency import Photos\n", "import UIKit\n"):
    assert body.count(platform_import) == 1, f"expected exactly one {platform_import.strip()}"
    body = body.replace(platform_import, "", 1)
assert "UIApplication.protectedDataWillBecomeUnavailableNotification" in body
app = (repo / "SimpleVisionGallery/SimpleVisionGalleryApp.swift").read_text()
assert re.search(r"@Environment\(\\\.scenePhase\)\s+private var scenePhase", app), "app phase observer missing"
assert re.search(r"\.onChange\(of:\s*scenePhase\).*?phase\s*==\s*\.background\s*\{\s*GalleryVaultService\.shared\.lock\(\)", app, re.S), "app background lock missing"
# The source-version predicate is also production code; fake Photos supplies its inputs.
photo_source = (repo / "SimpleVisionGallery/Gallery/GalleryVaultPhotoLibrary.swift").read_text()
fake_source = (HERE / "vault/FakePhotoKit.swift").read_text()
marker_start = "    static func isSameVersion("
marker_end = "    static func fetch(ids:"
assert photo_source.count(marker_start) == fake_source.count(marker_start) == 1
assert photo_source.count(marker_end) == fake_source.count(marker_end) == 1
version_predicate = photo_source[photo_source.index(marker_start):photo_source.index(marker_end)]
fake_source = fake_source[:fake_source.index(marker_start)] + version_predicate + fake_source[fake_source.index(marker_end):]
parent_start = "    static func usableParents("
production_end = "\n}\n\nnonisolated enum GalleryVaultTransferError"
fake_end = "\n}\nnonisolated final class GalleryVaultResourceWriter"
assert photo_source.count(parent_start) == fake_source.count(parent_start) == 1
assert photo_source.count(production_end) == fake_source.count(fake_end) == 1
parent_predicate = photo_source[photo_source.index(parent_start):photo_source.index(production_end)]
fake_source = fake_source[:fake_source.index(parent_start)] + parent_predicate + fake_source[fake_source.index(fake_end):]
with tempfile.TemporaryDirectory(prefix="gallery-vault-transfer-") as temp:
    path = pathlib.Path(temp)
    extracted = path / "ServiceUnderTest.swift"
    extracted.write_text(body)
    fake = path / "FakePhotoKit.swift"
    fake.write_text(fake_source)
    binary = path / "transfer-test"
    subprocess.run([
        "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
        str(fake), str(repo / "SimpleVisionGallery/Gallery/GalleryVaultModels.swift"),
        str(extracted), str(HERE / "vault/TransferHarness.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
