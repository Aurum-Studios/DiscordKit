#!/usr/bin/env python3
# File: Docs/Tasks/ci-reliability/phase-4/validate.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Retain bounded Phase 4 local helper execution; never starts a native compiler."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[4]
OUTPUT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "Tools/ci"))
from linux_ci import Command, execute

commands = {
    "helpers": (ROOT, (sys.executable, "-m", "unittest", "discover", "-s", "Tools/ci", "-p", "test_*.py"), 300),
    "exact-types-green": (ROOT / "Tools/ci", (sys.executable, "-m", "unittest",
        "test_native_jobs.NativeArtifactTests.test_final_compatibility_change_fails_after_successful_restored_tests",
        "test_native_jobs.NativeArtifactTests.test_compilation_rejects_required_runtime_type_drift_before_sealing"), 60),
    "policy": (ROOT, (sys.executable, "Tools/ci/scheduling_policy.py", "validate"), 60),
}
name = sys.argv[1]
repository, arguments, limit = commands[name]
try:
    execute(Command("phase4-" + name, arguments, limit, operation="localHelperCheck", stage="phase4"),
            repository, OUTPUT / (name + ".log"))
except Exception as error:
    print(f"{name}: {error}", file=sys.stderr)
    raise SystemExit(1)
