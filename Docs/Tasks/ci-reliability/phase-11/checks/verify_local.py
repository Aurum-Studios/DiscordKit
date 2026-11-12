#!/usr/bin/env python3
# File: Docs/Tasks/ci-reliability/phase-11/checks/verify_local.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Verify the phase-local documentation, tested inputs and preserved source work."""

import ast
import hashlib
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote

root = Path(__file__).resolve().parents[5]
phase = root / 'Docs/Tasks/ci-reliability/phase-11'
validation = json.loads((phase / 'validation.json').read_text())
parsed = []
for name, expected in validation['inputSHA256'].items():
    path = root / name
    assert hashlib.sha256(path.read_bytes()).hexdigest() == expected, name
    if name.endswith('.py'):
        ast.parse(path.read_text(), filename=name)
        parsed.append(name)
ast.parse(Path(__file__).read_text(), filename=__file__)
for name, expected in json.loads((phase / 'review.json').read_text())['inputSHA256'].items():
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == expected, name
for name, expected in json.loads((phase / 'source-preflight.json').read_text())['originalPlanningSHA256'].items():
    assert hashlib.sha256((root.parent / 'DiscordKit' / name).read_bytes()).hexdigest() == expected, name
links = 0
for path in [root / 'Docs/CI.md', *root.glob('Docs/Tasks/ci-reliability/*.md'), *phase.rglob('*.md')]:
    for target in re.findall(r'\[[^\]]*\]\(([^)]+)\)', path.read_text()):
        if re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*:', target) or target.startswith('#'):
            continue
        target = unquote(target.split('#', 1)[0].split('?', 1)[0])
        assert (path.parent / target).exists(), (path, target)
        links += 1
json_files = 0
for path in phase.rglob('*.json'):
    json.loads(path.read_text())
    json_files += 1
assert json.loads((root / 'Tools/ci/rollout.v1.json').read_text()) == {
    'schemaVersion': 1, 'automaticMode': 'preflight', 'nativeExpansionEnabled': False,
    'spendAdmissionImplemented': True}
policy = json.loads((root / 'Tools/ci/admission.v1.json').read_text())
assert policy['authorization']['enabled'] is False
assert policy['allowances']['maximumPaidJobs'] == 0
assert subprocess.run(['git', 'diff', '--check'], cwd=root, check=False).returncode == 0
assert subprocess.run(['git', 'diff', '--cached', '--check'], cwd=root, check=False).returncode == 0
print(json.dumps({'status': 'passed', 'pythonFiles': len(parsed) + 1,
                  'jsonFiles': json_files, 'localMarkdownLinks': links,
                  'originalPlanningPreserved': True, 'testedInputsVerified': True,
                  'nativeAndPaidRolloutContained': True}, sort_keys=True))
