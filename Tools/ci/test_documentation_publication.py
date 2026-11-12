# File: Tools/ci/test_documentation_publication.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Exercise same-run Pages trust and safe site extraction without remote writes."""

import copy
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import documentation_publication as publication


REVISION = "abcdef0123" * 4
OTHER = "1234567890" * 4
REPOSITORY = publication.TRUSTED_REPOSITORY
ARTIFACT_NAME = f"documentation-site-{REVISION}-1234-2-t1"
DIGEST = "sha256:" + "c" * 64


def execution(**changes):
    result = {"scope": "github", "repository": REPOSITORY, "repositoryID": "42",
              "workflowRef": f"{REPOSITORY}/.github/workflows/ci.yml@refs/heads/main",
              "workflowSHA": REVISION, "runID": "1234", "runAttempt": "2", "jobID": "publish",
              "event": "push", "ref": "refs/heads/main", "headRef": "", "baseRef": ""}
    result.update(changes)
    return result


def job(identifier, name, step, **changes):
    value = {"id": identifier, "name": name, "run_id": 1234, "run_attempt": 2,
             "head_sha": REVISION, "status": "completed", "conclusion": "success",
             "steps": [{"name": step, "status": "completed", "conclusion": "success"}]}
    value.update(changes)
    return value


class FakeAPI:
    repository = REPOSITORY

    def __init__(self):
        self.calls = []
        self.responses = {
            "": {"id": 42, "full_name": REPOSITORY, "fork": False, "default_branch": "main"},
            "git/ref/heads/main": {"ref": "refs/heads/main", "object": {"type": "commit", "sha": REVISION}},
            "actions/workflows/ci.yml": {"id": 12, "path": ".github/workflows/ci.yml"},
            "actions/runs/1234": {
                "id": 1234, "run_attempt": 2, "workflow_id": 12, "path": ".github/workflows/ci.yml",
                "event": "push", "head_sha": REVISION, "head_branch": "main", "status": "in_progress",
                "conclusion": None, "repository": {"id": 42, "full_name": REPOSITORY},
                "head_repository": {"id": 42, "full_name": REPOSITORY}},
            "actions/runs/1234/attempts/2/jobs?per_page=100&page=1": {
                "total_count": 2, "jobs": [
                    job(101, publication.FULL_JOB, publication.FULL_STEP),
                    job(102, publication.SITE_JOB, publication.SITE_STEP)]},
            "actions/artifacts/56": {"id": 56, "name": ARTIFACT_NAME, "digest": DIGEST,
                "expired": False, "workflow_run": {"id": 1234, "repository_id": 42,
                    "head_repository_id": 42, "head_sha": REVISION}},
        }

    def request(self, path):
        self.calls.append(path)
        value = self.responses[path]
        if callable(value):
            value = value()
        if isinstance(value, BaseException):
            raise value
        return copy.deepcopy(value)


class PublicationTrustTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeAPI()

    def verify(self, **changes):
        values = {"execution": execution(), "revision": REVISION, "mode": "full",
                  "artifact_id": "56", "artifact_digest": DIGEST,
                  "artifact_name": ARTIFACT_NAME, "producer_attempt": "2"}
        values.update(changes)
        return publication.verify(self.api, **values)

    @property
    def jobs(self):
        return self.api.responses["actions/runs/1234/attempts/2/jobs?per_page=100&page=1"]["jobs"]

    def test_in_progress_original_run_with_fresh_full_gate_is_admitted_read_only(self):
        result = self.verify()
        self.assertEqual(result["status"], "verified")
        self.assertEqual(result["fullGateJobID"], "101")
        self.assertEqual(result["siteJobID"], "102")
        self.assertEqual(result["artifact"], {"id": "56", "name": ARTIFACT_NAME,
                                              "digest": DIGEST, "producerAttempt": "2"})
        self.assertEqual(self.api.calls.count("actions/runs/1234"), 2)
        self.assertEqual(self.api.calls.count("git/ref/heads/main"), 2)
        self.assertNotIn("actions/runs/1234/attempts/1/jobs?per_page=100&page=1", self.api.calls)

    def test_mocked_github_http_reads_use_only_the_workflow_token_and_exact_run(self):
        calls = []
        prefix = f"https://api.github.com/repos/{REPOSITORY}/"
        def read(request, timeout):
            self.assertEqual(request.get_method(), "GET")
            self.assertEqual(request.get_header("Authorization"), "Bearer workflow-test-token")
            self.assertEqual(timeout, 60)
            self.assertTrue(request.full_url.startswith(prefix))
            path = request.full_url[len(prefix):]
            calls.append(path)
            return io.BytesIO(json.dumps(self.api.responses[path]).encode())
        with patch.dict(os.environ, {"GITHUB_REPOSITORY": REPOSITORY, "GH_TOKEN": "workflow-test-token",
                                    "RELEASE_TOKEN": "unused-publication-token", "GITHUB_API_URL": "https://api.github.com"}), \
                patch.object(publication.github_release, "urlopen", side_effect=read):
            api = publication.github_release.GitHubAPI()
            result = publication.verify(api, execution=execution(), revision=REVISION, mode="full",
                artifact_id="56", artifact_digest=DIGEST, artifact_name=ARTIFACT_NAME, producer_attempt="2")
        self.assertEqual(result["status"], "verified")
        self.assertIn("actions/runs/1234/attempts/2/jobs?per_page=100&page=1", calls)
        self.assertIn("actions/artifacts/56", calls)

    def test_explicit_full_manual_default_branch_run_is_admitted(self):
        self.api.responses["actions/runs/1234"]["event"] = "workflow_dispatch"
        self.assertEqual(self.verify(execution=execution(event="workflow_dispatch"))["status"], "verified")

    def test_completed_successful_run_can_be_rechecked(self):
        self.api.responses["actions/runs/1234"].update(status="completed", conclusion="success")
        self.assertEqual(self.verify()["status"], "verified")

    def test_non_full_requests_fail_before_api_reads(self):
        for mode in ("diagnostic", "preflight", "", "FULL"):
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                self.verify(mode=mode)
        self.assertEqual(self.api.calls, [])

    def test_fork_context_is_rejected_even_when_its_own_default_branch_matches(self):
        fork = "other/DiscordKit"
        self.api.repository = fork
        with self.assertRaises(ValueError):
            self.verify(execution=execution(repository=fork,
                workflowRef=f"{fork}/.github/workflows/ci.yml@refs/heads/main"))
        self.assertEqual(self.api.calls, [])

    def test_pr_workflow_run_and_workflow_call_contexts_are_rejected(self):
        for event in ("pull_request", "workflow_run", "workflow_call"):
            context = execution(event=event)
            if event == "pull_request":
                context.update(ref="refs/pull/7/merge", headRef="feature", baseRef="main")
            with self.subTest(event=event), self.assertRaises(ValueError):
                self.verify(execution=context)
        self.assertEqual(self.api.calls, [])

    def test_wrong_workflow_source_and_non_default_branch_are_rejected(self):
        invalid = [execution(ref="refs/heads/feature"), execution(workflowSHA=OTHER),
                   execution(workflowRef=f"{REPOSITORY}/.github/workflows/documentation.yml@refs/heads/main")]
        for context in invalid:
            with self.subTest(context=context), self.assertRaises(ValueError):
                self.verify(execution=context)

    def test_live_repository_fork_identity_and_default_branch_must_match(self):
        invalid = ({"fork": True}, {"id": 99}, {"full_name": "other/DiscordKit"},
                   {"default_branch": "trunk"}, {"default_branch": ""})
        for changes in invalid:
            self.api = FakeAPI()
            self.api.responses[""].update(changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.verify()

    def test_default_branch_tip_must_still_identify_the_exact_source(self):
        for change in ({"sha": OTHER}, {"type": "tag"}):
            self.api.responses["git/ref/heads/main"]["object"].update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.verify()

    def test_changed_default_branch_tip_during_admission_is_rejected(self):
        tip = self.api.responses["git/ref/heads/main"]
        sequence = [copy.deepcopy(tip), {**tip, "object": {"type": "commit", "sha": OTHER}}]
        self.api.responses["git/ref/heads/main"] = lambda: sequence.pop(0)
        with self.assertRaisesRegex(ValueError, "changed during"):
            self.verify()

    def test_original_run_event_repository_workflow_source_and_attempt_must_match(self):
        invalid = ({"event": "pull_request"}, {"event": "workflow_run"}, {"head_sha": OTHER},
                   {"head_branch": "feature"}, {"run_attempt": 1}, {"run_attempt": 3},
                   {"workflow_id": 99}, {"path": ".github/workflows/documentation.yml"},
                   {"repository": {"id": 42, "full_name": "other/DiscordKit"}},
                   {"head_repository": {"id": 99, "full_name": "other/DiscordKit"}},
                   {"head_repository": None})
        for changes in invalid:
            self.api = FakeAPI()
            self.api.responses["actions/runs/1234"].update(changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.verify()

    def test_failed_cancelled_queued_and_inconsistent_runs_are_rejected(self):
        invalid = (("completed", "failure"), ("completed", "cancelled"), ("completed", "timed_out"),
                   ("completed", "skipped"), ("queued", None), ("in_progress", "failure"),
                   ("completed", None))
        for status, conclusion in invalid:
            self.api.responses["actions/runs/1234"].update(status=status, conclusion=conclusion)
            with self.subTest(status=status, conclusion=conclusion), self.assertRaises(ValueError):
                self.verify()

    def test_rerun_started_during_admission_invalidates_old_full_gate(self):
        run = self.api.responses["actions/runs/1234"]
        sequence = [copy.deepcopy(run), {**run, "run_attempt": 3}]
        self.api.responses["actions/runs/1234"] = lambda: sequence.pop(0)
        with self.assertRaisesRegex(ValueError, "changed during"):
            self.verify()

    def test_exact_full_and_site_jobs_steps_must_have_passed(self):
        invalid = ({"name": "Diagnostic scope passed"}, {"name": "Preflight scope passed"},
                   {"head_sha": OTHER}, {"run_id": 88}, {"run_attempt": 1},
                   {"conclusion": "cancelled"}, {"conclusion": "skipped"},
                   {"conclusion": "failure"}, {"status": "in_progress"}, {"steps": []},
                   {"steps": [{"name": publication.FULL_STEP, "status": "completed", "conclusion": "skipped"}]})
        for changes in invalid:
            self.api = FakeAPI()
            self.jobs[0].update(changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.verify()
        for conclusion in ("cancelled", "failure", "skipped"):
            self.api = FakeAPI()
            self.jobs[1]["conclusion"] = conclusion
            with self.subTest(site_conclusion=conclusion), self.assertRaises(ValueError):
                self.verify()

    def test_missing_and_duplicate_full_gates_cannot_publish(self):
        for replacement in ([], [job(103, publication.FULL_JOB, publication.FULL_STEP)]):
            self.api = FakeAPI()
            payload = self.api.responses["actions/runs/1234/attempts/2/jobs?per_page=100&page=1"]
            payload["jobs"] = self.jobs[1:] + replacement
            payload["total_count"] = len(payload["jobs"])
            if replacement:
                payload["jobs"].append(job(104, publication.FULL_JOB, publication.FULL_STEP))
                payload["total_count"] += 1
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                self.verify()

    def test_attempt_endpoint_may_omit_redundant_job_attempt_field(self):
        for entry in self.jobs:
            del entry["run_attempt"]
        self.assertEqual(self.verify()["status"], "verified")

    def test_jobs_pagination_is_complete_and_unambiguous(self):
        unrelated = [job(number, "Unrelated " + str(number), "Other") for number in range(1000, 1098)]
        payload = self.api.responses["actions/runs/1234/attempts/2/jobs?per_page=100&page=1"]
        second = payload["jobs"].pop()
        payload["jobs"] += unrelated + [job(2000, "Other", "Other")]
        payload["total_count"] = 101
        self.api.responses["actions/runs/1234/attempts/2/jobs?per_page=100&page=2"] = {
            "total_count": 101, "jobs": [second]}
        self.assertEqual(self.verify()["status"], "verified")

    def test_incomplete_or_duplicate_job_listing_is_rejected(self):
        payload = self.api.responses["actions/runs/1234/attempts/2/jobs?per_page=100&page=1"]
        payload["total_count"] = 3
        with self.assertRaises(ValueError):
            self.verify()
        payload["total_count"] = 2
        self.jobs[1]["id"] = self.jobs[0]["id"]
        with self.assertRaises(ValueError):
            self.verify()

    def test_stale_future_or_malformed_immutable_input_arguments_are_rejected(self):
        invalid = ({"producer_attempt": "1"}, {"producer_attempt": "3"},
                   {"artifact_id": "name"}, {"artifact_id": "01"}, {"artifact_digest": "sha256:bad"},
                   {"artifact_name": ARTIFACT_NAME.replace(REVISION, OTHER)},
                   {"artifact_name": ARTIFACT_NAME.replace("-2-t1", "-1-t1")},
                   {"artifact_name": ARTIFACT_NAME.replace("-t1", "-t4")})
        for changes in invalid:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.verify(**changes)

    def test_expired_wrong_run_fork_sha_digest_name_and_id_artifacts_are_rejected(self):
        invalid = ({"expired": True}, {"id": 77}, {"name": "other"}, {"digest": "sha256:" + "d" * 64},
                   {"workflow_run": {"id": 4321, "repository_id": 42, "head_repository_id": 42, "head_sha": REVISION}},
                   {"workflow_run": {"id": 1234, "repository_id": 42, "head_repository_id": 99, "head_sha": REVISION}},
                   {"workflow_run": {"id": 1234, "repository_id": 42, "head_repository_id": 42, "head_sha": OTHER}})
        for changes in invalid:
            self.api = FakeAPI()
            self.api.responses["actions/artifacts/56"].update(changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.verify()


class SiteExtractionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.archive = self.root / "site.tar.gz"
        self.output = self.root / "website"

    def create(self, extra=(), omit=(), marker=publication.MARKER_CONTENT):
        with tarfile.open(self.archive, "w:gz") as archive:
            for name in sorted(publication.REQUIRED_FILES - set(omit)):
                data = marker if name == publication.SITE_MARKER else b"<html>site</html>"
                member = tarfile.TarInfo("site/" + name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
            for member, data in extra:
                archive.addfile(member, io.BytesIO(data) if data is not None else None)

    def test_regular_site_routes_and_marker_are_extracted_to_fresh_output(self):
        self.create()
        result = publication.extract_site(self.archive, self.output)
        self.assertEqual(result["files"], 4)
        self.assertEqual((self.output / publication.SITE_MARKER).read_bytes(), publication.MARKER_CONTENT)
        self.assertTrue((self.output / "documentation/index.html").is_file())

    def test_missing_routes_or_invalid_marker_fail_before_extraction(self):
        for name in publication.REQUIRED_FILES:
            self.create(omit=[name])
            with self.subTest(name=name), self.assertRaises(ValueError):
                publication.extract_site(self.archive, self.output)
            self.assertFalse(self.output.exists())
        self.create(marker=b"untrusted")
        with self.assertRaises(ValueError):
            publication.extract_site(self.archive, self.output)
        self.assertFalse(self.output.exists())

    def test_traversal_absolute_aliased_duplicate_and_non_site_members_fail_closed(self):
        for name in ("../escape", "/site/absolute", "site/../escape", "site//double", "site/./dot",
                     "site\\windows", "other/file", "site/index.html", "site/documentation"):
            member = tarfile.TarInfo(name)
            member.size = 1
            self.create(extra=[(member, b"x")])
            with self.subTest(name=name), self.assertRaises(ValueError):
                publication.extract_site(self.archive, self.output)
            self.assertFalse(self.output.exists())

    def test_symbolic_hard_links_devices_and_fifo_members_fail_before_any_write(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.CHRTYPE, tarfile.BLKTYPE, tarfile.FIFOTYPE):
            member = tarfile.TarInfo("site/unsafe")
            member.type = kind
            member.linkname = "../escape"
            self.create(extra=[(member, None)])
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                publication.extract_site(self.archive, self.output)
            self.assertFalse(self.output.exists())

    def test_extraction_has_total_expansion_and_member_count_limits(self):
        self.create()
        with patch.object(publication, "MAX_SITE_BYTES", 1), self.assertRaises(ValueError):
            publication.extract_site(self.archive, self.output)
        with patch.object(publication, "MAX_SITE_MEMBERS", 1), self.assertRaises(ValueError):
            publication.extract_site(self.archive, self.output)
        self.assertFalse(self.output.exists())

    def test_existing_output_and_symlink_ancestors_or_archive_are_rejected(self):
        self.create()
        self.output.mkdir()
        with self.assertRaises(ValueError):
            publication.extract_site(self.archive, self.output)
        self.output.rmdir()
        linked = self.root / "linked"
        linked.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            publication.extract_site(self.archive, linked / "website")
        linked.unlink()
        linked.symlink_to(self.archive)
        with self.assertRaises(ValueError):
            publication.extract_site(linked, self.output)

    def test_corrupt_archive_does_not_create_partial_output(self):
        self.archive.write_bytes(b"not a tar")
        with self.assertRaises(ValueError):
            publication.extract_site(self.archive, self.output)
        self.assertFalse(self.output.exists())


class PublicationCLITests(unittest.TestCase):
    def test_cli_verifies_checkout_extracts_site_and_retains_reviewable_read_only_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "report.json"
            with patch.dict(os.environ, {"GITHUB_SHA": REVISION}), \
                    patch.object(publication.receipts, "execution_identity", return_value=execution()), \
                    patch.object(publication.github_release, "GitHubAPI", return_value=FakeAPI()), \
                    patch.object(publication.subprocess, "check_output", return_value=REVISION + "\n"), \
                    patch.object(publication, "extract_site", return_value={"files": 4, "bytes": 123}) as extract:
                result = publication.main(["--mode", "full", "--artifact-id", "56", "--artifact-digest", DIGEST,
                    "--artifact-name", ARTIFACT_NAME, "--producer-attempt", "2", "--output", str(output),
                    "--site-archive", str(root / "site.tar.gz"), "--site-output", str(root / "site")])
            self.assertEqual(result, 0)
            self.assertEqual(json.loads(output.read_text())["status"], "verified")
            extract.assert_called_once()

    def test_wrong_checkout_or_rejected_authority_never_extracts_or_publishes(self):
        for checkout in (OTHER, REVISION):
            with tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary) / "report.json"
                api = FakeAPI()
                api.responses["actions/runs/1234"]["conclusion"] = "cancelled"
                with patch.dict(os.environ, {"GITHUB_SHA": REVISION}), \
                        patch.object(publication.receipts, "execution_identity", return_value=execution()), \
                        patch.object(publication.github_release, "GitHubAPI", return_value=api), \
                        patch.object(publication.subprocess, "check_output", return_value=checkout + "\n"), \
                        patch.object(publication, "extract_site") as extract:
                    result = publication.main(["--mode", "full", "--artifact-id", "56", "--artifact-digest", DIGEST,
                        "--artifact-name", ARTIFACT_NAME, "--producer-attempt", "2", "--output", str(output),
                        "--site-archive", "site.tar.gz", "--site-output", "site"])
                self.assertEqual(result, 1)
                self.assertEqual(json.loads(output.read_text())["status"], "rejected")
                extract.assert_not_called()


if __name__ == "__main__":
    unittest.main()
