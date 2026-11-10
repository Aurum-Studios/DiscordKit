#!/usr/bin/env python3
# File: Tools/ci/package_source.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Archive the clean, tested Git revision as a SwiftPM source distribution."""

import argparse
import hashlib
import json
import os
import platform
import subprocess
from pathlib import Path


PLATFORMS = {
    "linux-x64": ("Linux", ("x86_64", "amd64"), "linux"),
    "macos-arm64": ("Darwin", ("arm64", "aarch64"), "macosx"),
    "windows-x64": ("Windows", ("x86_64", "amd64"), "windows"),
}


def git(repository, *arguments):
    """Run Git against an explicit checkout without shell interpolation."""
    return subprocess.check_output(["git", "-C", str(repository), *arguments])


def native_provenance(native_platform):
    """Require the requested native host and compiler target before naming a bundle."""
    if native_platform not in PLATFORMS:
        raise ValueError("unsupported source-package platform")
    expected_system, expected_machines, target_family = PLATFORMS[native_platform]
    system, machine = platform.system(), platform.machine().lower()
    if system != expected_system or machine not in expected_machines:
        raise ValueError("source packaging host does not match the requested native platform")
    target = json.loads(subprocess.check_output(["swift", "-print-target-info"], text=True))
    triple = target["target"]["triple"]
    target_parts = triple.lower().split("-")
    if (target_parts[0] not in expected_machines
            or not any(part.startswith(target_family) for part in target_parts)):
        raise ValueError("source packaging requires a Swift target matching the requested native platform")
    host = {"system": system, "machine": machine, "release": platform.release(),
            "version": platform.version()}
    if native_platform == "linux-x64":
        host["distribution"] = platform.freedesktop_os_release()
    elif native_platform == "macos-arm64":
        host["macOSVersion"] = platform.mac_ver()[0]
    else:
        release, version, service_pack, edition = platform.win32_ver()
        host["windows"] = {"release": release, "version": version,
                           "servicePack": service_pack, "edition": edition}
    swift_version = subprocess.check_output(["swift", "--version"], text=True).strip()
    return triple, swift_version, host


def package_source(repository, output, native_platform="linux-x64"):
    """Package tracked source only, with compiler/host provenance and a checksum.

    A clean checkout ensures that the archived HEAD is the source just built and
    tested. Untracked files and ignored build caches never enter the archive.
    The complete tree preserves local dependencies between root, authoring
    packages, examples and fixtures. Private Air task data is excluded.
    """
    repository = repository.resolve()
    if git(repository, "status", "--porcelain", "--untracked-files=no").strip():
        raise ValueError("Source packaging requires a clean tracked checkout")
    revision = git(repository, "rev-parse", "HEAD").decode().strip()
    if os.environ.get("GITHUB_SHA", revision) != revision:
        raise ValueError("Source packaging checkout differs from the executing GitHub SHA")
    triple, swift_version, host = native_provenance(native_platform)
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    suffix = "linux-source" if native_platform == "linux-x64" else f"{native_platform}-source"
    name = f"DiscordKit-{revision}-{suffix}"
    archive = output / f"{name}.tar.gz"
    subprocess.run(["git", "-C", str(repository), "archive", "--format=tar.gz",
                    f"--output={archive}", "--prefix=DiscordKit/", revision,
                    "--", ".", ":(exclude).air"], check=True)
    with archive.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    checksum = output / f"{name}.tar.gz.sha256"
    checksum.write_text(f"{digest}  {archive.name}\n")
    metadata = {
        "schemaVersion": 2,
        "format": "swiftpm-source",
        "revision": revision,
        "archive": archive.name,
        "sha256": digest,
        "configuration": "release",
        "platform": native_platform,
        "swiftVersion": swift_version,
        "targetTriple": triple,
        "host": host,
        "runID": os.environ.get("GITHUB_RUN_ID", "local"),
        "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT", "local"),
    }
    manifest = output / f"{name}.json"
    manifest.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    return archive, checksum, manifest


def main():
    """Write a native-platform source bundle after that platform's validation gates."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path, default=Path(".build/packages"))
    parser.add_argument("--platform", choices=PLATFORMS, default="linux-x64")
    arguments = parser.parse_args()
    for path in package_source(arguments.repository, arguments.output, arguments.platform):
        print(path)


if __name__ == "__main__":
    main()
