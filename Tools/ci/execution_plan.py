#!/usr/bin/env python3
# File: Tools/ci/execution_plan.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Expand the execution matrices and read their enclosing workflow cost bounds."""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
CI_JOBS = {'scope', 'source', 'helpers', 'maintenance', 'native-linux', 'native-macos',
           'documentation-site', 'complete', 'publish-documentation'}
NATIVE_JOBS = {'platform', 'plan', 'build', 'canary', 'build-core', 'build-remaining',
               'resolve', 'tests-root', 'tests', 'audit', 'fixtures', 'public-api',
               'apple-compilation', 'coverage', 'package', 'complete'}


def workflow_jobs(repository, name, expected):
    """Fail on unaccounted jobs or nonliteral outer deadlines rather than guessing."""
    text = (Path(repository) / '.github/workflows' / name).read_text()
    sections = re.split(r'^jobs:\n', text, maxsplit=1, flags=re.M)
    if len(sections) != 2:
        raise ValueError(f'missing execution jobs in {name}')
    parts = re.split(r'^  ([A-Za-z_][A-Za-z0-9_-]*):\n', sections[1], flags=re.M)
    if len(parts[1::2]) != len(set(parts[1::2])):
        raise ValueError(f'duplicate execution jobs in {name}')
    jobs = dict(zip(parts[1::2], parts[2::2]))
    if set(jobs) != expected:
        raise ValueError(f'unaccounted execution jobs in {name}')
    return jobs


def maximum_seconds(block):
    limits = re.findall(r'^    timeout-minutes: ([1-9][0-9]*)$', block, flags=re.M)
    if len(limits) != 1:
        raise ValueError('execution job requires one literal enclosing timeout')
    return int(limits[0]) * 60


def validate_runner_mappings(ci, native, docs, helper_groups):
    """Unknown runner/matrix edits must fail at bootstrap, before runner startup."""
    import native_jobs

    for jobs, matrix_jobs in ((ci, {'helpers'}), (docs, set()), (native,
            {'build', 'build-core', 'build-remaining', 'tests-root', 'tests', 'fixtures'})):
        for job, block in jobs.items():
            if bool(re.search(r'^    strategy:', block, flags=re.M)) != (job in matrix_jobs):
                raise ValueError('unaccounted workflow matrix strategy')

    def check(block, expected):
        match = re.search(r'^    runs-on:\s*\n      group: (.+)$', block, flags=re.M)
        if match is None:
            match = re.search(r'^    runs-on: (.+)$', block, flags=re.M)
        if match is None or match[1] != expected:
            raise ValueError('workflow runner mapping differs from the exact execution planner')

    for job, block in ci.items():
        if job in ('native-linux', 'native-macos'):
            platform = 'linux-x64' if job == 'native-linux' else 'macos-arm64'
            for field, group in [('runner-group', native_jobs.runner_entry(platform, False)['group']),
                                 ('build-group', native_jobs.runner_entry(platform, True)['group'])]:
                if not re.search(r'^      ' + field + ': ' + re.escape(group) + '$', block, flags=re.M):
                    raise ValueError('reusable caller runner mapping differs from execution')
            if not re.search(r'^      platform: ' + platform + '$', block, flags=re.M):
                raise ValueError('reusable caller platform differs from execution')
        else:
            check(block, 'MacOS-26-5' if job == 'documentation-site' else 'ubuntu-24.04')
    check(docs['request'], 'ubuntu-24.04')
    for job, block in native.items():
        expected = ('${{ matrix.group }}' if job in ('build', 'build-core', 'build-remaining', 'tests-root', 'tests')
                    else '${{ inputs.build-group }}' if job == 'fixtures'
                    else 'MacOS-26-5' if job in ('public-api', 'apple-compilation')
                    else '${{ inputs.runner-group }}')
        check(block, expected)
    def matrix(block):
        match = re.search(r'^      matrix:(.*?)(?=^    steps:)', block, flags=re.M | re.S)
        if not match:
            raise ValueError('execution matrix is missing')
        return ' '.join(match[1].split())

    expected_matrices = {
        'build': 'include: - platform: ${{ inputs.platform }} component: load '
                 'group: ${{ inputs.build-group }} jobs: ${{ inputs.build-jobs }} shell: ${{ inputs.shell }}',
        'build-core': '${{ fromJSON(needs.plan.outputs.core-builds) }}',
        'build-remaining': '${{ fromJSON(needs.plan.outputs.builds) }}',
        'tests-root': '${{ fromJSON(needs.plan.outputs.root-tests) }}',
        'tests': '${{ fromJSON(needs.plan.outputs.tests) }}',
        'fixtures': 'suite: [dsl_compile_fixtures, dsl_extension_fixtures]',
    }
    for job, expected in expected_matrices.items():
        if matrix(native[job]) != expected:
            raise ValueError('workflow matrix differs from the exact execution planner')
    if matrix(ci['helpers']) != 'group: [' + ', '.join(helper_groups) + ']':
        raise ValueError('helper matrix differs from the exact execution planner')


def execution_jobs(mode, *, platform=None, component=None, suite=None, repository=ROOT,
                   publication=False):
    """Use the very same platform partitions as execution; never approximate suites.

    Whole-job timeouts include provisioning, commands, transport recovery, cleanup
    and report reserves. Conditional failures can reduce this maximum, never expand
    it. Matrix rows are reserved individually even when scheduled concurrently.
    """
    import workflow_scope
    import native_jobs
    from preflight import GROUPS

    if type(publication) is not bool:
        raise ValueError('publication scope must be boolean')
    ci = workflow_jobs(repository, 'ci.yml', CI_JOBS)
    native = workflow_jobs(repository, 'native-platform.yml', NATIVE_JOBS)
    docs = workflow_jobs(repository, 'documentation.yml', {'request'})
    validate_runner_mappings(ci, native, docs, GROUPS)
    rows = []

    def add(identifier, block, group, name):
        rows.append({'id': identifier, 'group': group,
                     'maximumSeconds': maximum_seconds(block), 'jobName': name})

    if mode == 'documentation-request':
        if any((platform, component, suite, publication)):
            raise ValueError('documentation request does not accept native filters')
        add('documentation-request', docs['request'], 'ubuntu-24.04',
            'Request full CI with shared documentation inputs')
        return rows
    workflow_scope.select(mode, platform=platform, component=component, suite=suite,
                          repository=repository)
    if publication and mode != 'full':
        raise ValueError('publication requires full scope')
    shared_names = {'scope': 'Validate scope and contained rollout',
                    'source': 'Source policy and workflow syntax',
                    'maintenance': 'Upstream maintenance review freshness',
                    'complete': {'full': 'Offline certification passed',
                                 'diagnostic': 'Diagnostic scope passed',
                                 'preflight': 'Preflight scope passed'}[mode]}
    for job in ('scope', 'source', 'maintenance', 'complete'):
        add(job, ci[job], 'ubuntu-24.04', shared_names[job])
    for group in GROUPS:
        add('helpers/' + group, ci['helpers'], 'ubuntu-24.04', 'Helper suites / ' + group)
    if mode == 'preflight':
        return rows
    for target in workflow_scope.PREFIXES if mode == 'full' else [platform]:
        plan = workflow_scope.platform_plan(mode, target, component=component, suite=suite,
            repository=repository, commit='planning', run_id='planning', run_attempt='1')
        runtime = native_jobs.runner_entry(target, False)['group']
        large = native_jobs.runner_entry(target, True)['group']
        prefix = workflow_scope.PREFIXES[target] + ' / '

        def local(identifier, job, name, group=runtime):
            add(target + '/' + identifier, native[job], group, prefix + name)

        local('platform', 'platform', 'Platform check')
        local('plan', 'plan', 'Plan platform builds and suites')
        for row in plan['all-builds']['include']:
            component_name = row['component']
            actual_job = ('build' if component_name == 'load' else 'build-core'
                          if component_name in workflow_scope.CORE_COMPONENTS else 'build-remaining')
            local('build/' + component_name, actual_job,
                  f'Builds / {target} / {component_name}', row['group'])
        local('canary', 'canary', 'Canary / load tests and smokes')
        if plan['has-core-builds'] or plan['has-builds']:
            local('resolve', 'resolve', 'Resolve immutable producers')
        for matrix, job in (('root-tests', 'tests-root'), ('tests', 'tests')):
            for row in plan[matrix]['include']:
                local('suite/' + row['component'] + '/' + row['suite'], job,
                      'Tests / ' + row['suite'], row['group'])
        if mode == 'full':
            local('audit', 'audit', 'Documentation, inventory, generation and release audits')
            for fixture in ('dsl_compile_fixtures', 'dsl_extension_fixtures'):
                local('fixture/' + fixture, 'fixtures', 'Compiler fixtures / ' + fixture, large)
            local('export', 'package', 'Export validated platform source')
            if target == 'macos-arm64':
                local('public-api', 'public-api', 'Public API and DocC / macOS ARM')
                local('apple', 'apple-compilation', 'Build Apple minima / device and simulator modules')
        local('coverage', 'coverage', 'Verify platform coverage before source export')
        local('complete', 'complete', 'Platform validation passed')
    if mode == 'full':
        add('documentation-site', ci['documentation-site'], 'MacOS-26-5',
            'Documentation site from validated archives')
        if publication:
            add('publish-documentation', ci['publish-documentation'], 'ubuntu-24.04',
                'Publish GitHub Pages')
    if len(rows) != len({row['id'] for row in rows}) or len(rows) != len({row['jobName'] for row in rows}):
        raise ValueError('execution planner produced duplicate jobs')
    return rows


def validate_trigger(event, ref, default_branch):
    """Only PR, current default-branch pushes and manual requests may enter CI."""
    if event == 'push':
        if ref != 'refs/heads/' + default_branch:
            raise ValueError('branch push duplicates PR validation or is not maintained')
    elif event not in ('pull_request', 'workflow_dispatch'):
        raise ValueError('unsupported CI trigger')
    if not default_branch:
        raise ValueError('default branch identity is required')
