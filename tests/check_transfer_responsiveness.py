#!/usr/bin/env python3
# Target audience: developers. Generated encrypted data on macOS; visionOS protection is a separate check.
from pathlib import Path
import subprocess
import sys

script = Path(__file__).resolve().parent / 'transfer/run.py'
subprocess.run([sys.executable, str(script)], check=True)
