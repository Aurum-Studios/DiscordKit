# File: Tools/ci/test_qualification_evidence.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Verify exact-source retained proofs and reject partial or fabricated promotion."""

import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import native_jobs
import native_receipts as receipts
import qualification_evidence as evidence
import test_results
import workflow_scope

REVISION = 'a' * 40
REPOSITORY = 'aurum/DiscordKit'
OPTIONS = {'repository': REPOSITORY, 'revision': REVISION, 'workflow_id': 7}


def run(attempt, conclusion='success'):
    return {'id': 42, 'workflow_id': 7, 'run_attempt': attempt, 'head_sha': REVISION,
            'repository': {'id': 123, 'full_name': REPOSITORY},
            'head_repository': {'id': 123, 'full_name': REPOSITORY},
            'path': evidence.WORKFLOW_PATH, 'event': 'workflow_dispatch',
            'status': 'completed', 'conclusion': conclusion}


def job(name, identifier, attempt=1, conclusion='success', steps=()):
    return {'id': identifier, 'run_id': 42, 'head_sha': REVISION, 'run_attempt': attempt,
            'name': name, 'status': 'completed', 'conclusion': conclusion,
            'steps': [{'name': step, 'status': 'completed', 'conclusion': status}
                      for step, status in steps]}


def snapshot(attempt=1, *, partial=False):
    return {'schemaVersion': 1, 'workflow': {'id': 7, 'path': evidence.WORKFLOW_PATH},
            'scope': copy.deepcopy(evidence.PARTIAL_SCOPE if partial else evidence.FULL_SCOPE),
            'run': run(attempt), 'jobs': []}


def full_snapshot(attempt=1):
    value = snapshot(attempt)
    value['jobs'] = [job('Offline certification passed', 901, attempt,
        steps=[('Verify full scope and complete coverage', 'success')])]
    return value


def execution(component, attempt, *, producer=False):
    return {'scope': 'github', 'repository': REPOSITORY, 'repositoryID': '123',
            'workflowRef': REPOSITORY + '/.github/workflows/ci.yml@refs/heads/main',
            'workflowSHA': REVISION, 'runID': '42', 'runAttempt': str(attempt),
            'jobID': 'build' if producer else 'tests-root' if component == 'root' else 'canary',
            'event': 'workflow_dispatch', 'ref': 'refs/heads/main', 'headRef': '', 'baseRef': ''}


def selection(component, attempt):
    package = native_jobs.PACKAGES[component]
    module = 'DiscordBitsTests' if component == 'root' else 'DiscordKitLoadTestsTests'
    leaves = [module + '.Fixture/test()']
    tests = {package: {module: leaves}}
    producer = receipts.producer_receipt(execution(component, 1, producer=True), tests,
                                        startedAt='2000-01-01T00:00:00Z')
    metadata = {'formatVersion': 2, 'status': 'passed', 'component': component,
        'compatibility': {'identity': {'commit': REVISION, 'sourceSHA256': 'b' * 64,
            'dependencyPinsSHA256': {'Package.resolved': 'c' * 64}, 'repository': str(evidence.ROOT),
            'platform': 'linux-x64', 'system': 'Linux', 'machine': 'x64', 'swiftVersion': 'Swift 6.4.1',
            'swiftTarget': 'linux', 'buildSystem': 'native', 'runtime': {'compiler': 'fixture'},
            'buildEnvironment': {}}, 'build': {'testPackages': [package]}},
        'tests': tests, 'buildRoots': ['.build'], 'payloadSHA256': 'd' * 64, 'producer': producer}
    return {'formatVersion': 1, 'execution': execution(component, attempt), 'sourceCommit': REVISION,
            'platform': 'linux-x64', 'expectedComponents': [component], 'components': {component: {
                'artifactID': '101' if component == 'root' else '102',
                'receiptArtifactID': '201' if component == 'root' else '202',
                'artifactDigest': 'sha256:' + 'e' * 64, 'archiveSHA256': 'f' * 64,
                'artifactName': f'compiled-linux-x64-{component}-{REVISION}-42-1-t1',
                'producer': producer, 'metadata': metadata}}}


def group(component, index, attempt):
    metadata = index['components'][component]['metadata']
    package, inventory = next(iter(metadata['tests'].items()))
    leaves = next(iter(inventory.values()))
    qualified = [package + '::' + leaf for leaf in leaves]
    suite = 'DiscordBitsTests' if component == 'root' else 'load'
    result = {'formatVersion': 1, 'status': 'passed', 'framework': 'swift-testing',
        'eventStreamVersion': test_results.EVENT_STREAM_VERSION, 'expectedLeaves': leaves,
        'executedLeaves': leaves, 'excludedLeaves': {},
        'leaves': {leaf: {'outcome': 'passed', 'parameterized': False, 'caseCount': 1} for leaf in leaves},
        'counts': {'expected': 1, 'executed': 1, 'passed': 1, 'excluded': 0, 'cases': 1}, 'runCount': 1}
    value = {'formatVersion': 1, 'status': 'passed', 'component': component, 'suite': suite,
        'suites': [suite], 'platform': 'linux-x64', 'sourceCommit': REVISION,
        'execution': execution(component, attempt), 'producer': metadata['producer'],
        'compatibility': metadata['compatibility'], 'inventory': metadata['tests'],
        'inventorySHA256': receipts.digest(metadata['tests']), 'expectedLeaves': qualified,
        'executedLeaves': qualified, 'excludedLeaves': {}, 'suiteResults': [{'suite': suite,
            'status': 'passed', 'expectedLeaves': qualified, 'executedLeaves': qualified,
            'excludedLeaves': {}, 'result': result}]}
    return {'receipt': value, 'artifact': {
        'id': 300 + attempt if component == 'root' else 400 + attempt,
        'name': f'test-coverage-linux-x64-{suite}-{REVISION}-42-{attempt}-t1',
        'digest': 'sha256:' + '1' * 64, 'expired': False,
        'workflow_run': {'id': 42, 'repository_id': 123, 'head_repository_id': 123, 'head_sha': REVISION}}}


def partial_snapshots():
    first, current = snapshot(partial=True), snapshot(2, partial=True)
    first['run']['conclusion'] = 'failure'
    manifest = workflow_scope.platform_plan('diagnostic', 'linux-x64', component='root',
        suite='DiscordBitsTests', commit=REVISION, run_id='42', run_attempt='2')['coverage']
    for number, entry in enumerate(manifest['entries'], 10):
        steps = [(entry['stepName'], 'success')]
        if entry['id'] == 'suite/root/DiscordBitsTests':
            first['jobs'].append(job(entry['jobName'], number, conclusion='failure',
                                    steps=steps + [(evidence.FAULT_STEP, 'failure')]))
            current['jobs'].append(job(entry['jobName'], number + 100, 2,
                                      steps=steps + [(evidence.FAULT_STEP, 'success')]))
        else:
            first['jobs'].append(job(entry['jobName'], number, steps=steps))
    current['jobs'] += [job('Linux x64 / Platform validation passed', 501, 2),
                        job('Diagnostic scope passed', 502, 2)]
    first['selections'] = {component: selection(component, 1) for component in ('load', 'root')}
    current['selections'] = copy.deepcopy(first['selections'])
    current['selections']['root']['execution']['runAttempt'] = '2'
    first['groups'] = {component: group(component, first['selections'][component], 1)
                       for component in ('load', 'root')}
    current['groups'] = copy.deepcopy(first['groups'])
    current['groups']['root'] = group('root', current['selections']['root'], 2)
    return first, current


class FullEvidenceTests(unittest.TestCase):
    def test_exact_terminal_full_barrier_is_verified_without_claiming_live_qualification(self):
        result = evidence.verify_full(full_snapshot(2), **OPTIONS)
        self.assertEqual(result['barrierJobID'], '901')
        self.assertEqual(result['runAttempt'], '2')
        self.assertFalse(result['certificationEstablished'])
        self.assertFalse(result['liveObserved'])

    def test_wrong_source_repository_workflow_and_unfinished_run_are_rejected(self):
        mutations = [('head_sha', 'b' * 40), ('workflow_id', 8), ('path', '.github/workflows/release.yml'),
                     ('status', 'in_progress'), ('conclusion', 'failure'), ('event', 'pull_request'),
                     ('repository', {'id': 999, 'full_name': 'other/DiscordKit'})]
        for key, value in mutations:
            snapshot = full_snapshot()
            snapshot['run'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                evidence.verify_full(snapshot, **OPTIONS)

    def test_diagnostic_preflight_and_old_or_future_gate_cannot_qualify(self):
        for name in ('Diagnostic scope passed', 'Preflight scope passed'):
            snapshot = full_snapshot()
            snapshot['jobs'][0]['name'] = name
            with self.subTest(name=name), self.assertRaises(ValueError):
                evidence.verify_full(snapshot, **OPTIONS)
        for attempt in (1, 3):
            snapshot = full_snapshot(2)
            snapshot['jobs'][0]['run_attempt'] = attempt
            with self.subTest(attempt=attempt), self.assertRaises(ValueError):
                evidence.verify_full(snapshot, **OPTIONS)

    def test_missing_skipped_or_duplicate_coverage_step_fails(self):
        for steps in ([], [('Verify full scope and complete coverage', 'skipped')],
                      [('Verify full scope and complete coverage', 'success')] * 2):
            snapshot = full_snapshot()
            snapshot['jobs'][0]['steps'] = job('', 1, steps=steps)['steps']
            with self.subTest(steps=steps), self.assertRaises(ValueError):
                evidence.verify_full(snapshot, **OPTIONS)


class PartialEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.before, self.after = partial_snapshots()

    def verify(self):
        return evidence.verify_partial(self.before, self.after, **OPTIONS)

    def test_partial_rerun_keeps_both_immutable_producers_and_runs_a_new_consumer(self):
        result = self.verify()
        self.assertEqual(result['consumerJobID'], '116')
        self.assertEqual(set(result['producers']), {'root', 'load'})
        self.assertTrue(all(row['producerAttempt'] == '1' for row in result['producers'].values()))
        self.assertFalse(result['certificationEstablished'])

    def test_changed_run_source_or_scope_fails(self):
        for key, value in (('id', 43), ('head_sha', 'b' * 40), ('run_attempt', 3)):
            before, after = partial_snapshots()
            after['run'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                evidence.verify_partial(before, after, **OPTIONS)
        self.after['scope']['suite'] = 'DiscordHTTPTests'
        with self.assertRaises(ValueError):
            self.verify()

    def test_producer_rebuild_or_changed_immutable_archive_fails(self):
        producer = next(row for row in self.before['jobs'] if 'Builds / ' in row['name'])
        self.after['jobs'].append({**producer, 'id': 999, 'run_attempt': 2})
        with self.assertRaisesRegex(ValueError, 'reran a producer'):
            self.verify()
        self.before, self.after = partial_snapshots()
        self.after['selections']['root']['components']['root']['archiveSHA256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'changed an immutable'):
            self.verify()

    def test_corrupt_producer_receipt_and_missing_coverage_are_rejected(self):
        self.after['selections']['root']['components']['root']['metadata']['payloadSHA256'] = 'corrupt'
        with self.assertRaises(ValueError):
            self.verify()
        self.before, self.after = partial_snapshots()
        self.after['groups']['root']['receipt']['executedLeaves'] = []
        with self.assertRaises(ValueError):
            self.verify()

    def test_stale_or_future_consumer_selection_and_result_fail(self):
        for field in ('selection', 'receipt'):
            for attempt in ('1', '3'):
                self.before, self.after = partial_snapshots()
                value = self.after['selections']['root'] if field == 'selection' else self.after['groups']['root']['receipt']
                value['execution']['runAttempt'] = attempt
                with self.subTest(field=field, attempt=attempt), self.assertRaises(ValueError):
                    self.verify()

    def test_fresh_consumer_cannot_relabel_the_original_immutable_result(self):
        self.after['groups']['root']['artifact']['id'] = self.before['groups']['root']['artifact']['id']
        with self.assertRaisesRegex(ValueError, 'fresh immutable consumer'):
            self.verify()

    def test_missing_or_wrong_intentional_failure_marker_fails(self):
        for conclusion in ('success', 'skipped', 'cancelled'):
            self.before, self.after = partial_snapshots()
            consumer = next(row for row in self.before['jobs'] if 'Tests / DiscordBitsTests' in row['name'])
            consumer['steps'][-1]['conclusion'] = conclusion
            with self.subTest(conclusion=conclusion), self.assertRaises(ValueError):
                self.verify()

    def test_real_consumer_assertion_failure_cannot_be_fault_proof(self):
        consumer = next(row for row in self.before['jobs'] if 'Tests / DiscordBitsTests' in row['name'])
        consumer['steps'][0]['conclusion'] = 'failure'
        with self.assertRaises(ValueError):
            self.verify()

    def test_missing_expected_work_and_expired_test_artifacts_fail(self):
        self.before['jobs'] = [row for row in self.before['jobs'] if 'Resolve immutable' not in row['name']]
        with self.assertRaises(ValueError):
            self.verify()
        self.before, self.after = partial_snapshots()
        self.after['groups']['root']['artifact']['expired'] = True
        with self.assertRaises(ValueError):
            self.verify()

    def test_diagnostic_never_accepts_a_full_named_release_gate(self):
        gate = full_snapshot(2)['jobs'][0]
        self.after['jobs'].append(gate)
        with self.assertRaisesRegex(ValueError, 'never establish release'):
            self.verify()

    def test_fault_proof_rejects_extra_native_work_on_either_platform(self):
        for name in ('macOS ARM64 / Canary / load tests and smokes',
                     'Linux x64 / Public API and DocC / macOS ARM'):
            self.before, self.after = partial_snapshots()
            self.before['jobs'].append(job(name, 998))
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'outside the fixed'):
                self.verify()

    def test_root_diagnostic_barrier_must_finish_in_the_new_attempt(self):
        self.after['jobs'] = [row for row in self.after['jobs'] if row['name'] != 'Diagnostic scope passed']
        with self.assertRaisesRegex(ValueError, 'missing or duplicate qualification job'):
            self.verify()

    def test_cli_reads_retained_json_and_writes_only_local_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            before, after, output = root / 'before.json', root / 'after.json', root / 'verified.json'
            before.write_text(json.dumps(self.before))
            after.write_text(json.dumps(self.after))
            with patch('sys.stdout', new=io.StringIO()):
                code = evidence.main(['partial', '--before', str(before), '--after', str(after),
                    '--repository', REPOSITORY, '--revision', REVISION, '--workflow-id', '7',
                    '--output', str(output)])
            self.assertEqual(code, 0)
            self.assertFalse(json.loads(output.read_text())['liveObserved'])

    def test_duplicate_json_keys_are_rejected_before_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'snapshot.json'
            path.write_text('{"schemaVersion":1,"schemaVersion":1}')
            with self.assertRaisesRegex(ValueError, 'duplicate'):
                evidence.read_snapshot(path)

    def test_failed_cli_replaces_a_stale_success_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            snapshot, output = root / 'snapshot.json', root / 'verification.json'
            snapshot.write_text(json.dumps(full_snapshot()))
            output.write_text('{"status":"passed","certificationEstablished":true}')
            with patch('sys.stderr', new=io.StringIO()):
                code = evidence.main(['full', '--snapshot', str(snapshot), '--repository', REPOSITORY,
                    '--revision', 'b' * 40, '--workflow-id', '7', '--output', str(output)])
            self.assertEqual(code, 1)
            failed = json.loads(output.read_text())
            self.assertEqual(failed['status'], 'failed')
            self.assertFalse(failed['certificationEstablished'])

    def test_snapshot_size_bound_is_enforced_before_loading_json(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'snapshot.json'
            path.write_text('{"schemaVersion":1}')
            with patch.object(evidence, 'MAX_SNAPSHOT_BYTES', 4), self.assertRaisesRegex(ValueError, 'size bound'):
                evidence.read_snapshot(path)


if __name__ == '__main__':
    unittest.main()
