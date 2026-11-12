#!/usr/bin/env python3
# File: Tools/ci/native_provisioning.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Reuse authenticated Swift distributions with one finite provisioning allowance.

Only the original signed installer payload is cached. Every restored byte is
hashed against the repository pin and its upstream signature is checked before
installation or compiler execution. Installations, state, keys, credentials and
compiled project outputs never enter this cache. A bad hit fails explicitly;
there is no retry that silently acquires a second provisioning allowance.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import time

from linux_ci import CLEANUP_ALLOWANCE_SECONDS, Command, PLATFORMS, execute


POLICY_PATH = Path(__file__).with_name("provisioning-policy.v1.json")
REPOSITORY = Path(__file__).resolve().parents[2]


def canonical(value):
    """Serialize compatibility policy identically for keys and receipt checks."""
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def load_policy(path=POLICY_PATH):
    """Require exact release pins and finite resource limits before any download."""
    policy = json.loads(path.read_text())
    if (policy.get("schemaVersion") != 1 or policy.get("cacheSchemaVersion") != 1
            or policy.get("swiftVersion") != "6.4.1"
            or policy.get("installerPolicy") != "authenticated-swift-distribution-v1"
            or policy.get("allowanceSeconds") != 600
            or policy.get("maximumDistributionBytes") != 2 * 1024 ** 3
            or set(policy.get("platforms", {})) != set(PLATFORMS)):
        raise ValueError("unsupported provisioning policy")
    for target in ("linux-x64", "macos-arm64"):
        distribution = policy["platforms"][target]
        if (distribution.get("cacheEnabled") is not True
                or not re.fullmatch(r"[0-9a-f]{64}", distribution.get("distributionSHA256", ""))
                or not distribution.get("distributionURL", "").startswith("https://download.swift.org/swift-6.4.1-release/")):
            raise ValueError("authenticated distribution requires an exact official URL and SHA256 pin")
    linux = policy["platforms"]["linux-x64"]
    macos = policy["platforms"]["macos-arm64"]
    if (linux.get("signature") != "gpg-detached"
            or linux.get("signerFingerprints") != ["52BB7E3DE28A71BE22EC05FFEF80A866B47A981F"]
            or linux.get("installationPath") != "/opt/discordkit/swift-6.4.1-RELEASE-ubuntu24.04"
            or macos.get("signature") != "apple-package"
            or macos.get("signer") != "Developer ID Installer: Swift Open Source (V9AUD2URP3)"
            or macos.get("toolchainDirectory") != "swift-6.4.1-RELEASE.xctoolchain"):
        raise ValueError("Swift signature and deterministic installation policy must remain enabled")
    if policy["platforms"]["windows-x64"].get("cacheEnabled") is not False:
        raise ValueError("Windows distribution caching is not qualified")
    return policy


def required(value, name):
    """Reject missing image and SDK facts instead of sharing an unknown cache key."""
    if (not isinstance(value, str) or not value.strip()
            or value.strip().lower() in ("unknown", "none", "n/a", "unavailable")
            or any(char in value for char in "\0\r\n")):
        raise ValueError(f"required provisioning fact is unavailable: {name}")
    return value.strip()


def native_platform(target="auto"):
    """Require the actual host OS and architecture to agree with the selected lane."""
    observed = {("Linux", "x86_64"): "linux-x64", ("Linux", "amd64"): "linux-x64",
                ("Darwin", "arm64"): "macos-arm64", ("Darwin", "aarch64"): "macos-arm64",
                ("Windows", "amd64"): "windows-x64", ("Windows", "x86_64"): "windows-x64"}.get(
                    (platform.system(), platform.machine().lower()))
    if observed is None or target not in ("auto", observed):
        raise ValueError("actual host does not match the provisioning platform")
    return observed


def cache_save_allowed(environment=None):
    """Only default-branch pushes/manual runs may publish a trusted cache entry.

    Pull requests, pull_request_target, tags, arbitrary branches and missing event
    metadata are read-only even if a caller accidentally requests a cache save.
    GitHub's exact-key restore is scoped to the current/default branch. Refuse PR
    writes so a PR cannot populate an entry later consumed by another PR.
    """
    environment = os.environ if environment is None else environment
    branch = environment.get("DISCORDKIT_DEFAULT_BRANCH", "")
    return bool(branch and environment.get("GITHUB_EVENT_NAME") in ("push", "workflow_dispatch")
                and environment.get("GITHUB_REF") == f"refs/heads/{branch}")


def write_json(path, record):
    """Persist evidence atomically and never publish a half-written receipt."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(record, indent=2) + "\n")
    temporary.replace(path)


def terminal_failure(plan, error):
    """Finalize safely located plan evidence even when admission fails before provision."""
    try:
        root = Path(plan["root"])
        report = Path(plan["receiptPath"])
        if (not root.is_absolute() or root.is_symlink()
                or report != root / "evidence/provisioning.json"
                or report.is_symlink() or not report.parent.resolve().is_relative_to(root.resolve())):
            return
        record = {}
        if report.is_file() and report.stat().st_size < 1024 ** 2:
            try:
                record = json.loads(report.read_text())
                if not isinstance(record, dict):
                    record = {}
            except (ValueError, OSError):
                pass
        record.update(schemaVersion=1, status="failed", error=str(error), platform=plan.get("platform"))
        write_json(report, record)
    except (KeyError, TypeError, ValueError, OSError):
        # Malformed plans do not select arbitrary evidence destinations.
        return


def remaining(plan):
    """Include prerequisite installation, cache transport and cleanup in 600 seconds."""
    elapsed = time.time() - plan["startedEpoch"]
    if not math.isfinite(elapsed) or elapsed < -1:
        raise ValueError("provisioning start time is invalid")
    budget = plan["allowanceSeconds"] - max(0, elapsed)
    if budget <= CLEANUP_ALLOWANCE_SECONDS:
        raise ValueError("provisioning allowance exhausted; no cold fallback is permitted")
    return budget


def run_command(plan, name, arguments, *, maximum=300):
    """Use the existing durable supervisor and reserve cleanup inside the allowance."""
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,80}", name):
        raise ValueError("invalid provisioning command name")
    evidence = Path(plan["receiptPath"]).parent
    evidence.mkdir(parents=True, exist_ok=True)
    stdout = evidence / f"{name}.stdout"
    budget = remaining(plan) - CLEANUP_ALLOWANCE_SECONDS
    try:
        execute(Command(name, tuple(map(str, arguments)), min(maximum, budget),
                        operation="provisioning", stage="setup-native"), REPOSITORY,
                evidence / f"{name}.log", stdout_log=stdout, deadline=time.monotonic() + budget)
        remaining(plan)
    except BaseException as error:
        terminal_failure(plan, error)
        raise
    return stdout.read_text(encoding="utf-8", errors="replace").strip()


def image_facts(target, query):
    """Bind cache compatibility to the exact hosted image, OS and selected SDK."""
    facts = {"system": platform.system(), "architecture": platform.machine().lower(),
             "release": required(platform.release(), "OS release"),
             "version": required(platform.version(), "OS version"),
             "imageOS": required(os.environ.get("ImageOS"), "ImageOS"),
             "imageVersion": required(os.environ.get("ImageVersion"), "ImageVersion")}
    if target == "linux-x64":
        release = platform.freedesktop_os_release()
        if release.get("ID") != "ubuntu" or release.get("VERSION_ID") != "24.04":
            raise ValueError("native Linux provisioning requires Ubuntu 24.04")
        facts["distribution"] = {"id": release["ID"], "version": release["VERSION_ID"]}
    elif target == "macos-arm64":
        facts["xcode"] = {"developerDirectory": query(["xcode-select", "-p"]),
                          "version": query(["xcodebuild", "-version"]),
                          "sdkPath": query(["xcrun", "--sdk", "macosx", "--show-sdk-path"]),
                          "sdkVersion": query(["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
                          "sdkBuildVersion": query(["xcrun", "--sdk", "macosx", "--show-sdk-build-version"])}
        for name, value in facts["xcode"].items():
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"required provisioning SDK fact is unavailable: {name}")
            facts["xcode"][name] = value.strip()
        facts["xcode"]["sdkRootOverride"] = (required(os.environ["SDKROOT"], "SDKROOT")
                                              if "SDKROOT" in os.environ else None)
        facts["xcode"]["developerDirectoryOverride"] = (required(os.environ["DEVELOPER_DIR"], "DEVELOPER_DIR")
                                                       if "DEVELOPER_DIR" in os.environ else None)
    return facts


def compatibility_key(policy, target, facts):
    """Use a single exact key, never prefix restore across images or installers."""
    identity = {"cacheSchemaVersion": policy["cacheSchemaVersion"], "platform": target,
                "policy": policy, "image": facts}
    return f"discordkit-swift-v{policy['cacheSchemaVersion']}-{target}-{hashlib.sha256(canonical(identity)).hexdigest()}"


def prepare(target, root, output, *, github_output=None, github_env=None):
    """Start the shared allowance before prerequisite setup and cache transport."""
    policy = load_policy()
    target = native_platform(target)
    if root.is_symlink():
        raise ValueError("provisioning root must not be a symbolic link")
    root = root.resolve()
    if root.exists() and any(root.iterdir()):
        raise ValueError("provisioning root must be a fresh dedicated directory")
    root.mkdir(parents=True, exist_ok=True)
    plan = {"schemaVersion": 1, "platform": target, "root": str(root),
            "receiptPath": str(root / "evidence/provisioning.json"),
            "startedEpoch": time.time(), "startedAt": datetime.now(timezone.utc).isoformat(),
            "allowanceSeconds": policy["allowanceSeconds"],
            "policySHA256": hashlib.sha256(canonical(policy)).hexdigest(),
            "cachePath": str(root / "distribution"),
            "cacheEnabled": policy["platforms"][target]["cacheEnabled"],
            "cacheSaveAllowed": cache_save_allowed() and policy["platforms"][target]["cacheEnabled"]}
    count = 0

    def query(arguments):
        """Retain finite SDK observations used in the cache key."""
        nonlocal count
        count += 1
        return run_command(plan, f"prepare-sdk-{count}", arguments, maximum=30)

    plan["image"] = image_facts(target, query)
    if target == "macos-arm64":
        # Standalone signed toolchains need the Xcode SDK explicitly, including
        # direct swiftc consumers. Select it before sealing the cache identity.
        xcode = plan["image"]["xcode"]
        sdk = required(xcode["sdkRootOverride"] if xcode["sdkRootOverride"] is not None
                       else xcode["sdkPath"], "SDKROOT")
        if not Path(sdk).is_absolute() or not Path(sdk).is_dir():
            raise ValueError("SDKROOT must identify an existing absolute macOS SDK directory")
        os.environ["SDKROOT"] = sdk
        xcode["sdkRootOverride"] = sdk
        if github_env:
            with github_env.open("a") as stream:
                stream.write(f"SDKROOT={sdk}\n")
    plan["cacheKey"] = compatibility_key(policy, target, plan["image"])
    write_json(output, plan)
    write_json(Path(plan["receiptPath"]), {"schemaVersion": 1, "status": "prepared",
               "platform": target, "startedAt": plan["startedAt"],
               "allowanceSeconds": policy["allowanceSeconds"]})
    if github_output:
        values = {"cache-key": plan["cacheKey"], "cache-path": plan["cachePath"],
                  "cache-save": str(plan["cacheSaveAllowed"]).lower(),
                  "cache-enabled": str(plan["cacheEnabled"]).lower(),
                  "receipt-path": plan["receiptPath"]}
        with github_output.open("a") as stream:
            for name, value in values.items():
                stream.write(f"{name}={required(value, name)}\n")
    return plan


def load_plan(path):
    """Reject stale plans, changed policies and altered host selection."""
    plan = json.loads(path.read_text())
    policy = load_policy()
    if (plan.get("schemaVersion") != 1
            or plan.get("policySHA256") != hashlib.sha256(canonical(policy)).hexdigest()
            or plan.get("allowanceSeconds") != policy["allowanceSeconds"]):
        raise ValueError("provisioning plan does not match the current policy")
    if (type(plan.get("startedEpoch")) not in (int, float)
            or not math.isfinite(plan["startedEpoch"])
            or plan.get("cachePath") != str(Path(plan["root"]) / "distribution")
            or plan.get("receiptPath") != str(Path(plan["root"]) / "evidence/provisioning.json")):
        raise ValueError("provisioning plan paths or start time are invalid")
    native_platform(plan["platform"])
    if (plan.get("cacheKey") != compatibility_key(policy, plan["platform"], plan["image"])
            or plan.get("cacheEnabled") != policy["platforms"][plan["platform"]]["cacheEnabled"]):
        raise ValueError("provisioning plan cache identity is inconsistent")
    remaining(plan)
    return plan


def file_sha256(path, plan, maximum):
    """Bound cached file reads and reject links before touching restored payloads."""
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= maximum:
        raise ValueError("cached distribution is missing, oversized, or not a regular file")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 ** 2):
            remaining(plan)
            digest.update(block)
    return digest.hexdigest()


def payload_path(plan, policy):
    """Keep the official extension required by Apple's package installer."""
    filename = policy["platforms"][plan["platform"]]["distributionURL"].rsplit("/", 1)[1]
    return Path(plan["cachePath"]) / filename


def signing_keys(plan):
    """Import official Swift keys into isolated uncached state on cold and hit paths."""
    directory = Path(plan["root"]) / "signing-keys"
    if directory.exists():
        raise ValueError("Swift signing key directory must be fresh and uncached")
    directory.mkdir(mode=0o700)
    keys = Path(plan["receiptPath"]).parent / "swift-signing-keys.asc"
    run_command(plan, "download-signing-keys", ["curl", "--compressed", "--fail", "--show-error",
                "--silent", "--location", "--proto", "=https", "--tlsv1.2", "--max-filesize", "1048576",
                "--output", keys, "https://www.swift.org/keys/all-keys.asc"], maximum=60)
    run_command(plan, "import-signing-keys", ["gpg", "--homedir", directory,
                "--batch", "--import", keys], maximum=30)
    for index, fingerprint in enumerate(("E813C892820A6FA13755B268F167DF1ACF9CE069",
                                        "52BB7E3DE28A71BE22EC05FFEF80A866B47A981F")):
        output = run_command(plan, f"verify-signing-fingerprint-{index}", ["gpg", "--homedir", directory,
                             "--batch", "--with-colons", "--fingerprint", fingerprint], maximum=30)
        if not any(row.startswith("fpr:") and row.split(":")[9] == fingerprint
                   for row in output.splitlines() if len(row.split(":")) > 9):
            raise ValueError("official Swift key import did not produce the pinned signing fingerprint")
    return directory


def verify_distribution(plan, policy):
    """Authenticate the exact bytes before unpacking a restored or cold payload."""
    distribution = policy["platforms"][plan["platform"]]
    cache = Path(plan["cachePath"])
    payload = payload_path(plan, policy)
    expected = {payload.name, "identity.json"}
    if distribution["signature"] == "gpg-detached":
        expected.add(payload.name + ".sig")
    if cache.is_symlink() or not cache.is_dir() or {path.name for path in cache.iterdir()} != expected:
        raise ValueError("cached distribution contains missing or unexpected files")
    identity = cache / "identity.json"
    file_sha256(identity, plan, 16 * 1024)
    if json.loads(identity.read_text()) != {"schemaVersion": 1, "key": plan["cacheKey"],
                                           "distributionURL": distribution["distributionURL"],
                                           "distributionSHA256": distribution["distributionSHA256"]}:
        raise ValueError("cached distribution identity is stale or belongs to another platform")
    actual_hash = file_sha256(payload, plan, policy["maximumDistributionBytes"])
    if actual_hash != distribution["distributionSHA256"]:
        raise ValueError("cached distribution SHA256 does not match the pinned official payload")
    if distribution["signature"] == "gpg-detached":
        signature = payload.with_name(payload.name + ".sig")
        file_sha256(signature, plan, 64 * 1024)
        directory = signing_keys(plan)
        status = run_command(plan, "verify-distribution-signature", ["gpg", "--homedir", directory, "--batch",
                             "--no-auto-key-retrieve", "--status-fd", "1", "--verify", signature, payload], maximum=60)
        fingerprints = []
        for line in status.splitlines():
            fields = line.split()
            if fields[:2] == ["[GNUPG:]", "VALIDSIG"] and len(fields) >= 12:
                fingerprints.extend((fields[2], fields[-1]))
        allowed = distribution["signerFingerprints"]
        signer = next((fingerprint for fingerprint in fingerprints if fingerprint in allowed), None)
        if signer is None:
            raise ValueError("distribution signature did not authenticate an allowed Swift signing fingerprint")
    else:
        status = run_command(plan, "verify-distribution-signature",
                             ["pkgutil", "--check-signature", payload], maximum=60)
        signer = distribution["signer"]
        if ("Status: signed by a developer certificate issued by Apple for distribution" not in status
                or "Notarization: trusted by the Apple notary service" not in status
                or not re.search(rf"^\s*1\.\s+{re.escape(signer)}\s*$", status, flags=re.MULTILINE)):
            raise ValueError("distribution package is not signed by the trusted Swift Open Source installer")
    return {"method": distribution["signature"], "signer": signer, "signatureVerified": True,
            "sha256": actual_hash}


def download_distribution(plan, policy):
    """Fetch only official pinned payloads and keep the cache strictly file-only."""
    distribution = policy["platforms"][plan["platform"]]
    cache = Path(plan["cachePath"])
    if cache.exists():
        raise ValueError("a cache miss must not reuse leftover distribution files")
    cache.mkdir()
    payload = payload_path(plan, policy)
    downloads = [("distribution", distribution["distributionURL"], payload)]
    if distribution["signature"] == "gpg-detached":
        downloads.append(("signature", distribution["distributionURL"] + ".sig", payload.with_name(payload.name + ".sig")))
    for name, url, destination in downloads:
        run_command(plan, f"download-{name}", ["curl", "--fail", "--show-error", "--silent", "--location",
                    "--proto", "=https", "--tlsv1.2", "--max-filesize", str(policy["maximumDistributionBytes"]),
                    "--output", destination, url], maximum=300)
    write_json(cache / "identity.json", {"schemaVersion": 1, "key": plan["cacheKey"],
               "distributionURL": distribution["distributionURL"],
               "distributionSHA256": distribution["distributionSHA256"]})


def install_distribution(plan, policy):
    """Materialize authenticated bytes at the same compiler path on cold and hit jobs."""
    distribution = policy["platforms"][plan["platform"]]
    payload = payload_path(plan, policy)
    if plan["platform"] == "linux-x64":
        installation = Path(distribution["installationPath"])
        if installation.exists() or installation.is_symlink():
            raise ValueError("pinned compiler installation path is not fresh")
        run_command(plan, "create-installation-directory", ["sudo", "mkdir", "-p", installation])
        # The archive is authenticated before tar observes its headers or links.
        # Strip the official top-level directory to retain one deterministic path.
        run_command(plan, "install-distribution", ["sudo", "tar", "--extract", "--gzip", "--file", payload,
                    "--directory", installation, "--strip-components=1", "--no-same-owner"], maximum=300)
    else:
        installation = Path.home() / "Library/Developer/Toolchains" / distribution["toolchainDirectory"]
        if installation.exists() or installation.is_symlink():
            raise ValueError("pinned compiler installation path is not fresh")
        run_command(plan, "install-distribution", ["installer", "-pkg", payload,
                    "-target", "CurrentUserHomeDirectory"], maximum=300)
    binary = installation / "usr/bin"
    if not (binary / "swift").is_file() or not (binary / "swiftc").is_file():
        raise ValueError("verified installer did not produce the required compiler and runtime")
    return binary


def compiler_identity(plan, binary, policy):
    """Observe the installed compiler before exposing its PATH to consumers."""
    swift = binary / "swift" if binary else Path("swift")
    version = run_command(plan, "compiler-version", [swift, "--version"], maximum=30)
    if not re.search(rf"\bSwift version {re.escape(policy['swiftVersion'])}(?:\s|$)", version):
        raise ValueError("installed compiler does not match the pinned Swift version")
    info = json.loads(run_command(plan, "compiler-target", [swift, "-print-target-info"], maximum=30))
    try:
        triple = info["target"]["triple"]
        expected_architecture, family = {"linux-x64": ("x86_64", "linux"),
                                         "macos-arm64": ("arm64", "macosx"),
                                         "windows-x64": ("x86_64", "windows")}[plan["platform"]]
        parts = triple.lower().split("-")
        if parts[0] != expected_architecture or not any(part.startswith(family) for part in parts):
            raise ValueError("installed compiler target does not match the native platform")
        if not info["paths"]["runtimeResourcePath"] or not info["paths"]["runtimeLibraryPaths"]:
            raise ValueError("installed compiler runtime identity is incomplete")
    except (KeyError, TypeError, AttributeError) as error:
        raise ValueError("installed compiler target identity is incomplete") from error
    return version, info


def provision(plan, *, cache_hit=False, github_path=None, github_env=None):
    """Reject bad hits explicitly and retain failed evidence within the same budget."""
    policy = load_policy()
    started = time.monotonic()
    report = Path(plan["receiptPath"])
    record = {"schemaVersion": 1, "status": "running", "platform": plan["platform"],
              "startedAt": plan["startedAt"], "allowanceSeconds": plan["allowanceSeconds"],
              "cache": {"key": plan["cacheKey"], "hit": cache_hit,
                        "enabled": plan["cacheEnabled"], "saveAllowed": plan["cacheSaveAllowed"]},
              "image": plan["image"], "policySHA256": plan["policySHA256"]}
    write_json(report, record)
    try:
        native_platform(plan["platform"])
        remaining(plan)
        count = 0

        def query(arguments):
            """Re-observe compatibility instead of trusting restored metadata."""
            nonlocal count
            count += 1
            return run_command(plan, f"verify-sdk-{count}", arguments, maximum=30)

        if image_facts(plan["platform"], query) != plan["image"]:
            raise ValueError("provisioning image or SDK changed after the cache key was selected")
        if not plan["cacheEnabled"]:
            raise ValueError("compiler distribution provisioning is not qualified on this platform")
        else:
            if not cache_hit:
                download_distribution(plan, policy)
            record["verification"] = verify_distribution(plan, policy)
            distribution = policy["platforms"][plan["platform"]]
            record["distribution"] = {"url": distribution["distributionURL"],
                                       "sha256": distribution["distributionSHA256"]}
            size = payload_path(plan, policy).stat().st_size
            record.update(distributionBytes=size, downloadedBytes=0 if cache_hit else size,
                          cacheBytesReused=size if cache_hit else 0)
            write_json(report, record)
            binary = install_distribution(plan, policy)
        version, target = compiler_identity(plan, binary, policy)
        record.update(swiftVersion=version, targetInfo=target,
                      binPath=str(binary) if binary else None)
        remaining(plan)
        record.update(status="passed", elapsedSeconds=max(0, time.time() - plan["startedEpoch"]),
                      verificationAndInstallSeconds=time.monotonic() - started)
        write_json(report, record)
        if binary and github_path:
            with github_path.open("a") as stream:
                stream.write(required(str(binary), "compiler PATH") + "\n")
        if github_env:
            with github_env.open("a") as stream:
                stream.write(f"DISCORDKIT_PROVISIONING_RECEIPT={required(str(report), 'receipt path')}\n")
    except BaseException as error:
        record.update(status="failed", error=str(error), elapsedSeconds=max(0, time.time() - plan["startedEpoch"]))
        write_json(report, record)
        raise
    return record


def main():
    """Expose finite prepare, prerequisite-command, and authenticated-install steps."""
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    prepare_parser = actions.add_parser("prepare")
    prepare_parser.add_argument("--platform", choices=("auto", *PLATFORMS), default="auto")
    prepare_parser.add_argument("--root", type=Path, required=True)
    prepare_parser.add_argument("--output", type=Path, required=True)
    prepare_parser.add_argument("--github-output", type=Path)
    prepare_parser.add_argument("--github-env", type=Path)
    for name in ("provision", "run"):
        action = actions.add_parser(name)
        action.add_argument("--plan", type=Path, required=True)
        if name == "provision":
            action.add_argument("--cache-hit", choices=("", "true", "false"), default="false")
            action.add_argument("--github-path", type=Path)
            action.add_argument("--github-env", type=Path)
        else:
            action.add_argument("--name", required=True)
            action.add_argument("arguments", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    try:
        if arguments.action == "prepare":
            prepare(arguments.platform, arguments.root, arguments.output, github_output=arguments.github_output,
                    github_env=arguments.github_env)
        else:
            plan = load_plan(arguments.plan)
            if arguments.action == "run":
                command = arguments.arguments
                if command[:1] == ["--"]:
                    command = command[1:]
                if not command:
                    raise ValueError("a prerequisite command is required")
                run_command(plan, arguments.name, command)
            else:
                provision(plan, cache_hit=arguments.cache_hit == "true",
                          github_path=arguments.github_path, github_env=arguments.github_env)
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        if arguments.action in ("run", "provision"):
            try:
                if arguments.plan.stat().st_size < 1024 ** 2:
                    terminal_failure(json.loads(arguments.plan.read_text()), error)
            except (OSError, ValueError, TypeError):
                pass
        print(f"Native provisioning failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
