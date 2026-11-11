#!/usr/bin/env python3
# Target audience: developers. Compile production history and frozen-plan types against controlled fixtures.
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
fixtures = root / 'tests/core'
manager = (root / 'SimpleVisionGallery/Gallery/GalleryManager.swift').read_text()
start = manager.index('nonisolated enum GalleryDeletionMediaKind:')
end = manager.index('private struct GalleryNamedAssetIndex:', start)
with tempfile.TemporaryDirectory(prefix='gallery-album-contracts-') as tmp:
    tmp = Path(tmp)
    types = tmp / 'DeletionPlanTypes.swift'
    types.write_text('import Foundation\n' + manager[start:end])
    cases = [
        [str(root / 'SimpleVisionGallery/Gallery/GalleryMoveHistory.swift'), str(fixtures / 'MoveHistoryHarness.swift')],
        [str(types), str(fixtures / 'DeletionPlanHarness.swift')],
    ]
    for index, files in enumerate(cases):
        binary = tmp / f'check-{index}'
        subprocess.run(['swiftc', '-swift-version', '5', '-default-isolation', 'MainActor', '-parse-as-library', *files, '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
