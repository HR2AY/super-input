"""Validate the neutral template and the Feishu-only runtime before publishing."""
from pathlib import Path
import json

root = Path(__file__).resolve().parent.parent
rules = sorted((root / 'Resources/Rules').glob('*.json'))
assert [p.name for p in rules] == ['feishu.json'], 'Only the Feishu template belongs in a release'
rule = json.loads(rules[0].read_text())
assert rule['id'] == 'feishu'
assert rule['feishuSend']['destinations'] == []
assert rule['feishuSend']['accountOpenID'] == rule['feishuSend']['appID'] == rule['feishuSend']['cliPath'] == ''
for file in (root / 'Sources').glob('*.swift'):
    text = file.read_text()
    for retired in ['DSHNext', 'dshNext', 'ChatGPT', 'HandoffEngine', 'AXUIElement', 'CGRequestScreenCaptureAccess']:
        assert retired not in text, f'Retired runtime dependency in {file.name}: {retired}'
assert len(list((root / 'Sources').glob('*.swift'))) == 6
print('PASS: Feishu-only runtime and blank public configuration')
