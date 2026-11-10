#!/usr/bin/env python3
# File: Tools/ci/emit_symbol_graphs.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Emit native SwiftPM symbol graphs and normalize their generated output location."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def require_generated_path(path, build):
    """Reject paths or symlinks outside the package's owned generated build tree."""
    if not path.is_absolute() or ".." in path.parts or not path.is_relative_to(build):
        raise ValueError("symbol graphs must remain inside the package build directory")
    for candidate in (path, *path.parents):
        if candidate == build.parent:
            break
        if candidate.is_symlink():
            raise ValueError("symbol graph paths must not contain symbolic links")


def validate_directory(path, build):
    """Require an ordinary generated directory and reject links anywhere in its tree."""
    require_generated_path(path, build)
    if not path.is_dir():
        raise ValueError("the compiler did not produce a symbol graph directory")
    if any(child.is_symlink() for child in path.rglob("*")):
        raise ValueError("symbol graph directories must not contain symbolic links")


def emit(repository, jobs=5, run=None):
    """Emit pinned native graphs and replace normalized output only after complete validation.

    Existing normalized graphs survive failed compilation, missing or malformed
    primary graphs, and copying failures. Only generated output is replaced.
    """
    if type(jobs) is not int or jobs <= 0:
        raise ValueError("jobs must be a positive integer")
    repository = repository.resolve()
    if not (repository / "Package.swift").is_file():
        raise ValueError("a Swift package manifest is required")
    run = run or subprocess.run
    build = repository / ".build"
    destination = build / "out/symbolgraph"
    require_generated_path(destination, build)
    options = ["--package-path", str(repository), "--jobs", str(jobs),
               "--force-resolved-versions", "--build-system", "native",
               "--disable-experimental-prebuilts"]
    completed = run(["swift", "build", *options, "--show-bin-path"], cwd=repository,
                    capture_output=True, text=True, check=True, timeout=120)
    location = completed.stdout.strip()
    if not location or len(location.splitlines()) != 1:
        raise ValueError("SwiftPM did not return one native binary directory")
    source = Path(location).parent / "symbolgraph"
    require_generated_path(source, build)
    if source.is_relative_to(destination) or destination.is_relative_to(source):
        raise ValueError("native and normalized graph directories must be independent")
    if source.exists():
        validate_directory(source, build)
        # SwiftPM writes current modules without removing graphs for deleted ones.
        # Clear only this validated generated directory; normalized graphs stay intact.
        shutil.rmtree(source)
    run(["swift", "package", *options, "dump-symbol-graph", "--minimum-access-level", "public"],
        cwd=repository, check=True, timeout=3600)
    validate_directory(source, build)
    graphs = sorted(source.glob("*.symbols.json"))
    primary = [graph for graph in graphs if "@" not in graph.name]
    if not primary:
        raise ValueError("the compiler must emit at least one primary symbol graph")
    for graph in graphs:
        if not graph.is_file():
            raise ValueError("symbol graph outputs must be regular JSON files")
        document = json.loads(graph.read_text(encoding="utf-8"))
        if (not isinstance(document, dict) or not isinstance(document.get("module"), dict)
                or not isinstance(document["module"].get("name"), str)):
            raise ValueError("symbol graph JSON must identify its module")
    require_generated_path(destination, build)
    if destination.exists():
        validate_directory(destination, build)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".symbolgraph-", dir=destination.parent) as temporary:
        staging = Path(temporary) / "next"
        staging.mkdir()
        for graph in graphs:
            shutil.copy2(graph, staging / graph.name)
        previous = Path(temporary) / "previous"
        if destination.exists():
            destination.rename(previous)
        try:
            staging.rename(destination)
        except BaseException:
            if previous.exists():
                previous.rename(destination)
            raise
    return [graph.name for graph in graphs]


def main():
    """Normalize one selected package's public symbol graphs without changing its sources."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--jobs", type=int, default=5)
    arguments = parser.parse_args()
    try:
        graphs = emit(arguments.repository, arguments.jobs)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Symbol graph emission failed: {error}", file=sys.stderr)
        return 1
    print(f"Normalized {len(graphs)} public symbol graph files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
