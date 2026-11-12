# File: Tools/ci/native_resources.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Conservative compiler admission from current host observations and policy caps.

Memory reserve and per-compiler bytes are initial scheduling assumptions, not
measured compiler peaks. Unknown or insufficient headroom admits one process
and records the uncertainty; native qualification requires separate evidence.
"""

import os
from pathlib import Path
import platform
import re
import subprocess


GIB = 1024 ** 3
DEFAULT_RESERVE_BYTES = 2 * GIB
DEFAULT_BYTES_PER_COMPILER = 4 * GIB
MAX_COMPILER_JOBS = 2
_DETECT = object()


def observed_affinity_count():
    """Prefer the OS affinity restriction where available instead of nominal cores."""
    affinity = getattr(os, "sched_getaffinity", None)
    if affinity is None:
        return None
    try:
        return len(affinity(0)) or None
    except (OSError, NotImplementedError):
        return None


def _read_integer(path):
    try:
        value = Path(path).read_text().strip()
        return int(value) if value != "max" else None
    except (OSError, ValueError):
        return None


def linux_memory_observation(meminfo="/proc/meminfo", cgroup="/sys/fs/cgroup"):
    """Cap observed available memory by remaining cgroup allowance when present."""
    candidates, sources = [], []
    try:
        match = re.search(r"^MemAvailable:\s+(\d+)\s+kB$", Path(meminfo).read_text(), re.MULTILINE)
    except OSError:
        match = None
    if match:
        candidates.append(int(match[1]) * 1024)
        sources.append("linux-memavailable")
    for limit_name, current_name in (("memory.max", "memory.current"),
                                     ("memory/memory.limit_in_bytes", "memory/memory.usage_in_bytes")):
        limit = _read_integer(Path(cgroup) / limit_name)
        current = _read_integer(Path(cgroup) / current_name)
        if limit is not None and limit >= 0 and current is not None and current >= 0:
            candidates.append(max(0, limit - current))
            sources.append("cgroup-headroom")
    return {"availableMemoryBytes": min(candidates) if candidates else None,
            "memorySources": sources}


def darwin_memory_observation():
    """Bound the vm_stat query and count only free/speculative pages conservatively."""
    try:
        result = subprocess.run(("/usr/bin/vm_stat",), capture_output=True, text=True,
                                timeout=2, check=True, env={"LANG": "C", "LC_ALL": "C"})
    except (OSError, subprocess.SubprocessError):
        return {"availableMemoryBytes": None, "memorySources": []}
    size = re.search(r"page size of (\d+) bytes", result.stdout)
    free = re.search(r"^Pages free:\s+(\d+)\.", result.stdout, re.MULTILINE)
    speculative = re.search(r"^Pages speculative:\s+(\d+)\.", result.stdout, re.MULTILINE)
    if not size or not free:
        return {"availableMemoryBytes": None, "memorySources": []}
    return {"availableMemoryBytes": int(size[1]) * (int(free[1]) + (int(speculative[1]) if speculative else 0)),
            "memorySources": ["darwin-free-plus-speculative-pages"]}


def observed_memory():
    """Read the current supported host; unavailable observations remain explicit."""
    if platform.system() == "Linux":
        return linux_memory_observation()
    if platform.system() == "Darwin":
        return darwin_memory_observation()
    return {"availableMemoryBytes": None, "memorySources": []}


def compiler_admission(requested, *, policy_cap=MAX_COMPILER_JOBS,
                       cpu_count=_DETECT, affinity_count=_DETECT, available_memory_bytes=_DETECT,
                       memory_reserve_bytes=DEFAULT_RESERVE_BYTES,
                       bytes_per_compiler=DEFAULT_BYTES_PER_COMPILER):
    """Return admitted jobs plus inputs, limiting reasons and conservative fallbacks.

    The initial hard maximum is two even on a nominal 64-core pool. Explicit
    observation arguments, including None for unavailable, support deterministic
    admission checks without querying the host. Memory starvation never invents
    a zero-process compiler mode: it is reported and falls back to one.
    """
    for name, value in (("requested jobs", requested), ("policy cap", policy_cap),
                        ("bytes per compiler", bytes_per_compiler)):
        if type(value) is not int or value < 1:
            raise ValueError(f"{name} must be a positive integer")
    if policy_cap > MAX_COMPILER_JOBS:
        raise ValueError("initial compiler policy cap cannot exceed two")
    if type(memory_reserve_bytes) is not int or memory_reserve_bytes < 0:
        raise ValueError("memory reserve must be a nonnegative integer")
    cpu = os.cpu_count() if cpu_count is _DETECT else cpu_count
    affinity = observed_affinity_count() if affinity_count is _DETECT else affinity_count
    memory = observed_memory() if available_memory_bytes is _DETECT else {
        "availableMemoryBytes": available_memory_bytes,
        "memorySources": ["supplied-observation"] if available_memory_bytes is not None else []}
    available = memory["availableMemoryBytes"]
    for name, value, minimum in (("CPU count", cpu, 1), ("affinity count", affinity, 1),
                                 ("available memory bytes", available, 0)):
        if value is not None and (type(value) is not int or value < minimum):
            raise ValueError(f"{name} observation is invalid")
    counts = [value for value in (cpu, affinity) if value is not None]
    cpu_limit = min(counts) if counts else 1
    memory_capacity = None if available is None else max(0, available - memory_reserve_bytes) // bytes_per_compiler
    memory_limit = max(1, memory_capacity) if memory_capacity is not None else 1
    limits = {"requested": requested, "policy": policy_cap, "cpu": cpu_limit, "memory": memory_limit}
    jobs = min(limits.values())
    reasons = [f"{name}-cap" for name, limit in limits.items() if limit == jobs]
    flags = []
    if not counts:
        flags.append("cpu-observation-unavailable-fallback-one")
    if available is None:
        flags.append("memory-observation-unavailable-fallback-one")
    elif memory_capacity == 0:
        flags.append("insufficient-observed-memory-headroom-fallback-one")
    return {"jobs": jobs, "requestedJobs": requested, "policyCompilerJobs": policy_cap,
            "observed": {"cpuCount": cpu, "affinityCount": affinity,
                         "availableMemoryBytes": available, "memorySources": memory["memorySources"]},
            "memoryPolicy": {"reserveBytes": memory_reserve_bytes, "bytesPerCompiler": bytes_per_compiler,
                             "assurance": "initial conservative scheduling assumptions; compiler peaks unmeasured"},
            "limits": limits, "reasons": reasons, "flags": flags}
