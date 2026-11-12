#!/usr/bin/env python3
# File: Tools/ci/workflow_scope.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Plan scoped CI and its exact job coverage without granting paid admission."""

import argparse
import json
import os
from pathlib import Path

import native_jobs
import scheduling_policy

ROOT = Path(__file__).resolve().parents[2]
ROLLOUT = Path(__file__).with_name('rollout.v1.json')
PREFIXES = {'linux-x64': 'Linux x64', 'macos-arm64': 'macOS ARM64'}


def rollout():
    """Phase 10 must replace this closed admission contract before native expansion."""
    value = json.loads(ROLLOUT.read_text())
    if value != {'schemaVersion': 1, 'automaticMode': 'preflight',
                 'nativeExpansionEnabled': False, 'spendAdmissionImplemented': False}:
        raise ValueError('rollout settings require reviewed Phase 10 admission')
    return value


def select(mode, *, platform=None, component=None, suite=None, repository=ROOT):
    """Reject invalid filters before constructing jobs, including compiler-free preflight."""
    return scheduling_policy.plan_scope(scheduling_policy.load_policy(), mode, platform=platform or None,
                                       component=component or None, suite=suite or None, repository=repository)


def authorize(mode):
    """Neither a dispatch input nor a repository variable supplies execution authorization."""
    rollout()
    if mode != 'preflight':
        raise ValueError('native execution contained: Phase 10 spend admission is not implemented; '
                         'a separately reviewed bounded bootstrap probe is required')


CORE_COMPONENTS = frozenset(('root', 'macros', 'extensions', 'tooling'))


def platform_plan(mode, platform, *, component=None, suite=None, repository=ROOT,
                  commit, run_id, run_attempt):
    """Partition the load canary once; all other jobs follow only its own platform."""
    if platform not in PREFIXES or mode not in ('full', 'diagnostic'):
        raise ValueError('native planning requires full or diagnostic and a supported platform')
    scope = select(mode, platform=platform if mode == 'diagnostic' else None,
                   component=component, suite=suite, repository=repository)
    builds = [row.copy() for row in scope['nativeBuilds'] if row['platform'] == platform]
    tests = [row.copy() for row in scope['nativeSuites'] if row['platform'] == platform]
    # Every scope explicitly includes the same complete load round trip. Its tests
    # and smokes are canonical once, never replayed in the remaining matrix.
    canary = {**native_jobs.runner_entry(platform, True), 'component': 'load'}
    core_builds = [row for row in builds if row['component'] in CORE_COMPONENTS]
    remaining_builds = [row for row in builds if row['component'] not in CORE_COMPONENTS | {'load'}]
    remaining_tests = [row for row in tests if row['component'] != 'load']
    all_builds = [canary, *core_builds, *remaining_builds]
    root_tests = [row for row in remaining_tests if row['component'] == 'root']
    other_tests = [row for row in remaining_tests if row['component'] != 'root']
    prefix = PREFIXES[platform] + ' / '
    entries = []
    def entry(identifier, name, step=None, test=None):
        row = {'id': identifier, 'jobName': prefix + name}
        if step:
            row['stepName'] = step
        if test is not None:
            row['testCoverage'] = {'platform': platform, 'component': test['component'],
                                   'suite': test['suite'], 'suites': test['suites'],
                                   'jobID': ('canary' if test['component'] == 'load' else
                                             'tests-root' if test['component'] == 'root' else 'tests')}
        entries.append(row)
    entry('probe', 'Platform check', 'Check native host, compiler, linker and runtime')
    entry('plan', 'Plan platform builds and suites', 'Discover owned test targets and assign runner sizes')
    for row in all_builds:
        entry('build/' + row['component'], f"Builds / {platform} / {row['component']}",
              'Share compiled products with independent test jobs')
    entry('canary/load', 'Canary / load tests and smokes', 'Run complete load suite and existing smokes',
          {'component': 'load', 'suite': 'load', 'suites': ['load']})
    if core_builds or remaining_builds:
        entry('resolve', 'Resolve immutable producers', 'Reconcile every expected component without matrix outputs')
    for row in remaining_tests:
        entry('suite/' + row['component'] + '/' + row['suite'], 'Tests / ' + row['suite'],
              'Run selected complete suites without rebuilding', row)
    if mode == 'full':
        entry('audit', 'Documentation, inventory, generation and release audits', 'Run audits using the compiled tooling executable')
        for fixture in ('dsl_compile_fixtures', 'dsl_extension_fixtures'):
            entry('fixture/' + fixture, 'Compiler fixtures / ' + fixture, 'Require positive builds and exact negative compiler diagnostics')
        entry('export', 'Export validated platform source', 'Require full scope before source export'
              if os.environ.get('GITHUB_EVENT_NAME') == 'pull_request' else 'Package the clean source revision validated on this platform')
        if os.environ.get('GITHUB_EVENT_NAME') != 'pull_request':
            entry('export/upload', 'Export validated platform source', 'Upload platform SwiftPM source bundle')
        if platform == 'macos-arm64':
            entry('api', 'Public API and DocC / macOS ARM', 'Compare scoped public API and convert all public DocC modules')
            entry('apple', 'Build Apple minima / device and simulator modules', 'Emit selected modules with installed Xcode SDKs')
    manifest = {'schemaVersion': 1, 'mode': mode, 'platform': platform, 'commit': commit,
                'runID': str(run_id), 'runAttempt': str(run_attempt), 'entries': entries}
    limits = scheduling_policy.load_policy()['concurrency']
    return {'build-concurrency': limits['buildsPerPlatform'],
            'runtime-concurrency': limits['runtimeGroupsPerPlatform'],
            'core-builds': {'include': core_builds}, 'builds': {'include': remaining_builds},
            'root-tests': {'include': root_tests}, 'tests': {'include': other_tests},
            'all-builds': {'include': all_builds}, 'coverage': manifest,
            'has-core-builds': bool(core_builds), 'has-builds': bool(remaining_builds),
            'has-root-tests': bool(root_tests), 'has-tests': bool(other_tests)}


def shared_manifest(*, commit, run_id, run_attempt):
    """Freeze every shared helper row rather than trusting one matrix aggregate."""
    from preflight import GROUPS
    entries = [
        {'id': 'scope', 'jobName': 'Validate scope and contained rollout',
         'stepName': 'Validate all selections before scheduling'},
        {'id': 'source', 'jobName': 'Source policy and workflow syntax',
         'stepName': 'Validate source-only policy and documentation snapshots'},
        {'id': 'workflow', 'jobName': 'Source policy and workflow syntax',
         'stepName': 'Validate workflow syntax and action expressions'},
        {'id': 'maintenance', 'jobName': 'Upstream maintenance review freshness',
         'stepName': 'Require a current upstream review for certification'},
    ]
    entries += [{'id': 'helper/' + group, 'jobName': 'Helper suites / ' + group,
                 'stepName': 'Run bounded balanced helper group'} for group in GROUPS]
    return {'schemaVersion': 1, 'mode': 'full', 'commit': commit, 'runID': str(run_id),
            'runAttempt': str(run_attempt), 'platform': 'shared', 'entries': entries}


def verify_full(repository, results, summaries):
    """Require source-bound complete coverage from both independent platform barriers."""
    from workflow_coverage import validate_summary
    import artifact_index
    expected_jobs = {'scope', 'source', 'helpers', 'maintenance', 'native-linux', 'native-macos'}
    if set(results) != expected_jobs or any(row.get('result') != 'success' for row in results.values()):
        raise ValueError('full certification requires every exact shared and native dependency')
    if results['scope'].get('outputs', {}).get('mode') != 'full':
        raise ValueError('full certification requires validated full scope')
    if set(summaries) != set(PREFIXES):
        raise ValueError('full certification requires both platform summaries')
    commit = native_jobs.source_identity(repository)['commit']
    if commit != os.environ['GITHUB_SHA']:
        raise ValueError('certification checkout differs from selected source')
    current_manifests = {}
    for platform in PREFIXES:
        manifest = platform_plan('full', platform, repository=repository, commit=commit,
                                 run_id=os.environ['GITHUB_RUN_ID'], run_attempt=os.environ['GITHUB_RUN_ATTEMPT'])['coverage']
        current_manifests[platform] = manifest
        # An unaffected successful reusable call is not rerun by GitHub. Its
        # original seal remains useful, while this root barrier rechecks every
        # latest job and every producer at the current attempt below.
        previous = dict(manifest, runAttempt=summaries[platform]['runAttempt'])
        if int(previous['runAttempt']) > int(manifest['runAttempt']):
            raise ValueError('future platform barrier cannot certify this attempt')
        validate_summary(previous, summaries[platform], require_full=True)
    from artifact_transfer import GitHubArtifactClient
    import native_receipts
    import workflow_coverage
    execution = native_receipts.execution_identity(repository)
    client = GitHubArtifactClient(execution['repository'], os.environ.get('GH_TOKEN', ''), execution['runID'])
    shared = shared_manifest(commit=commit, run_id=execution['runID'], run_attempt=execution['runAttempt'])
    for platform, manifest in current_manifests.items():
        shared['entries'] += [{**row, 'id': platform + '/' + row['id']} for row in manifest['entries']]
        shared['entries'].append({'id': platform + '/barrier',
            'jobName': PREFIXES[platform] + ' / Platform validation passed',
            'stepName': 'Verify complete platform coverage in this barrier attempt'})
        components = platform_plan('full', platform, repository=repository, commit=commit,
            run_id=execution['runID'], run_attempt=execution['runAttempt'])['all-builds']
        selected = artifact_index.resolve(client, execution=execution, platform=platform,
                                          components=components, source_commit=commit)
        native_jobs.write_json(Path('.build') / ('full-producers-' + platform + '.json'), selected)
    shared_summary = workflow_coverage.certify(client, manifest=shared, execution=execution, source_commit=commit)
    if any(summary['headSHA'] != shared_summary['headSHA'] for summary in summaries.values()):
        raise ValueError('platform API source differs from fresh full barrier source')
    native_jobs.write_json(Path('.build/full-shared-coverage.json'), shared_summary)
    return {'status': 'passed', 'mode': 'full', 'commit': commit,
            'runID': os.environ['GITHUB_RUN_ID'], 'runAttempt': os.environ['GITHUB_RUN_ATTEMPT']}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('select', 'platform-plan', 'authorize', 'verify-full'))
    parser.add_argument('--mode', choices=scheduling_policy.MODES, default='preflight')
    parser.add_argument('--platform')
    parser.add_argument('--component')
    parser.add_argument('--suite')
    parser.add_argument('--repository', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args(argv)
    try:
        if args.operation == 'verify-full':
            value = verify_full(args.repository, json.loads(os.environ['RESULTS']),
                                json.loads(os.environ['COVERAGE']))
        elif args.operation == 'platform-plan':
            value = platform_plan(args.mode, args.platform, component=args.component or None,
                                  suite=args.suite or None, repository=args.repository,
                                  commit=os.environ['GITHUB_SHA'], run_id=os.environ['GITHUB_RUN_ID'],
                                  run_attempt=os.environ['GITHUB_RUN_ATTEMPT'])
        else:
            if args.operation == 'authorize' and args.platform not in PREFIXES:
                raise ValueError('unsupported contextual native platform')
            scope = select(args.mode, platform=None if args.operation == 'authorize' and args.mode == 'full' else args.platform, component=args.component,
                           suite=args.suite, repository=args.repository)
            authorize(args.mode)
            value = {'mode': scope['mode'], 'native-enabled': False, 'status': 'contained'}
        if args.output:
            native_jobs.write_json(args.output, value)
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
                for key, item in value.items():
                    output.write(key + '=' + (item if isinstance(item, str) else json.dumps(item, separators=(',', ':'))) + '\n')
        print(json.dumps(value, sort_keys=True))
    except (ValueError, OSError, KeyError, TypeError) as error:
        if args.output:
            native_jobs.write_json(args.output, {'status': 'failed', 'operation': args.operation, 'error': str(error)})
        parser.exit(1, str(error) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
