#!/usr/bin/env python3
# Target audience: developers. Host crypto contract; native authentication and sandboxing are separate.
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="gallery-vault-share-") as directory:
    binary = Path(directory) / "VaultInboxHarness"
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library",
        str(root / "SimpleVisionGallery/Gallery/GalleryVaultInbox.swift"),
        str(root / "SimpleVisionGallery/Gallery/GalleryLeasedStaging.swift"),
        str(root / "tests/sharing/VaultInboxHarness.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
