#!/usr/bin/env python3
"""Retain phase-2 local command receipts under phase-1 process supervision."""
from pathlib import Path
import os
import sys

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / 'Tools/ci'))
from linux_ci import Command, execute

name = sys.argv[1]
load = ('--package-path', 'Tools/DiscordKitLoadTests', '--scratch-path', '.build/ci-phase2-load')
common = ('--build-system', 'native', '--jobs', '6', '--force-resolved-versions', '--disable-experimental-prebuilts')
commands = {
    'red-build': (1200, ('swift', 'build', *load, *common, '--build-tests')),
    'red-tests': (90, ('swift', 'test', *load, *common, '--skip-build', '--no-parallel', '--filter', 'EventHubTimingTests/(dequeueCancellationDoesNotInventDiscard|completedWaitingResultsSurviveInterruptedAggregation)')),
    'green-build': (1200, ('swift', 'build', *load, *common, '--build-tests')),
    'green-discovery': (60, ('swift', 'test', *load, *common, '--skip-build', 'list')),
    'green-tests': (90, ('swift', 'test', *load, *common, '--skip-build', '--no-parallel', '--filter', 'EventHubTiming')),
    'runtime-build': (1200, ('swift', 'build', '--scratch-path', '.build/ci-phase2-runtime', *common, '--build-tests')),
    'runtime-discovery': (60, ('swift', 'test', '--scratch-path', '.build/ci-phase2-runtime', *common, '--skip-build', 'list')),
    'runtime-tests': (90, ('swift', 'test', '--scratch-path', '.build/ci-phase2-runtime', *common, '--skip-build', '--no-parallel', '--filter', 'EventHubTests')),
}
for case, policy in [('queued', 'dropNewest'), ('waiting', 'dropNewest'), ('overflow', 'resynchronize'), ('cancelled', 'dropOldest')]:
    commands[f'smoke-{case}'] = (120, (
        str(ROOT / '.build/ci-phase2-load/debug/DiscordKitLoadTests'), 'gateway-hub-timing',
        '--case', f'gateway.hub{case.title()}V1', '--requests', '8', '--subscriptions', '2',
        '--hubs', '2', '--queued-depth', '2', '--payload-bytes', '0', '--policy', policy,
        '--warmup-requests', '0', '--warmup-seconds', '0', '--duration-seconds', '3',
        '--output', str(Path(__file__).resolve().parent / f'smoke-{case}.json'),
        '--common-report', str(Path(__file__).resolve().parent / f'smoke-{case}-common.json')))
limit, arguments = commands[name]
os.environ['SWIFTNIO_STRICT'] = '1'
output = Path(__file__).resolve().parent
try:
    execute(Command(name, arguments, limit, operation='phase2-local', stage=name), ROOT, output / f'{name}.log')
except Exception as error:
    print(f'{name}: {error}', file=sys.stderr)
    sys.exit(1)
