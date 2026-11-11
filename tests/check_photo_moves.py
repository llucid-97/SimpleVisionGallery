#!/usr/bin/env python3
# Target audience: developers. Test production PhotoKit transaction construction with a fake library.
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
fixtures = root / 'tests/photo-move'
queue = (root / 'SimpleVisionGallery/Gallery/GalleryDeleteQueue.swift').read_text()
executor = (root / 'SimpleVisionGallery/Gallery/GalleryQueuedPhotoDeletion.swift').read_text()
request_types = queue.split('#if os(visionOS)', 1)[0].replace('import Foundation\n', '')
executor = executor.replace('import Foundation\n', '').replace('@preconcurrency import Photos\n', '')
source = '\n'.join(['import Foundation', (fixtures / 'FakePhotoKit.swift').read_text(),
                    request_types, executor, (fixtures / 'Harness.swift').read_text()])
with tempfile.TemporaryDirectory(prefix='gallery-photo-move-') as tmp:
    tmp = Path(tmp)
    swift, binary = tmp / 'check.swift', tmp / 'check'
    swift.write_text(source)
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
