# Target audience: agents. Exercise production snapshot and playlist methods with fake PhotoKit.
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source_root = Path(sys.argv[1]) if len(sys.argv) > 1 else root
manager = (source_root / 'SimpleVisionGallery/Gallery/GalleryManager.swift').read_text()
viewer = (source_root / 'SimpleVisionGallery/Gallery/GalleryViewerStore.swift').read_text()

def block(source, marker):
    """Extract production bodies so the regression exercises the real handoff code."""
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 0
    for pos in range(opening, len(source)):
        if source[pos] == '{': depth += 1
        elif source[pos] == '}':
            depth -= 1
            if depth == 0: return source[start:pos + 1]
    raise ValueError(marker)

index = block(viewer, 'nonisolated struct GalleryPlaylistIndex')
snapshot = block(viewer, 'struct GalleryViewerSnapshot')
playlist_source = block(viewer, 'fileprivate final class GalleryViewerPlaylist').replace('fileprivate final class', 'final class', 1)
playlist = playlist_source[:playlist_source.index('    func dropNativeFetch')] + block(playlist_source, '    func displayIndex(forSource') + '\n}'
manager_methods = '\n'.join(block(manager, marker) for marker in [
    '    func viewerIndex(forDisplayIndex', '    private func rebuildPendingDisplayIndexIfNeeded',
    '    private func requestAffectsCurrentGrid', '    func viewerSnapshot()'])
store_methods = '\n'.join(block(viewer, marker) for marker in [
    '    func createSession(from manager:', '    private func stageQueuedDelete(_ request:',
    '    func finishQueuedDelete(_ request:'])
harness = (root / 'tests/queue/ViewerMaskHarness.swift').read_text()
for marker, content in [('// INDEX', index), ('// SNAPSHOT', snapshot), ('// PLAYLIST', playlist),
                        ('// MANAGER_METHODS', manager_methods), ('// STORE_METHODS', store_methods)]:
    harness = harness.replace(marker, content)
with tempfile.TemporaryDirectory() as tmp:
    source = Path(tmp) / 'Harness.swift'
    binary = Path(tmp) / 'viewer-mask-check'
    source.write_text(harness)
    subprocess.run(['swiftc', '-swift-version', '5', '-default-isolation', 'MainActor', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
