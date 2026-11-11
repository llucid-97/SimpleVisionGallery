#!/usr/bin/env python3
# Target audience: developers. Exercise actual production methods with controlled media/cache doubles.
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
for script in sorted((root / 'tests/loading').glob('test_*.py')):
    print(f'RUN {script.name}', flush=True)
    subprocess.run([sys.executable, str(script), str(root)], cwd=root, check=True)
