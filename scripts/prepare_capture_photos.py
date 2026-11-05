#!/usr/bin/env python3
"""Target audience: agents. Download one declared mixed fixture set, never user media."""
import hashlib
import json
from pathlib import Path
import shutil
import sys
import urllib.request

scenes = [
    ('photo-1519501025264-65ba15a82390', 'City at Dusk'),
    ('photo-1473116763249-2faaef81ccda', 'Coastal Walk'),
    ('photo-1441974231531-c6227db76b6e', 'Forest Light'),
    ('photo-1470770841072-f978cf4d019e', 'Mountain Lakes; Luca Bravo, https://unsplash.com/photos/zAjdgNXsMeg'),
    ('photo-1464822759023-fed622ff2c3b', 'High Country'),
    ('photo-1500534623283-312aade485b7', 'Last Light'),
]
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
records = []
for index in range(20):
    variant = index % 10
    scene = variant if variant < 6 else variant - 6
    orientation = 'landscape' if variant < 6 else 'portrait'
    width, height = (1200, 850) if orientation == 'landscape' else (800, 1200)
    identifier, description = scenes[scene]
    url = f'https://images.unsplash.com/{identifier}?auto=format&fit=crop&w={width}&h={height}&q=85&fm=jpg'
    destination = out / f'capture-{index:02}.jpg'
    if index >= 10:
        shutil.copyfile(out / f'capture-{variant:02}.jpg', destination)
    elif not destination.exists():
        urllib.request.urlretrieve(url, destination)
    records.append(dict(index=index, filename=destination.name, title=description.split(';')[0],
                        scene=scene, orientation=orientation, width=width, height=height,
                        duplicateOf=variant if index >= 10 else None,
                        source=url, attribution=description, license='https://unsplash.com/license',
                        sha256=hashlib.sha256(destination.read_bytes()).hexdigest()))
assert len(records) == 20 and sum(r['orientation'] == 'portrait' for r in records) == 8
assert all(records[r['duplicateOf']]['sha256'] == r['sha256'] for r in records if r['duplicateOf'] is not None)
fixture = dict(description='20 synthetic photo records: six landscape scenes and four portrait crops, each included twice. Portrait crops reuse the declared original scenes. No user media.',
               records=records)
(out / 'capture-fixtures.json').write_text(json.dumps(fixture, indent=2) + '\n')
