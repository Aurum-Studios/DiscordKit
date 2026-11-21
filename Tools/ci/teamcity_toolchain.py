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
import re
import shutil
import subprocess
import tempfile
import time

import native_provisioning as swift


LINUX_RUNTIME = Path("usr/lib/discordkit-ubuntu-runtime")
UBUNTU_LIBRARIES = {"libncurses6": "libncurses.so.6", "libtinfo6": "libtinfo.so.6"}
RUNTIME_RECEIPT = ".discordkit-ubuntu-runtime.json"


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


def library_path(directory):
    """Keep the packaged Ubuntu libraries first in the current job's search path."""
    inherited = os.environ.get("LD_LIBRARY_PATH")
    return f"{directory}:{inherited}" if inherited else str(directory)


def ubuntu_runtime(plan, destination):
    """Materialize the two Ubuntu runtime libraries from signed APT metadata under Swift."""
    receipt = destination / RUNTIME_RECEIPT
    if destination.is_symlink() or receipt.is_symlink():
        raise ValueError("The DiscordKit Ubuntu runtime cache must use regular paths")
    if not destination.exists():
        root = Path(plan["root"])
        downloads = root / "ubuntu-debs"
        packages = root / "ubuntu-libraries"
        downloads.mkdir()
        packages.mkdir()
        lists = root / "apt-lists"
        lists.mkdir()
        sources = root / "ubuntu.list"
        archive = "https://archive.ubuntu.com/ubuntu"
        security = "https://security.ubuntu.com/ubuntu"
        keyring = Path("/usr/share/keyrings/ubuntu-archive-keyring.gpg")
        if not keyring.is_file():
            raise ValueError("The Ubuntu archive signing keyring is unavailable")
        sources.write_text("".join(f"deb [arch=amd64 signed-by={keyring}] {uri} {series} main\n"
                                   for uri, series in ((archive, "noble"), (archive, "noble-updates"),
                                                       (security, "noble-security"))))
        configuration = root / "apt.conf"
        configuration.write_text(f'''
Dir::Etc::parts "-";
Dir::Etc::main "-";
Dir::Etc::sourcelist "{sources}";
Dir::Etc::sourceparts "-";
Dir::State::lists "{lists}";
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
Acquire::Languages "none";
Acquire::IndexTargets::deb::DEP-11::DefaultEnabled "false";
Acquire::AllowInsecureRepositories "false";
Acquire::AllowDowngradeToInsecureRepositories "false";
APT::Get::AllowUnauthenticated "false";
APT::Update::Error-Mode "any";
''')
        apt = ["env", f"APT_CONFIG={configuration}", "apt-get"]
        swift.run_command(plan, "refresh-ubuntu-runtime-index", [*apt, "update"], maximum=180, cwd=downloads)
        swift.run_command(plan, "download-ubuntu-runtime", [*apt, "download",
            *(f"{name}:amd64" for name in UBUNTU_LIBRARIES)], maximum=120, cwd=downloads)
        inventory = {}
        archives = sorted(downloads.glob("*.deb"))
        if len(archives) != len(UBUNTU_LIBRARIES):
            raise ValueError("APT did not supply the exact DiscordKit Ubuntu runtime packages")
        for number, deb in enumerate(archives):
            digest = swift.file_sha256(deb, plan, 16 * 1024 ** 2)
            metadata = swift.run_command(plan, f"inspect-ubuntu-runtime-{number}",
                ["dpkg-deb", "--field", deb, "Package", "Version", "Architecture"], maximum=20)
            fields = dict(line.split(": ", 1) for line in metadata.splitlines())
            name = fields.get("Package")
            version = fields.get("Version", "")
            if (name not in UBUNTU_LIBRARIES or name in inventory or fields.get("Architecture") != "amd64"
                    or not re.fullmatch(r"[A-Za-z0-9.+:~\-]+", version)):
                raise ValueError("Unexpected DiscordKit Ubuntu runtime package metadata")
            unpacked = (root / f"ubuntu-runtime-{number}").resolve()
            swift.run_command(plan, f"unpack-ubuntu-runtime-{number}",
                              ["dpkg-deb", "--extract", deb, unpacked], maximum=20)
            soname = UBUNTU_LIBRARIES[name]
            candidates = [(unpacked / prefix / "x86_64-linux-gnu" / soname).resolve()
                          for prefix in ("usr/lib", "lib")]
            libraries = {path for path in candidates if path.is_file() and path.is_relative_to(unpacked)}
            if len(libraries) != 1:
                raise ValueError(f"Expected one regular {soname} in the Ubuntu archive")
            library = packages / soname
            shutil.copy2(libraries.pop(), library)
            inventory[name] = {"version": version, "architecture": "amd64", "packageSHA256": digest,
                               "librarySHA256": swift.file_sha256(library, plan, 16 * 1024 ** 2)}
        swift.write_json(packages / RUNTIME_RECEIPT, inventory)
        destination.parent.mkdir(parents=True, exist_ok=True)
        packages.rename(destination)

    inventory = json.loads(receipt.read_text())
    if not isinstance(inventory, dict) or set(inventory) != set(UBUNTU_LIBRARIES):
        raise ValueError("DiscordKit Ubuntu runtime receipt has an incomplete package inventory")
    for name, soname in UBUNTU_LIBRARIES.items():
        package = inventory[name]
        if (not isinstance(package, dict) or package.get("architecture") != "amd64"
                or not re.fullmatch(r"[A-Za-z0-9.+:~\-]+", str(package.get("version", "")))
                or not re.fullmatch(r"[0-9a-f]{64}", str(package.get("packageSHA256", "")))
                or swift.file_sha256(destination / soname, plan, 16 * 1024 ** 2) != package.get("librarySHA256")):
            raise ValueError(f"DiscordKit Ubuntu runtime library differs from its receipt: {soname}")
    return inventory


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
            runtime = None
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
                    runtime = ubuntu_runtime(plan, candidate / LINUX_RUNTIME)
                    swift.compiler_identity(plan, candidate / "usr/bin", policy,
                                            library_path=library_path(candidate / LINUX_RUNTIME))
                    swift.write_json(candidate / marker.name, expected)
                    candidate.rename(installation)
                else:
                    swift.write_json(marker, installing)
                    swift.run_command(plan, "install-macos-toolchain", ["installer", "-pkg",
                        swift.payload_path(plan, policy), "-target", "CurrentUserHomeDirectory"], maximum=300)
                    swift.compiler_identity(plan, binary, policy)
                    swift.write_json(marker, expected)
            if is_linux:
                if runtime is None:
                    runtime = ubuntu_runtime(plan, installation / LINUX_RUNTIME)
                version, target = swift.compiler_identity(plan, binary, policy,
                                                          library_path=library_path(installation / LINUX_RUNTIME))
            else:
                version, target = swift.compiler_identity(plan, binary, policy)
    receipt = {**expected, "status": "passed", "cacheHit": cached, "swiftVersion": version, "targetInfo": target}
    if is_linux:
        receipt["ubuntuRuntime"] = {"directory": str(installation / LINUX_RUNTIME), "packages": runtime}
    swift.write_json(evidence, receipt)
    print(version, flush=True)
    return binary


def main():
    """Write the selected toolchain path and its nonsecret receipt into the build workspace."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("linux-x64", "macos-arm64"), required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--bin-output", type=Path, required=True)
    parser.add_argument("--library-output", type=Path, required=True)
    arguments = parser.parse_args()
    home = Path.home().resolve()
    try:
        binary = select(arguments.platform, home / ".cache/aurum/discordkit/toolchain", home, arguments.evidence)
        arguments.bin_output.parent.mkdir(parents=True, exist_ok=True)
        arguments.bin_output.write_text(f"{binary}\n")
        arguments.library_output.parent.mkdir(parents=True, exist_ok=True)
        library = binary.parents[1] / LINUX_RUNTIME if arguments.platform == "linux-x64" else ""
        arguments.library_output.write_text(f"{library}\n")
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        swift.write_json(arguments.evidence, {"status": "failed", "platform": arguments.platform, "error": str(error)})
        parser.exit(1, f"DiscordKit Swift setup failed: {error}\n")


if __name__ == "__main__":
    main()
