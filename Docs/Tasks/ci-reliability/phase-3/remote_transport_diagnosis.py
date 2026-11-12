#!/usr/bin/env python3
"""One explicitly admitted Rosetta remote transport diagnostic; never a CI pass."""
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import resource
import signal
import socket
import subprocess
import sys
import threading
import time

ROOT = Path('/work')
OUTPUT = ROOT / 'Docs/Tasks/ci-reliability/phase-3'
sys.path.insert(0, str(ROOT / 'Tools/ci'))
from linux_ci import Command, execute

STARTED = time.monotonic()
EXECUTABLE = '/scratch/x86_64-unknown-linux-gnu/debug/DiscordKitLoadTestsPackageTests.xctest'
ARGUMENTS = [EXECUTABLE, '--testing-library', 'swift-testing', '--no-parallel', '--filter',
             'DiscordKitLoadTestsTests.TransportTimingRunnerTests/nativeChunkControlsCloseOwnedResources']
REPORT = OUTPUT / 'red-transport-remote.json'
if REPORT.exists():
    raise SystemExit('Refusing to repeat an already retained diagnostic')
record = {'schemaVersion': 1, 'capturedAtUTC': datetime.now(timezone.utc).isoformat(),
          'qualification': 'One exploratory emulated red diagnostic; test will be deliberately interrupted for stacks',
          'arguments': ARGUMENTS, 'runBeforeSnapshotSeconds': 10, 'overallLimitSeconds': 90,
          'discoverySource': 'baseline-discovery.stdout', 'snapshots': [], 'cleanup': {}}
known = {}
lock = threading.Lock()
stop = threading.Event()
fixture = None
sampler = None

def write_report():
    REPORT.write_text(json.dumps(record, indent=2) + '\n')


def identity(pid):
    try:
        text = Path(f'/proc/{pid}/stat').read_text()
        name = text[text.index('(') + 1:text.rindex(')')]
        fields = text[text.rindex(')') + 2:].split()
        return {'pid': pid, 'name': name, 'state': fields[0], 'parentPID': int(fields[1]),
                'processGroup': int(fields[2]), 'sessionID': int(fields[3]), 'startTicks': int(fields[19])}
    except (OSError, ValueError, IndexError):
        return None


def capture():
    if fixture is None:
        return
    rows = {}
    for path in Path('/proc').iterdir():
        if path.name.isdigit():
            row = identity(int(path.name))
            if row:
                rows[row['pid']] = row
    owned = {fixture.pid}
    changed = True
    while changed:
        additions = {pid for pid, row in rows.items() if row['parentPID'] in owned} - owned
        changed = bool(additions)
        owned.update(additions)
    selected = []
    for pid in sorted(owned):
        row = rows.get(pid)
        if row is None:
            continue
        known[(pid, row['startTicks'])] = row
        try:
            status = dict(line.split(':', 1) for line in Path(f'/proc/{pid}/status').read_text().splitlines() if ':' in line)
            row['signalState'] = {key: status[key].strip() for key in
                ('SigPnd', 'ShdPnd', 'SigBlk', 'SigIgn', 'SigCgt', 'Threads') if key in status}
            names = [part.partition(b'=')[0] for part in Path(f'/proc/{pid}/environ').read_bytes().split(b'\0')]
            row['rosettaDebugVariablePresent'] = b'ROSETTA_DEBUGSERVER_PORT' in names
            row['renamedDiagnosticVariablePresent'] = b'_OSETTA_DEBUGSERVER_PORT' in names
            argv = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
            if b'--timing-case' in argv:
                index = argv.index(b'--timing-case')
                row['peerTimingCase'] = argv[index + 1].decode(errors='replace')
        except (OSError, ValueError, IndexError):
            pass
        selected.append(row)
    with lock:
        record['snapshots'].append({'seconds': round(time.monotonic() - STARTED, 3), 'processes': selected})
        write_report()


def sample():
    while not stop.wait(0.5):
        capture()


def alarm(signum, frame):
    raise TimeoutError('90-second diagnostic owner deadline reached')

signal.signal(signal.SIGALRM, alarm)
signal.alarm(85)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
try:
    core = ROOT / 'core'
    if core.exists():
        metadata = core.stat()
        digest = hashlib.sha256()
        with core.open('rb') as stream:
            header = stream.read(20)
            digest.update(header)
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        record['ownedPriorCore'] = {'bytes': metadata.st_size, 'mtimeUnix': metadata.st_mtime,
            'sha256': digest.hexdigest(), 'elfHeaderHex': header.hex(),
            'ownerEvidence': 'Earlier unsupported unsetenv remote experiment; rosetta-remote-unsetenv-capability.json',
            'removed': False}
        core.unlink()
        record['ownedPriorCore']['removed'] = True
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), 'PR_SET_CHILD_SUBREAPER')
    record['childSubreaperEnabled'] = True
    scrub = json.loads((OUTPUT / 'rosetta-remote-envp-capability.json').read_text())['environmentScrubCode']
    modules = json.loads((OUTPUT / 'rosetta-remote-modules-capability.json').read_text())['moduleLoadCode']
    # Reuse an existing module if LLDB already owns the executable's symbols.
    modules = modules.replace("module=lldb.target.AddModule(path,'x86_64-unknown-linux-gnu',None)",
        "module=lldb.target.FindModule(lldb.SBFileSpec(path))\n    if not module.IsValid():\n        module=lldb.target.AddModule(path,'x86_64-unknown-linux-gnu',None)")
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    environment = dict(os.environ)
    environment['ROSETTA_DEBUGSERVER_PORT'] = str(port)
    environment['SWIFTNIO_STRICT'] = '1'
    with (OUTPUT / 'red-transport-test.log').open('wb') as test_output:
        fixture = subprocess.Popen(ARGUMENTS, cwd=ROOT, env=environment,
                                   stdout=test_output, stderr=subprocess.STDOUT, start_new_session=True)
        record.update(testPID=fixture.pid, debugPort=port)
        capture()
        sampler = threading.Thread(target=sample, daemon=True)
        sampler.start()
        until = time.monotonic() + 2
        while time.monotonic() < until and fixture.poll() is None:
            rows = Path('/proc/net/tcp').read_text().splitlines()[1:]
            if any(row.split()[1].split(':')[-1] == f'{port:04X}' and row.split()[3] == '0A' for row in rows):
                break
            time.sleep(0.02)
        run = scrub + '''
import time
lldb.debugger.SetAsync(True)
error=lldb.process.Continue()
if error.Fail():
    raise RuntimeError('remote continue failed: '+str(error))
print('DIAGNOSTIC_TEST_CONTINUED')
until=time.monotonic()+10
while time.monotonic()<until and lldb.process.GetState() not in (lldb.eStateExited,lldb.eStateDetached,lldb.eStateInvalid):
    time.sleep(0.05)
if lldb.process.GetState()==lldb.eStateRunning:
    error=lldb.process.Stop()
    if error.Fail():
        raise RuntimeError('remote stop failed: '+str(error))
until=time.monotonic()+2
while time.monotonic()<until and lldb.process.GetState()!=lldb.eStateStopped:
    time.sleep(0.01)
if lldb.process.GetState()!=lldb.eStateStopped:
    raise RuntimeError('diagnostic process did not remain stopped')
print('DIAGNOSTIC_TEST_STOPPED')
'''
        frame = 'frame #${frame.index}: ${frame.pc} ${module.file.basename} ${function.name-without-args}' + chr(92) + 'n'
        debugger = ('lldb', '--batch', '--no-lldbinit', '-o', f"settings set frame-format '{frame}'",
            '-o', f'target create --arch x86_64 {EXECUTABLE}', '-o', f'gdb-remote 127.0.0.1:{port}',
            '-o', 'script exec(' + repr(run) + ')', '-o', 'script exec(' + repr(modules) + ')',
            '-o', 'image list -o -f', '-o', 'thread backtrace all --count 128', '-o', 'process kill')
        record['debuggerArguments'] = list(debugger)
        write_report()
        try:
            execute(Command('red-transport-remote', debugger, 60, operation='focusedTest',
                    stage='phase3-red-transport-remote'), ROOT, OUTPUT / 'red-transport-debugger.log')
            record['debuggerSupervisorResult'] = 'exited-zero; inspect symbol stacks and diagnostic kill separately'
        except BaseException as error:
            record['debuggerSupervisorResult'] = str(error)
        capture()
except BaseException as error:
    record['ownerError'] = str(error)
finally:
    stop.set()
    if sampler is not None:
        sampler.join(timeout=1)
    if fixture is not None:
        capture()
        record['cleanup']['signals'] = []
        # The tracked start identity prevents signalling a reused PID or another job.
        for (pid, start), old in list(known.items()):
            current = identity(pid)
            if current is not None and current['startTicks'] == start and current['state'] != 'Z':
                try:
                    os.kill(pid, signal.SIGKILL)
                    record['cleanup']['signals'].append({'pid': pid, 'startTicks': start, 'signal': 'SIGKILL'})
                except ProcessLookupError:
                    pass
        try:
            fixture.wait(timeout=2)
        except subprocess.TimeoutExpired:
            record['cleanup']['fixtureReapTimeout'] = True
        record['cleanup']['testReaped'] = fixture.returncode is not None
        record['cleanup']['testExitCode'] = fixture.returncode
        reaped = []
        until = time.monotonic() + 3
        while time.monotonic() < until:
            try:
                pid, status = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                break
            if pid:
                reaped.append({'pid': pid, 'waitStatus': status})
            else:
                time.sleep(0.02)
        record['cleanup']['adoptedChildrenReaped'] = reaped
        remaining = []
        for (pid, start) in known:
            current = identity(pid)
            if current is not None and current['startTicks'] == start:
                remaining.append(current)
        record['cleanup']['remainingOwnedProcesses'] = remaining
    signal.alarm(0)
    record['seconds'] = round(time.monotonic() - STARTED, 3)
    with lock:
        write_report()
print(json.dumps({'report': str(REPORT), 'seconds': record['seconds'],
                  'debuggerSupervisorResult': record.get('debuggerSupervisorResult'),
                  'cleanup': record['cleanup']}, indent=2))
