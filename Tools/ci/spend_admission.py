#!/usr/bin/env python3
# File: Tools/ci/spend_admission.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Reserve exact workflow job/attempt maxima before any expensive hosted work.

This is a fixed partition, not a mutable remaining-balance ledger. A current job
recomputes the source-bound plan instead of trusting an earlier successful job's
output. Dated authorization and priced ceilings contain each admitted workflow;
the provider budget supplies the separate monthly aggregate backstop.
"""

import argparse
import copy
from contextlib import redirect_stdout
from datetime import date, datetime, timezone
from decimal import Decimal
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sys

import execution_plan
import native_jobs
import native_receipts
import scheduling_policy as scheduling
import workflow_scope


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_POLICY = Path(__file__).with_name('admission.v1.json')
MODES = (*scheduling.MODES, 'documentation-request')
IDENTITY_FIELDS = {'repository', 'repositoryID', 'workflowRef', 'workflowSHA', 'event',
                   'ref', 'headRef', 'baseRef', 'runID', 'runAttempt', 'defaultBranch'}
SOURCE_FIELDS = {'commit', 'sourceSHA256', 'dependencyPinsSHA256'}
require = scheduling.require
integer = scheduling.integer
dollars = scheduling.dollars


def digest(value):
    """Hash the canonical full value so reservations bind all planning inputs."""
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                     allow_nan=False).encode()).hexdigest()


def read_json(path):
    """Reject duplicate JSON keys and nonfinite numbers in policy or saved plans."""
    with Path(path).open() as stream:
        return native_receipts.read_json(stream)


def _validate_policy(value):
    require(isinstance(value, dict) and set(value) == {'schemaVersion', 'policyID', 'status',
        'authorization', 'billing', 'entryReserveSeconds', 'runnerRates', 'additionalCharges',
        'allowances', 'limitations'}, 'invalid spend admission policy fields')
    require(type(value['schemaVersion']) is int and value['schemaVersion'] == 1
            and value['policyID'] == 'ci-spend-admission-v1', 'unsupported admission policy version')
    authorization = value['authorization']
    authorization_fields = {'enabled', 'repository', 'maximumRunAttempts'}
    validity_fields = {'validFrom', 'validUntil'}
    require(isinstance(authorization, dict)
            and authorization_fields <= set(authorization) <= authorization_fields | validity_fields,
            'invalid authorization fields')
    require(('validFrom' in authorization) == ('validUntil' in authorization),
            'authorization validity requires both validFrom and validUntil')
    if 'validFrom' in authorization:
        valid_from = scheduling.iso_date(authorization['validFrom'], 'authorization validFrom')
        valid_until = scheduling.iso_date(authorization['validUntil'], 'authorization validUntil')
        require(valid_from <= valid_until, 'authorization validFrom must not follow validUntil')
    require(type(authorization['enabled']) is bool, 'authorization enabled must be boolean')
    require(isinstance(authorization['repository'], str) and re.fullmatch(
        r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', authorization['repository']), 'invalid authorized repository')
    integer(authorization['maximumRunAttempts'], 'maximum run attempts')
    require(authorization['maximumRunAttempts'] <= 100, 'maximum run attempts cannot exceed 100')
    billing = value['billing']
    require(set(billing) == {'currency', 'rounding', 'rateMaxAgeDays'}
            and billing['currency'] == 'USD' and billing['rounding'] == 'ceil-each-job-minute',
            'unsupported admission billing contract')
    integer(billing['rateMaxAgeDays'], 'maximum rate age')
    integer(value['entryReserveSeconds'], 'entry reserve seconds')
    require(isinstance(value['runnerRates'], dict) and value['runnerRates'], 'runner rates are required')
    for group, rate in value['runnerRates'].items():
        require(isinstance(group, str) and group and isinstance(rate, dict) and set(rate) == {
            'sku', 'usdPerMinute', 'verifiedOn', 'sourceURL', 'billingMappingVerified', 'mappingAssurance'},
            'invalid runner rate fields')
        require(isinstance(rate['sku'], str) and rate['sku'], 'runner SKU is required')
        require(type(rate['billingMappingVerified']) is bool, 'runner mapping verification must be boolean')
        require(isinstance(rate['mappingAssurance'], str) and rate['mappingAssurance'].strip(),
                'runner mapping assurance is required')
        require(isinstance(rate['sourceURL'], str) and rate['sourceURL'].startswith('https://docs.github.com/'),
                'runner pricing requires an official source')
        if rate['usdPerMinute'] is None:
            require(rate['verifiedOn'] is None and not rate['billingMappingVerified'],
                    'unknown runner rate cannot claim verification')
        else:
            dollars(rate['usdPerMinute'], group)
            scheduling.iso_date(rate['verifiedOn'], group)
    require(set(value['additionalCharges']) == {'storage', 'transfer'}, 'missing non-runner pricing')
    for name, charge in value['additionalCharges'].items():
        require(isinstance(charge, dict) and set(charge) == {'applicability', 'unit',
            'maximumUnitsPerJobAttempt', 'usdPerUnit', 'verifiedOn', 'sourceURL', 'evidence'},
            f'invalid {name} pricing fields')
        require(charge['applicability'] in ('unknown', 'bounded', 'not-applicable'),
                f'unknown {name} applicability contract')
        require(charge['unit'] == ('GiB-day' if name == 'storage' else 'GiB'), f'invalid {name} unit')
        require(isinstance(charge['sourceURL'], str)
                and charge['sourceURL'].startswith('https://docs.github.com/'),
                f'{name} pricing requires an official source')
        require(isinstance(charge['evidence'], str) and charge['evidence'].strip(),
                f'{name} pricing evidence is required')
        if charge['applicability'] == 'unknown':
            require(charge['maximumUnitsPerJobAttempt'] is None and charge['usdPerUnit'] is None
                    and charge['verifiedOn'] is None, f'unknown {name} cannot claim a priced bound')
        else:
            units = dollars(charge['maximumUnitsPerJobAttempt'], name + ' units')
            rate = dollars(charge['usdPerUnit'], name + ' rate')
            scheduling.iso_date(charge['verifiedOn'], name)
            if charge['applicability'] == 'not-applicable':
                require(units == 0 and rate == 0, f'inapplicable {name} must explicitly cost zero')
            else:
                require(units > 0 and rate > 0, f'applicable {name} requires a positive finite bound and rate')
    allowance = value['allowances']
    require(set(allowance) == {'experimentUSD', 'workflowUSD', 'safetyUSD', 'maximumPaidJobs',
                             'maximumPaidMinutes', 'maximumPaidAttempts'}, 'invalid allowances')
    for name in ('experimentUSD', 'workflowUSD', 'safetyUSD'):
        dollars(allowance[name], name)
    for name in ('maximumPaidJobs', 'maximumPaidMinutes', 'maximumPaidAttempts'):
        integer(allowance[name], name, 0)
    require(isinstance(value['limitations'], list) and value['limitations']
            and all(isinstance(item, str) and item for item in value['limitations']),
            'admission limitations are required')
    return value


def validate_policy(value):
    """Surface missing or malformed fields as a fail-closed ValueError."""
    try:
        return _validate_policy(value)
    except (KeyError, TypeError, AttributeError) as error:
        raise ValueError(f'malformed spend admission policy: {error}') from error


def load_policy(path=DEFAULT_POLICY):
    return validate_policy(read_json(path))


def fresh(policy, verified_on, name, as_of):
    age = (as_of - scheduling.iso_date(verified_on, name)).days
    require(0 <= age <= policy['billing']['rateMaxAgeDays'], f'stale or future {name} rate')


def runner_rate(policy, group, as_of):
    require(group in policy['runnerRates'], f'unknown runner group: {group}')
    rate = policy['runnerRates'][group]
    require(rate['usdPerMinute'] is not None, f'unknown runner rate: {group}')
    fresh(policy, rate['verifiedOn'], group, as_of)
    require(rate['billingMappingVerified'], f'runner billing mapping is unverified: {group}')
    return dollars(rate['usdPerMinute'], group)


def additional_cost(policy, name, as_of):
    charge = policy['additionalCharges'][name]
    require(charge['applicability'] != 'unknown', f'unknown {name} pricing/applicability')
    fresh(policy, charge['verifiedOn'], name, as_of)
    return dollars(charge['maximumUnitsPerJobAttempt'], name) * dollars(charge['usdPerUnit'], name)


def execution_identity(repository, *, run_id=None, run_attempt=None, identity=None):
    """Keep local planning possible without treating local values as hosted permission."""
    if identity is not None:
        value = copy.deepcopy(identity)
    else:
        names = {'repository': 'GITHUB_REPOSITORY', 'repositoryID': 'GITHUB_REPOSITORY_ID',
                 'workflowRef': 'GITHUB_WORKFLOW_REF', 'workflowSHA': 'GITHUB_WORKFLOW_SHA',
                 'event': 'GITHUB_EVENT_NAME', 'ref': 'GITHUB_REF', 'headRef': 'GITHUB_HEAD_REF',
                 'baseRef': 'GITHUB_BASE_REF', 'runID': 'GITHUB_RUN_ID', 'runAttempt': 'GITHUB_RUN_ATTEMPT',
                 'defaultBranch': 'ADMISSION_DEFAULT_BRANCH'}
        hosted = os.environ.get('GITHUB_ACTIONS') == 'true' or any(name in os.environ for name in names.values())
        value = ({key: os.environ.get(name, '') for key, name in names.items()} if hosted else
                 {key: 'local' for key in IDENTITY_FIELDS})
        if not hosted:
            value.update(repository=str(Path(repository).resolve()), ref='', headRef='', baseRef='', defaultBranch='')
    require(isinstance(value, dict) and set(value) == IDENTITY_FIELDS, 'invalid admission execution identity fields')
    require(all(isinstance(item, str) and not any(character in item for character in '\0\r\n')
                for item in value.values()), 'invalid admission execution identity values')
    if run_id is not None:
        require(str(run_id) == value['runID'], 'run ID differs from current execution identity')
    if run_attempt is not None:
        require(str(run_attempt) == value['runAttempt'], 'run attempt differs from current execution identity')
    return value


def identity_errors(identity, policy):
    if identity['runID'] == 'local':
        return ['local plan does not authorize hosted execution']
    errors = []
    try:
        require(identity['repository'] == policy['authorization']['repository'], 'unauthorized repository identity')
        for field in ('repositoryID', 'runID', 'runAttempt'):
            require(re.fullmatch(r'[1-9][0-9]*', identity[field]), f'invalid admission {field}')
        require(identity['workflowRef'].startswith(identity['repository'] + '/.github/workflows/')
                and re.fullmatch(r'[^@]+@refs/\S+', identity['workflowRef']), 'invalid admission workflow identity')
        require(re.fullmatch(r'[0-9a-f]{40}', identity['workflowSHA']), 'invalid admission workflow source')
        require(identity['ref'].startswith('refs/'), 'invalid admission source ref')
        if identity['event'] == 'pull_request':
            require(re.fullmatch(r'refs/pull/[1-9][0-9]*/merge', identity['ref'])
                    and identity['headRef'] and identity['baseRef'], 'invalid admission pull request identity')
        else:
            require(not identity['headRef'] and not identity['baseRef'], 'unexpected pull request identity')
        execution_plan.validate_trigger(identity['event'], identity['ref'], identity['defaultBranch'])
    except ValueError as error:
        errors.append(str(error))
    return errors


def validate_source(source):
    require(isinstance(source, dict) and set(source) == SOURCE_FIELDS, 'invalid admission source fields')
    require(isinstance(source['commit'], str) and re.fullmatch(r'[0-9a-f]{40}', source['commit'])
            and isinstance(source['sourceSHA256'], str) and re.fullmatch(r'[0-9a-f]{64}', source['sourceSHA256'])
            and isinstance(source['dependencyPinsSHA256'], dict), 'invalid admission source identity')
    for path, checksum in source['dependencyPinsSHA256'].items():
        require(isinstance(path, str) and path and not path.startswith('/') and '..' not in path.split('/')
                and isinstance(checksum, str) and re.fullmatch(r'[0-9a-f]{64}', checksum),
                'invalid dependency pin identity')


def money(value):
    return None if value is None else str(value)


def current_source_identity(repository):
    """Recompute exact source bytes without forwarding the binary filename inventory.

    Metadata children remain supervised and their complete stdout is captured by
    the native helper. Raw base64 filenames are transport data, not a console
    report. Keep a bounded diagnostic excerpt if the query itself fails.
    """
    diagnostics = io.StringIO()
    try:
        with redirect_stdout(diagnostics):
            return native_jobs.source_identity(Path(repository))
    except Exception:
        detail = diagnostics.getvalue()
        if detail:
            print('Source identity query failed; final diagnostics:\n' + detail[-4096:], file=sys.stderr)
        raise


def make_plan(mode, *, platform=None, component=None, suite=None, repository=ROOT, publication=False,
              qualification_fault=False,
              policy=None, as_of=None, source=None, run_id=None, run_attempt=None, identity=None):
    """Produce disjoint whole-job/attempt reservations from the execution planner.

    Pure planning performs no network calls, checkout changes, compilation or
    provisioning. Explicit source/identity arguments support offline fixtures;
    the CLI always derives both from the current checkout and GitHub environment.
    """
    from qualification_fault import validate_selection
    validate_selection(enabled=qualification_fault, mode=mode, platform=platform or None,
                       component=component or None, suite=suite or None, publication=publication)
    policy = copy.deepcopy(load_policy() if policy is None else validate_policy(policy))
    require(mode in MODES, 'unsupported admission mode')
    as_of = datetime.now(timezone.utc).date() if as_of is None else as_of
    require(type(as_of) is date, 'admission comparison requires a date')
    source = copy.deepcopy(current_source_identity(repository) if source is None else source)
    validate_source(source)
    identity = execution_identity(repository, run_id=run_id, run_attempt=run_attempt, identity=identity)
    jobs = copy.deepcopy(workflow_scope.execution_jobs(mode, platform=platform or None,
        component=component or None, suite=suite or None, repository=repository, publication=publication))
    require(jobs and len(jobs) == len({job['id'] for job in jobs}), 'execution planner contains missing or duplicate jobs')
    reasons = identity_errors(identity, policy)
    if not policy['authorization']['enabled']:
        reasons.append('hosted execution authorization is disabled')
    if 'validFrom' in policy['authorization']:
        valid_from = scheduling.iso_date(policy['authorization']['validFrom'], 'authorization validFrom')
        valid_until = scheduling.iso_date(policy['authorization']['validUntil'], 'authorization validUntil')
        if not valid_from <= as_of <= valid_until:
            reasons.append('current date is outside hosted authorization validity window')
    maximum_attempts = policy['authorization']['maximumRunAttempts']
    current_attempt = int(identity['runAttempt']) if re.fullmatch(r'[1-9][0-9]*', identity['runAttempt']) else 1
    if current_attempt > maximum_attempts:
        reasons.append('current run attempt exceeds fixed attempt reservations')
    amounts = {}
    for name in ('storage', 'transfer'):
        try:
            amounts[name] = additional_cost(policy, name, as_of)
        except ValueError as error:
            amounts[name] = None
            reasons.append(str(error))
    reservations, runner_total, entry_total = [], Decimal(0), Decimal(0)
    total_minutes = 0
    for job in jobs:
        require(isinstance(job, dict) and {'id', 'group', 'maximumSeconds'} <= set(job)
                and set(job) <= {'id', 'group', 'maximumSeconds', 'jobName'}, 'invalid execution job fields')
        require(isinstance(job['id'], str) and re.fullmatch(r'[A-Za-z0-9_/-]+', job['id'])
                and isinstance(job['group'], str) and job['group'], 'invalid execution job identity')
        integer(job['maximumSeconds'], 'job maximum seconds')
        require(job['maximumSeconds'] >= policy['entryReserveSeconds'], 'job omits startup/checkout admission reserve')
        minutes = scheduling.billed_minutes(job['maximumSeconds'])
        # Checkout/guard do not have a separate aggregate deadline. A rejection
        # can occupy the entire outer job, so its honest maximum is the full
        # timeout; entryReserveSeconds is only a required minimum envelope.
        entry_minutes = minutes
        try:
            rate = runner_rate(policy, job['group'], as_of)
        except ValueError as error:
            rate = None
            reasons.append(str(error))
        runner_cost = None if rate is None else rate * minutes
        entry_cost = None if rate is None else rate * entry_minutes
        if runner_cost is None:
            runner_total = None
            entry_total = None
        else:
            if runner_total is not None:
                runner_total += runner_cost * maximum_attempts
            if entry_total is not None:
                entry_total += entry_cost * maximum_attempts
        job.update(billedMaximumMinutes=minutes, entryMaximumMinutes=entry_minutes,
                   rateUSDPerMinute=money(rate), runnerCostUSDPerAttempt=money(runner_cost),
                   entryCostUSDPerAttempt=money(entry_cost))
        for attempt in range(1, maximum_attempts + 1):
            total_cost = (runner_cost + amounts['storage'] + amounts['transfer']
                          if runner_cost is not None and all(item is not None for item in amounts.values()) else None)
            reservations.append({'id': f"{job['id']}@{attempt}", 'jobID': job['id'], 'group': job['group'],
                'attempt': attempt, 'billedMaximumMinutes': minutes, 'entryMaximumMinutes': entry_minutes,
                'runnerCostUSD': money(runner_cost), 'entryCostUSD': money(entry_cost),
                'storageUSD': money(amounts['storage']), 'transferUSD': money(amounts['transfer']),
                'totalUSD': money(total_cost)})
            total_minutes += minutes
    allowance = policy['allowances']
    storage_total = None if amounts['storage'] is None else amounts['storage'] * len(reservations)
    transfer_total = None if amounts['transfer'] is None else amounts['transfer'] * len(reservations)
    safety = dollars(allowance['safetyUSD'], 'safety allowance')
    maximum = (runner_total + storage_total + transfer_total + safety
               if all(value is not None for value in (runner_total, storage_total, transfer_total)) else None)
    selected_allowance = min(dollars(allowance['workflowUSD'], 'workflow allowance'),
                             dollars(allowance['experimentUSD'], 'experiment allowance')) if mode == 'diagnostic' else dollars(allowance['workflowUSD'], 'workflow allowance')
    if maximum is not None and maximum > selected_allowance:
        reasons.append('maximum cost exceeds workflow/experiment allowance')
    if len(reservations) > allowance['maximumPaidJobs']:
        reasons.append('job reservations exceed maximum paid jobs')
    if total_minutes > allowance['maximumPaidMinutes']:
        reasons.append('minute reservations exceed maximum paid minutes')
    if maximum_attempts > allowance['maximumPaidAttempts']:
        reasons.append('attempt reservations exceed maximum paid attempts')
    # Keep the independently reviewed rollout switch separate from verified prices.
    rollout = workflow_scope.rollout()
    native_enabled = not reasons and mode in ('full', 'diagnostic') and rollout['nativeExpansionEnabled']
    result = {'schemaVersion': 1, 'policyID': policy['policyID'], 'policySHA256': digest(policy),
        'plannerSHA256': digest(jobs), 'asOf': as_of.isoformat(), 'mode': mode,
        'selection': {'platform': platform or None, 'component': component or None,
                      'suite': suite or None, 'publication': publication,
                      'qualificationFault': qualification_fault},
        'source': source, 'identity': identity, 'runID': identity['runID'], 'runAttempt': current_attempt,
        'admitted': not reasons, 'native-enabled': native_enabled, 'status': 'admitted' if not reasons else 'rejected',
        'reasons': list(dict.fromkeys(reasons)), 'jobs': jobs, 'reservations': reservations,
        'runnerRates': policy['runnerRates'], 'additionalCharges': policy['additionalCharges'],
        'totals': {'runnerUSD': money(runner_total), 'storageUSD': money(storage_total),
            'transferUSD': money(transfer_total), 'safetyUSD': str(safety), 'maximumUSD': money(maximum),
            'maximumMinutes': total_minutes, 'maximumJobs': len(reservations),
            'maximumAttempts': maximum_attempts, 'allowanceUSD': str(selected_allowance),
            'remainingUSD': None if maximum is None else str(selected_allowance - maximum),
            'includedEntryReserveUSD': money(entry_total)},
        'limitations': policy['limitations'], 'certificationEstablished': False,
        'billingReconciled': False, 'providerBudgetConfigured': False,
        'unboundedRejectedAttemptEntryCosts': True}
    result['planSHA256'] = digest(result)
    return result


def guard_job(job_id, *, group=None, plan=None, **arguments):
    """Recompute current run/source/scope; never grant from a stale upstream plan."""
    current = make_plan(**arguments)
    reasons = list(current['reasons'])
    selected = next((row for row in current['jobs'] if row['id'] == job_id), None)
    if selected is None:
        reasons.append('job is outside the exact execution plan')
    elif group is not None and selected['group'] != group:
        reasons.append('current runner group differs from exact execution plan')
    if selected and '/' in job_id and job_id.split('/')[0] in scheduling.PLATFORMS and not current['native-enabled']:
        reasons.append('native expansion remains disabled by reviewed rollout')
    if selected and job_id == 'documentation-site' and not current['native-enabled']:
        reasons.append('documentation native expansion remains disabled by reviewed rollout')
    if plan is not None and plan != current:
        reasons.append('saved plan differs from current source/run/attempt/policy reservations')
    attempt = current['runAttempt']
    reservation = next((row for row in current['reservations']
                        if row['jobID'] == job_id and row['attempt'] == attempt), None)
    if reservation is None:
        reasons.append('no current job/attempt reservation')
    current['guard'] = {'status': 'admitted' if not reasons else 'rejected', 'jobID': job_id,
        'group': group if group is not None else (selected['group'] if selected else None),
        'reservation': reservation, 'planSHA256': current['planSHA256'], 'reasons': list(dict.fromkeys(reasons))}
    current.update(status=current['guard']['status'], admitted=not reasons,
                   reasons=current['guard']['reasons'])
    if reasons:
        current['native-enabled'] = False
    return current


def boolean(value):
    require(value in ('true', 'false', ''), 'publication must be true or false')
    return value == 'true'


def summary(plan):
    """Expose bounded maximums with an explicit rejected/unknown billing state."""
    totals = plan['totals']
    lines = ['### CI spend admission', '', f"Status: **{plan['status']}**; mode: {plan['mode']}; "
        f"attempt: {plan['runAttempt']} / {totals['maximumAttempts']}.", '',
        f"Reserved jobs/attempts: {totals['maximumJobs']}; maximum runner minutes: {totals['maximumMinutes']}.",
        f"Maximum USD: {totals['maximumUSD'] if totals['maximumUSD'] is not None else 'unknown'}; "
        f"allowance USD: {totals['allowanceUSD']}; safety USD: {totals['safetyUSD']}.", '',
        'This is a conservative local estimate, not an invoice or an exact provider-enforced cutoff.']
    if plan['reasons']:
        lines += ['', *['- ' + reason for reason in plan['reasons']]]
    return '\n'.join(lines) + '\n'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('plan', 'guard', 'validate'))
    parser.add_argument('--mode', choices=MODES, default=os.environ.get('ADMISSION_MODE', 'preflight'))
    parser.add_argument('--policy', type=Path, default=DEFAULT_POLICY)
    parser.add_argument('--repository', type=Path, default=ROOT)
    parser.add_argument('--platform', default=os.environ.get('ADMISSION_PLATFORM'))
    parser.add_argument('--component', default=os.environ.get('ADMISSION_COMPONENT'))
    parser.add_argument('--suite', default=os.environ.get('ADMISSION_SUITE'))
    parser.add_argument('--publication', action='store_true')
    parser.add_argument('--qualification-fault', action='store_true')
    parser.add_argument('--job')
    parser.add_argument('--group')
    parser.add_argument('--plan', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args(argv)
    try:
        policy = load_policy(args.policy)
        if args.operation == 'validate':
            print(json.dumps({'status': 'valid', 'policyID': policy['policyID']}))
            return 0
        arguments = dict(mode=args.mode, platform=args.platform or None, component=args.component or None,
                         suite=args.suite or None, repository=args.repository, policy=policy,
                         publication=args.publication or boolean(os.environ.get('ADMISSION_PUBLICATION', '')),
                         qualification_fault=args.qualification_fault or boolean(
                             os.environ.get('ADMISSION_QUALIFICATION_FAULT', '')))
        if args.operation == 'guard':
            require(args.job is not None, 'guard requires one exact job ID')
            plan = guard_job(args.job, group=args.group, plan=read_json(args.plan) if args.plan else None, **arguments)
        else:
            plan = make_plan(**arguments)
        output = args.output or args.repository / '.build/spend-admission' / (
            'plan.json' if args.operation == 'plan' else 'guard-' + args.job.replace('/', '-') + '.json')
        native_jobs.write_json(output, plan)
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
                for key in ('mode', 'admitted', 'native-enabled', 'status'):
                    stream.write(key + '=' + (plan[key] if isinstance(plan[key], str) else json.dumps(plan[key])) + '\n')
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
                stream.write(summary(plan))
        # The complete exact plan is retained above. Console output stays small
        # even when a full workflow reserves dozens of native jobs and attempts.
        print(json.dumps({key: plan[key] for key in
            ('status', 'mode', 'admitted', 'native-enabled', 'runID', 'runAttempt',
             'selection', 'planSHA256', 'totals', 'reasons')} | {
                'sourceCommit': plan['source']['commit'], 'output': str(output)}, sort_keys=True))
        return 1 if args.operation == 'guard' and not plan['admitted'] else 0
    except (ValueError, OSError, KeyError, TypeError) as error:
        if args.output:
            native_jobs.write_json(args.output, {'status': 'rejected', 'admitted': False,
                'native-enabled': False, 'reasons': [str(error)]})
        print(f'spend admission rejected: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
