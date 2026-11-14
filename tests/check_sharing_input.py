#!/usr/bin/env python3
# Target audience: developers and release agents.
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / "GalleryShareExtension/GalleryShareInput.swift"
harness = root / "tests/sharing/ProviderHarness.swift"

with tempfile.TemporaryDirectory(prefix="gallery-share-") as directory:
    binary = Path(directory) / "ProviderHarness"
    subprocess.run(
        ["swiftc", "-swift-version", "5", "-parse-as-library", str(source), str(harness), "-o", str(binary)],
        cwd=root,
        check=True,
    )
    subprocess.run([str(binary)], cwd=root, check=True)
