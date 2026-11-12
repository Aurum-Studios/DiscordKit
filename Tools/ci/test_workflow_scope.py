# File: Tools/ci/test_workflow_scope.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Prove contained scope selection, once-only canaries and actual workflow gate wiring."""

from contextlib import redirect_stdout, redirect_stderr
import io
import json
import os
import re
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import native_jobs
import scheduling_policy
import workflow_scope as scope
import workflow_coverage as coverage

ROOT = Path(__file__).resolve().parents[2]


class WorkflowScopeTests(unittest.TestCase):
    def plan(self, mode='full', platform='linux-x64', **filters):
        return scope.platform_plan(mode, platform, commit='a'*40, run_id='42', run_attempt='2', **filters)

    def test_invalid_selection_fails_before_native_planning(self):
        for mode, filters in [('full', {'platform':'linux-x64'}), ('preflight', {'suite':'load'}),
                              ('diagnostic', {}), ('diagnostic', {'platform':'windows-x64','component':'load'}),
                              ('diagnostic', {'platform':'linux-x64','component':'load','suite':'OtherTests'}),
                              ('bad', {})]:
            with self.subTest(mode=mode, filters=filters), self.assertRaises(ValueError):
                scope.select(mode, **filters)

    def test_automatic_and_manual_native_requests_remain_contained(self):
        self.assertEqual(scope.rollout()['automaticMode'], 'preflight')
        scope.authorize('preflight')
        for mode in ('full', 'diagnostic'):
            with self.assertRaisesRegex(ValueError, 'Phase 10'):
                scope.authorize(mode)
        with patch.dict(os.environ, {'CI_NATIVE_ROLLOUT':'true', 'CI_NATIVE_ENABLED':'true'}):
            with self.assertRaises(ValueError):
                scope.authorize('full')

    def test_mutated_rollout_does_not_enable_paid_work(self):
        with patch.object(scope.Path, 'read_text', return_value=json.dumps(
                {'schemaVersion':1,'automaticMode':'full','nativeExpansionEnabled':True,'spendAdmissionImplemented':True})):
            with self.assertRaisesRegex(ValueError, 'reviewed Phase 10'):
                scope.authorize('full')

    def test_manual_rollout_switch_is_distinct_from_paid_admission_and_automatic_scope(self):
        value = {'schemaVersion': 1, 'automaticMode': 'preflight',
                 'nativeExpansionEnabled': True, 'spendAdmissionImplemented': True}
        with patch.object(scope.Path, 'read_text', return_value=json.dumps(value)):
            self.assertEqual(scope.rollout(), value)
            with self.assertRaises(ValueError):
                scope.authorize('full')
        for changes in ({'nativeExpansionEnabled': 1}, {'schemaVersion': True},
                        {'automaticMode': 'full'}, {'spendAdmissionImplemented': False}):
            with patch.object(scope.Path, 'read_text', return_value=json.dumps(dict(value, **changes))):
                with self.subTest(changes=changes), self.assertRaises(ValueError):
                    scope.rollout()

    def test_full_canonical_partition_equals_previous_complete_matrices(self):
        policy=scheduling_policy.load_policy()
        for platform in scope.PREFIXES:
            with self.subTest(platform=platform):
                planned=self.plan(platform=platform)
                builds, tests=native_jobs.matrices(policy['inventory']['rootTargets'],platform)
                self.assertEqual({row['component'] for row in planned['all-builds']['include']},
                                 {row['component'] for row in builds['include']})
                self.assertEqual({(row['component'], suite) for row in
                                  planned['root-tests']['include'] + planned['tests']['include'] for suite in row['suites']} | {('load','load')},
                                 {(row['component'], suite) for row in tests['include'] for suite in row['suites']})
                self.assertEqual(len(planned['root-tests']['include']), 4)
                consumers = [row for row in planned['tests']['include'] if row['component'] == 'consumers']
                self.assertEqual(len(consumers), 1)
                self.assertEqual(consumers[0]['suites'], list(native_jobs.CONSUMER_SUITES))
                self.assertEqual({row['component'] for row in planned['core-builds']['include']}, scope.CORE_COMPONENTS)
                self.assertFalse(scope.CORE_COMPONENTS & {row['component'] for row in planned['builds']['include']})
                self.assertNotIn('load', {row['component'] for row in planned['builds']['include']})
                ids=[row['id'] for row in planned['coverage']['entries']]
                self.assertEqual(ids.count('build/load'),1)
                self.assertEqual(ids.count('canary/load'),1)
                self.assertEqual(len(ids),len(set(ids)))
                coverage.validate_manifest(planned['coverage'])
                self.assertEqual('api' in ids,platform=='macos-arm64')
                self.assertEqual('apple' in ids,platform=='macos-arm64')
                self.assertIn('export',ids)

    def test_scoped_package_does_not_expand_into_unselected_work(self):
        planned=self.plan('diagnostic', component='root',suite='DiscordBitsTests')
        self.assertEqual([row['component'] for row in planned['all-builds']['include']],['load','root'])
        self.assertEqual([row['suite'] for row in planned['root-tests']['include']],['DiscordBitsTests'])
        self.assertEqual(planned['root-tests']['include'][0]['suites'], ['DiscordBitsTests'])
        self.assertFalse(planned['has-tests'])
        ids={row['id'] for row in planned['coverage']['entries']}
        self.assertFalse(ids & {'audit','export','apple','api'})
        self.assertFalse(any(item.startswith('fixture/') for item in ids))

    def test_load_diagnostic_reuses_canary_and_build_only_does_not_add_suites(self):
        for suite in (None,'load'):
            planned=self.plan('diagnostic',component='load',suite=suite)
            self.assertFalse(planned['has-builds'])
            self.assertFalse(planned['has-tests'])
            self.assertEqual(len(planned['all-builds']['include']),1)
        planned=self.plan('diagnostic',component='root')
        self.assertTrue(planned['has-core-builds'])
        self.assertFalse(planned['has-builds'])
        self.assertFalse(planned['has-root-tests'])
        self.assertFalse(planned['has-tests'])

    def test_empty_discovery_or_evaluated_inventory_drift_cannot_plan(self):
        # Execute the real native plan entrypoint with only the compiler query mocked.
        with tempfile.TemporaryDirectory() as temporary:
            for targets in ([],['UnknownTests']):
                with self.subTest(targets=targets), patch('sys.argv', ['native_jobs.py','plan','--mode','full',
                        '--platform','linux-x64','--output',temporary]), patch.object(native_jobs,'dump_targets',return_value=targets), redirect_stderr(io.StringIO()):
                    self.assertEqual(native_jobs.main(),1)
                    self.assertEqual(json.loads((Path(temporary)/'failure.json').read_text())['status'],'failed')

    def test_native_plan_cli_retains_scoped_inventory_and_exact_once_outputs(self):
        policy=scheduling_policy.load_policy()
        with tempfile.TemporaryDirectory() as temporary, patch('sys.argv', ['native_jobs.py','plan','--mode','diagnostic',
                '--platform','linux-x64','--component','load','--suite','load','--output',temporary]), \
                patch.object(native_jobs,'dump_targets',return_value=policy['inventory']['rootTargets']), \
                patch.dict(os.environ, {'GITHUB_SHA':'a'*40,'GITHUB_RUN_ID':'42','GITHUB_RUN_ATTEMPT':'2'}):
            self.assertEqual(native_jobs.main(),0)
            planned=json.loads((Path(temporary)/'scope-plan.json').read_text())
            self.assertEqual(planned,self.plan('diagnostic',component='load',suite='load'))
            self.assertEqual(json.loads((Path(temporary)/'build-matrix.json').read_text()),{'include':[]})

    def successful_summary(self, manifest):
        jobs = {}
        for entry in manifest['entries']:
            job = jobs.setdefault(entry['jobName'], {'id': len(jobs)+1, 'name': entry['jobName'], 'run_id': 42,
                         'run_attempt': int(manifest['runAttempt']), 'head_sha': 'a'*40, 'status': 'completed',
                         'conclusion': 'success', 'steps': []})
            job['steps'].append({'name': entry.get('stepName', 'Run'),
                         'status': 'completed', 'conclusion': 'success'})
        rows = list(jobs.values())
        proofs = {entry['id']: {'artifactID': str(1000 + i), 'artifactDigest': 'sha256:' + 'b'*64,
                    'artifactName': coverage.evidence_prefix(entry['testCoverage'], manifest, manifest['runAttempt']) + '-t1',
                    'receiptSHA256': 'c'*64} for i, entry in enumerate(manifest['entries']) if 'testCoverage' in entry}
        return coverage.validate_jobs(manifest, rows, head_sha='a'*40, test_evidence=proofs)

    def test_full_gate_requires_both_exact_platform_summaries_and_every_shared_row(self):
        results={name:{'result':'success'} for name in ('scope','source','helpers','maintenance','native-linux','native-macos','documentation-site')}
        results['scope']['outputs']={'mode':'full'}
        summaries={platform:self.successful_summary(self.plan(platform=platform)['coverage']) for platform in scope.PREFIXES}
        env={'GITHUB_SHA':'a'*40, 'GITHUB_RUN_ID':'42', 'GITHUB_RUN_ATTEMPT':'2'}
        execution={'repository':'owner/repo','runID':'42','runAttempt':'2'}
        with patch.dict(os.environ,env), patch.object(native_jobs,'source_identity',return_value={'commit':'a'*40}), \
                patch('native_receipts.execution_identity',return_value=execution), \
                patch('artifact_transfer.GitHubArtifactClient'), patch('artifact_index.resolve', return_value={'status':'passed'}), patch.object(coverage,'certify', side_effect=lambda client, **kwargs: self.successful_summary(kwargs['manifest'])) as certify, \
                patch.object(native_jobs,'write_json'):
            self.assertEqual(scope.verify_full(ROOT,results,summaries)['status'],'passed')
            shared=certify.call_args.kwargs['manifest']
            self.assertEqual({row['id'] for row in shared['entries'] if not row['id'].startswith(('linux-x64/','macos-arm64/'))},
                {'scope','source','workflow','maintenance','helper/ci-python','helper/tooling-python',
                 'helper/benchmark-python','helper/browser','documentation-site'})
            old=json.loads(json.dumps(summaries))
            old_manifest=self.plan(platform='linux-x64')['coverage']
            old_manifest['runAttempt']='1'
            old['linux-x64']=self.successful_summary(old_manifest)
            self.assertEqual(scope.verify_full(ROOT,results,old)['status'],'passed')
            forged=json.loads(json.dumps(summaries)); forged['linux-x64']['headSHA']='b'*40
            with self.assertRaisesRegex(ValueError,'API source'):
                scope.verify_full(ROOT,results,forged)
            for platform in summaries:
                changed=json.loads(json.dumps(summaries))
                changed[platform]['entries'].pop()
                with self.subTest(platform=platform),self.assertRaises(ValueError):
                    scope.verify_full(ROOT,results,changed)
            changed=json.loads(json.dumps(summaries)); changed['linux-x64']['mode']='diagnostic'
            with self.assertRaises(ValueError):
                scope.verify_full(ROOT,results,changed)
            with patch.object(coverage,'certify',side_effect=ValueError('missing helper')):
                with self.assertRaises(ValueError):
                    scope.verify_full(ROOT,results,summaries)

    def test_no_failed_skipped_or_missing_shared_gate_qualifies_full(self):
        base={name:{'result':'success'} for name in ('scope','source','helpers','maintenance','native-linux','native-macos','documentation-site')}
        base['scope']['outputs']={'mode':'full'}
        for name in base:
            for state in ('failure','cancelled','skipped'):
                changed=json.loads(json.dumps(base)); changed[name]['result']=state
                with self.subTest(name=name,state=state),self.assertRaises(ValueError):
                    scope.verify_full(ROOT,changed,{})
        del base['maintenance']
        with self.assertRaises(ValueError):
            scope.verify_full(ROOT,base,{})


class WorkflowGraphTests(unittest.TestCase):
    def setUp(self):
        self.ci=(ROOT/'.github/workflows/ci.yml').read_text()
        self.native=(ROOT/'.github/workflows/native-platform.yml').read_text()

    def job(self,text,name):
        return re.split(r'\n  [A-Za-z][\w-]*:\n', text.split('\n  '+name+':\n', 1)[1], maxsplit=1)[0]

    def test_independent_platforms_wait_for_shared_checks(self):
        for job in ('native-linux','native-macos'):
            block=self.job(self.ci,job)
            self.assertIn('needs: [scope, source, helpers, maintenance]',block)
            self.assertIn("native-enabled == 'true'",block)
            self.assertNotIn('needs: [native-',block)

    def test_every_expensive_wave_is_behind_canary(self):
        for job in ('build-core','build-remaining','resolve','tests-root','tests','audit','fixtures','public-api','apple-compilation'):
            block=self.job(self.native,job)
            self.assertRegex(block,r'needs: [^\n]*canary')
        self.assertIn('needs: [plan, build]',self.job(self.native,'canary'))
        self.assertIn('components-json: \'["load"]\'',self.job(self.native,'canary'))
        self.assertIn('--component load --suite load',self.job(self.native,'canary'))
        self.assertIn('needs: coverage',self.job(self.native,'package'))
        self.assertIn("if: inputs.mode == 'full'",self.job(self.native,'package'))

    def test_component_waves_allow_root_runtime_and_core_audits_before_remaining_builds(self):
        for job in ('tests-root', 'audit', 'public-api'):
            block = self.job(self.native, job)
            self.assertIn('build-core', block.split('runs-on:', 1)[0])
            self.assertNotIn('build-remaining', block.split('runs-on:', 1)[0])
        self.assertIn('tests-root', self.job(self.native, 'tests').split('runs-on:', 1)[0])
        for job in ('canary', 'tests-root', 'tests'):
            self.assertIn('test-coverage-', self.job(self.native, job))
            self.assertIn('group-coverage.json', self.job(self.native, job))

    def test_scope_check_names_and_concurrency_do_not_collide(self):
        concurrency=self.ci.split('concurrency:',1)[1].split('\nenv:',1)[0]
        for field in ('mode','platform','component','suite'):
            self.assertIn('inputs.'+field,concurrency)
        complete=self.job(self.ci,'complete')
        self.assertIn("needs.scope.outputs.mode == 'full' && 'Offline certification passed'",complete)
        self.assertIn('Verify full scope and complete coverage',complete)
        self.assertNotIn('name: Offline certification passed\n',complete)

    def test_documentation_requests_share_full_ci_without_automatic_compilation(self):
        docs=(ROOT/'.github/workflows/documentation.yml').read_text()
        self.assertIn('  workflow_dispatch:', docs)
        self.assertNotIn('  push:', docs)
        self.assertNotIn('  pull_request:', docs)
        self.assertNotIn('workflow_run:', docs)
        self.assertNotIn('native_jobs.py', docs)
        self.assertIn('gh workflow run ci.yml', docs)
        self.assertIn('-f mode=full', docs)
        site = self.job(self.ci, 'documentation-site')
        self.assertIn('needs: [scope, native-macos]', site)
        self.assertIn("if: needs.scope.outputs.mode == 'full'", site)
        self.assertIn('documentation_workflow.py prepare-site', site)
        self.assertNotIn('build_docc.py', site)
        self.assertNotIn('upload-pages-artifact', site)
        self.assertIn('documentation-site]', self.job(self.ci, 'complete'))
        publisher = self.job(self.ci, 'publish-documentation')
        self.assertIn('needs: [scope, complete, documentation-site]', publisher)
        self.assertIn('documentation_publication.py', publisher)
        self.assertIn('pages: write', publisher)
        self.assertIn('name: github-pages', publisher)
        api = self.job(self.native, 'public-api')
        for component in ('root', 'macros', 'extensions'):
            self.assertEqual(api.count('documentation_inputs.py prepare --component ' + component), 1)
        self.assertNotIn('build_docc.py', api)


if __name__=='__main__':
    unittest.main()
