# File: Tools/ci/test_documentation_inputs.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Source/trust-bound DocC transport tests without a compiler or network."""

import copy
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import Mock, patch

import documentation_inputs as inputs


SOURCE = {"commit": "a" * 40, "sourceSHA256": "b" * 64,
          "dependencyPinsSHA256": {"Package.resolved": "c" * 64}}


def github_execution(attempt="1", job="public-api"):
    return {"scope": "github", "repository": "owner/DiscordKit", "repositoryID": "7",
            "workflowRef": "owner/DiscordKit/.github/workflows/ci.yml@refs/heads/main",
            "workflowSHA": "a" * 40, "runID": "42", "runAttempt": attempt, "jobID": job,
            "event": "push", "ref": "refs/heads/main", "headRef": "", "baseRef": ""}


def converted_fixture(directory, modules):
    """Write strict conversion outputs including a merge that must not transfer."""
    directory.mkdir(parents=True)
    modules = sorted(modules)
    report = {"modules": modules, "archiveCount": len(modules), "warningsAsErrors": True,
              "analyze": True, "publicSymbolsOnly": True, "failedModules": [],
              "mergeStatus": "succeeded", "mergedArchive": "DiscordKitLibrary.doccarchive",
              "limits": "Private documentation review remains separate"}
    (directory / "build-report.json").write_text(json.dumps(report))
    for module in modules:
        archive = directory / f"{module}.doccarchive"
        (archive / "data/documentation").mkdir(parents=True)
        (archive / "metadata.json").write_text('{"schemaVersion":{"major":0,"minor":1,"patch":0}}')
        (archive / "data/documentation" / f"{module.lower()}.json").write_text(json.dumps({"title": module}))
        (archive / "empty-resource").touch()
    (directory / "DiscordKitLibrary.doccarchive").mkdir()
    (directory / "DiscordKitLibrary.doccarchive/unused.json").write_text("package merge")
    return report


def sealed_fixture(repository, component, modules=None, execution=None):
    modules = modules or {"root": ["DiscordKit", "DiscordCore"], "macros": ["DiscordDSLMacros"],
                          "extensions": ["DiscordDSLExtensions"]}[component]
    execution = execution or github_execution()
    converted = repository / f"converted-{component}"
    converted_fixture(converted, modules)
    archive, receipt = repository / f"{component}.tar.gz", repository / f"{component}.json"
    with patch.object(inputs.native_jobs, "source_identity", return_value=SOURCE), \
            patch.object(inputs.receipts, "execution_identity", return_value=execution):
        metadata = inputs.seal(repository, component, converted, archive, receipt,
                               source=SOURCE, execution=execution)
    return archive, metadata


def rewrite_archive(archive, mutate):
    """Edit tiny tar fixtures while preserving all otherwise valid members."""
    with tarfile.open(archive, "r:gz") as transport:
        records = [(copy.copy(member), transport.extractfile(member).read()) for member in transport.getmembers()]
    mutate(records)
    with tarfile.open(archive, "w:gz") as transport:
        for member, data in records:
            member.size = len(data)
            transport.addfile(member, io.BytesIO(data))


def mutate_metadata(records, mutate):
    for number, (member, data) in enumerate(records):
        if member.name == inputs.METADATA:
            metadata = json.loads(data)
            mutate(metadata)
            records[number] = member, json.dumps(metadata).encode()


class DocumentationInputTests(unittest.TestCase):
    def restore(self, archive, destination, **options):
        return inputs.restore(archive, destination, source=SOURCE, execution=github_execution(job="documentation-site"), **options)

    def test_seal_restores_only_individual_archives_and_binds_every_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary).resolve()
            archive, metadata = sealed_fixture(repository, "root")
            restored, archives = self.restore(archive, repository / "restored")
            self.assertEqual(restored, {key: value for key, value in metadata.items() if key != "archiveSHA256"})
            self.assertEqual([path.name for path in archives], ["DiscordCore.doccarchive", "DiscordKit.doccarchive"])
            self.assertFalse((repository / "restored/DiscordKitLibrary.doccarchive").exists())
            self.assertTrue((archives[0] / "empty-resource").is_file())
            self.assertEqual(metadata["archiveSHA256"], inputs.native_jobs.file_digest(archive))
            for path, record in metadata["files"].items():
                self.assertEqual(record["sha256"], inputs.native_jobs.file_digest(repository / "restored" / path))

    def test_sealing_rejects_failed_non_strict_incomplete_and_unsafe_outputs(self):
        for invalid in ("failed", "warnings", "count", "merge", "missing", "empty", "symlink", "report-symlink", "duplicate-json"):
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as temporary:
                repository = Path(temporary).resolve()
                converted = repository / "converted"
                report = converted_fixture(converted, ["DiscordKit"])
                if invalid == "failed":
                    report["failedModules"] = ["DiscordKit"]
                elif invalid == "warnings":
                    report["warningsAsErrors"] = False
                elif invalid == "count":
                    report["archiveCount"] = 0
                elif invalid == "merge":
                    report["mergeStatus"] = "failed"
                elif invalid == "missing":
                    report["modules"] = ["Missing"]
                elif invalid == "empty":
                    report["modules"] = []
                elif invalid == "symlink":
                    (converted / "DiscordKit.doccarchive/link").symlink_to(repository)
                (converted / "build-report.json").write_text(json.dumps(report))
                if invalid == "report-symlink":
                    report_path = converted / "build-report.json"
                    report_path.rename(repository / "report.json")
                    report_path.symlink_to(repository / "report.json")
                elif invalid == "duplicate-json":
                    (converted / "build-report.json").write_text('{"modules":[],"modules":[]}')
                with patch.object(inputs.native_jobs, "source_identity", return_value=SOURCE), \
                        patch.object(inputs.receipts, "execution_identity", return_value=github_execution()), \
                        self.assertRaises((ValueError, FileNotFoundError)):
                    inputs.seal(repository, "root", converted, repository / "input.tar.gz", repository / "receipt.json",
                                source=SOURCE, execution=github_execution())
                self.assertFalse((repository / "input.tar.gz").exists())

    def test_source_or_execution_change_during_conversion_or_sealing_fails(self):
        for change in ("source", "execution", "during-seal"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                repository = Path(temporary).resolve()
                converted_fixture(repository / "converted", ["DiscordKit"])
                source = {**SOURCE, "sourceSHA256": "d" * 64}
                source_values = [SOURCE, source] if change == "during-seal" else [source, source] if change == "source" else [SOURCE, SOURCE]
                execution = github_execution(attempt="2") if change == "execution" else github_execution()
                with patch.object(inputs.native_jobs, "source_identity", side_effect=source_values), \
                        patch.object(inputs.receipts, "execution_identity", return_value=execution), \
                        self.assertRaisesRegex(ValueError, "changed"):
                    inputs.seal(repository, "root", repository / "converted", repository / "input.tar.gz",
                                repository / "receipt.json", source=SOURCE, execution=github_execution())
                self.assertFalse((repository / "input.tar.gz").exists())
                self.assertFalse((repository / "receipt.json").exists())

    def test_archive_and_receipt_are_immutable_and_arbitrary_outputs_are_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary).resolve()
            archive, _ = sealed_fixture(repository, "root")
            original = archive.read_bytes()
            with patch.object(inputs.native_jobs, "source_identity", return_value=SOURCE),                     patch.object(inputs.receipts, "execution_identity", return_value=github_execution()),                     self.assertRaisesRegex(ValueError, "new path"):
                inputs.seal(repository, "root", repository / "converted-root", archive, repository / "another.json",
                            source=SOURCE, execution=github_execution())
            self.assertEqual(archive.read_bytes(), original)
            destination = repository / "existing"
            destination.mkdir()
            (destination / "source").write_text("keep")
            with self.assertRaisesRegex(ValueError, "new path"):
                self.restore(archive, destination)
            self.assertEqual((destination / "source").read_text(), "keep")

    def test_missing_tampered_extra_duplicate_and_unsafe_archive_members_fail_before_install(self):
        for invalid in ("missing", "tampered", "extra", "duplicate", "traversal", "absolute", "backslash", "symlink", "hardlink", "fifo"):
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as temporary:
                repository = Path(temporary).resolve()
                archive, _ = sealed_fixture(repository, "root")
                def mutate(records):
                    if invalid == "missing":
                        records.pop(0)
                    elif invalid == "tampered":
                        member, _ = records[0]
                        records[0] = member, b"changed bytes"
                    elif invalid == "duplicate":
                        records.append(copy.deepcopy(records[0]))
                    else:
                        name = {"traversal": "../escape", "absolute": "/escape", "backslash": "a\\escape"}.get(invalid, "extra-file")
                        member = tarfile.TarInfo(name)
                        if invalid in ("symlink", "hardlink", "fifo"):
                            member.type = {"symlink": tarfile.SYMTYPE, "hardlink": tarfile.LNKTYPE, "fifo": tarfile.FIFOTYPE}[invalid]
                            member.linkname = "../escape"
                        records.append((member, b"unsafe"))
                rewrite_archive(archive, mutate)
                with self.assertRaises(ValueError):
                    self.restore(archive, repository / "restored")
                self.assertFalse((repository / "restored").exists())
                self.assertFalse((repository.parent / "escape").exists())

    def test_malformed_seal_or_changed_trust_scope_is_rejected(self):
        changes = [lambda meta: meta.update(status="failed"), lambda meta: meta.update(formatVersion=True),
                   lambda meta: meta.update(component="diagnostic"), lambda meta: meta.update(modules=["../escape"]),
                   lambda meta: meta["source"].update(commit="d" * 40),
                   lambda meta: meta["source"].update(sourceSHA256="d" * 64),
                   lambda meta: meta["execution"].update(repository="fork/DiscordKit"),
                   lambda meta: meta["execution"].update(repositoryID="8"),
                   lambda meta: meta["execution"].update(event="workflow_dispatch"),
                   lambda meta: meta["execution"].update(runID="43"),
                   lambda meta: meta["execution"].update(runAttempt="2"),
                   lambda meta: meta["execution"].update(jobID="diagnostics"),
                   lambda meta: meta.update(payloadSHA256="0" * 64)]
        for number, change in enumerate(changes):
            with self.subTest(change=number), tempfile.TemporaryDirectory() as temporary:
                repository = Path(temporary).resolve()
                archive, _ = sealed_fixture(repository, "root")
                rewrite_archive(archive, lambda records: mutate_metadata(records, change))
                with self.assertRaises(ValueError):
                    self.restore(archive, repository / "restored")
                self.assertFalse((repository / "restored").exists())

    def test_prepare_supervises_one_conversion_without_building_or_emitting_graphs(self):
        for component in inputs.PACKAGES:
            with self.subTest(component=component), tempfile.TemporaryDirectory() as temporary:
                repository = Path(temporary).resolve()
                graphs = repository / inputs.PACKAGES[component] / ".build/out/symbolgraph"
                graphs.mkdir(parents=True)
                (graphs / "Example.symbols.json").write_text('{"module":{"name":"Example"}}')
                output = repository / "conversion"
                def execute(commands, root, logs, report, **options):
                    self.assertGreater(options["deadline"], inputs.time.monotonic())
                    self.assertEqual(logs, repository / "conversion-preparation")
                    self.assertEqual([command.name for command in commands],
                        ["curate-docc", *(["documentation-examples"] if component == "root" else []), "convert-docc"])
                    self.assertTrue(all(command.operation == "localHelperCheck" for command in commands))
                    self.assertTrue(all("emit_symbol_graphs.py" not in " ".join(command.arguments) and "swift" != command.arguments[0]
                                        for command in commands))
                    self.assertEqual(commands[-1].timeout, 1800)
                    converted_fixture(output, ["Example"])
                with patch.object(inputs.native_jobs, "source_identity", return_value=SOURCE), \
                        patch.object(inputs.receipts, "execution_identity", return_value=github_execution()), \
                        patch.object(inputs.native_jobs, "execute_commands", side_effect=execute) as execute_commands:
                    inputs.prepare(repository, component, output, repository / "input.tar.gz", repository / "receipt.json", "docc")
                execute_commands.assert_called_once()
                self.assertTrue((repository / "input.tar.gz").is_file())

    def test_prepare_finds_xcode_docc_with_a_finite_lookup(self):
        with patch.object(inputs.shutil, "which", side_effect=lambda name: "/usr/bin/xcrun" if name == "xcrun" else None), \
                patch.object(inputs.subprocess, "check_output", return_value="/toolchain/docc\n") as lookup, \
                patch.object(inputs, "prepare") as prepare:
            inputs.main(["prepare", "--component", "root", "--output", "converted", "--archive", "input.tar.gz", "--receipt", "receipt.json"])
        lookup.assert_called_once_with(["xcrun", "--find", "docc"], text=True, timeout=30)
        self.assertEqual(prepare.call_args.args[-1], "/toolchain/docc")


class DocumentationSelectionTests(unittest.TestCase):
    def client(self, *, selected_attempt="1", latest_attempt="2"):
        client = Mock()
        run = {"id": 42, "repository": {"id": 7, "full_name": "owner/DiscordKit"},
               "head_repository": {"id": 7}, "head_sha": "a" * 40, "event": "push",
               "path": ".github/workflows/ci.yml", "run_attempt": int(latest_attempt)}
        artifact = {"id": 100, "expired": False,
                    "name": f"documentation-inputs-{'a' * 40}-42-{selected_attempt}-t1", "digest": "sha256:" + "f" * 64,
                    "workflow_run": {"id": 42, "repository_id": 7, "head_repository_id": 7, "head_sha": "a" * 40}}
        job = {"id": 200, "run_id": 42, "head_sha": "a" * 40, "name": inputs.PRODUCER_JOB_NAME,
               "status": "completed", "conclusion": "success"}
        client.get_run.return_value = run
        client.get_artifact.return_value = artifact
        client.list_jobs.side_effect = lambda attempt: [job] if attempt == selected_attempt else []
        return client, run, artifact, job

    def select(self, client):
        return inputs.select_artifact(client, github_execution("2", "documentation-site"), SOURCE, "100", "sha256:" + "f" * 64)

    def test_verified_earlier_success_admits_only_the_selected_same_run_producer(self):
        client, _, _, _ = self.client()
        selection = self.select(client)
        self.assertEqual(selection["producerAttempt"], "1")
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary).resolve()
            archive, _ = sealed_fixture(repository, "root")
            with self.assertRaisesRegex(ValueError, "attempt differs"):
                inputs.restore(archive, repository / "no-selection", source=SOURCE, execution=github_execution("2", "documentation-site"))
            inputs.restore(archive, repository / "selected", source=SOURCE,
                           execution=github_execution("2", "documentation-site"), selection=selection)
            selection["artifact"]["name"] = selection["artifact"]["name"].replace("-1-t1", "-2-t1")
            with self.assertRaisesRegex(ValueError, "name and producer attempt"):
                inputs.restore(archive, repository / "edited", source=SOURCE,
                               execution=github_execution("2", "documentation-site"), selection=selection)

    def test_linux_skipped_homonym_does_not_ambiguate_macos_producer(self):
        client, _, _, job = self.client(selected_attempt="2")
        linux = {**job, "id": 201, "name": "Linux x64 / Public API and DocC / macOS ARM",
                 "conclusion": "skipped"}
        self.assertEqual(job["name"], "macOS ARM64 / Public API and DocC / macOS ARM")
        client.list_jobs.side_effect = lambda attempt: [linux, job] if attempt == "2" else []
        self.assertEqual(self.select(client)["producerAttempt"], "2")

    def test_later_linux_skip_does_not_supersede_earlier_macos_success(self):
        client, _, _, job = self.client()
        linux = {**job, "id": 201, "name": "Linux x64 / Public API and DocC / macOS ARM",
                 "conclusion": "skipped"}
        client.list_jobs.side_effect = lambda attempt: [job, linux] if attempt == "1" else [linux]
        self.assertEqual(self.select(client)["producerAttempt"], "1")

    def test_only_exact_macos_hierarchy_can_certify_documentation_producer(self):
        for name in ("Public API and DocC / macOS ARM", "Linux x64 / Public API and DocC / macOS ARM",
                     "Other / macOS ARM64 / Public API and DocC / macOS ARM"):
            with self.subTest(name=name):
                client, _, _, job = self.client()
                job["name"] = name
                with self.assertRaisesRegex(ValueError, "missing or superseded"):
                    self.select(client)

    def test_duplicate_macos_producers_remain_ambiguous_with_linux_skip(self):
        client, _, _, job = self.client()
        linux = {**job, "id": 201, "name": "Linux x64 / Public API and DocC / macOS ARM",
                 "conclusion": "skipped"}
        client.list_jobs.side_effect = lambda attempt: [linux, job, {**job, "id": 202}]
        with self.assertRaisesRegex(ValueError, "ambiguous documentation producer"):
            self.select(client)

    def test_newer_failed_cancelled_running_or_successful_replacements_supersede_old_success(self):
        for status, conclusion in (("completed", "failure"), ("completed", "cancelled"),
                                   ("in_progress", None), ("completed", "success")):
            with self.subTest(conclusion=conclusion):
                client, _, _, job = self.client()
                replacement = {**job, "id": 201, "status": status, "conclusion": conclusion}
                client.list_jobs.side_effect = lambda attempt: [job] if attempt == "1" else [replacement]
                with self.assertRaisesRegex(ValueError, "superseded"):
                    self.select(client)

    def test_immutable_id_digest_source_event_fork_attempt_and_job_fail_closed(self):
        for invalid in ("id", "digest", "source", "event", "fork", "future", "stale-run", "failed-job", "job-attempt", "duplicate-job", "missing-job"):
            with self.subTest(invalid=invalid):
                client, run, artifact, job = self.client()
                if invalid == "id":
                    artifact["id"] = 101
                elif invalid == "digest":
                    artifact["digest"] = "sha256:" + "0" * 64
                elif invalid == "source":
                    run["head_sha"] = "d" * 40
                elif invalid == "event":
                    run["event"] = "pull_request"
                elif invalid == "fork":
                    run["repository"]["full_name"] = "fork/DiscordKit"
                elif invalid == "future":
                    artifact["name"] = artifact["name"].replace("-1-t1", "-3-t1")
                elif invalid == "stale-run":
                    run["run_attempt"] = 1
                elif invalid == "failed-job":
                    job["conclusion"] = "failure"
                elif invalid == "job-attempt":
                    job["run_attempt"] = 2
                elif invalid == "duplicate-job":
                    client.list_jobs.side_effect = lambda attempt: [job, job]
                else:
                    client.list_jobs.side_effect = lambda attempt: []
                with self.assertRaises(ValueError):
                    self.select(client)


if __name__ == "__main__":
    unittest.main()
