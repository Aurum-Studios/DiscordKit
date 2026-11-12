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
import platform
import re
import shutil
import subprocess
import sys
import tempfile

import linux_runtime
from linux_ci import PLATFORMS, SWIFT_VERSION, metadata_query, native_preflight


PROBE = '''import Foundation
let payload = try JSONSerialization.data(withJSONObject: ["native": true])
let decoded = try JSONSerialization.jsonObject(with: payload) as! [String: Bool]
precondition(decoded["native"] == true)
print("DiscordKit native probe passed")
'''


def verified_provisioning_facts(native_platform, swift_version, target_info, query):
    """Bind optional provisioning evidence to the active compiler, never cache-hit state.

    Local unmanaged callers retain their existing compatibility contract. A job
    supplied with a provisioning receipt must prove its successful authenticated
    install still owns Swift on PATH and matches the current image and policy.
    Cold and cache-hit installations prove the same authenticated distribution.
    Linux binds that distribution and signer into its exact runtime contract;
    cache transport state remains informational.
    """
    receipt_path = os.environ.get("DISCORDKIT_PROVISIONING_RECEIPT")
    if receipt_path is None:
        return None
    import hashlib
    import native_provisioning

    path = Path(receipt_path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 128 * 1024:
        raise ValueError("provisioning receipt is unavailable or invalid")
    record = json.loads(path.read_text())
    if (not isinstance(record, dict) or not isinstance(record.get("verification"), dict)
            or not isinstance(record.get("cache"), dict)):
        raise ValueError("provisioning receipt is malformed")
    policy = native_provisioning.load_policy()
    distribution = policy["platforms"][native_platform]
    verification = record.get("verification", {})
    if (record.get("schemaVersion") != 1 or record.get("status") != "passed"
            or record.get("platform") != native_platform
            or record.get("policySHA256") != hashlib.sha256(native_provisioning.canonical(policy)).hexdigest()
            or record.get("distribution") != {"url": distribution.get("distributionURL"),
                                                "sha256": distribution.get("distributionSHA256")}
            or verification.get("signatureVerified") is not True
            or verification.get("method") != distribution.get("signature")
            or verification.get("sha256") != distribution.get("distributionSHA256")):
        raise ValueError("provisioning receipt does not prove an authenticated current installation")
    signers = distribution.get("signerFingerprints", [distribution.get("signer")])
    if verification.get("signer") not in signers:
        raise ValueError("provisioning receipt has an untrusted Swift signer")
    facts = native_provisioning.image_facts(native_platform, query)
    key = native_provisioning.compatibility_key(policy, native_platform, facts)
    if record.get("image") != facts or record.get("cache", {}).get("key") != key:
        raise ValueError("provisioning receipt belongs to another image or SDK")
    binary = (Path(distribution["installationPath"]) / "usr/bin" if native_platform == "linux-x64"
              else Path.home() / "Library/Developer/Toolchains" / distribution["toolchainDirectory"] / "usr/bin")
    if (record.get("binPath") != str(binary) or record.get("swiftVersion") != swift_version
            or record.get("targetInfo") != target_info
            or any(not shutil.which(name) or Path(shutil.which(name)).resolve() != (binary / name).resolve()
                   for name in ("swift", "swiftc"))):
        raise ValueError("active compiler differs from the verified provisioning receipt")
    return {"distributionSHA256": distribution["distributionSHA256"],
            "signer": verification["signer"], "cacheKey": key,
            "cacheHit": record["cache"].get("hit"), "receipt": str(path)}


def required_text(value, name):
    """Reject missing or placeholder required metadata instead of guessing compatibility."""
    if (not isinstance(value, str) or not value.strip() or "\0" in value
            or value.strip().lower() in ("unknown", "none", "n/a", "unavailable")
            or len(value) > 128 * 1024):
        raise ValueError(f"required build compatibility fact is unavailable: {name}")
    return value.strip()


def build_compatibility_facts(repository, native_platform, *, query=None):
    """Collect conservative exact build inputs separately from diagnostic image facts.

    Every value under ``exact`` requires equality, including kernel release/version,
    distribution/libc or OS runtime version, compiler target/runtime paths, image
    ImageOS and macOS Xcode/SDK facts. Linux additionally compares its complete
    native ELF/runtime closure instead of unrelated weekly image build numbers.
    Other platforms retain exact ImageVersion. No version ranges are inferred.
    Hosted execution requires an assigned image; local unmanaged hosts have an
    explicit image kind and still require the complete native OS/runtime identity.

    A supplied query must enforce its caller's aggregate and child deadlines.
    Standalone calls use the shared supervised 30-second metadata child limit.
    """
    if query is None:
        with tempfile.TemporaryDirectory(prefix="discordkit-build-facts-") as temporary:
            count = 0

            def supervised(arguments):
                """Retain separate command receipts without reusing one command's output."""
                nonlocal count
                count += 1
                return metadata_query(arguments, repository, Path(temporary), f"build-fact-{count}")

            return build_compatibility_facts(repository, native_platform, query=supervised)
    if native_platform not in PLATFORMS:
        raise ValueError("unsupported native build compatibility platform")
    expected_system, architectures, family = {
        "linux-x64": ("Linux", ("x86_64", "amd64"), "linux"),
        "macos-arm64": ("Darwin", ("arm64", "aarch64"), "macosx"),
        "windows-x64": ("Windows", ("x86_64", "amd64"), "windows"),
    }[native_platform]
    if platform.system() != expected_system or platform.machine().lower() not in architectures:
        raise ValueError("actual host does not match the native build compatibility platform")

    def text(arguments):
        """Keep query output finite and require an observed value for every command."""
        return required_text(query(arguments), " ".join(arguments))

    swift_version = text(["swift", "--version"])
    if not re.search(rf"\bSwift version {re.escape(SWIFT_VERSION)}(?:\s|$)", swift_version):
        raise ValueError(f"expected Swift {SWIFT_VERSION}")
    try:
        target_info = json.loads(text(["swift", "-print-target-info"]))
        if not isinstance(target_info, dict):
            raise ValueError("compiler target information must be an object")
        required_text(target_info["compilerVersion"], "compilerVersion")
        target = target_info["target"]
        triple = required_text(target["triple"], "Swift target triple")
        for field in ("unversionedTriple", "moduleTriple"):
            required_text(target[field], f"Swift target {field}")
        for field in ("runtimeLibraryPaths", "runtimeLibraryImportPaths"):
            paths = target_info["paths"][field]
            if not isinstance(paths, list) or not paths:
                raise ValueError(f"required Swift {field} are unavailable")
            for path in paths:
                required_text(path, f"Swift {field}")
        required_text(target_info["paths"]["runtimeResourcePath"], "Swift runtimeResourcePath")
    except (KeyError, TypeError, json.JSONDecodeError) as error:
        raise ValueError("required Swift target/runtime compatibility facts are unavailable") from error
    parts = triple.lower().split("-")
    if (parts[0] not in architectures or not any(part.startswith(family) for part in parts)
            or (native_platform == "macos-arm64" and "apple" not in parts)
            or (native_platform == "windows-x64" and "msvc" not in parts)):
        raise ValueError("Swift target does not match the native build compatibility platform")

    image_os, image_version = os.environ.get("ImageOS"), os.environ.get("ImageVersion")
    if image_os is not None or image_version is not None or os.environ.get("GITHUB_ACTIONS") == "true":
        image = {"kind": "runner-image", "os": required_text(image_os, "ImageOS"),
                 "version": required_text(image_version, "ImageVersion")}
    else:
        image = {"kind": "unmanaged"}
    exact = {"policyVersion": 1, "system": expected_system,
             "release": required_text(platform.release(), "OS release"),
             "version": required_text(platform.version(), "OS version"),
             "swiftVersion": swift_version, "swiftTarget": triple, "swiftTargetInfo": target_info,
             "image": image, "xcode": None}
    if native_platform == "linux-x64":
        exact["policyVersion"] = 2
        if "version" in image:
            del image["version"]
        distribution = platform.freedesktop_os_release()
        identifier = required_text(distribution.get("ID"), "Linux distribution ID")
        version = required_text(distribution.get("VERSION_ID"), "Linux distribution VERSION_ID")
        if identifier != "ubuntu" or version != "24.04":
            raise ValueError("native Linux artifacts require Ubuntu 24.04")
        libc = text(["ldd", "--version"]).splitlines()[0]
        if "GLIBC" not in libc and "GNU libc" not in libc:
            raise ValueError("required GNU libc runtime identity is unavailable")
        exact["osRuntime"] = {"distributionID": identifier, "distributionVersion": version,
                              "libc": libc}
        try:
            exact["linuxABI"] = linux_runtime.validate_facts(json.loads(text(
                [sys.executable, str(Path(__file__).with_name("linux_runtime.py"))])))
        except (TypeError, json.JSONDecodeError) as error:
            raise ValueError("required native Linux ABI facts are unavailable or malformed") from error
    elif native_platform == "macos-arm64":
        exact["osRuntime"] = {"productVersion": text(["sw_vers", "-productVersion"]),
                              "buildVersion": text(["sw_vers", "-buildVersion"])}
        exact["xcode"] = {"developerDirectory": text(["xcode-select", "-p"]),
                          "version": text(["xcodebuild", "-version"]),
                          "sdkPath": text(["xcrun", "--sdk", "macosx", "--show-sdk-path"]),
                          "sdkVersion": text(["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
                          "sdkBuildVersion": text(["xcrun", "--sdk", "macosx", "--show-sdk-build-version"]),
                          "sdkRootOverride": (required_text(os.environ["SDKROOT"], "SDKROOT")
                                              if "SDKROOT" in os.environ else None),
                          "developerDirectoryOverride": (required_text(os.environ["DEVELOPER_DIR"], "DEVELOPER_DIR")
                                                         if "DEVELOPER_DIR" in os.environ else None)}
    else:
        ucrt = ["powershell", "-NoProfile", "-NonInteractive", "-Command",
                "(Get-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\\ucrtbase.dll')).VersionInfo.FileVersion"]
        exact["osRuntime"] = {"ucrtVersion": text(ucrt)}
    informational = {"imageRelease": os.environ.get("ImageRelease"),
                     "runnerName": os.environ.get("RUNNER_NAME"),
                     "runnerEnvironment": os.environ.get("RUNNER_ENVIRONMENT"),
                     "pythonVersion": platform.python_version()}
    if native_platform == "linux-x64":
        informational["observedImageVersion"] = image_version
    provisioning = verified_provisioning_facts(native_platform, swift_version, target_info, query)
    if provisioning is not None:
        informational["provisioning"] = provisioning
    if native_platform == "linux-x64":
        exact["swiftDistribution"] = ({"kind": "authenticated", "sha256": provisioning["distributionSHA256"],
                                      "signer": provisioning["signer"]}
                                     if provisioning is not None else {"kind": "unmanaged"})
    return {"exact": exact, "informational": informational}


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
        count = 0

        def compatibility_query(arguments):
            """Retain all native compatibility queries under bounded child supervision."""
            nonlocal count
            count += 1
            return metadata_query(arguments, repository, output, f"compatibility-{count}")

        record["buildCompatibility"] = build_compatibility_facts(repository, target, query=compatibility_query)
        save()
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
