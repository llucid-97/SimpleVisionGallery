#!/usr/bin/env python3
# Target audience: developers and release agents. Run through the shared compute queue.
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
checks = sorted((root / 'tests').glob('check_*.py'))
if not checks:
    raise SystemExit('No core checks found')
for check in checks:
    print(f'RUN {check.name}', flush=True)
    subprocess.run([sys.executable, str(check)], cwd=root, check=True)
print(f'PASS: {len(checks)} core checks. Native Simulator transitions and headset appearance are separate release checks.')
