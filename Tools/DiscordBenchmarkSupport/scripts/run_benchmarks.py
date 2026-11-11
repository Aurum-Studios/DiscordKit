#!/usr/bin/env python3
# File: Tools/DiscordBenchmarkSupport/scripts/run_benchmarks.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Build release executables and supervise finite, fresh-process benchmark runs.

This orchestration manifest is deliberately separate from DiscordBenchmarkReport
and legacy native reports. Environment variables are requests to participants,
not evidence that an arbitrary executable honors warmup, duration or cohort
limits. The driver enforces wall timeout, sampled leader RSS, bounded artifacts
and process-group teardown itself; unsupported gauges remain unavailable.

Commands are JSON arrays, never shell text. A release-build receipt binds an
executable to its source, pins, compiler and flags. Run artifacts must live in an
ignored directory (for example .build/benchmark-runs) or outside source checkouts,
so creating them cannot invalidate the dirty-source fingerprint.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import selectors
import shutil
import signal
import subprocess
import sys
import time
import traceback
from typing import Any


MIB = 1024 * 1024
FORMAT = "discordkit.benchmark-orchestration"
RECEIPT_FORMAT = "discordkit.benchmark-release-build"
MAX_REPORT_BYTES = 32 * MIB
MAX_DIAGNOSTIC_BYTES = 16 * MIB


@dataclass(frozen=True)
class Profile:
    """Reviewed finite ceilings; callers may lower limits but never raise them."""

    name: str
    version: int
    measured_cap_seconds: int
    repetitions: int
    active_cohort_cap: int
    rss_cap_bytes: int
    retained_state_cap_bytes: int
    backlog_cap: int = 1024
    warmup_cap_seconds: int = 60


PROFILES = {
    "smoke": Profile("smoke", 1, 10, 1, 64, 1024 * MIB, 16 * MIB),
    "standard": Profile("standard", 1, 300, 5, 256, 2048 * MIB, 16 * MIB),
    "stress": Profile("stress", 1, 300, 3, 256, 2048 * MIB, 16 * MIB),
    "soak": Profile("soak", 1, 3600, 1, 256, 2048 * MIB, 16 * MIB),
}


@dataclass(frozen=True)
class ProcessLimits:
    """Concrete process budgets; short budgets are injectable for real tests."""

    timeout_seconds: float
    grace_seconds: float = 5.0
    diagnostic_bytes: int = MAX_DIAGNOSTIC_BYTES
    report_bytes: int = MAX_REPORT_BYTES
    rss_bytes: int = 1024 * MIB
    sample_seconds: float = 0.1

    def __post_init__(self) -> None:
        """Reject nonfinite and nonpositive limits before launching a child."""
        for name in ("timeout_seconds", "grace_seconds", "sample_seconds"):
            value = getattr(self, name)
            if not math.isfinite(value) or value <= 0:
                raise ValueError(f"{name} must be finite and positive")
        if self.grace_seconds > 5:
            raise ValueError("termination grace cannot exceed five seconds")
        for name in ("diagnostic_bytes", "report_bytes", "rss_bytes"):
            if not isinstance(getattr(self, name), int) or getattr(self, name) <= 0:
                raise ValueError(f"{name} must be a positive integer")
        if self.diagnostic_bytes > MAX_DIAGNOSTIC_BYTES or self.report_bytes > MAX_REPORT_BYTES:
            raise ValueError("artifact limits exceed the reviewed ceilings")


class Cancellation:
    """Shared signal-safe cancellation flag, with no per-operation tasks."""

    def __init__(self) -> None:
        self.requested = False

    def request(self, *_: object) -> None:
        """Record SIGINT/SIGTERM or an explicit caller cancellation."""
        self.requested = True


def sha256_file(path: Path) -> str:
    """Hash arbitrary files incrementally rather than retaining file contents."""
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, value: Any, cap: int = MAX_REPORT_BYTES, *, compact: bool = False) -> None:
    """Serialize outside measurement and reject oversize rather than truncate JSON."""
    payload = json.dumps(value, indent=None if compact else 2, separators=(",", ":") if compact else None,
                         sort_keys=True, allow_nan=False).encode() + b"\n"
    if len(payload) > cap:
        raise ValueError("serialized manifest exceeds the report ceiling")
    temporary = path.with_name(path.name + ".partial")
    temporary.write_bytes(payload)
    temporary.replace(path)


def strict_json(payload: bytes | str) -> Any:
    """Reject nonfinite JSON numbers and malformed/deep partial report artifacts."""
    def finite_number(value: str) -> float:
        result = float(value)
        if not math.isfinite(result):
            raise ValueError("nonfinite JSON number")
        return result

    def invalid_constant(_: str) -> None:
        raise ValueError("nonstandard JSON constant")

    try:
        return json.loads(payload, parse_float=finite_number, parse_constant=invalid_constant)
    except RecursionError as error:
        raise ValueError("JSON nesting exceeds decoder bounds") from error


def capture(command: list[str], cwd: Path | None = None, *, strip: bool = True,
            timeout_seconds: float = 30, accepted_returncodes: tuple[int, ...] = (0,)) -> str:
    """Collect small trusted metadata commands with a timeout and byte ceiling."""
    process = subprocess.Popen(command, cwd=cwd, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, start_new_session=True)
    assert process.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    result = bytearray()
    deadline = time.monotonic() + timeout_seconds
    try:
        while selector.get_map():
            if time.monotonic() >= deadline:
                raise ValueError(f"metadata command timed out: {command[0]}")
            for key, _ in selector.select(0.05):
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                elif len(result) + len(chunk) > MAX_DIAGNOSTIC_BYTES:
                    raise ValueError("metadata command exceeded its byte ceiling")
                else:
                    result.extend(chunk)
        if process.wait(timeout=max(0.01, deadline - time.monotonic())) not in accepted_returncodes:
            raise ValueError(f"metadata command failed: {command[0]}")
        value = result.decode(errors="surrogateescape")
        return value.strip() if strip else value
    finally:
        selector.close()
        process.stdout.close()
        if process.poll() is None:
            signal_group(process.pid, signal.SIGKILL)
        process.wait()


def optional_capture(command: list[str]) -> str | None:
    """Represent missing platform metadata as unavailable instead of zero."""
    try:
        value = capture(command)
        return value or None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def linux_cgroup_limits(root: Path = Path("/sys/fs/cgroup"),
                        membership_path: Path = Path("/proc/self/cgroup")) -> dict[str, Any]:
    """Read effective finite cgroup-v2 ancestor caps instead of only mount-root caps.

    Namespace-relative mount layouts fall back to the visible mount root. Missing
    v1/controller support is unavailable; an explicitly unlimited v2 quota is
    distinguished from a failed read.
    """
    root = root.resolve()
    result: dict[str, Any] = {"cpu_quota": None, "memory_limit_bytes": None,
                              "memory_limit_state": "unavailable"}
    try:
        membership = next(line.split(":", 2)[2] for line in membership_path.read_text().splitlines()
                          if line.startswith("0::"))
        location = (root / membership.lstrip("/")).resolve()
        candidates = []
        while location == root or root in location.parents:
            if location.is_dir():
                candidates.append(location)
            if location == root:
                break
            location = location.parent
        if root not in candidates:
            candidates.append(root)
        quotas = []
        memories = []
        quota_seen = False
        memory_seen = False
        for candidate in candidates:
            quota = candidate / "cpu.max"
            if quota.is_file():
                tokens = quota.read_text().split()
                if len(tokens) != 2 or not tokens[1].isdigit() or int(tokens[1]) <= 0:
                    raise ValueError("invalid cpu.max")
                quota_seen = True
                if tokens[0] != "max":
                    amount = int(tokens[0])
                    if amount <= 0:
                        raise ValueError("invalid cpu.max quota")
                    quotas.append(amount / int(tokens[1]))
            limit = candidate / "memory.max"
            if limit.is_file():
                value = limit.read_text().strip()
                if value != "max" and (not value.isdigit() or int(value) <= 0):
                    raise ValueError("invalid memory.max")
                memory_seen = True
                if value.isdigit():
                    memories.append(int(value))
        if quota_seen:
            result["cpu_quota"] = {"effective_cores": min(quotas) if quotas else None,
                                   "state": "finite" if quotas else "unlimited",
                                   "method": "visible cgroup-v2 cpu.max hierarchy"}
        result["memory_limit_bytes"] = min(memories) if memories else None
        if memory_seen:
            result["memory_limit_state"] = "finite" if memories else "unlimited"
    except (OSError, ValueError, StopIteration, ZeroDivisionError):
        pass
    return result


def source_identity(repository: Path) -> dict[str, Any]:
    """Fingerprint exact dirty file bytes, including deleted and untracked inputs."""
    repository = Path(capture(["git", "rev-parse", "--show-toplevel"], repository))
    revision = capture(["git", "rev-parse", "HEAD"], repository)
    status = capture(["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"], repository, strip=False)
    changed = capture(["git", "diff", "--name-only", "-z", "HEAD"], repository, strip=False).split("\0")
    untracked = capture(["git", "ls-files", "--others", "--exclude-standard", "-z"], repository, strip=False).split("\0")
    tracked = capture(["git", "ls-files", "-z"], repository, strip=False).split("\0")
    digest = hashlib.sha256(os.fsencode(status))
    for name in sorted(set(changed + untracked) - {""}):
        path = repository / name
        digest.update(os.fsencode(name) + b"\0")
        if path.is_symlink():
            digest.update(b"symlink\0" + os.fsencode(os.readlink(path)))
        elif path.is_file():
            digest.update(sha256_file(path).encode())
        else:
            digest.update(b"deleted-or-directory")
    pins = {name: sha256_file(repository / name) for name in sorted(set(tracked + untracked))
            if Path(name).name in {"Package.resolved", "Cargo.lock", "package-lock.json"}
            and (repository / name).is_file()}
    return {"repository": str(repository), "revision": revision, "dirty": bool(status),
            "dirty_fingerprint_sha256": digest.hexdigest(), "dependency_hashes": pins}


def environment() -> dict[str, Any]:
    """Capture macOS/Linux host allocation; unavailable gauges carry a reason."""
    system = platform.system()
    result: dict[str, Any] = {
        "machine_identity_sha256": hashlib.sha256(platform.node().encode()).hexdigest() if platform.node() else None,
        "operating_system": platform.platform(), "architecture": platform.machine() or None,
        "logical_cpu_count": os.cpu_count(), "cpu_affinity": None, "cpu_quota": None,
        "cpu_model": None, "hardware_model": None, "memory_bytes": None,
        "memory_limit_bytes": None, "memory_limit_state": "not-applicable" if system == "Darwin" else "unavailable",
        "unavailability_reasons": {},
        "runner_identity_sha256": hashlib.sha256(os.environ["RUNNER_NAME"].encode()).hexdigest()
            if os.environ.get("RUNNER_NAME") else None,
    }
    if hasattr(os, "sched_getaffinity"):
        try:
            result["cpu_affinity"] = sorted(os.sched_getaffinity(0))
        except OSError:
            pass
    if system == "Darwin":
        result["hardware_model"] = optional_capture(["sysctl", "-n", "hw.model"])
        result["cpu_model"] = optional_capture(["sysctl", "-n", "machdep.cpu.brand_string"])
        memory = optional_capture(["sysctl", "-n", "hw.memsize"])
        result["memory_bytes"] = int(memory) if memory and memory.isdigit() else None
    elif system == "Linux":
        try:
            info = Path("/proc/cpuinfo").read_text()
            result["cpu_model"] = next((line.split(":", 1)[1].strip() for line in info.splitlines()
                                         if line.startswith(("model name", "Hardware"))), None)
            # DMI is commonly absent on ARM and containers; cpu_model still identifies CPU.
            model = Path("/sys/devices/virtual/dmi/id/product_name")
            result["hardware_model"] = model.read_text().strip() if model.is_file() else None
            for line in Path("/proc/meminfo").read_text().splitlines():
                if line.startswith("MemTotal:"):
                    result["memory_bytes"] = int(line.split()[1]) * 1024
            result.update(linux_cgroup_limits())
        except (OSError, ValueError):
            pass
    for key, value in result.items():
        if value is None:
            result["unavailability_reasons"][key] = f"not available from {system} host APIs"
    return result


def host_observation() -> dict[str, Any]:
    """Retain inexpensive contention indicators, never a claim of host exclusivity."""
    try:
        load = list(os.getloadavg())
    except (AttributeError, OSError):
        load = None
    return {"load_average_1_5_15_minutes": load,
            "method": "os.getloadavg; host-level indicator, not exclusive-allocation proof"}


def process_rss(pid: int) -> int | None:
    """Return current leader RSS bytes, never a fabricated per-row process maximum."""
    try:
        if platform.system() == "Linux":
            for line in Path(f"/proc/{pid}/status").read_text().splitlines():
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) * 1024
        elif platform.system() == "Darwin":
            value = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True,
                                   timeout=0.5, check=False, text=True).stdout.strip()
            return int(value) * 1024 if value else None
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return None


def group_has_live_members(pid: int) -> bool | None:
    """Resolve Darwin EPERM when an orphan group contains only exiting zombies.

    Darwin may return EPERM for killpg while its last orphan is being reaped.
    Check actual member states before treating that race as terminal. An unknown
    or live group remains an ownership failure; permission errors are never
    silently interpreted as successful cleanup of live descendants.
    """
    if platform.system() != "Darwin":
        return None
    try:
        states = capture(["ps", "-o", "stat=", "-g", str(pid)], timeout_seconds=0.5,
                         accepted_returncodes=(0, 1))
        return any(not state.startswith("Z") for state in states.split())
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return None


def signal_group(pid: int, value: int) -> bool:
    """Signal only the session/process group created and owned by this driver."""
    try:
        os.killpg(pid, value)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        if group_has_live_members(pid) is False:
            return False
        raise


def group_exists(pid: int) -> bool:
    """Check for surviving descendants even after the direct child has exited."""
    try:
        os.killpg(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        if group_has_live_members(pid) is False:
            return False
        # EPERM establishes existence when live state cannot be disproved.
        return True


def schedule(profile: Profile, seed: int, paired: bool) -> list[dict[str, Any]]:
    """Alternate deterministic A/B order across independent paired processes."""
    if profile.name == "standard" and not paired:
        raise ValueError("standard requires an explicit baseline/candidate pair")
    generator = random.Random(seed)
    first = generator.randrange(2)
    rows = []
    for repetition in range(profile.repetitions):
        pair_seed = generator.randrange(0, 2**63)
        arms = (["baseline", "candidate"] if (first + repetition) % 2 == 0
                else ["candidate", "baseline"]) if paired else ["single"]
        for position, arm in enumerate(arms):
            rows.append({"repetition": repetition, "position": position, "arm": arm,
                         "seed": pair_seed})
    return rows


def artifact(path: Path) -> dict[str, Any]:
    """Identify retained evidence by its exact post-truncation size and hash."""
    return {"path": str(path), "bytes": path.stat().st_size, "sha256": sha256_file(path)}


def run_process(command: list[str], directory: Path, limits: ProcessLimits,
                cancellation: Cancellation | None = None, *, cwd: Path | None = None,
                env: dict[str, str] | None = None, report_paths: list[Path] | None = None,
                stdout_is_report: bool = False, require_json: bool = False) -> dict[str, Any]:
    """Drain bounded pipes, enforce budgets, terminate descendants and reap the owner.

    No sample/task is allocated per logical operation. Pipe reads use one selector
    and a fixed buffer. Exceeding a budget invalidates the run while preserving the
    retained prefix and explicit dropped-byte counts. The report file is sampled
    while running; any excess is truncated after all owned writers are stopped.
    """
    directory.mkdir(parents=True, exist_ok=False)
    cancellation = cancellation or Cancellation()
    report_paths = report_paths or []
    stdout_path, stderr_path = directory / "stdout.log", directory / "stderr.log"
    started = time.monotonic_ns()
    process: subprocess.Popen[bytes] | None = None
    selector = selectors.DefaultSelector()
    retained = {"stdout": 0, "stderr": 0}
    dropped = {"stdout": 0, "stderr": 0, "report_files": 0}
    peak_rss: int | None = None
    samples = 0
    term_started: float | None = None
    status = "completed"
    termination: dict[str, Any] = {"term_sent": False, "kill_sent": False, "owner_reaped": False,
                                   "unexpected_descendants": False, "group_has_live_members_after_cleanup": None}
    handles = {"stdout": stdout_path.open("wb"), "stderr": stderr_path.open("wb")}
    try:
        if cancellation.requested:
            status = "cancelled"
        else:
            process = subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, start_new_session=True)
            assert process.stdout is not None and process.stderr is not None
            os.set_blocking(process.stdout.fileno(), False)
            os.set_blocking(process.stderr.fileno(), False)
            selector.register(process.stdout, selectors.EVENT_READ, "stdout")
            selector.register(process.stderr, selectors.EVENT_READ, "stderr")
            deadline = time.monotonic() + limits.timeout_seconds
            next_sample = 0.0
            grace_deadline: float | None = None
            while selector.get_map() or process.poll() is None:
                now = time.monotonic()
                if status == "completed":
                    if cancellation.requested:
                        status = "cancelled"
                    elif now >= deadline:
                        status = "timed_out"
                    if now >= next_sample:
                        rss = process_rss(process.pid)
                        if rss is not None:
                            peak_rss = max(peak_rss or 0, rss)
                            samples += 1
                            if rss > limits.rss_bytes:
                                status = "rss_limit_exceeded"
                        next_sample = now + limits.sample_seconds
                    file_bytes = sum(path.stat().st_size for path in report_paths if path.is_file())
                    stdout_bytes = retained["stdout"] if stdout_is_report else 0
                    if file_bytes + stdout_bytes > limits.report_bytes:
                        status = "report_limit_exceeded"
                    if process.poll() is not None and group_exists(process.pid):
                        termination["unexpected_descendants"] = True
                        status = "cleanup_failed"
                if status != "completed" and grace_deadline is None:
                    termination["term_sent"] = signal_group(process.pid, signal.SIGTERM)
                    term_started = now
                    grace_deadline = now + limits.grace_seconds
                if grace_deadline is not None and now >= grace_deadline:
                    termination["kill_sent"] = signal_group(process.pid, signal.SIGKILL)
                    # A descendant can retain pipes indefinitely; after KILL, drain
                    # the available fixed kernel buffers and close the descriptors.
                    for key in list(selector.get_map().values()):
                        os.set_blocking(key.fd, False)
                    grace_deadline = float("inf")
                wait_seconds = min(limits.sample_seconds, 0.05)
                if grace_deadline is not None:
                    wait_seconds = min(wait_seconds, max(0, grace_deadline - time.monotonic()))
                elif status == "completed":
                    wait_seconds = min(wait_seconds, max(0, deadline - time.monotonic()))
                events = selector.select(wait_seconds)
                for key, _ in events:
                    try:
                        chunk = os.read(key.fd, 65536)
                    except (BlockingIOError, InterruptedError):
                        # Readiness can become stale during EOF/teardown races.
                        # Keep ownership and retry through the same finite loop.
                        continue
                    if not chunk:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                        continue
                    stream = key.data
                    if stream == "stdout" and stdout_is_report:
                        available = max(0, limits.report_bytes - retained["stdout"])
                    else:
                        diagnostic_used = retained["stderr"] + (0 if stdout_is_report else retained["stdout"])
                        available = max(0, limits.diagnostic_bytes - diagnostic_used)
                    keep = min(len(chunk), available)
                    handles[stream].write(chunk[:keep])
                    retained[stream] += keep
                    dropped[stream] += len(chunk) - keep
                    if keep < len(chunk) and status == "completed":
                        status = "report_limit_exceeded" if stream == "stdout" and stdout_is_report else "diagnostic_limit_exceeded"
                if grace_deadline == float("inf") and process.poll() is not None and not events:
                    for key in list(selector.get_map().values()):
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
            process.wait()
            termination["owner_reaped"] = True
            # A daemon may close all inherited descriptors before the owner exits.
            if group_exists(process.pid):
                termination["unexpected_descendants"] = True
                if term_started is None:
                    termination["term_sent"] = signal_group(process.pid, signal.SIGTERM)
                    term_started = time.monotonic()
                until = term_started + limits.grace_seconds
                while group_exists(process.pid) and time.monotonic() < until:
                    time.sleep(min(0.01, max(0, until - time.monotonic())))
                if group_exists(process.pid):
                    termination["kill_sent"] = signal_group(process.pid, signal.SIGKILL) or termination["kill_sent"]
                if status == "completed":
                    status = "cleanup_failed"
            if process.returncode != 0 and status == "completed":
                status = "process_failed"
    except (OSError, ValueError) as error:
        frames = traceback.extract_tb(error.__traceback__)
        ownership_error = termination["unexpected_descendants"] or any(
            frame.name in {"signal_group", "group_exists"} for frame in frames)
        if status == "completed":
            status = "cleanup_failed" if ownership_error else "launch_or_collection_failed"
        termination["error_type"] = type(error).__name__
        termination["error_errno"] = getattr(error, "errno", None)
        frame = frames[-1]
        termination["error_location"] = {"function": frame.name, "line": frame.lineno}
        termination["error_reason"] = (getattr(error, "strerror", None) or str(error))[:256]
    finally:
        if process is not None:
            # Collection can fail after the owner exits while descendants still
            # hold its group. Teardown ownership therefore never depends only on
            # the direct child's running state.
            try:
                if group_exists(process.pid):
                    if term_started is None:
                        termination["term_sent"] = signal_group(process.pid, signal.SIGTERM)
                        term_started = time.monotonic()
                    until = term_started + limits.grace_seconds
                    while group_exists(process.pid) and time.monotonic() < until:
                        time.sleep(min(0.01, max(0, until - time.monotonic())))
                    if group_exists(process.pid):
                        termination["kill_sent"] = signal_group(process.pid, signal.SIGKILL) or termination["kill_sent"]
            except OSError as error:
                termination["group_cleanup_error_errno"] = error.errno
                if status == "completed":
                    status = "cleanup_failed"
            if process.poll() is None:
                process.kill()
            process.wait()
            termination["owner_reaped"] = True
            termination["group_has_live_members_after_cleanup"] = group_has_live_members(process.pid)
        selector.close()
        for pipe in (process.stdout, process.stderr) if process is not None else ():
            if pipe is not None:
                pipe.close()
        for output in handles.values():
            output.close()
    elapsed_ns = time.monotonic_ns() - started
    remaining = max(0, limits.report_bytes - (retained["stdout"] if stdout_is_report else 0))
    reports = []
    for path in report_paths:
        if path.is_file():
            original = path.stat().st_size
            if original > remaining:
                with path.open("r+b") as output:
                    output.truncate(remaining)
                dropped["report_files"] += original - remaining
                if status == "completed":
                    status = "report_limit_exceeded"
            remaining -= min(original, remaining)
            reports.append(artifact(path))
    json_valid: bool | None = None
    if require_json:
        native = stdout_path if stdout_is_report else (report_paths[0] if report_paths else None)
        try:
            if native is None:
                raise ValueError("no native report")
            strict_json(native.read_bytes())
            json_valid = True
        except (OSError, ValueError):
            json_valid = False
            if status == "completed":
                status = "incomplete_report"
    result = {
        "status": status, "command": command, "pid": process.pid if process else None,
        "exit_code": process.returncode if process else None, "elapsed_ns": elapsed_ns,
        "clock": "driver-monotonic-nanoseconds", "limits": asdict(limits),
        "cleanup": termination, "dropped_bytes": dropped, "native_json_valid": json_valid,
        "stdout": artifact(stdout_path), "stderr": artifact(stderr_path), "reports": reports,
        "rss": {"sampled_peak_bytes": peak_rss, "samples": samples,
                "method": "/proc/PID/status VmRSS" if platform.system() == "Linux" else "ps -o rss",
                "scope": "leader process current RSS samples across whole process lifetime; children excluded",
                "unavailable_reason": None if peak_rss is not None else "process exited between samples or unsupported host API"},
        "retained_state": {"observed_bytes": None, "unavailable_reason": "requires participant-owned working-set accounting"},
        "cpu_time": {"nanoseconds": None, "unavailable_reason": "portable per-child CPU gauge not collected"},
    }
    atomic_json(directory / "process.json", result)
    return result


def release_build(package: Path, product: str, receipt_path: Path, swift: str,
                  repository: Path, cancellation: Cancellation, timeout: float = 1800) -> dict[str, Any]:
    """Build an optimized product and bind its binary to stable source/compiler evidence."""
    package, repository, receipt_path = package.resolve(), repository.resolve(), receipt_path.resolve()
    if receipt_path.exists():
        raise ValueError("release receipt already exists; select a new artifact path")
    if not (package / "Package.swift").is_file():
        raise ValueError("package has no Package.swift")
    before = source_identity(repository)
    compiler = capture([swift, "--version"])
    target = json.loads(capture([swift, "-print-target-info"]))
    flags = ["-c", "release", "--product", product, "--force-resolved-versions", "-j", "4",
             "--build-system", "native", "--disable-experimental-prebuilts"]
    command = [swift, "build", "--package-path", str(package), *flags]
    sdk = {"version": optional_capture(["xcrun", "--show-sdk-version"]) if platform.system() == "Darwin" else None,
           "path": optional_capture(["xcrun", "--show-sdk-path"]) if platform.system() == "Darwin" else None}
    sdk["unavailable_reason"] = (None if sdk["version"] and sdk["path"] else
                                  "SDK unavailable from host xcrun API" if platform.system() == "Darwin" else
                                  "Linux compiler target has no Apple SDK")
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    directory = receipt_path.parent / (receipt_path.stem + "-build")
    result = run_process(command, directory, ProcessLimits(timeout, rss_bytes=8 * 1024 * MIB), cancellation)
    receipt: dict[str, Any] = {"format": RECEIPT_FORMAT, "version": 1, "status": result["status"],
                               "source": before, "compiler": compiler, "target_info": target, "sdk": sdk,
                               "optimization": "release", "build_flags": flags,
                               "build_command": command, "build_process": result, "executable": None}
    if result["status"] == "completed":
        after = source_identity(repository)
        if before != after:
            receipt["status"] = "source_changed_during_build"
        else:
            binary_directory = capture([swift, "build", "--package-path", str(package), "-c", "release",
                                        "--build-system", "native", "--disable-experimental-prebuilts", "--show-bin-path"])
            executable = Path(binary_directory) / product
            if not executable.is_file():
                receipt["status"] = "missing_executable"
            else:
                receipt["executable"] = artifact(executable.resolve())
    atomic_json(receipt_path, receipt)
    return receipt


def validate_receipt(path: Path, command: list[str]) -> dict[str, Any]:
    """Reject stale, modified, debug or unbound binaries before measurement."""
    if path.stat().st_size > MAX_REPORT_BYTES:
        raise ValueError("release receipt exceeds report ceiling")
    receipt = strict_json(path.read_bytes())
    version = receipt.get("version")
    if receipt.get("format") != RECEIPT_FORMAT or type(version) is not int or version != 1:
        raise ValueError("unsupported release-build receipt")
    if receipt.get("status") != "completed" or receipt.get("optimization") != "release":
        raise ValueError("a successful release build is required")
    executable = Path(command[0]).resolve()
    identity = receipt["executable"]
    if str(executable) != identity["path"] or sha256_file(executable) != identity["sha256"]:
        raise ValueError("command executable does not match release-build receipt")
    if source_identity(Path(receipt["source"]["repository"])) != receipt["source"]:
        raise ValueError("source or dependency pins changed since release build")
    return receipt


def command_array(value: str) -> list[str]:
    """Parse a nonempty shell-free JSON command with literal string arguments."""
    try:
        command = json.loads(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("command must be a JSON array") from error
    if not isinstance(command, list) or not command or not all(isinstance(item, str) and item for item in command):
        raise argparse.ArgumentTypeError("command must be a nonempty JSON array of nonempty strings")
    return command


def run_suite(args: argparse.Namespace, cancellation: Cancellation) -> dict[str, Any]:
    """Persist a partial manifest after every fresh process and stop on cancellation."""
    profile = PROFILES[args.profile]
    warmup = args.warmup_seconds
    duration = profile.measured_cap_seconds if args.duration_seconds is None else args.duration_seconds
    if not 0 <= args.seed < 2**63:
        raise ValueError("seed must fit a nonnegative signed 64-bit integer")
    if not 0 <= warmup <= profile.warmup_cap_seconds or not 0 < duration <= profile.measured_cap_seconds:
        raise ValueError("warmup or measured duration exceeds selected profile ceilings")
    if warmup and args.warmup_policy != "participant-declared":
        raise ValueError("positive warmup requires --warmup-policy participant-declared")
    if not 0 < args.concurrency <= profile.active_cohort_cap:
        raise ValueError("declared active cohort exceeds the selected profile")
    paired = bool(args.baseline_command or args.candidate_command)
    if paired:
        if args.command or not all((args.baseline_command, args.candidate_command, args.baseline_receipt, args.candidate_receipt)):
            raise ValueError("provide exactly one command/receipt or a complete explicit pair")
        arms = {"baseline": (args.baseline_command, args.baseline_receipt),
                "candidate": (args.candidate_command, args.candidate_receipt)}
    else:
        if not args.command or not args.receipt:
            raise ValueError("a command and release receipt are required")
        arms = {"single": (args.command, args.receipt)}
    rows = schedule(profile, args.seed, paired)
    if profile.name == "stress":
        if not all(any("{concurrency}" in item for item in command) for command, _ in arms.values()):
            raise ValueError("stress commands must explicitly use {concurrency} for their load sweep")
        if args.concurrency < 4:
            raise ValueError("stress requires a maximum cohort of at least four for three distinct load levels")
    for row in rows:
        row["declared_active_cohort"] = ([args.concurrency // 4, args.concurrency // 2, args.concurrency][row["repetition"]]
                                          if profile.name == "stress" else args.concurrency)
    receipts = {arm: validate_receipt(Path(receipt), command) for arm, (command, receipt) in arms.items()}
    fixtures = {str(Path(path).resolve()): sha256_file(Path(path).resolve()) for path in args.fixture}
    if not fixtures:
        raise ValueError("at least one explicit --fixture input is required")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    manifest: dict[str, Any] = {
        "format": FORMAT, "version": 1, "status": "running", "informational_only": True,
        "created_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "profile": asdict(profile), "scenario": args.scenario, "seed": args.seed,
        "environment": environment(), "build_receipts": receipts, "fixture_hashes": fixtures,
        "schedule": rows, "processes": [], "repetitions": profile.repetitions,
        "fresh_process_per_observation": True,
        "warmup": {"requested_seconds": warmup, "policy": args.warmup_policy,
                   "verification": "not independently observable by generic process driver"},
        "measurement": {"requested_seconds": duration, "duration_control": "participant-declared; process timeout is enforced",
                        "declared_active_cohort": args.concurrency, "cohort_verification": "participant responsibility",
                        "scheduler_policy": args.scheduler_policy, "backlog_cap": profile.backlog_cap,
                        "retained_state_cap_bytes": profile.retained_state_cap_bytes,
                        "retained_state_enforcement": "participant responsibility; observed gauge may be unavailable"},
        "qualification": "unavailable: orchestration success is not numerical comparison or tail qualification",
    }
    manifest_path = output / "orchestration.json"
    atomic_json(manifest_path, manifest)
    for index, row in enumerate(rows):
        if cancellation.requested:
            break
        command, receipt_path = arms[row["arm"]]
        validate_receipt(Path(receipt_path), command)
        if any(sha256_file(Path(path)) != digest for path, digest in fixtures.items()):
            raise ValueError("fixture changed during repetitions")
        directory = output / f"{index:02}-{row['arm']}"
        native = directory / "native-report.json"
        envelope = directory / "benchmark-envelope.json"
        tokens = {"output": str(native), "seed": str(row["seed"]), "warmup_seconds": str(warmup),
                  "duration_seconds": str(duration), "profile": profile.name,
                  "concurrency": str(row["declared_active_cohort"]), "rss_cap_bytes": str(profile.rss_cap_bytes),
                  "retained_state_cap_bytes": str(profile.retained_state_cap_bytes)}
        expanded = []
        for item in command:
            for key, value in tokens.items():
                item = item.replace("{" + key + "}", value)
            expanded.append(item)
        expanded[0] = str(Path(expanded[0]).resolve())
        child_environment = dict(os.environ)
        child_environment.update({"DK_BENCHMARK_" + key.upper(): value for key, value in tokens.items()})
        child_environment["DK_BENCHMARK_ENVELOPE"] = str(envelope)
        stdout_report = not any("{output}" in item for item in command)
        before_environment, before_host = environment(), host_observation()
        result = run_process(expanded, directory,
                             ProcessLimits(warmup + duration + 30, rss_bytes=profile.rss_cap_bytes),
                             cancellation, env=child_environment,
                             report_paths=([envelope] if stdout_report else [native, envelope]),
                             stdout_is_report=stdout_report, require_json=True)
        result["environment_before"] = before_environment
        result["environment_after"] = environment()
        result["host_observation_before"] = before_host
        result["host_observation_after"] = host_observation()
        try:
            if envelope.stat().st_size > MAX_REPORT_BYTES:
                raise ValueError("oversize envelope")
            common = strict_json(envelope.read_bytes())
            version = common.get("schemaVersion")
            if common.get("format") != "DiscordBenchmarkReport" or type(version) is not int or version != 1:
                raise ValueError("unsupported common envelope identity")
            result["common_envelope"] = {"available": True, "format": common["format"], "schema_version": 1,
                                          "validation": "JSON and identity checked; shared report validator supplies semantic checks"}
        except (OSError, ValueError, AttributeError):
            result["common_envelope"] = {"available": False, "reason": "participant did not emit a complete common JSON envelope"}
            if result["status"] == "completed":
                result["status"] = "incomplete_report"
        result["observation"] = row
        manifest["processes"].append(result)
        atomic_json(manifest_path, manifest)
        # Detect changes during the final observation too, retaining its result
        # before invalidating the suite. A run never silently outlives its inputs.
        validate_receipt(Path(receipt_path), command)
        if any(sha256_file(Path(path)) != digest for path, digest in fixtures.items()):
            raise ValueError("fixture changed during observation")
        if result["status"] == "cancelled":
            break
    manifest["status"] = ("cancelled" if cancellation.requested else
                          "completed" if len(manifest["processes"]) == len(rows)
                          and all(row["status"] == "completed" for row in manifest["processes"]) else "failed")
    manifest["completed_processes"] = len(manifest["processes"])
    atomic_json(manifest_path, manifest)
    return manifest


def main(argv: list[str] | None = None) -> int:
    """Expose separate release preparation and bounded measurement entry points."""
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    build = subparsers.add_parser("build", help="create a verified Swift release-build receipt")
    build.add_argument("--package", type=Path, required=True)
    build.add_argument("--product", required=True)
    build.add_argument("--receipt", type=Path, required=True)
    build.add_argument("--repository", type=Path, default=Path.cwd())
    build.add_argument("--swift", default=shutil.which("swift") or "swift")
    run = subparsers.add_parser("run", help="run explicit commands in fresh owned process groups")
    run.add_argument("--profile", choices=PROFILES, default="smoke")
    run.add_argument("--scenario", required=True)
    run.add_argument("--seed", type=int, default=1)
    run.add_argument("--fixture", action="append", default=[], type=Path)
    run.add_argument("--command", type=command_array)
    run.add_argument("--receipt", type=Path)
    run.add_argument("--baseline-command", type=command_array)
    run.add_argument("--baseline-receipt", type=Path)
    run.add_argument("--candidate-command", type=command_array)
    run.add_argument("--candidate-receipt", type=Path)
    run.add_argument("--output-dir", type=Path, required=True)
    run.add_argument("--warmup-seconds", type=int, default=0)
    run.add_argument("--warmup-policy", choices=("cold-process-no-in-process-warmup", "participant-declared"),
                     default="cold-process-no-in-process-warmup")
    run.add_argument("--duration-seconds", type=int)
    run.add_argument("--concurrency", type=int, required=True, help="actual native cohort declared by operator")
    run.add_argument("--scheduler-policy", required=True, help="actual native scheduler declared by operator")
    args = parser.parse_args(argv)
    cancellation = Cancellation()
    previous = {value: signal.signal(value, cancellation.request) for value in (signal.SIGINT, signal.SIGTERM)}
    try:
        if args.operation == "build":
            result = release_build(args.package, args.product, args.receipt, args.swift, args.repository, cancellation)
        else:
            result = run_suite(args, cancellation)
        print(json.dumps({"status": result["status"], "format": result["format"]}))
        return 0 if result["status"] == "completed" else 1
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        if args.operation == "run" and args.output_dir.is_dir():
            manifest_path = args.output_dir / "orchestration.json"
            if manifest_path.is_file():
                partial = json.loads(manifest_path.read_bytes())
                partial["status"] = "failed"
                partial["failure"] = str(error)[:4096]
                atomic_json(manifest_path, partial)
        print(f"benchmark driver: {error}", file=sys.stderr)
        return 1
    finally:
        for value, handler in previous.items():
            signal.signal(value, handler)


if __name__ == "__main__":
    raise SystemExit(main())
