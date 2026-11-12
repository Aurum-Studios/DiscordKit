# File: Tools/ci/test_execution_plan.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Prove cost scope follows actual execution and admission cannot be skipped."""

from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch

import execution_plan as execution
import workflow_scope

ROOT = Path(__file__).resolve().parents[2]


class ExecutionPlanTests(unittest.TestCase):
    def test_full_jobs_cover_every_exact_matrix_and_fixed_job(self):
        rows = workflow_scope.execution_jobs('full', publication=True)
        self.assertEqual(len(rows), len({row['id'] for row in rows}))
        self.assertEqual(len(rows), len({row['jobName'] for row in rows}))
        self.assertTrue(all(row['maximumSeconds'] > 0 for row in rows))
        for platform in workflow_scope.PREFIXES:
            native = workflow_scope.platform_plan('full', platform, commit='a'*40,
                                                  run_id='42', run_attempt='1')
            observed = {row['id'].removeprefix(platform + '/') for row in rows
                        if row['id'].startswith(platform + '/')}
            expected = {'platform', 'plan', 'canary', 'resolve', 'audit', 'coverage', 'export',
                        'complete', 'fixture/dsl_compile_fixtures', 'fixture/dsl_extension_fixtures'}
            expected |= {'build/' + row['component'] for row in native['all-builds']['include']}
            expected |= {'suite/' + row['component'] + '/' + row['suite'] for matrix in
                         ('root-tests', 'tests') for row in native[matrix]['include']}
            if platform == 'macos-arm64':
                expected |= {'public-api', 'apple'}
            self.assertEqual(observed, expected)
        self.assertEqual(sum(row['id'] == 'documentation-site' for row in rows), 1)
        self.assertEqual(sum(row['id'] == 'publish-documentation' for row in rows), 1)
        self.assertNotIn('publish-documentation', {row['id'] for row in
                         workflow_scope.execution_jobs('full')})

    def test_diagnostic_reserves_only_shared_canary_and_selected_producer(self):
        rows = execution.execution_jobs('diagnostic', platform='linux-x64', component='root',
                                         suite='DiscordBitsTests')
        native = {row['id'] for row in rows if row['id'].startswith('linux-x64/')}
        self.assertEqual(native, {'linux-x64/' + name for name in ('platform', 'plan', 'build/load',
                         'build/root', 'canary', 'resolve', 'suite/root/DiscordBitsTests',
                         'coverage', 'complete')})
        self.assertFalse(any(row['id'].startswith('macos-arm64/') for row in rows))
        with self.assertRaises(ValueError):
            execution.execution_jobs('diagnostic', platform='linux-x64', component='load', publication=True)

    def test_preflight_and_request_include_their_own_bootstrap(self):
        rows = execution.execution_jobs('preflight')
        self.assertEqual(len(rows), 8)
        self.assertEqual({row['group'] for row in rows}, {'ubuntu-24.04'})
        self.assertEqual(execution.execution_jobs('documentation-request'), [{
            'id': 'documentation-request', 'group': 'ubuntu-24.04', 'maximumSeconds': 300,
            'jobName': 'Request full CI with shared documentation inputs'}])
        with self.assertRaises(ValueError):
            execution.execution_jobs('documentation-request', component='load')

    def test_outer_deadline_changes_change_reservation_and_missing_jobs_fail(self):
        original = execution.workflow_jobs
        def changed(repository, name, expected):
            jobs = original(repository, name, expected)
            if name == 'ci.yml':
                jobs['source'] = jobs['source'].replace('timeout-minutes: 15', 'timeout-minutes: 17')
            return jobs
        with patch.object(execution, 'workflow_jobs', side_effect=changed):
            rows = execution.execution_jobs('preflight')
        self.assertEqual(next(row for row in rows if row['id'] == 'source')['maximumSeconds'], 1020)
        with self.assertRaises(ValueError):
            execution.maximum_seconds('    timeout-minutes: ${{ inputs.timeout }}\n')
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / '.github/workflows'
            directory.mkdir(parents=True)
            (directory / 'ci.yml').write_text('jobs:\n  source:\n    timeout-minutes: 5\n  unpaid-surprise:\n')
            with self.assertRaises(ValueError):
                execution.workflow_jobs(temporary, 'ci.yml', {'source'})

    def test_duplicate_branch_push_and_unexpected_trigger_rejected(self):
        for event, ref in [('push', 'refs/heads/feature'), ('push', 'refs/tags/1.0'),
                           ('workflow_run', 'refs/heads/main'), ('schedule', 'refs/heads/main')]:
            with self.subTest(event=event, ref=ref), self.assertRaises(ValueError):
                execution.validate_trigger(event, ref, 'main')
        for event, ref in [('push', 'refs/heads/main'), ('pull_request', 'refs/pull/2/merge'),
                           ('workflow_dispatch', 'refs/heads/feature')]:
            execution.validate_trigger(event, ref, 'main')
        ci = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('  push:\n    branches: [main]\n', ci)
        self.assertIn('  pull_request:\n', ci)
        docs = (ROOT / '.github/workflows/documentation.yml').read_text()
        self.assertNotIn('  push:', docs)

    def test_unknown_runner_and_matrix_expansion_fail_before_startup(self):
        original = execution.workflow_jobs
        for filename, old, new in [('ci.yml', 'build-group: Linux-x64-64', 'build-group: Unknown-128'),
                                    ('ci.yml', 'group: MacOS-26-5', 'group: Unknown-mac'),
                                    ('ci.yml', 'benchmark-python, browser]', 'benchmark-python, browser, extra]'),
                                    ('native-platform.yml', 'group: ${{ matrix.group }}', 'group: Unknown-128'),
                                    ('native-platform.yml', 'group: ${{ inputs.build-group }}', 'group: Unknown-128'),
                                    ('native-platform.yml', 'fromJSON(needs.plan.outputs.core-builds)', 'fromJSON(needs.plan.outputs.all-builds)'),
                                    ('ci.yml', '    name: Source policy and workflow syntax',
                                     '    strategy:\n      matrix:\n        extra: [a, b]\n    name: Source policy and workflow syntax'),
                                    ('native-platform.yml', 'suite: [dsl_compile_fixtures, dsl_extension_fixtures]',
                                     'suite: [dsl_compile_fixtures, dsl_extension_fixtures]\n        include: []')]:
            def changed(repository, name, expected):
                jobs = original(repository, name, expected)
                return {key: value.replace(old, new) for key, value in jobs.items()} if name == filename else jobs
            with self.subTest(filename=filename, new=new), patch.object(execution, 'workflow_jobs', side_effect=changed):
                with self.assertRaises(ValueError):
                    execution.execution_jobs('full')

    def test_every_runner_job_checks_current_attempt_before_provisioning(self):
        for name, expected in [('ci.yml', execution.CI_JOBS),
                               ('native-platform.yml', execution.NATIVE_JOBS),
                               ('documentation.yml', {'request'})]:
            for job, block in execution.workflow_jobs(ROOT, name, expected).items():
                if job in ('native-linux', 'native-macos', 'scope'):
                    continue
                with self.subTest(workflow=name, job=job):
                    guard = block.index('Tools/ci/spend_admission.py guard')
                    self.assertLess(block.index('actions/checkout@'), guard)
                    steps = block[block.index('    steps:'):]
                    before = steps[:steps.index('Tools/ci/spend_admission.py guard')]
                    self.assertNotRegex(before, r'uses: (?!actions/checkout@)')
                    self.assertNotIn('needs.scope.outputs.admitted', before)
                    self.assertIn('--group ', block)
        native = (ROOT / '.github/workflows/native-platform.yml').read_text()
        self.assertIn("ADMISSION_PLATFORM: ${{ inputs.mode == 'diagnostic' && inputs.platform || '' }}", native)


if __name__ == '__main__':
    unittest.main()
