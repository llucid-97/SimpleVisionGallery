# Target audience: agents. Compile the production queue with fake backing stores.
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source_path = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'SimpleVisionGallery/Gallery/GalleryDeleteQueue.swift'
source = source_path.read_text().replace('#if os(visionOS)\n', '').replace('@preconcurrency import Photos\n', '').rsplit('#endif', 1)[0]
with tempfile.TemporaryDirectory() as tmp:
    queue = Path(tmp) / 'QueueUnderTest.swift'
    binary = Path(tmp) / 'queue-check'
    queue.write_text(source)
    subprocess.run(['swiftc', '-swift-version', '5', '-default-isolation', 'MainActor', '-parse-as-library', str(queue), str(root / 'tests/queue/AsyncHarness.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
