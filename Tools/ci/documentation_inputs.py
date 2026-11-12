#!/usr/bin/env python3
# File: Tools/ci/documentation_inputs.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Prepare strict DocC once and admit sealed, source-bound site inputs.

Native compilation/graph restoration and API comparisons precede preparation.
This helper never compiles or emits graphs. Consumers restore only regular files
from fully inventoried archives; earlier attempts require immutable API selection.
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

import artifact_index
import artifact_transfer
import emit_symbol_graphs
import linux_ci
import native_jobs
import native_receipts as receipts


VERSION = 1
PACKAGES = {"root": ".", "macros": "Packages/DiscordDSLMacros",
            "extensions": "Packages/DiscordDSLExtensions"}
METADATA = "documentation-input.json"
MAX_METADATA_BYTES = 16 * 1024 * 1024
MAX_FILES = 200000
MAX_BYTES = 16 * 1024 * 1024 * 1024
PREPARE_SECONDS = 2400
PRODUCER_JOB_NAME = "Public API and DocC / macOS ARM"
METADATA_KEYS = {"formatVersion", "status", "component", "package", "source", "execution",
                 "modules", "files", "payloadSHA256"}
SOURCE_KEYS = {"commit", "sourceSHA256", "dependencyPinsSHA256"}


def safe_path(name):
    """Require a canonical relative path without platform-specific escapes."""
    if (not isinstance(name, str) or not name or "\\" in name
            or any(ord(character) < 32 for character in name)
            or PurePosixPath(name).is_absolute() or str(PurePosixPath(name)) != name
            or any(part in ("", ".", "..") for part in name.split("/"))):
        raise ValueError("unsafe documentation archive path")
    return name


def validate_source(source):
    receipts.object_keys(source, SOURCE_KEYS, "documentation source")
    if (not receipts.SHA1.fullmatch(str(source["commit"]))
            or not receipts.SHA256.fullmatch(str(source["sourceSHA256"]))
            or not isinstance(source["dependencyPinsSHA256"], dict)):
        raise ValueError("invalid documentation source identity")
    for path, digest in source["dependencyPinsSHA256"].items():
        safe_path(path)
        if not isinstance(digest, str) or not receipts.SHA256.fullmatch(digest):
            raise ValueError("invalid documentation dependency pin digest")


def validate_report(report):
    """Require the converter's complete, strictly successful public module scope."""
    required = {"modules", "archiveCount", "warningsAsErrors", "analyze", "publicSymbolsOnly",
                "failedModules", "mergeStatus", "mergedArchive", "limits"}
    receipts.object_keys(report, required, "DocC conversion report")
    modules = report["modules"]
    if (not isinstance(modules, list) or not modules
            or any(not isinstance(module, str) or not native_jobs.IDENTIFIER.fullmatch(module) for module in modules)
            or modules != sorted(set(modules)) or type(report["archiveCount"]) is not int
            or report["archiveCount"] != len(modules) or report["failedModules"] != []
            or report["mergeStatus"] != "succeeded"
            or report["mergedArchive"] != "DiscordKitLibrary.doccarchive"
            or any(report[key] is not True for key in ("warningsAsErrors", "analyze", "publicSymbolsOnly"))
            or not isinstance(report["limits"], str)):
        raise ValueError("incomplete or non-strict DocC conversion")
    return modules


def digest_stream(stream):
    digest = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
    return digest.hexdigest()


def inventory(converted, modules):
    """Inventory the report and individual archives, excluding the package merge."""
    paths = [converted / "build-report.json"]
    for module in modules:
        archive = converted / f"{module}.doccarchive"
        if archive.is_symlink() or not archive.is_dir():
            raise ValueError("missing converted public-module archive")
        files = []
        for path in sorted(archive.rglob("*")):
            if path.is_symlink() or not (path.is_file() or path.is_dir()):
                raise ValueError("documentation inputs must contain only regular files and directories")
            if path.is_file():
                files.append(path)
        if not files:
            raise ValueError("empty converted public-module archive")
        paths.extend(files)
    records = {}
    for path in sorted(paths):
        if path.is_symlink() or not path.is_file():
            raise ValueError("documentation input must be a regular file")
        name = safe_path(path.relative_to(converted).as_posix())
        records[name] = {"size": path.stat().st_size, "sha256": native_jobs.file_digest(path)}
    if len(records) > MAX_FILES or sum(item["size"] for item in records.values()) > MAX_BYTES:
        raise ValueError("documentation inputs exceed inventory limits")
    return records


def new_destination(path):
    path = Path(path).absolute()
    if path.exists() or path.is_symlink() or any(parent.is_symlink() for parent in path.parents):
        raise ValueError("documentation receipt/archive must be a new path without symlink ancestors")
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def seal(repository, component, converted, archive, receipt, *, source, execution):
    """Seal outputs only under the identity captured before supervised conversion."""
    repository, converted = Path(repository).resolve(), Path(converted).absolute()
    if component not in PACKAGES or converted.is_symlink() or any(parent.is_symlink() for parent in converted.parents):
        raise ValueError("invalid documentation component or conversion directory")
    archive, receipt = new_destination(archive), new_destination(receipt)
    if archive == receipt:
        raise ValueError("documentation archive and receipt paths must differ")
    validate_source(source)
    receipts.validate_execution(execution)
    if native_jobs.source_identity(repository) != source or receipts.execution_identity(repository) != execution:
        raise ValueError("source or execution changed during documentation conversion")
    if not 0 < (converted / "build-report.json").stat().st_size <= MAX_METADATA_BYTES:
        raise ValueError("missing or oversized DocC conversion report")
    with (converted / "build-report.json").open() as stream:
        modules = validate_report(receipts.read_json(stream))
    files = inventory(converted, modules)
    metadata = {"formatVersion": VERSION, "status": "passed", "component": component,
                "package": PACKAGES[component], "source": source, "execution": execution,
                "modules": modules, "files": files, "payloadSHA256": receipts.digest(files)}
    archive_created, receipt_created = False, False
    try:
        # Exclusive creation preserves immutable evidence even on a repeated invocation.
        destination = archive.open("xb")
        archive_created = True
        with destination, tarfile.open(fileobj=destination, mode="w:gz", compresslevel=1) as transport:
            for name in files:
                transport.add(converted / name, arcname=name, recursive=False)
            data = json.dumps(metadata, sort_keys=True, allow_nan=False).encode()
            member = tarfile.TarInfo(METADATA)
            member.size, member.mode = len(data), 0o644
            transport.addfile(member, io.BytesIO(data))
        if (inventory(converted, modules) != files or native_jobs.source_identity(repository) != source
                or receipts.execution_identity(repository) != execution):
            raise ValueError("documentation inputs or source changed during sealing")
        metadata_with_digest = {**metadata, "archiveSHA256": native_jobs.file_digest(archive)}
        stream = receipt.open("x")
        receipt_created = True
        with stream:
            json.dump(metadata_with_digest, stream, indent=2, sort_keys=True, allow_nan=False)
            stream.write("\n")
        return metadata_with_digest
    except BaseException:
        if archive_created:
            archive.unlink(missing_ok=True)
        if receipt_created:
            receipt.unlink(missing_ok=True)
        raise


def prepare(repository, component, output, archive, receipt, docc):
    """Validate restored graphs and convert once under Phase 1 process supervision."""
    repository, output = Path(repository).resolve(), Path(output).absolute()
    if component not in PACKAGES:
        raise ValueError("invalid documentation component")
    # Reject conflicting immutable exports before starting expensive work.
    new_destination(archive)
    new_destination(receipt)
    source, execution = native_jobs.source_identity(repository), receipts.execution_identity(repository)
    package, scripts = repository / PACKAGES[component], repository / "Tools/ci"
    graphs = package / ".build/out/symbolgraph"
    emit_symbol_graphs.validate_directory(graphs, package / ".build")
    commands = [linux_ci.Command("curate-docc", tuple(map(str, [sys.executable, scripts / "curate_docc.py",
                "--repository", package, "--symbolgraphs", graphs, "--check"])), 300, "localHelperCheck")]
    if component == "root":
        commands.append(linux_ci.Command("documentation-examples", tuple(map(str, [sys.executable,
            scripts / "documentation_examples.py", "--repository", repository])), 300, "localHelperCheck"))
    commands.append(linux_ci.Command("convert-docc", tuple(map(str, [sys.executable, scripts / "build_docc.py",
        "--repository", package, "--symbolgraphs", graphs, "--output", output, "--docc", docc])),
        1800, "localHelperCheck"))
    report = {"component": component, "status": "running", "aggregateSeconds": PREPARE_SECONDS}
    native_jobs.execute_commands(commands, repository, output.with_name(output.name + "-preparation"), report,
                                 deadline=time.monotonic() + PREPARE_SECONDS)
    return seal(repository, component, output, archive, receipt, source=source, execution=execution)


def validate_selection(selection, execution, source):
    """Require a current-job immutable selection before accepting an older attempt."""
    receipts.object_keys(selection, {"formatVersion", "execution", "sourceCommit", "producerAttempt", "artifact"},
                         "documentation artifact selection")
    artifact_index.same_execution(selection["execution"], execution)
    artifact = selection["artifact"]
    receipts.object_keys(artifact, {"id", "name", "digest"}, "documentation selected artifact")
    if (type(selection["formatVersion"]) is not int or selection["formatVersion"] != VERSION
            or selection["sourceCommit"] != source["commit"]
            or not isinstance(selection["producerAttempt"], str)
            or not artifact_index.positive_id(selection["producerAttempt"])
            or int(selection["producerAttempt"]) > int(execution["runAttempt"])
            or not isinstance(artifact["id"], str) or not artifact_index.positive_id(artifact["id"])
            or not isinstance(artifact["digest"], str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", artifact["digest"])
            or not isinstance(artifact["name"], str)):
        raise ValueError("invalid immutable documentation selection")
    prefix = f"documentation-inputs-{source['commit']}-{execution['runID']}-{selection['producerAttempt']}"
    if not re.fullmatch(re.escape(prefix) + r"-t[1-3]", artifact["name"]):
        raise ValueError("documentation artifact name and producer attempt differ")


def select_artifact(client, execution, source, artifact_id, expected_digest):
    """Verify original repository/event/source and successful attempt-specific API job."""
    receipts.validate_execution(execution)
    validate_source(source)
    run = client.get_run()
    artifact_index.validate_run(run, execution, source["commit"])
    if "run_attempt" in run and str(run["run_attempt"]) != execution["runAttempt"]:
        raise ValueError("documentation selection requires the fresh current workflow attempt")
    artifact = client.get_artifact(artifact_id)
    artifact_index.validate_artifact(artifact, run, execution)
    if str(artifact["id"]) != str(artifact_id) or artifact["digest"] != expected_digest:
        raise ValueError("documentation immutable artifact ID or digest differs")
    prefix = f"documentation-inputs-{source['commit']}-{execution['runID']}-"
    match = re.fullmatch(re.escape(prefix) + r"([1-9][0-9]*)-t[1-3]", artifact["name"])
    if not match or int(match[1]) > int(execution["runAttempt"]):
        raise ValueError("invalid or future documentation producer attempt")
    # A newer failed/cancelled/in-progress replacement cannot be hidden by an
    # older success. Endpoint provenance supplies attempts when REST omits them.
    latest = None
    for attempt in range(int(match[1]), int(execution["runAttempt"]) + 1):
        jobs = client.list_jobs(str(attempt))
        if (not isinstance(jobs, list) or any(not isinstance(job, dict) or
                ("run_attempt" in job and str(job["run_attempt"]) != str(attempt)) for job in jobs)):
            raise ValueError("invalid attempt-specific documentation job listing")
        matches = [job for job in jobs if job.get("name") == PRODUCER_JOB_NAME
                   or str(job.get("name", "")).endswith(" / " + PRODUCER_JOB_NAME)]
        if len(matches) > 1:
            raise ValueError("ambiguous documentation producer job")
        if matches:
            latest = (str(attempt), matches[0])
    if latest is None or latest[0] != match[1]:
        raise ValueError("missing or superseded documentation producer job")
    job = latest[1]
    if (not artifact_index.positive_id(job.get("id")) or str(job.get("run_id")) != execution["runID"]
            or job.get("head_sha") != run["head_sha"]
            or job.get("status") != "completed" or job.get("conclusion") != "success"):
        raise ValueError("documentation producer job did not succeed at the selected source/attempt")
    selected = {"formatVersion": VERSION, "execution": execution, "sourceCommit": source["commit"],
                "producerAttempt": match[1], "artifact": {"id": str(artifact["id"]),
                "name": artifact["name"], "digest": artifact["digest"]}}
    validate_selection(selected, execution, source)
    return selected


def validate_metadata(metadata, source, execution, selection=None):
    receipts.object_keys(metadata, METADATA_KEYS, "sealed documentation input")
    component = metadata["component"]
    if (type(metadata["formatVersion"]) is not int or metadata["formatVersion"] != VERSION
            or metadata["status"] != "passed" or not isinstance(component, str) or component not in PACKAGES
            or metadata["package"] != PACKAGES[component]):
        raise ValueError("invalid documentation input version, component or status")
    validate_source(metadata["source"])
    validate_source(source)
    if metadata["source"] != source:
        raise ValueError("sealed documentation source differs from current revision/contents/pins")
    producer = metadata["execution"]
    receipts.validate_execution(producer)
    if producer["scope"] == "github" and producer["jobID"] != "public-api":
        raise ValueError("sealed documentation requires the public-api producer job")
    receipts.validate_execution(execution)
    if selection is None:
        if any(producer[key] != execution[key] for key in receipts.EXECUTION_KEYS - {"jobID"}):
            raise ValueError("documentation producer repository/workflow/event/run/attempt differs")
    else:
        validate_selection(selection, execution, source)
        artifact_index.same_execution(producer, execution, earlier=True)
        if producer["runAttempt"] != selection["producerAttempt"] or producer["jobID"] != "public-api":
            raise ValueError("sealed documentation producer differs from selected successful API job")
    modules, files = metadata["modules"], metadata["files"]
    if (not isinstance(modules, list) or not modules
            or any(not isinstance(module, str) or not native_jobs.IDENTIFIER.fullmatch(module) for module in modules)
            or modules != sorted(set(modules)) or not isinstance(files, dict) or not files
            or len(files) > MAX_FILES or metadata["payloadSHA256"] != receipts.digest(files)
            or "build-report.json" not in files):
        raise ValueError("invalid sealed documentation inventory")
    total = 0
    for name, record in files.items():
        safe_path(name)
        receipts.object_keys(record, {"size", "sha256"}, "documentation file inventory")
        if (type(record["size"]) is not int or record["size"] < 0
                or not isinstance(record["sha256"], str) or not receipts.SHA256.fullmatch(record["sha256"])
                or name != "build-report.json" and not any(name.startswith(f"{module}.doccarchive/") for module in modules)):
            raise ValueError("invalid sealed documentation file scope, size or digest")
        total += record["size"]
    if total > MAX_BYTES or any(not any(name.startswith(f"{module}.doccarchive/") for name in files) for module in modules):
        raise ValueError("incomplete or oversized sealed documentation archive")


def restore(archive, destination, *, source, execution, selection=None):
    """Validate every tar member and hash before installing any archive inputs."""
    archive, destination = Path(archive), new_destination(destination)
    if archive.is_symlink() or not archive.is_file():
        raise ValueError("sealed documentation input must be a regular archive file")
    try:
        with tarfile.open(archive, "r:gz") as transport:
            members, expanded = [], 0
            for member in transport:
                members.append(member)
                expanded += max(member.size, 0)
                if len(members) > MAX_FILES + 1 or expanded > MAX_BYTES + MAX_METADATA_BYTES:
                    raise ValueError("documentation archive exceeds inventory limits")
            seen = set()
            for member in members:
                safe_path(member.name)
                if member.name in seen or not member.isfile() or member.size < 0:
                    raise ValueError("unsafe or duplicate documentation archive member")
                seen.add(member.name)
            manifests = [member for member in members if member.name == METADATA]
            if len(manifests) != 1 or not 0 < manifests[0].size <= MAX_METADATA_BYTES:
                raise ValueError("missing or oversized documentation receipt")
            with transport.extractfile(manifests[0]) as stream:
                metadata = receipts.read_json(stream)
            validate_metadata(metadata, source, execution, selection)
            files = metadata["files"]
            if seen != set(files) | {METADATA}:
                raise ValueError("documentation archive members differ from sealed inventory")
            for member in members:
                if member.name != METADATA:
                    with transport.extractfile(member) as stream:
                        if member.size != files[member.name]["size"] or digest_stream(stream) != files[member.name]["sha256"]:
                            raise ValueError("documentation archive file differs from sealed hash/size")
            report_member = transport.getmember("build-report.json")
            if report_member.size > MAX_METADATA_BYTES:
                raise ValueError("oversized DocC conversion report")
            with transport.extractfile(report_member) as stream:
                modules = validate_report(receipts.read_json(stream))
            if modules != metadata["modules"]:
                raise ValueError("sealed module scope differs from conversion report")
            with tempfile.TemporaryDirectory(prefix="documentation-restore-", dir=destination.parent) as temporary:
                staging = Path(temporary) / "inputs"
                staging.mkdir()
                for member in members:
                    if member.name == METADATA:
                        continue
                    output = staging / member.name
                    output.parent.mkdir(parents=True, exist_ok=True)
                    with transport.extractfile(member) as stream, output.open("xb") as target:
                        shutil.copyfileobj(stream, target)
                    if (output.stat().st_size != files[member.name]["size"]
                            or native_jobs.file_digest(output) != files[member.name]["sha256"]):
                        raise ValueError("documentation archive changed during restoration")
                staging.rename(destination)
        return metadata, [destination / f"{module}.doccarchive" for module in metadata["modules"]]
    except (tarfile.TarError, OSError, UnicodeError) as error:
        raise ValueError("invalid or missing sealed documentation archive") from error


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare", help="check restored graphs, convert once and seal")
    prepare_parser.add_argument("--component", choices=PACKAGES, required=True)
    prepare_parser.add_argument("--output", type=Path, required=True)
    prepare_parser.add_argument("--archive", type=Path, required=True)
    prepare_parser.add_argument("--receipt", type=Path, required=True)
    prepare_parser.add_argument("--docc", default=shutil.which("docc"))
    select_parser = commands.add_parser("select", help="verify a successful immutable same-run producer")
    select_parser.add_argument("--artifact-id", required=True)
    select_parser.add_argument("--expected-digest", required=True)
    select_parser.add_argument("--output", type=Path, required=True)
    for command in (prepare_parser, select_parser):
        command.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args(argv)
    if args.command == "prepare":
        if not args.docc and shutil.which("xcrun"):
            args.docc = subprocess.check_output(["xcrun", "--find", "docc"], text=True, timeout=30).strip()
        if not args.docc:
            parser.error("docc is not installed; pass --docc from the selected toolchain")
        prepare(args.repository, args.component, args.output, args.archive, args.receipt, args.docc)
    else:
        client = artifact_transfer.GitHubArtifactClient(os.environ.get("GITHUB_REPOSITORY", ""),
            os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN", ""), os.environ.get("GITHUB_RUN_ID", ""))
        execution, source = receipts.execution_identity(args.repository), native_jobs.source_identity(args.repository)
        budget = artifact_transfer.Budget()
        def attempt(_number, deadline):
            with client.within(budget, deadline):
                return select_artifact(client, execution, source, args.artifact_id, args.expected_digest)
        with artifact_transfer.wall_deadline(budget.remaining()):
            selected = artifact_transfer.recover(attempt, budget=budget, description="documentation-selection")
        artifact_transfer.write_json(args.output, selected)


if __name__ == "__main__":
    main()
