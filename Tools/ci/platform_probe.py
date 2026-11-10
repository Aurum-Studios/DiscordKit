#!/usr/bin/env python3
# File: Tools/ci/platform_probe.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Check native platform identity and compile, link and execute a small Swift probe."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from linux_ci import PLATFORMS, native_preflight


PROBE = '''import Foundation
let payload = try JSONSerialization.data(withJSONObject: ["native": true])
let decoded = try JSONSerialization.jsonObject(with: payload) as! [String: Bool]
precondition(decoded["native"] == true)
print("DiscordKit native probe passed")
'''


def probe(repository, output, target):
    """Retain identity and real compiler/runtime results before admitting build work.

    The temporary executable is offline and has no Discord dependency. Every
    child has a deadline, and failed or interrupted checks retain failed evidence.
    """
    output.mkdir(parents=True, exist_ok=True)
    record = {"platform": target, "status": "running", "commands": [],
              "runnerOS": os.environ.get("RUNNER_OS"),
              "runnerArchitecture": os.environ.get("RUNNER_ARCH")}
    report = output / "probe.json"

    def save():
        """Persist progress before a child starts and after every terminal result."""
        report.write_text(json.dumps(record, indent=2) + "\n")

    save()
    try:
        native_preflight(repository, output, target)
        expected_os, expected_arch = {
            "linux-x64": ("Linux", "X64"),
            "macos-arm64": ("macOS", "ARM64"),
            "windows-x64": ("Windows", "X64"),
        }[target]
        if record["runnerOS"] not in (None, expected_os) or record["runnerArchitecture"] not in (None, expected_arch):
            raise ValueError("assigned runner identity does not match the native platform")
        with tempfile.TemporaryDirectory(prefix="discordkit-platform-") as temporary:
            directory = Path(temporary)
            source = directory / "probe.swift"
            executable = directory / ("probe.exe" if target == "windows-x64" else "probe")
            source.write_text(PROBE)
            for name, arguments in (("compile", ["swiftc", str(source), "-o", str(executable)]),
                                    ("execute", [str(executable)])):
                command = {"name": name, "arguments": arguments, "status": "running"}
                record["commands"].append(command)
                save()
                completed = subprocess.run(arguments, cwd=repository, capture_output=True,
                                           text=True, timeout=120, check=True)
                (output / f"{name}.log").write_text(completed.stdout + completed.stderr)
                if name == "execute" and completed.stdout.strip() != "DiscordKit native probe passed":
                    raise ValueError("native probe did not report a successful roundtrip")
                command["status"] = "passed"
                save()
    except BaseException as error:
        record.update(status="failed", error=str(error))
        if record["commands"] and record["commands"][-1]["status"] == "running":
            record["commands"][-1]["status"] = "failed"
        if isinstance(error, subprocess.CalledProcessError):
            (output / "failure.log").write_text((error.stdout or "") + (error.stderr or ""))
        save()
        raise
    record["status"] = "passed"
    save()


def main():
    """Run the one selected native probe and return failure without installing tools."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--platform", choices=PLATFORMS, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        probe(arguments.repository.resolve(), arguments.output, arguments.platform)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Platform check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
