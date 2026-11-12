#!/usr/bin/env python3
"""Replay one bounded phase-3 experiment; compilation and execution stay separate."""
from pathlib import Path
import os
import sys

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "Tools/ci"))
from linux_ci import Command, execute

name = sys.argv[1]
scratch = os.environ.get("PHASE3_SCRATCH", str(ROOT / ".build/ci-phase3-load"))
load = ("--package-path", "Tools/DiscordKitLoadTests", "--scratch-path", scratch)
common = ("--build-system", "native", "--jobs", "6", "--force-resolved-versions",
          "--disable-experimental-prebuilts", "--explicit-target-dependency-import-check", "error")
commands = {
    "baseline-build": (1200, "coldCompileCommand", ("swift", "build", *load, *common, "--build-tests")),
    "baseline-discovery": (60, "testDiscovery", ("swift", "test", *load, *common, "--skip-build", "list")),
    "baseline-synthetic": (90, "focusedTest", ("swift", "test", *load, *common, "--skip-build", "--no-parallel",
                                              "--filter", "SyntheticCommandTimingRunnerTests")),
    "baseline-load": (600, "wholeLoadPackage", ("swift", "test", *load, *common, "--skip-build", "--no-parallel")),
    "green-build": (1200, "coldCompileCommand", ("swift", "build", *load, *common, "--build-tests")),
    "green-discovery": (60, "testDiscovery", ("swift", "test", *load, *common, "--skip-build", "list")),
    "green-synthetic": (90, "focusedTest", ("swift", "test", *load, *common, "--skip-build", "--no-parallel",
                                           "--filter", "SyntheticCommandTimingRunnerTests")),
    "green-transport": (90, "focusedTest", ("swift", "test", *load, *common, "--skip-build", "--no-parallel",
                                           "--filter", "TransportTimingRunnerTests")),
    "green-load": (600, "wholeLoadPackage", ("swift", "test", *load, *common, "--skip-build", "--no-parallel")),
    "peer-green": (60, "pythonRegression", ("python3", "-m", "unittest", "discover", "-s",
                                            "Tools/DiscordKitLoadTests/scripts", "-p", "test_local_peer.py", "-v")),
}
commands["green-final-build"] = commands["green-build"]
commands["final-discovery"] = commands["green-discovery"]
commands["final-load"] = commands["green-load"]
commands["peer-green-macos"] = commands["peer-green"]
output = Path(__file__).resolve().parent
binary = str(Path(scratch) / "x86_64-unknown-linux-gnu/debug/DiscordKitLoadTests")
for scenario in ("directImmediate", "dslImmediate", "directDeferred", "dslDeferred",
                 "directFailure", "dslFailure", "directCancelled", "dslCancelled"):
    key = "scenario-" + scenario
    commands[key] = (90, "focusedScenario", (binary, "command-timing", "--case", "synthetic." + scenario,
        "--requests", "7", "--concurrency", "3", "--warmup-requests", "0", "--delay-microseconds", "0",
        "--duration-seconds", "3", "--warmup-seconds", "0", "--profile", "smoke", "--seed", "1",
        "--output", str(output / (key + ".json")), "--common-report", str(output / (key + "-common.json"))))
for smoke, case, adapter in (("rest", "rest.cacheFresh", "scripted"),
                             ("loopback", "transport.smallBody", "nio")):
    key = "smoke-" + smoke
    commands[key] = (120, "timingSmoke", (binary, "timing", "--case", case, "--adapter", adapter,
        "--requests", "16", "--warmup-requests", "2", "--concurrency", "2", "--profile", "smoke",
        "--seed", "1", "--duration-seconds", "3", "--warmup-seconds", "1",
        "--output", str(output / (key + ".json")), "--common-report", str(output / (key + "-common.json"))))
limit, operation, arguments = commands[name]
os.environ["SWIFTNIO_STRICT"] = "1"
try:
    execute(Command(name, arguments, limit, operation=operation, stage="phase3-" + name), ROOT,
            output / (name + ".log"),
            stdout_log=output / (name + ".stdout") if operation == "testDiscovery" else None)
except Exception as error:
    print(f"{name}: {error}", file=sys.stderr)
    sys.exit(1)
