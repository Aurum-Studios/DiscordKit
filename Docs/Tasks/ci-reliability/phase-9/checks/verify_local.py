#!/usr/bin/env python3
# File: Docs/Tasks/ci-reliability/phase-9/checks/verify_local.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Verify phase-local source syntax, documentation links and retained evidence."""

import ast
import hashlib
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote


root = Path.cwd()
phase = root / 'Docs/Tasks/ci-reliability/phase-9'
changed = subprocess.check_output(['git', 'diff', '--name-only', 'e37ad2bc'], text=True).splitlines()
added = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', 'Tools/ci'], text=True).splitlines()
inputs = sorted(set(name for name in changed + added if name.startswith(('Tools/ci/', '.github/'))))
parsed = []
for name in inputs:
    if name.endswith('.py'):
        ast.parse((root / name).read_text(), filename=name)
        parsed.append(name)
embedded = 0
for path in root.glob('.github/workflows/*.yml'):
    lines = path.read_text().splitlines()
    for i, line in enumerate(lines):
        if not re.match(r'\s+run: \|[-+]?$', line):
            continue
        indent = len(line) - len(line.lstrip())
        step = max((j for j in range(i) if re.match(r'\s+- (name:|uses:)', lines[j])), default=0)
        if not any(re.match(r'\s+shell: python$', item) for item in lines[step:i]):
            continue
        body = []
        for child in lines[i + 1:]:
            if child.strip() and len(child) - len(child.lstrip()) <= indent:
                break
            body.append(child[indent + 2:])
        ast.parse('\n'.join(body), filename=str(path))
        embedded += 1
json_count = 0
for path in phase.rglob('*.json'):
    json.loads(path.read_text())
    json_count += 1
links = 0
for path in [root / 'Docs/CI.md', *root.glob('Docs/Tasks/ci-reliability/*.md'), *phase.rglob('*.md')]:
    for target in re.findall(r'\[[^\]]*\]\(([^)]+)\)', path.read_text()):
        if re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*:', target) or target.startswith('#'):
            continue
        target = unquote(target.split('#', 1)[0].split('?', 1)[0])
        assert (path.parent / target).exists(), (path, target)
        links += 1
for name, expected in json.loads((phase / 'source-preflight.json').read_text())['originalPlanningSHA256'].items():
    assert hashlib.sha256((root.parent / 'DiscordKit' / name).read_bytes()).hexdigest() == expected, name
assert json.loads((root / 'Tools/ci/rollout.v1.json').read_text()) == {
    'schemaVersion': 1, 'automaticMode': 'preflight', 'nativeExpansionEnabled': False,
    'spendAdmissionImplemented': False}
assert subprocess.run(['git', 'diff', '--check'], check=False).returncode == 0
record = {'status': 'passed', 'pythonFiles': parsed, 'embeddedPythonBlocks': embedded,
          'jsonFiles': json_count, 'localMarkdownLinks': links,
          'originalPlanningHashesUnchanged': True, 'rolloutContained': True}
print(json.dumps(record, sort_keys=True))
