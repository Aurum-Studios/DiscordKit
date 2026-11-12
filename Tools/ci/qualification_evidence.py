#!/usr/bin/env python3
# File: Tools/ci/qualification_evidence.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Verify retained qualification snapshots without network calls or remote writes.

Snapshots are retained observations, not live API authentication. A successful
result verifies their internal contracts; it never establishes native or hosted
qualification by itself. Capture each jobs list from its attempt-specific API
endpoint and annotate every job with that endpoint's run_attempt if omitted.
Parsed group receipts must come from digest-verified downloaded artifacts. This
offline verifier cannot authenticate captured JSON or bind parsed receipt bytes
to an API ZIP digest; that remains part of capture-time artifact verification.
"""

import argparse
import json
from pathlib import Path
import sys

import artifact_index
import github_release
import native_jobs
import native_receipts as receipts
import workflow_coverage
import workflow_scope

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_PATH = '.github/workflows/ci.yml'
FAULT_STEP = 'Inject first-attempt diagnostic consumer failure'
PARTIAL_SCOPE = {'mode': 'diagnostic', 'platform': 'linux-x64', 'component': 'root',
                 'suite': 'DiscordBitsTests', 'qualificationFault': True}
FULL_SCOPE = {'mode': 'full', 'platform': None, 'component': None,
              'suite': None, 'qualificationFault': False}
SNAPSHOT_KEYS = {'schemaVersion', 'workflow', 'scope', 'run', 'jobs'}
MAX_SNAPSHOT_BYTES = 64 * 1024 * 1024
LIMITATIONS = ['Retained JSON is not a live authenticated API observation.',
               'Capture must digest-verify downloaded artifacts before extracting parsed group receipts; '
               'this offline verification does not bind parsed JSON to an API ZIP digest.']


def require(condition, message):
    if not condition:
        raise ValueError(message)


class SnapshotAPI:
    """Expose only the retained current-attempt jobs read used by release tooling."""

    def __init__(self, snapshot):
        self.snapshot = snapshot

    def request(self, path):
        run = self.snapshot['run']
        prefix = f"actions/runs/{int(run['id'])}/attempts/{int(run['run_attempt'])}/jobs?per_page=100&page="
        require(path.startswith(prefix) and path[len(prefix):].isdigit(),
                'snapshot API refuses an unretained endpoint')
        page = int(path[len(prefix):])
        require(page > 0, 'invalid snapshot jobs page')
        return {'jobs': self.snapshot['jobs'][(page - 1) * 100:page * 100]}


def validate_snapshot(snapshot, *, repository, revision, workflow_id, partial=False):
    """Bind one terminal API attempt to the intended repository, workflow and SHA."""
    receipts.object_keys(snapshot, SNAPSHOT_KEYS | ({'selections', 'groups'} if partial else set()),
                         'qualification snapshot')
    require(type(snapshot['schemaVersion']) is int and snapshot['schemaVersion'] == 1,
            'unsupported qualification snapshot version')
    require(isinstance(revision, str) and receipts.SHA1.fullmatch(revision),
            'qualification requires an exact revision')
    require(artifact_index.positive_id(workflow_id), 'qualification requires the observed workflow ID')
    workflow, run = snapshot['workflow'], snapshot['run']
    receipts.object_keys(workflow, {'id', 'path'}, 'qualification workflow')
    require(isinstance(run, dict) and workflow['path'] == WORKFLOW_PATH
            and run.get('path') == WORKFLOW_PATH
            and str(workflow['id']) == str(workflow_id)
            and str(run.get('workflow_id')) == str(workflow_id),
            'qualification workflow identity differs')
    require(artifact_index.positive_id(run.get('id'))
            and artifact_index.positive_id(run.get('run_attempt'))
            and run.get('head_sha') == revision
            and run.get('status') == 'completed'
            and (run.get('head_repository') or {}).get('full_name', '').lower() == repository.lower()
            and (run.get('repository') or {}).get('full_name', '').lower() == repository.lower(),
            'qualification run is not a terminal exact-repository revision')
    require(snapshot['scope'] == (PARTIAL_SCOPE if partial else FULL_SCOPE)
            and type(snapshot['scope']['qualificationFault']) is bool,
            'qualification scope differs from the intended full or fault experiment')
    jobs = snapshot['jobs']
    require(isinstance(jobs, list) and jobs, 'qualification jobs are missing')
    identifiers = set()
    for job in jobs:
        require(isinstance(job, dict) and artifact_index.positive_id(job.get('id'))
                and str(job.get('run_id')) == str(run['id'])
                and job.get('head_sha') == revision
                and str(job.get('run_attempt')) == str(run['run_attempt'])
                and str(job['id']) not in identifiers,
                'snapshot jobs have missing, duplicate, stale or future attempt provenance')
        identifiers.add(str(job['id']))
    return run


def result(kind, run, **details):
    return {'schemaVersion': 1, 'status': 'passed', 'kind': kind,
            'evidenceScope': 'offline-retained-snapshot-verification',
            'liveObserved': False, 'certificationEstablished': False,
            'revision': run['head_sha'], 'runID': str(run['id']),
            'runAttempt': str(run['run_attempt']), 'limitations': list(LIMITATIONS), **details}


def verify_full(snapshot, *, repository, revision, workflow_id):
    """Require the release gate's exact current terminal full barrier and step."""
    run = validate_snapshot(snapshot, repository=repository, revision=revision, workflow_id=workflow_id)
    require(github_release.certified_run(run, repository, revision),
            'full snapshot is not a successful release-eligible push or manual run')
    require(github_release.certification_gate_passed(SnapshotAPI(snapshot), run),
            'full snapshot lacks the exact fresh full-coverage barrier')
    gate = next(job for job in snapshot['jobs'] if job.get('name') == 'Offline certification passed')
    return result('full-barrier', run, barrierJobID=str(gate['id']))


def exact_job(jobs, name, *, attempt=None):
    matches = [job for job in jobs if job.get('name') == name
               and (attempt is None or str(job['run_attempt']) == str(attempt))]
    require(len(matches) == 1, f'missing or duplicate qualification job: {name}')
    return matches[0]


def exact_step(job, name, conclusion):
    steps = job.get('steps', [])
    require(isinstance(steps, list), 'qualification job steps are missing')
    matches = [step for step in steps if isinstance(step, dict) and step.get('name') == name]
    require(len(matches) == 1 and matches[0].get('status') == 'completed'
            and matches[0].get('conclusion') == conclusion,
            f'qualification step did not finish with {conclusion}: {name}')


def selected_producer(snapshot, component, *, revision):
    """Reuse the existing complete native selection validator, including v2 receipts."""
    index = snapshot['selections'][component]
    require(isinstance(index, dict) and index.get('expectedComponents') == [component]
            and index.get('sourceCommit') == revision, 'qualification selection scope differs')
    execution = index['execution']
    artifact_index.validate_run(snapshot['run'], execution, revision)
    entry = index['components'][component]
    artifact_index.validate_selection(index, execution=execution, component=component,
        platform='linux-x64', archive_sha256=entry['archiveSHA256'], metadata=entry['metadata'])
    require(entry['producer']['execution']['runAttempt'] == '1',
            'partial proof producer was rebuilt instead of reused from attempt one')
    return index, entry


def group_proof(snapshot, component, manifest, selected, execution, job):
    """Verify captured result bytes against producer leaves and immutable API provenance."""
    bundle = snapshot['groups'][component]
    receipts.object_keys(bundle, {'receipt', 'artifact'}, 'qualification group evidence')
    entry = next(row for row in manifest['entries']
                 if row.get('testCoverage', {}).get('component') == component)
    attempt = str(job['run_attempt'])
    workflow_coverage.validate_group_receipt(bundle['receipt'], scope=entry['testCoverage'],
        manifest=manifest, metadata=selected['metadata'], execution=execution, job_attempt=attempt)
    artifact_index.validate_artifact(bundle['artifact'], snapshot['run'], execution)
    artifact = bundle['artifact']
    proof = {'artifactID': str(artifact['id']), 'artifactDigest': artifact['digest'],
             'artifactName': artifact['name'], 'receiptSHA256': receipts.digest(bundle['receipt'])}
    workflow_coverage.validate_test_evidence(entry['testCoverage'], manifest, proof, attempt)
    return entry['id'], proof


def verify_partial(before, after, *, repository, revision, workflow_id, source_repository=ROOT):
    """Prove the single fixed cheap fault and a fresh consumer without producer rebuilds."""
    arguments = {'repository': repository, 'revision': revision, 'workflow_id': workflow_id, 'partial': True}
    first = validate_snapshot(before, **arguments)
    current = validate_snapshot(after, **arguments)
    require(str(first['run_attempt']) == '1' and str(current['run_attempt']) == '2'
            and first['conclusion'] == 'failure' and current['conclusion'] == 'success',
            'partial proof requires terminal failed attempt one then successful attempt two')
    for key in ('id', 'workflow_id', 'head_sha', 'event', 'path', 'repository', 'head_repository'):
        require(first[key] == current[key], 'partial proof changes run, workflow, source or repository')
    require(current['event'] == 'workflow_dispatch', 'fault proof requires an explicit diagnostic dispatch')
    for snapshot in (before, after):
        require(not github_release.certification_gate_passed(SnapshotAPI(snapshot), snapshot['run']),
                'diagnostic partial proof must never establish release certification')
        receipts.object_keys(snapshot['selections'], {'load', 'root'}, 'qualification producer selections')
        receipts.object_keys(snapshot['groups'], {'load', 'root'}, 'qualification executed groups')
    require(str(before['groups']['root']['artifact']['id']) != str(after['groups']['root']['artifact']['id']),
            'partial proof must retain fresh immutable consumer evidence')
    prefix = workflow_scope.PREFIXES['linux-x64'] + ' / '
    consumer_name = prefix + 'Tests / DiscordBitsTests'
    old_consumer = exact_job(before['jobs'], consumer_name)
    fresh_consumer = exact_job(after['jobs'], consumer_name)
    require(old_consumer['status'] == fresh_consumer['status'] == 'completed'
            and old_consumer['conclusion'] == 'failure' and fresh_consumer['conclusion'] == 'success'
            and old_consumer['id'] != fresh_consumer['id'], 'partial proof lacks a new successful consumer')
    for consumer in (old_consumer, fresh_consumer):
        exact_step(consumer, 'Run selected complete suites without rebuilding', 'success')
    exact_step(old_consumer, FAULT_STEP, 'failure')
    exact_step(fresh_consumer, FAULT_STEP, 'success')
    require(not any('Builds / ' in str(job.get('name', '')) for job in after['jobs']),
            'partial proof reran a producer build')
    manifest = workflow_scope.platform_plan('diagnostic', 'linux-x64', component='root',
        suite='DiscordBitsTests', repository=source_repository, commit=revision,
        run_id=str(current['id']), run_attempt='2')['coverage']
    all_jobs = before['jobs'] + after['jobs']
    allowed_native = {entry['jobName'] for entry in manifest['entries']} | {
        prefix + 'Verify platform coverage before source export', prefix + 'Platform validation passed'}
    for job in all_jobs:
        name = str(job.get('name', ''))
        if name.startswith(tuple(workflow_coverage.NATIVE_PREFIXES.values())):
            require(name in allowed_native or job.get('conclusion') == 'skipped',
                    'partial proof executed work outside the fixed diagnostic scope')
    chosen = workflow_coverage.select_jobs(manifest, all_jobs, head_sha=revision)
    evidence, immutable = {}, {}
    for component in ('load', 'root'):
        previous_index, previous_entry = selected_producer(before, component, revision=revision)
        index, entry = selected_producer(after, component, revision=revision)
        require(previous_entry == entry, 'partial proof changed an immutable successful producer')
        artifact_index.same_execution(previous_index['execution'], index['execution'], earlier=True)
        expected_attempt = '2' if component == 'root' else '1'
        expected_job = 'tests-root' if component == 'root' else 'canary'
        require(previous_index['execution']['runAttempt'] == '1'
                and previous_index['execution']['jobID'] == expected_job
                and index['execution']['runAttempt'] == expected_attempt
                and index['execution']['jobID'] == expected_job
                and index['execution']['workflowSHA'] == revision,
                'partial proof selection is stale or names a different consumer')
        producer_name = prefix + 'Builds / linux-x64 / ' + component
        producer = exact_job(before['jobs'], producer_name)
        require(producer['status'] == 'completed' and producer['conclusion'] == 'success',
                'partial proof did not retain a successful original producer')
        execution = index['execution']
        group_name = consumer_name if component == 'root' else prefix + 'Canary / load tests and smokes'
        group_job = chosen[group_name]
        # The first root consumer really passed its tests before the deliberate failure.
        if component == 'root':
            first_manifest = dict(manifest, runAttempt='1')
            group_proof(before, component, first_manifest, previous_entry,
                        previous_index['execution'], old_consumer)
        identifier, proof = group_proof(after, component, manifest, entry, execution, group_job)
        evidence[identifier] = proof
        immutable[component] = {'artifactID': entry['artifactID'], 'artifactDigest': entry['artifactDigest'],
                                'producerAttempt': '1'}
    summary = workflow_coverage.validate_jobs(manifest, all_jobs, head_sha=revision, test_evidence=evidence)
    workflow_coverage.validate_summary(manifest, summary)
    for name in (prefix + 'Platform validation passed', 'Diagnostic scope passed'):
        job = exact_job(after['jobs'], name)
        require(job['status'] == 'completed' and job['conclusion'] == 'success',
                'partial proof current diagnostic barriers did not pass')
    return result('partial-rerun', current, consumerJobID=str(fresh_consumer['id']),
                  producers=immutable, coverageSHA256=receipts.digest(summary))


def read_snapshot(path):
    path = Path(path)
    require(path.is_file() and 0 < path.stat().st_size <= MAX_SNAPSHOT_BYTES,
            'qualification snapshot is missing, empty or exceeds its size bound')
    with path.open() as stream:
        return receipts.read_json(stream)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('full', 'partial'))
    parser.add_argument('--snapshot', type=Path)
    parser.add_argument('--before', type=Path)
    parser.add_argument('--after', type=Path)
    parser.add_argument('--repository', required=True, help='Expected GitHub owner/repository')
    parser.add_argument('--revision', required=True)
    parser.add_argument('--workflow-id', required=True)
    parser.add_argument('--source-repository', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path)
    arguments = parser.parse_args(argv)
    try:
        options = {'repository': arguments.repository, 'revision': arguments.revision,
                   'workflow_id': arguments.workflow_id}
        if arguments.operation == 'full':
            require(arguments.snapshot is not None and arguments.before is None and arguments.after is None,
                    'full verification requires only --snapshot')
            report = verify_full(read_snapshot(arguments.snapshot), **options)
        else:
            require(arguments.before is not None and arguments.after is not None and arguments.snapshot is None,
                    'partial verification requires --before and --after')
            report = verify_partial(read_snapshot(arguments.before), read_snapshot(arguments.after),
                                    source_repository=arguments.source_repository, **options)
        if arguments.output:
            native_jobs.write_json(arguments.output, report)
        print(json.dumps(report, sort_keys=True))
        return 0
    except (ValueError, KeyError, TypeError, OSError) as error:
        failed = {'schemaVersion': 1, 'status': 'failed',
                  'evidenceScope': 'offline-retained-snapshot-verification',
                  'liveObserved': False, 'certificationEstablished': False,
                  'limitations': list(LIMITATIONS), 'error': str(error)}
        if arguments.output:
            native_jobs.write_json(arguments.output, failed)
        print(f'qualification snapshot verification failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
