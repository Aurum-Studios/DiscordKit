#!/usr/bin/env python3
# File: Docs/Tasks/ci-reliability/phase-5/validate.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Retain bounded Phase 5 local helper checks; never invokes native compilation."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[4]
OUTPUT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'Tools/ci'))
from linux_ci import Command, execute

commands = {
    'helpers': (sys.executable, '-m', 'unittest', 'discover', '-s', 'Tools/ci', '-p', 'test_*.py', '-v'),
    'policy': (sys.executable, 'Tools/ci/scheduling_policy.py', 'validate'),
    'workflows': (str(ROOT / '.build/phase5-tools/actionlint'), '-shellcheck=', '-pyflakes='),
    'node-worker': ('node', '--check', 'Tools/ci/artifact-sdk/upload.mjs'),
    'node-launcher': ('node', '--check', '.github/actions/artifact-transfer/index.mjs'),
}
name = sys.argv[1]
try:
    execute(Command('phase5-' + name, commands[name], 300 if name == 'helpers' else 60,
                    operation='localHelperCheck', stage='phase5'),
            ROOT, OUTPUT / (name + '.log'))
except Exception as error:
    print(f'{name}: {error}', file=sys.stderr)
    raise SystemExit(1)
