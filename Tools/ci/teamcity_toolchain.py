#!/usr/bin/env python3
# File: Tools/ci/teamcity_toolchain.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Select DiscordKit's authenticated Swift toolchain in the TeamCity agent account."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform as host
import subprocess
import tempfile
import time

import native_provisioning as swift


def acquire(lock, seconds):
    """Serialize cold installs across agents sharing an account, with a finite wait."""
    deadline = time.monotonic() + seconds
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise TimeoutError("Timed out waiting for the DiscordKit Swift installation")
            time.sleep(0.25)


def select(platform, cache, home, evidence):
    """Authenticate the release on a cold install and verify the fixed compiler on every run."""
    policy = swift.load_policy()
    distribution = policy["platforms"][swift.native_platform(platform)]
    policy_digest = hashlib.sha256(swift.canonical(policy)).hexdigest()
    is_linux = platform == "linux-x64"
    if is_linux:
        release = host.freedesktop_os_release()
        if release.get("ID") != "ubuntu" or release.get("VERSION_ID") != "24.04":
            raise ValueError("DiscordKit Swift provisioning requires Ubuntu 24.04")
        installation = cache / distribution["archiveRoot"]
        marker = installation / ".discordkit-distribution.json"
    else:
        installation = home / "Library/Developer/Toolchains" / distribution["toolchainDirectory"]
        marker = cache / f"{distribution['toolchainDirectory']}.json"
    binary = installation / "usr/bin"
    expected = {"policySHA256": policy_digest, "distributionSHA256": distribution["distributionSHA256"],
                "signer": (distribution["signerFingerprints"][0] if is_linux else distribution["signer"]),
                "platform": platform, "binPath": str(binary)}

    cache.mkdir(mode=0o700, parents=True, exist_ok=True)
    if cache.is_symlink() or cache.stat().st_uid != os.getuid() or cache.stat().st_mode & 0o022:
        raise ValueError("DiscordKit Swift cache must belong to the agent without shared write access")
    with os.fdopen(os.open(cache / "swift.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600), "r+") as lock:
        acquire(lock, policy["allowanceSeconds"])
        with tempfile.TemporaryDirectory(prefix="swift-install-", dir=cache) as directory:
            root = Path(directory)
            plan = {"root": str(root), "platform": platform, "cachePath": str(root / "distribution"),
                    "cacheKey": policy_digest, "receiptPath": str(root / "evidence/provisioning.json"),
                    "startedEpoch": time.time(), "allowanceSeconds": policy["allowanceSeconds"]}
            if installation.is_symlink() or marker.is_symlink():
                raise ValueError("DiscordKit Swift installation and receipt must be regular paths")
            installed_receipt = json.loads(marker.read_text()) if marker.is_file() else None
            cached = installation.is_dir() and installed_receipt == expected
            if not cached:
                installing = {**expected, "status": "installing"}
                if installation.exists() and (is_linux or installed_receipt != installing):
                    raise ValueError(f"Existing Swift installation has no matching DiscordKit receipt: {installation}")
                swift.download_distribution(plan, policy)
                verification = swift.verify_distribution(plan, policy)
                if verification["signer"] != expected["signer"]:
                    raise ValueError("Swift signer does not match the installation receipt")
                if is_linux:
                    candidate = root / "installation"
                    candidate.mkdir()
                    swift.run_command(plan, "extract-linux-toolchain", ["tar", "--extract", "--gzip", "--file",
                        swift.payload_path(plan, policy), "--directory", candidate, "--strip-components=1",
                        "--no-same-owner"], maximum=300)
                    swift.compiler_identity(plan, candidate / "usr/bin", policy)
                    swift.write_json(candidate / marker.name, expected)
                    candidate.rename(installation)
                else:
                    swift.write_json(marker, installing)
                    swift.run_command(plan, "install-macos-toolchain", ["installer", "-pkg",
                        swift.payload_path(plan, policy), "-target", "CurrentUserHomeDirectory"], maximum=300)
                    swift.compiler_identity(plan, binary, policy)
                    swift.write_json(marker, expected)
            version, target = swift.compiler_identity(plan, binary, policy)
    swift.write_json(evidence, {**expected, "status": "passed", "cacheHit": cached,
                                "swiftVersion": version, "targetInfo": target})
    print(version, flush=True)
    return binary


def main():
    """Write the selected toolchain path and its nonsecret receipt into the build workspace."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("linux-x64", "macos-arm64"), required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--bin-output", type=Path, required=True)
    arguments = parser.parse_args()
    home = Path.home().resolve()
    try:
        binary = select(arguments.platform, home / ".cache/aurum/discordkit/toolchain", home, arguments.evidence)
        arguments.bin_output.parent.mkdir(parents=True, exist_ok=True)
        arguments.bin_output.write_text(f"{binary}\n")
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        swift.write_json(arguments.evidence, {"status": "failed", "platform": arguments.platform, "error": str(error)})
        parser.exit(1, f"DiscordKit Swift setup failed: {error}\n")


if __name__ == "__main__":
    main()
