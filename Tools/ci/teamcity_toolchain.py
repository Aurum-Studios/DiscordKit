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
import plistlib
import subprocess
import tempfile
import time
import xml.etree.ElementTree as xml

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


def macos_bundle(plan, policy):
    """Extract one expected Xcode toolchain from the already authenticated installer payload."""
    name = policy["platforms"]["macos-arm64"]["toolchainDirectory"]
    expanded = Path(plan["root"]) / "expanded-swift-package"
    swift.run_command(plan, "expand-macos-toolchain", ["pkgutil", "--expand-full",
        swift.payload_path(plan, policy), expanded], maximum=300)
    candidates = []
    for payload in expanded.rglob("Payload"):
        if payload.is_symlink() or not payload.is_dir():
            continue
        candidates.extend(payload.rglob(name))
        metadata = payload.with_name("PackageInfo")
        if (payload / "Info.plist").is_file() and (payload / "usr/bin").is_dir():
            if metadata.is_symlink() or not metadata.is_file() or metadata.stat().st_size > 512 * 1024:
                raise ValueError("A direct Swift payload requires regular component package metadata")
            location = xml.parse(metadata).getroot().get("install-location", "")
            if Path(location).parts[-3:] == ("Developer", "Toolchains", name):
                candidates.append(payload)
    if len(candidates) != 1 or candidates[0].is_symlink() or not candidates[0].is_dir():
        raise ValueError(f"Expected exactly one regular {name} bundle in the signed macOS package")
    bundle = candidates[0].resolve(strict=True)
    if not bundle.is_relative_to(expanded.resolve(strict=True)):
        raise ValueError("The Swift bundle must be contained within the package payload")
    description = bundle / "Info.plist"
    if description.is_symlink() or not description.is_file() or description.stat().st_size > 512 * 1024:
        raise ValueError("The extracted Swift toolchain has no regular Info.plist")
    with description.open("rb") as stream:
        properties = plistlib.load(stream)
    if not isinstance(properties, dict) or not isinstance(properties.get("CFBundleIdentifier"), str):
        raise ValueError("The extracted Swift toolchain has no bundle identifier")
    for executable in ("swift", "swiftc"):
        compiler = (bundle / "usr/bin" / executable).resolve(strict=True)
        if not compiler.is_relative_to(bundle) or not compiler.is_file() or not os.access(compiler, os.X_OK):
            raise ValueError(f"The extracted Swift toolchain has no internal executable {executable}")
    return bundle


def select(cache, evidence):
    """Authenticate the macOS release on a cold install and verify the compiler on each run."""
    platform = swift.native_platform("macos-arm64")
    policy = swift.load_policy()
    distribution = policy["platforms"][platform]
    policy_digest = hashlib.sha256(swift.canonical(policy)).hexdigest()
    installation = cache / distribution["toolchainDirectory"]
    marker = installation / ".discordkit-distribution.json"
    binary = installation / "usr/bin"
    expected = {"policySHA256": policy_digest, "distributionSHA256": distribution["distributionSHA256"],
                "signer": distribution["signer"], "platform": platform, "binPath": str(binary)}

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
                if installation.exists():
                    raise ValueError(f"Existing Swift installation has no matching DiscordKit receipt: {installation}")
                swift.download_distribution(plan, policy)
                verification = swift.verify_distribution(plan, policy)
                if verification["signer"] != expected["signer"]:
                    raise ValueError("Swift signer does not match the installation receipt")
                candidate = macos_bundle(plan, policy)
                swift.compiler_identity(plan, candidate / "usr/bin", policy)
                swift.write_json(candidate / marker.name, expected)
                candidate.rename(installation)
            version, target = swift.compiler_identity(plan, binary, policy)
    receipt = {**expected, "status": "passed", "cacheHit": cached, "swiftVersion": version, "targetInfo": target}
    swift.write_json(evidence, receipt)
    print(version, flush=True)
    return binary


def main():
    """Write the selected toolchain path and its nonsecret receipt into the build workspace."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--bin-output", type=Path, required=True)
    arguments = parser.parse_args()
    home = Path.home().resolve()
    try:
        binary = select(home / ".cache/aurum/discordkit/toolchain", arguments.evidence)
        arguments.bin_output.parent.mkdir(parents=True, exist_ok=True)
        arguments.bin_output.write_text(f"{binary}\n")
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, xml.ParseError) as error:
        swift.write_json(arguments.evidence, {"status": "failed", "platform": "macos-arm64", "error": str(error)})
        parser.exit(1, f"DiscordKit Swift setup failed: {error}\n")


if __name__ == "__main__":
    main()
