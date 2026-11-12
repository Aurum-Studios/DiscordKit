import contextlib, io, json, os, pathlib, signal, subprocess, sys, threading, time
from unittest.mock import patch
sys.path.insert(0, str(pathlib.Path("Tools/ci").resolve()))
import linux_ci
repo = pathlib.Path.cwd()
out = repo / "Docs/Tasks/ci-reliability/phase-1/faults"
out.mkdir(parents=True, exist_ok=True)
results = []
def run(name, code, expected, timeout=2, *, separate=False, debugger=False, forwarding=False, interrupt=False):
    log = out / (name + ".log")
    stdout = log.with_suffix(".stdout") if separate else None
    command = linux_ci.Command(name, (sys.executable, "-c", code), timeout, operation="focusedTest" if debugger else "fixture", stage="phase-1-fault-injection")
    started = time.monotonic()
    caught = None
    timer = None
    with contextlib.ExitStack() as stack:
        stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
        if debugger:
            def fail_debugger(pid, deadline):
                return dict(linux_ci._probe((sys.executable, "-c", "import sys; sys.exit(3)"), deadline), pid=pid, faultInjection="debugger exited 3")
            stack.enter_context(patch.object(linux_ci, "_stacks", fail_debugger))
        if forwarding:
            stack.enter_context(patch.object(linux_ci, "_console_write", side_effect=BrokenPipeError("injected failed forwarding")))
        if interrupt:
            timer = threading.Timer(.25, lambda: os.kill(os.getpid(), signal.SIGTERM))
            timer.start()
        try:
            linux_ci.execute(command, repo, log, stdout_log=stdout)
        except BaseException as error:
            caught = error
        finally:
            if timer:
                timer.cancel()
                timer.join(timeout=1)
    elapsed = time.monotonic() - started
    if expected is None:
        assert caught is None, (name, repr(caught))
    else:
        assert isinstance(caught, expected), (name, repr(caught))
    receipt = json.loads(log.with_suffix(".receipt.json").read_text())
    assert receipt["readerThreads"] == 0
    assert receipt["cleanup"]["parentReaped"]
    assert receipt["cleanup"]["groupState"] in ("gone", "zombies-only"), (name, receipt["cleanup"])
    assert elapsed <= timeout + receipt["cleanupAllowanceSeconds"] + .25, (name, elapsed)
    assert receipt["arguments"] == list(command.arguments)
    assert receipt["status"] == ("interrupted" if interrupt else "failed" if expected else "passed")
    if debugger:
        snapshots = [json.loads(line) for line in log.with_suffix(".diagnostics.jsonl").read_text().splitlines()]
        assert any(s.get("status") == "failed" and s.get("exitCode") == 3 for v in snapshots for s in v.get("stacks", [])), snapshots
    if separate:
        assert stdout.read_text() == "FixtureTests.Suite/test()\n"
        assert "BogusTests/diagnosticOnly()" not in stdout.read_text()
    results.append({"name":name,"seconds":round(elapsed,3),"expectedException":expected.__name__ if expected else None,"exception":type(caught).__name__ if caught else None,"status":receipt["status"],"timeoutCategory":receipt["timeoutCategory"],"readerThreads":receipt["readerThreads"],"groupState":receipt["cleanup"]["groupState"],"receipt":log.with_suffix(".receipt.json").name,"diagnostics":log.with_suffix(".diagnostics.jsonl").name,"testProcessAttempts":1})
run("normal-success", "print('offline success')", None)
run("assertion-failure", "import sys; print('assertion fixture failed', flush=True); sys.exit(7)", subprocess.CalledProcessError)
run("silent-stuck", "import time; time.sleep(60)", subprocess.TimeoutExpired, .7)
run("term-ignoring", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready',flush=True); time.sleep(60)", subprocess.TimeoutExpired, .7)
run("inherited-stdout", "import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); print('parent completed',flush=True)", subprocess.TimeoutExpired, .7)
run("failed-debugger", "import time; time.sleep(60)", subprocess.TimeoutExpired, .9, debugger=True)
run("failed-forwarding", "print('output retained before failed forwarding', flush=True)", OSError, forwarding=True)
run("interruption", "import time; time.sleep(60)", linux_ci.CommandInterrupted, 3, interrupt=True)
run("discovery-stdout", "import os; os.write(1,b'FixtureTests.Su'); os.write(2,b'BogusTests/diagnosticOnly()\\n'); os.write(1,b'ite/test()\\n')", None, separate=True)
(out / "results.json").write_text(json.dumps({"schemaVersion":1,"qualification":"local macOS Python process fixtures; no native Swift or hosted qualification","cases":results},indent=2)+"\n")
print(json.dumps(results))
