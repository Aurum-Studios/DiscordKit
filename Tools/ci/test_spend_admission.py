# File: Tools/ci/test_spend_admission.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Exercise exact planner admission with synthetic, explicitly verified prices."""

from contextlib import redirect_stderr, redirect_stdout
import copy
from datetime import date, timedelta
from decimal import Decimal
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import spend_admission as spend


AS_OF = date(2026, 11, 12)
SOURCE = {'commit': 'a' * 40, 'sourceSHA256': 'b' * 64, 'dependencyPinsSHA256': {}}
IDENTITY = {'repository': 'Aurum-Studios/DiscordKit', 'repositoryID': '1',
    'workflowRef': 'Aurum-Studios/DiscordKit/.github/workflows/ci.yml@refs/heads/main',
    'workflowSHA': 'a' * 40, 'event': 'workflow_dispatch', 'ref': 'refs/heads/main',
    'headRef': '', 'baseRef': '', 'runID': '100', 'runAttempt': '1', 'defaultBranch': 'main'}


class SpendAdmissionTests(unittest.TestCase):
    """Successful synthetic policies never change the checked-in authorization."""

    def setUp(self):
        self.policy = spend.load_policy()
        self.policy['authorization'].pop('validFrom', None)
        self.policy['authorization'].pop('validUntil', None)
        self.policy['authorization'].update(enabled=True, maximumRunAttempts=2)
        for rate in self.policy['runnerRates'].values():
            rate.update(usdPerMinute='0.01', verifiedOn=AS_OF.isoformat(),
                        billingMappingVerified=True, mappingAssurance='offline fixture verified account mapping')
        for charge in self.policy['additionalCharges'].values():
            charge.update(applicability='not-applicable', maximumUnitsPerJobAttempt='0', usdPerUnit='0',
                          verifiedOn=AS_OF.isoformat(), evidence='offline fixture affirmative zero applicability')
        self.policy['allowances'].update(workflowUSD='10000', experimentUSD='10000', safetyUSD='1.50',
                                        maximumPaidJobs=1000, maximumPaidMinutes=1000000, maximumPaidAttempts=2)
        self.rollout = patch.object(spend.workflow_scope, 'rollout', return_value={
            'schemaVersion': 1, 'nativeExpansionEnabled': True, 'spendAdmissionImplemented': True,
            'automaticMode': 'preflight'})
        self.rollout.start()
        self.addCleanup(self.rollout.stop)

    def plan(self, mode='preflight', **arguments):
        options = dict(policy=self.policy, as_of=AS_OF, source=SOURCE, identity=IDENTITY)
        options.update(arguments)
        return spend.make_plan(mode, **options)

    def guard(self, job='source', **arguments):
        options = dict(mode='preflight', policy=self.policy, as_of=AS_OF, source=SOURCE, identity=IDENTITY)
        options.update(arguments)
        return spend.guard_job(job, **options)

    def disabled_policy(self):
        policy = copy.deepcopy(self.policy)
        policy['authorization']['enabled'] = False
        for rate in policy['runnerRates'].values():
            rate['billingMappingVerified'] = False
        policy['runnerRates']['ubuntu-24.04'].update(usdPerMinute=None, verifiedOn=None)
        for charge in policy['additionalCharges'].values():
            charge.update(applicability='unknown', maximumUnitsPerJobAttempt=None,
                          usdPerUnit=None, verifiedOn=None)
        policy['allowances'].update(workflowUSD='0.00', experimentUSD='0.00', safetyUSD='0.00',
                                    maximumPaidJobs=0, maximumPaidMinutes=0, maximumPaidAttempts=0)
        return policy

    def test_disabled_policy_with_unknown_bootstrap_refuses_every_scope(self):
        policy = self.disabled_policy()
        for mode, selection in [('preflight', {}), ('full', {}),
                ('diagnostic', {'platform': 'linux-x64', 'component': 'load', 'suite': 'load'})]:
            with self.subTest(mode=mode):
                result = self.plan(mode, policy=policy, **selection)
                self.assertFalse(result['admitted'])
                self.assertFalse(result['native-enabled'])
                self.assertIn('unknown runner rate: ubuntu-24.04', result['reasons'])
                self.assertIsNone(result['totals']['maximumUSD'])
        self.assertFalse(self.guard(policy=policy)['admitted'])

    def test_authorization_window_is_inclusive_and_old_policies_remain_valid(self):
        self.assertTrue(self.plan()['admitted'])
        first, last = AS_OF + timedelta(days=1), AS_OF + timedelta(days=2)
        self.policy['authorization'].update(validFrom=first.isoformat(), validUntil=last.isoformat())
        for current in (first, last):
            with self.subTest(current=current):
                self.assertTrue(self.plan(as_of=current)['admitted'])
        for current in (first - timedelta(days=1), last + timedelta(days=1)):
            with self.subTest(current=current):
                result = self.plan(as_of=current)
                self.assertFalse(result['admitted'])
                self.assertFalse(result['native-enabled'])
                self.assertIn('current date is outside hosted authorization validity window', result['reasons'])
        self.policy['authorization']['validUntil'] = first.isoformat()
        self.assertTrue(self.plan(as_of=first)['admitted'])

    def test_expired_authorization_rejects_fresh_and_saved_rerun_guards(self):
        self.policy['authorization'].update(validFrom=AS_OF.isoformat(), validUntil=AS_OF.isoformat())
        previous = self.plan()
        self.assertTrue(previous['admitted'])
        for saved in (None, previous):
            with self.subTest(saved=saved is not None):
                result = self.guard(as_of=AS_OF + timedelta(days=1), plan=saved,
                                    identity=dict(IDENTITY, runAttempt='2'))
                self.assertFalse(result['admitted'])
                self.assertEqual(result['guard']['reservation']['attempt'], 2)
                self.assertIn('current date is outside hosted authorization validity window', result['reasons'])

    def test_authorization_window_requires_paired_canonical_ordered_dates(self):
        invalid_windows = [
            {'validFrom': '2026-11-12'}, {'validUntil': '2026-11-30'},
            {'validFrom': '2026-11-12', 'validUntil': '2026-11-11'},
            {'validFrom': '20261112', 'validUntil': '2026-11-30'},
            {'validFrom': '2026-11-12', 'validUntil': '2026-11-31'},
            {'validFrom': None, 'validUntil': '2026-11-30'},
            {'validFrom': '2026-11-12', 'validUntil': True},
            {'validFrom': '2026-11-12T00:00:00Z', 'validUntil': '2026-11-30'},
            {'validFrom': '2026-11-12', 'validUntil': '2026-11-30', 'validTo': '2026-11-30'},
        ]
        for window in invalid_windows:
            with self.subTest(window=window), self.assertRaises(ValueError):
                policy = copy.deepcopy(self.policy)
                policy['authorization'].update(window)
                spend.validate_policy(policy)

    def test_fresh_source_identity_keeps_exact_hashes_without_console_inventory(self):
        changed = dict(SOURCE, sourceSHA256='c' * 64)
        sources = iter((SOURCE, changed))
        def query(_repository):
            print('binary-filename-inventory-' * 20000, end='')
            return next(sources)
        with patch.object(spend.native_jobs, 'source_identity', side_effect=query) as queried, \
                redirect_stdout(io.StringIO()) as console:
            first = self.plan(source=None)
            second = self.guard(source=None)
        self.assertEqual(console.getvalue(), '')
        self.assertEqual(queried.call_count, 2)
        self.assertEqual(first, self.plan(source=SOURCE))
        self.assertEqual(second, self.guard(source=changed))
        self.assertNotEqual(first['source']['sourceSHA256'], second['source']['sourceSHA256'])

    def test_source_identity_failure_preserves_actionable_bounded_diagnostics(self):
        def query(_repository):
            print('x' * 10000 + '\nfatal: tracked file cannot be read')
            raise OSError('source identity could not read tracked file')
        with patch.object(spend.native_jobs, 'source_identity', side_effect=query), \
                redirect_stdout(io.StringIO()) as console, redirect_stderr(io.StringIO()) as errors:
            with self.assertRaisesRegex(OSError, 'could not read tracked file'):
                self.plan(source=None)
        self.assertEqual(console.getvalue(), '')
        self.assertIn('fatal: tracked file cannot be read', errors.getvalue())
        self.assertLess(len(errors.getvalue()), 4200)

    def test_cli_compact_output_preserves_complete_full_publication_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'plan.json'
            with patch.dict(os.environ, {'ADMISSION_PUBLICATION': 'true'}, clear=True), \
                    patch.object(spend.native_jobs, 'source_identity', return_value=SOURCE), \
                    patch.object(spend, 'load_policy', return_value=self.policy), \
                    redirect_stdout(io.StringIO()) as console:
                expected = spend.make_plan('full', publication=True, source=SOURCE, policy=self.policy)
                self.assertEqual(spend.main(['plan', '--mode', 'full', '--output', str(output)]), 0)
            saved = json.loads(output.read_text())
            printed = json.loads(console.getvalue())
            self.assertEqual(saved, expected)
            self.assertEqual(len(saved['jobs']), len(spend.workflow_scope.execution_jobs('full', publication=True)))
            self.assertEqual(len(saved['reservations']), len(saved['jobs']) * 2)
            self.assertEqual(printed['planSHA256'], saved['planSHA256'])
            self.assertEqual(printed['sourceCommit'], SOURCE['commit'])
            self.assertEqual(printed['totals'], saved['totals'])
            self.assertTrue(printed['selection']['publication'])
            self.assertNotIn('jobs', printed)
            self.assertNotIn('reservations', printed)
            self.assertLess(len(console.getvalue()), 4096)

    def test_exact_workflow_planner_is_the_only_job_source(self):
        result = self.plan('full', publication=True)
        expected = spend.workflow_scope.execution_jobs('full', publication=True)
        self.assertEqual([{key: row[key] for key in expected[0]} for row in result['jobs']], expected)
        self.assertTrue(result['admitted'])
        self.assertTrue(result['native-enabled'])
        self.assertFalse(result['certificationEstablished'])
        self.assertFalse(result['billingReconciled'])
        identifiers = {row['id'] for row in result['jobs']}
        self.assertTrue({'scope', 'source', 'maintenance', 'complete', 'documentation-site',
                         'publish-documentation', 'linux-x64/coverage', 'macos-arm64/coverage'} <= identifiers)
        self.assertEqual(len(result['reservations']), len(expected) * 2)

    def test_each_job_and_attempt_rounds_independently_and_reserves_rejected_entry(self):
        jobs = [{'id': 'scope', 'group': 'ubuntu-24.04', 'maximumSeconds': 61},
                {'id': 'source', 'group': 'ubuntu-24.04', 'maximumSeconds': 60}]
        with patch.object(spend.workflow_scope, 'execution_jobs', return_value=jobs):
            plan = self.plan()
        self.assertEqual(plan['totals']['maximumMinutes'], 6)
        self.assertEqual(Decimal(plan['totals']['runnerUSD']), Decimal('0.06'))
        self.assertEqual(Decimal(plan['totals']['maximumUSD']), Decimal('1.56'))
        self.assertEqual(plan['totals']['includedEntryReserveUSD'], plan['totals']['runnerUSD'])
        self.assertTrue(all(row['entryMaximumMinutes'] == row['billedMaximumMinutes']
                            for row in plan['reservations']))
        jobs[0]['maximumSeconds'] = 59
        with patch.object(spend.workflow_scope, 'execution_jobs', return_value=jobs), \
                self.assertRaisesRegex(ValueError, 'startup/checkout'):
            self.plan()

    def test_platforms_and_jobs_cannot_each_spend_the_remaining_balance(self):
        result = self.plan('full')
        ids = [row['id'] for row in result['reservations']]
        self.assertEqual(len(ids), len(set(ids)))
        by_platform = {}
        for row in result['reservations']:
            key = row['jobID'].split('/')[0]
            by_platform[key] = by_platform.get(key, Decimal(0)) + Decimal(row['totalUSD'])
        summed = sum(by_platform.values()) + Decimal(result['totals']['safetyUSD'])
        self.assertEqual(summed, Decimal(result['totals']['maximumUSD']))
        # Each platform individually fits, but their sum plus shared work does not.
        self.policy['allowances']['workflowUSD'] = str(max(by_platform['linux-x64'], by_platform['macos-arm64']))
        rejected = self.plan('full')
        self.assertFalse(rejected['admitted'])
        self.assertIn('maximum cost exceeds workflow/experiment allowance', rejected['reasons'])

    def test_unknown_stale_future_and_unverified_rates_reject_expansion(self):
        cases = [('unknown', None, None, False, 'unknown runner rate'),
            ('stale', '0.01', (AS_OF - timedelta(days=31)).isoformat(), True, 'stale or future'),
            ('future', '0.01', (AS_OF + timedelta(days=1)).isoformat(), True, 'stale or future'),
            ('unverified', '0.01', AS_OF.isoformat(), False, 'mapping is unverified')]
        for name, amount, verified_on, mapping, message in cases:
            with self.subTest(name=name):
                policy = copy.deepcopy(self.policy)
                policy['runnerRates']['ubuntu-24.04'].update(usdPerMinute=amount,
                    verifiedOn=verified_on, billingMappingVerified=mapping)
                result = self.plan(policy=policy)
                self.assertFalse(result['admitted'])
                self.assertIsNone(result['totals']['maximumUSD'])
                self.assertTrue(any(message in reason for reason in result['reasons']))
        del self.policy['runnerRates']['ubuntu-24.04']
        self.assertIn('unknown runner group: ubuntu-24.04', self.plan()['reasons'])

    def test_storage_and_transfer_require_bounded_or_affirmative_zero_pricing(self):
        for name in ('storage', 'transfer'):
            with self.subTest(name=name):
                policy = copy.deepcopy(self.policy)
                policy['additionalCharges'][name].update(applicability='unknown',
                    maximumUnitsPerJobAttempt=None, usdPerUnit=None, verifiedOn=None)
                result = self.plan(policy=policy)
                self.assertFalse(result['admitted'])
                self.assertIn('unknown ' + name + ' pricing/applicability', result['reasons'])
        self.policy['additionalCharges']['storage'].update(applicability='bounded',
            maximumUnitsPerJobAttempt='90', usdPerUnit='0.01')
        self.policy['additionalCharges']['transfer'].update(applicability='bounded',
            maximumUnitsPerJobAttempt='3', usdPerUnit='0.02')
        result = self.plan()
        count = len(result['reservations'])
        self.assertEqual(Decimal(result['totals']['storageUSD']), Decimal('0.90') * count)
        self.assertEqual(Decimal(result['totals']['transferUSD']), Decimal('0.06') * count)
        self.policy['additionalCharges']['transfer']['verifiedOn'] = '2026-01-01'
        self.assertTrue(any('stale or future transfer' in reason for reason in self.plan()['reasons']))

    def test_limits_invalid_allowances_and_huge_attempt_count_fail_closed(self):
        for field in ('maximumPaidJobs', 'maximumPaidMinutes', 'maximumPaidAttempts'):
            with self.subTest(field=field):
                policy = copy.deepcopy(self.policy)
                policy['allowances'][field] = 0
                self.assertFalse(self.plan(policy=policy)['admitted'])
        for field, invalid in [('workflowUSD', '-1'), ('safetyUSD', 'NaN'), ('maximumPaidJobs', True)]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                policy = copy.deepcopy(self.policy)
                policy['allowances'][field] = invalid
                self.plan(policy=policy)
        self.policy['authorization']['maximumRunAttempts'] = 10 ** 12
        with self.assertRaisesRegex(ValueError, 'cannot exceed 100'):
            self.plan()

    def test_current_attempt_guard_rejects_stale_outputs_and_exhausted_attempts(self):
        plan = self.plan()
        first = self.guard(plan=plan, group='ubuntu-24.04')
        self.assertTrue(first['admitted'])
        next_identity = dict(IDENTITY, runAttempt='2')
        second = self.guard(identity=next_identity)
        self.assertTrue(second['admitted'])
        self.assertEqual(second['guard']['reservation']['attempt'], 2)
        self.assertEqual(second['totals'], first['totals'])
        stale = self.guard(identity=next_identity, plan=plan)
        self.assertFalse(stale['admitted'])
        third = self.guard(identity=dict(IDENTITY, runAttempt='3'))
        self.assertFalse(third['admitted'])
        self.assertIsNone(third['guard']['reservation'])
        self.assertIn('current run attempt exceeds fixed attempt reservations', third['reasons'])

    def test_source_run_scope_reservation_and_runner_tampering_cannot_grant_work(self):
        plan = self.plan()
        for field in ('source', 'runID', 'reservations', 'policySHA256'):
            with self.subTest(field=field):
                changed = copy.deepcopy(plan)
                changed[field] = None
                self.assertFalse(self.guard(plan=changed)['admitted'])
        self.assertFalse(self.guard(plan=plan, source=dict(SOURCE, commit='c' * 40))['admitted'])
        self.assertFalse(self.guard(plan=plan, identity=dict(IDENTITY, runID='101'))['admitted'])
        self.assertFalse(self.guard('linux-x64/build/root')['admitted'])
        self.assertFalse(self.guard(group='MacOS-26-5')['admitted'])
        with self.assertRaisesRegex(ValueError, 'run attempt differs'):
            self.plan(run_attempt='2')

    def test_duplicate_branch_trigger_and_untrusted_repository_are_rejected(self):
        identities = [dict(IDENTITY, event='push', ref='refs/heads/feature'),
                      dict(IDENTITY, repository='other/DiscordKit'),
                      dict(IDENTITY, event='schedule'), dict(IDENTITY, defaultBranch='')]
        for identity in identities:
            with self.subTest(identity=identity):
                self.assertFalse(self.plan(identity=identity)['admitted'])
        self.assertTrue(self.plan(identity=dict(IDENTITY, event='push'))['admitted'])
        pull_request = dict(IDENTITY, event='pull_request', ref='refs/pull/20/merge', headRef='feature', baseRef='main')
        self.assertTrue(self.plan(identity=pull_request)['admitted'])

    def test_local_missing_hosted_identity_and_closed_native_rollout_cannot_authorize(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertFalse(self.plan(identity=None)['admitted'])
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}, clear=True):
            self.assertFalse(self.plan(identity=None)['admitted'])
        with patch.object(spend.workflow_scope, 'rollout', return_value={'nativeExpansionEnabled': False}):
            result = self.plan('diagnostic', platform='linux-x64', component='load')
            self.assertTrue(result['admitted'])
            self.assertFalse(result['native-enabled'])
            guard = self.guard('linux-x64/canary', mode='diagnostic', platform='linux-x64', component='load')
            self.assertFalse(guard['admitted'])

    def test_qualification_fault_is_sealed_and_cannot_expand_or_reset_reservations(self):
        options = dict(platform='linux-x64', component='root', suite='DiscordBitsTests')
        ordinary = self.plan('diagnostic', **options)
        fault = self.plan('diagnostic', qualification_fault=True, **options)
        self.assertTrue(fault['admitted'])
        self.assertTrue(fault['selection']['qualificationFault'])
        self.assertEqual(fault['jobs'], ordinary['jobs'])
        self.assertEqual(fault['reservations'], ordinary['reservations'])
        self.assertNotEqual(fault['planSHA256'], ordinary['planSHA256'])
        second = self.plan('diagnostic', qualification_fault=True,
                           identity=dict(IDENTITY, runAttempt='2'), **options)
        self.assertEqual(fault['reservations'], second['reservations'])
        with patch.object(spend.native_jobs, 'source_identity') as query:
            with self.assertRaises(ValueError):
                spend.make_plan('full', qualification_fault=True, policy=self.policy,
                                as_of=AS_OF, identity=IDENTITY)
            query.assert_not_called()

    def test_enabled_rollout_still_refuses_disabled_authorization(self):
        result = self.plan('diagnostic', platform='linux-x64', component='root',
                           suite='DiscordBitsTests', qualification_fault=True,
                           policy=self.disabled_policy())
        self.assertFalse(result['admitted'])
        self.assertFalse(result['native-enabled'])

    def test_documentation_request_is_single_bootstrap_scope_and_full_only_publication(self):
        result = self.plan('documentation-request')
        self.assertEqual([row['id'] for row in result['jobs']], ['documentation-request'])
        self.assertTrue(result['admitted'])
        self.assertFalse(result['native-enabled'])
        for arguments in ({'publication': True}, {'platform': 'linux-x64'}, {'component': 'load'}):
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                self.plan('documentation-request', **arguments)
        with self.assertRaisesRegex(ValueError, 'publication requires full'):
            self.plan(publication=True)

    def test_cli_environment_selection_is_current_and_rejected_plan_is_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'plan.json'
            env_output = Path(directory) / 'output'
            step_summary = Path(directory) / 'summary'
            env = {'ADMISSION_MODE': 'diagnostic', 'ADMISSION_PLATFORM': 'linux-x64',
                   'ADMISSION_COMPONENT': 'load', 'ADMISSION_SUITE': 'load',
                   'GITHUB_OUTPUT': str(env_output), 'GITHUB_STEP_SUMMARY': str(step_summary)}
            with patch.dict(os.environ, env, clear=True), \
                    patch.object(spend.native_jobs, 'source_identity', return_value=SOURCE), \
                    patch.object(spend, 'load_policy', return_value=self.disabled_policy()), \
                    redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                self.assertEqual(spend.main(['plan', '--output', str(output)]), 0)
                result = json.loads(output.read_text())
                self.assertEqual(result['mode'], 'diagnostic')
                self.assertEqual(result['selection']['suite'], 'load')
                self.assertFalse(result['admitted'])
                self.assertIn('admitted=false', env_output.read_text())
                self.assertIn('Maximum USD: unknown', step_summary.read_text())
                self.assertEqual(spend.main(['guard', '--job', 'linux-x64/canary', '--group', 'Linux-x64-8',
                                             '--output', str(output)]), 1)
                self.assertEqual(json.loads(output.read_text())['guard']['jobID'], 'linux-x64/canary')

    def test_duplicate_json_keys_and_malformed_policy_reject(self):
        for invalid in ({}, [], {**self.policy, 'authorization': None},
                        {**self.policy, 'entryReserveSeconds': True}):
            with self.subTest(invalid=type(invalid)), self.assertRaises(ValueError):
                spend.validate_policy(invalid)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'policy.json'
            path.write_text('{"schemaVersion":1,"schemaVersion":1}')
            with self.assertRaisesRegex(ValueError, 'duplicate'):
                spend.load_policy(path)


if __name__ == '__main__':
    unittest.main()
