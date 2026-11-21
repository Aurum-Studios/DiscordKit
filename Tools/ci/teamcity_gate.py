#!/usr/bin/env python3
# copyright:begin
# File: Tools/ci/teamcity_gate.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com
# copyright:end

"""Bind passed TeamCity jobs and the documentation artifact to one Git revision."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[2]
STATE = Path(".build/teamcity")


def require_id(value, pattern):
    """Reject unresolved TeamCity parameters and unsafe names."""
    if not re.fullmatch(pattern, value):
        raise ValueError("Missing or invalid candidate identity")
    return value


def identity(repository):
    """Require TeamCity's snapshot SHA and an unchanged tracked checkout."""
    revision = require_id(os.environ["DISCORDKIT_VCS_REVISION"], "[a-f0-9]{40}")
    build = require_id(os.environ["DISCORDKIT_CI_BUILD_ID"], "[1-9][0-9]*")
    checkout = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()
    if checkout != revision or subprocess.check_output(
            ["git", "status", "--porcelain", "--untracked-files=no"], cwd=repository):
        raise ValueError("Tracked checkout differs from the assigned TeamCity revision")
    return {"schemaVersion": 1, "buildId": build, "revision": revision, "status": "passed"}


def record(repository, job):
    """Seal a job's successful completion after all its checks pass."""
    job = require_id(job, "[A-Za-z][A-Za-z0-9]*")
    receipt = {**identity(repository), "job": job}
    output = repository / STATE / "out" / "receipts"
    output.mkdir(parents=True, exist_ok=True)
    with (output / f"{job}.json").open("x") as stream:
        json.dump(receipt, stream, indent=2)
        stream.write("\n")


def certify(repository, expected):
    """Require every declared successful job from the exact snapshot chain."""
    candidate = identity(repository)
    incoming = repository / STATE / "in"
    names, builds = set(), set()
    for entry in expected:
        name, separator, build = entry.partition("=")
        require_id(name, "[A-Za-z][A-Za-z0-9]*")
        require_id(build, "[1-9][0-9]*")
        if not separator or name in names or build in builds or build == candidate["buildId"]:
            raise ValueError("Certification contains a duplicate or invalid prerequisite")
        names.add(name)
        builds.add(build)
        path = incoming / "receipts" / f"{name}.json"
        expected_receipt = {**candidate, "buildId": build, "job": name}
        if json.loads(path.read_text()) != expected_receipt:
            raise ValueError(f"Invalid prerequisite receipt for {name}")
    if {p.name for p in (incoming / "receipts").iterdir()} != {f"{job}.json" for job in names}:
        raise ValueError("Certification prerequisite inventory differs from the build chain")
    with (incoming / "DiscordKitLibrary.doccarchive.tar.gz").open("rb") as archive:
        candidate["documentationArchiveSHA256"] = hashlib.file_digest(archive, "sha256").hexdigest()
    candidate["prerequisites"] = dict(entry.split("=", 1) for entry in expected)
    output = repository / STATE / "out"
    output.mkdir(parents=True, exist_ok=True)
    with (output / "certification.json").open("x") as stream:
        json.dump(candidate, stream, indent=2, sort_keys=True)
        stream.write("\n")


def main():
    """Write a stage or aggregate receipt, withholding it when validation fails."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("record").add_argument("job")
    commands.add_parser("certify").add_argument("jobs", nargs="+")
    args = parser.parse_args()
    try:
        if args.command == "record":
            record(ROOT, args.job)
        else:
            certify(ROOT, args.jobs)
    except (KeyError, OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"TeamCity evidence rejected: {error}\n")


if __name__ == "__main__":
    main()
