#!/usr/bin/env python3
# copyright:begin
# File: Tools/ci/teamcity_pipeline.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com
# copyright:end

"""Run a bounded TeamCity pipeline job and stage its individually uploaded files."""

import argparse
import os
from pathlib import Path, PurePosixPath
import subprocess
import tempfile

import linux_ci
import teamcity_gate


ROOT = Path(__file__).resolve().parents[2]
STATE = teamcity_gate.STATE
RESERVED = {"pipeline", "receipts"}


def stage_artifacts(output, destination, patterns, *, required):
    """Preserve regular matching files under their relative paths without duplicating archive bytes."""
    if output.resolve() != output or destination.resolve() != destination:
        raise ValueError("Pipeline artifact directories must remain inside the checkout")
    selected = set()
    missing = []
    for pattern in patterns:
        matches = set()
        for entry in output.glob(pattern):
            paths = entry.rglob("*") if entry.is_dir() and not entry.is_symlink() else (entry,)
            for path in paths:
                relative = path.relative_to(output)
                if path.resolve() != path or relative.parts[0] in RESERVED:
                    raise ValueError(f"Unexpected pipeline artifact path: {relative}")
                if not path.is_dir():
                    if not path.is_file():
                        raise ValueError(f"Pipeline artifacts must be regular files: {relative}")
                    matches.add(relative)
        if not matches:
            missing.append(pattern)
        selected.update(matches)
    for relative in sorted(selected):
        staged = destination / relative
        staged.parent.mkdir(parents=True, exist_ok=True)
        staged.hardlink_to(output / relative)
    if required and missing:
        raise ValueError(f"Missing pipeline artifacts: {', '.join(missing)}")


def run_job(repository, job, timeout, patterns, command):
    """Refresh an exact CI checkout, supervise its job, and publish a receipt after success."""
    teamcity_gate.require_id(job, "[A-Za-z][A-Za-z0-9]*")
    for pattern in patterns:
        relative = PurePosixPath(pattern)
        if relative.is_absolute() or not relative.parts or ".." in relative.parts or relative.parts[0] in RESERVED:
            raise ValueError(f"Invalid pipeline artifact pattern: {pattern}")
    if os.environ.get("CI") != "true" or not command.strip():
        raise ValueError("A TeamCity pipeline checkout and script are required")
    root = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], cwd=repository, text=True).strip()
    if Path(root).resolve() != repository:
        raise ValueError("Run the pipeline job from the checkout root")
    teamcity_gate.identity(repository)
    # Pipeline jobs can reuse an incremental checkout. Preserve only the dependency inputs.
    subprocess.run(["git", "clean", "-ffdx", "-e", f"/{STATE}/in/", "--", "."], cwd=repository, check=True)
    output = repository / STATE / "out"
    destination = output / "pipeline" / job
    destination.mkdir(parents=True)
    passed = False
    try:
        with tempfile.TemporaryDirectory(prefix="discordkit-pipeline-") as directory:
            script = Path(directory) / "job.sh"
            script.write_text(f"set -eu\n{command}\n", encoding="utf-8")
            task = linux_ci.Command(job, ("/bin/bash", "--noprofile", "--norc", str(script)),
                                    timeout, stage="teamcity-pipeline")
            linux_ci.execute(task, repository, destination / "runner.log")
        passed = True
    finally:
        stage_artifacts(output, destination, patterns, required=passed)

    receipt = output / "receipts" / f"{job}.json"
    try:
        teamcity_gate.record(repository, job)
        staged = destination / "receipts" / receipt.name
        staged.parent.mkdir()
        receipt.rename(staged)
    finally:
        receipt.unlink(missing_ok=True)


def main(argv=None):
    """Read the job's declared deadline and paths, returning a failure without a success receipt."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("job")
    parser.add_argument("minutes", type=int)
    parser.add_argument("patterns", nargs="*")
    args = parser.parse_args(argv)
    if args.minutes < 1:
        parser.error("minutes must be positive")
    try:
        repository = Path.cwd().resolve()
        if repository != ROOT:
            raise ValueError("Run the pipeline job from its own checkout")
        run_job(repository, args.job, args.minutes * 60, args.patterns, os.environ["DISCORDKIT_PIPELINE_SCRIPT"])
    except (KeyError, OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"TeamCity pipeline job failed: {error}\n")


if __name__ == "__main__":
    main()
