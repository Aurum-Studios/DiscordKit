# File: Tools/ci/teamcity_artifact_transport.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Transport a sealed archive through TeamCity as individually bounded artifacts."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tarfile
import tempfile


PART_SIZE = 32 * 1024 * 1024
MAX_PARTS = 4096
MANIFEST = "manifest.json"
MAX_MANIFEST_BYTES = 1024 * 1024
READ_SIZE = 1024 * 1024


def _part_name(index):
    return f"part-{index:04d}"


def _digest(value):
    return isinstance(value, str) and re.fullmatch("[0-9a-f]{64}", value) is not None


def split(source: Path, destination: Path, *, part_size: int = PART_SIZE):
    """Publish the archive's ordered, hashed parts as one complete directory."""
    if type(part_size) is not int or not 1 <= part_size <= PART_SIZE:
        raise ValueError("Invalid TeamCity artifact part size")
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as workspace, source.open("rb") as archive:
        staged = Path(workspace) / "parts"
        staged.mkdir()
        digest = hashlib.sha256()
        size = 0
        parts = []
        while data := archive.read(part_size):
            if len(parts) == MAX_PARTS:
                raise ValueError("Too many TeamCity artifact parts")
            name = _part_name(len(parts))
            (staged / name).write_bytes(data)
            digest.update(data)
            size += len(data)
            parts.append({"name": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        manifest = {"schemaVersion": 1, "partSize": part_size, "size": size,
                    "sha256": digest.hexdigest(), "parts": parts}
        (staged / MANIFEST).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        staged.rename(destination)


def pack(source: Path, destination: Path):
    """Bundle a diagnostic directory before applying the upload size limit."""
    if not source.exists():
        return
    if not source.is_dir() or source.is_symlink():
        raise ValueError(f"Expected a diagnostic directory: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as workspace:
        staged = Path(workspace) / "evidence.tar.gz"
        with tarfile.open(staged, "w:gz", compresslevel=3) as archive:
            archive.add(source, arcname=source.name)
        split(staged, destination)


def _manifest(source):
    path = source / MANIFEST
    if path.is_symlink() or not path.is_file():
        raise ValueError("Missing regular TeamCity artifact manifest")
    with path.open("rb") as stream:
        data = stream.read(MAX_MANIFEST_BYTES + 1)
    if len(data) > MAX_MANIFEST_BYTES:
        raise ValueError("TeamCity artifact manifest exceeds its size limit")
    manifest = json.loads(data)
    if (not isinstance(manifest, dict) or set(manifest) != {"schemaVersion", "partSize", "size", "sha256", "parts"}
            or type(manifest["schemaVersion"]) is not int or manifest["schemaVersion"] != 1
            or type(manifest["partSize"]) is not int or not 1 <= manifest["partSize"] <= PART_SIZE
            or type(manifest["size"]) is not int or manifest["size"] < 0
            or not _digest(manifest["sha256"]) or not isinstance(manifest["parts"], list)):
        raise ValueError("Invalid TeamCity artifact manifest")
    size, part_size, parts = manifest["size"], manifest["partSize"], manifest["parts"]
    if len(parts) > MAX_PARTS or len(parts) != (size + part_size - 1) // part_size:
        raise ValueError("Invalid TeamCity artifact part count")
    for index, part in enumerate(parts):
        expected_size = min(part_size, size - index * part_size)
        if (not isinstance(part, dict) or set(part) != {"name", "size", "sha256"}
                or part["name"] != _part_name(index) or type(part["size"]) is not int
                or part["size"] != expected_size or not _digest(part["sha256"])):
            raise ValueError("Invalid TeamCity artifact part order, size, or digest")
    if {entry.name for entry in source.iterdir()} != {MANIFEST, *(part["name"] for part in parts)}:
        raise ValueError("TeamCity artifact part inventory differs from its manifest")
    return manifest


def join(source: Path, destination: Path):
    """Verify every transported byte and reconstruct the exact original archive."""
    manifest = _manifest(source)
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256()
    with tempfile.TemporaryDirectory(dir=destination.parent) as workspace:
        staged = Path(workspace) / "archive"
        with staged.open("xb") as archive:
            for part in manifest["parts"]:
                path = source / part["name"]
                if path.is_symlink() or not path.is_file():
                    raise ValueError(f"Invalid TeamCity artifact part: {path.name}")
                part_digest = hashlib.sha256()
                remaining = part["size"]
                with path.open("rb") as stream:
                    while remaining and (data := stream.read(min(remaining, READ_SIZE))):
                        archive.write(data)
                        digest.update(data)
                        part_digest.update(data)
                        remaining -= len(data)
                    if remaining or stream.read(1) or part_digest.hexdigest() != part["sha256"]:
                        raise ValueError(f"TeamCity artifact part failed verification: {path.name}")
        if digest.hexdigest() != manifest["sha256"]:
            raise ValueError("TeamCity artifact archive digest differs from its manifest")
        # A concurrent join cannot replace an already published archive.
        os.link(staged, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    operations = {"split": split, "join": join, "pack": pack}
    parser.add_argument("operation", choices=operations)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        operations[args.operation](args.source, args.destination)
    except (OSError, ValueError, tarfile.TarError) as error:
        parser.exit(1, f"TeamCity artifact transport failed: {error}\n")


if __name__ == "__main__":
    main()
