#!/usr/bin/env python3
"""Target audience: agents. Declared crops/resizes only; preserve raw screenshots."""
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
if len(sys.argv) == 3:
    transforms = json.loads(Path(sys.argv[2]).read_text())
else:
    rectangle = list(map(int, sys.argv[2:6]))
    transforms = {image.name: dict(rectangle=rectangle) for image in (root / 'screenshots').glob('*.png')}
out = root / 'window-crops'
out.mkdir(exist_ok=False)
for name, transform in transforms.items():
    x, y, width, height = transform['rectangle']
    assert min(x, y) >= 0 and min(width, height) > 0
    destination = out / name
    subprocess.run(['sips', '--cropToHeightWidth', str(height), str(width), '--cropOffset', str(y), str(x),
                    str(root / 'screenshots' / name), '--out', str(destination)], check=True, stdout=subprocess.DEVNULL)
    if 'resize' in transform:
        target_width, target_height = transform['resize']
        subprocess.run(['sips', '-z', str(target_height), str(target_width), str(destination)], check=True, stdout=subprocess.DEVNULL)
(out / 'crop.json').write_text(json.dumps(dict(transforms=transforms,
    operation='sips crop and declared size normalization only; no retouch', originals='../screenshots'),indent=2)+'\n')
