# Target audience: agents. Validate only the measured model/enqueue contract.
import json, re, sys
from pathlib import Path

def validate(path):
    payload = json.loads(Path(path).read_text())
    if not payload.get('passed'):
        raise ValueError('Native fixture did not pass')
    rows = {row['case']: row for row in payload['rows']}
    for name in ('vault-1000-next', 'vault-10000-next', 'photos-1000-next'):
        row = rows[name]
        if not row['warmed_before_navigation'] or row['load_mode'] != 'retained' or not row['media_success'] or row['media_ready_ms'] >= 50:
            raise ValueError(f'{name}: retained media readiness contract failed')
    for name in ('vault-1000-vault-move', 'vault-10000-vault-move'):
        row = rows[name]
        if not row['advanced_immediately'] or row['failed'] or row['enqueue_ms'] >= 50:
            raise ValueError(f'{name}: immediate Move enqueue contract failed')
        print(f"{name}: successor load mode {row['successor_load_mode']}")
    for name, row in rows.items():
        match = re.search(r'=([0-9]+)ms max=([0-9]+)ms', row.get('frame', ''))
        if match and max(map(int, match.groups())) > 50:
            print(f'WARNING {name}: first or maximum frame callback exceeds 50 ms ({match.group(1)}/{match.group(2)} ms)')
    print('Retained model readiness and immediate Move enqueue checks passed; frame warnings are separate.')

if __name__ == '__main__':
    validate(sys.argv[1])
