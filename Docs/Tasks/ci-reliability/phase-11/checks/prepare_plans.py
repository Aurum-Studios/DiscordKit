#!/usr/bin/env python3
# File: Docs/Tasks/ci-reliability/phase-11/checks/prepare_plans.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Retain pure local plans; this replay never grants execution or qualification."""

import argparse
from collections import Counter
from contextlib import redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[5]
sys.path.insert(0, str(ROOT / 'Tools/ci'))
import native_jobs
import spend_admission
import workflow_scope


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    # Identity queries include binary tracked-name output; keep that transport
    # internal while retaining the resulting source and pin hashes below.
    with redirect_stdout(io.StringIO()):
        source = native_jobs.source_identity(ROOT)
    selections = {
        'preflight': {'mode': 'preflight'},
        'linux-fault': {'mode': 'diagnostic', 'platform': 'linux-x64',
                        'component': 'root', 'suite': 'DiscordBitsTests', 'qualification_fault': True},
        'macos-load': {'mode': 'diagnostic', 'platform': 'macos-arm64', 'component': 'load', 'suite': 'load'},
        'full': {'mode': 'full'},
    }
    rows = []
    for name, selection in selections.items():
        plan = spend_admission.make_plan(**selection, repository=ROOT, source=source)
        if plan['admitted'] or plan['native-enabled']:
            raise ValueError('local preparation must retain refused hosted admission')
        path = output / (name + '.json')
        native_jobs.write_json(path, plan)
        minutes = Counter()
        for job in plan['jobs']:
            minutes[job['group']] += job['billedMaximumMinutes']
        rows.append({'name': name, 'status': plan['status'], 'planSHA256': plan['planSHA256'],
                     'fileSHA256': hashlib.sha256(path.read_bytes()).hexdigest(),
                     'jobsPerAttempt': len(plan['jobs']), 'maximumRunnerMinutesPerAttempt': sum(minutes.values()),
                     'minutesByGroup': dict(minutes), 'completeMaximumUSD': plan['totals']['maximumUSD'],
                     'maximumReservedAttempts': plan['totals']['maximumAttempts'], 'reasons': plan['reasons']})
    for platform in workflow_scope.PREFIXES:
        plan = workflow_scope.platform_plan('full', platform, repository=ROOT, commit=source['commit'],
                                            run_id='local-planning', run_attempt='1')
        native_jobs.write_json(output / ('coverage-' + platform + '.json'), plan)
    result = {'schemaVersion': 1, 'status': 'passed-local-refusal-planning', 'source': source,
              'checkoutStatus': subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True),
              'plans': rows, 'certificationEstablished': False, 'paidJobsExecuted': 0,
              'limitations': ['Native discovery and hosted acceptance are not established.',
                              'Maximum runner minutes are outer-timeout ceilings, not forecasts or actual billing.',
                              'Account runner pricing and storage/transfer charges remain unverified.']}
    native_jobs.write_json(output / 'results.json', result)
    print(json.dumps({'status': result['status'], 'sourceCommit': source['commit'],
                      'scopes': [{key: row[key] for key in ('name', 'jobsPerAttempt',
                                 'maximumRunnerMinutesPerAttempt', 'status')} for row in rows]}, sort_keys=True))


if __name__ == '__main__':
    main()
