#!/usr/bin/env python3
# Target audience: developers. The real request factory and confirm method run against a controlled vault.
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'SimpleVisionGallery/Gallery/GalleryVaultView.swift').read_text()
start = source.index('struct GalleryVaultTransferRequest:')
end = source.index('struct GalleryVaultConfirmation:', start)
harness = (root / 'tests/core/VaultConfirmationHarness.swift').read_text()
with tempfile.TemporaryDirectory(prefix='gallery-confirmation-') as tmp:
    path = Path(tmp)
    swift = path / 'Harness.swift'
    swift.write_text(harness.replace('// PRODUCTION_REQUEST', source[start:end]))
    binary = path / 'check'
    subprocess.run(['swiftc', '-swift-version', '5', '-default-isolation', 'MainActor', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
