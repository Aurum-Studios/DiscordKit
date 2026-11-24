# File: Tools/ci/test_teamcity_release.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Verify release certification and GitHub publication without remote writes."""

import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import github_release
import teamcity_release


REVISION = "a" * 40
OTHER_REVISION = "b" * 40
VCS_ROOT = "DiscordKit_GitHub"
VERSION = "1.2.3"
TAG = f"v{VERSION}"
BUILD_ID = 27
RELEASE_ID = 41
REPOSITORY = github_release.GITHUB_REPOSITORY


def build(**changes):
    return {
        "id": BUILD_ID,
        "buildTypeId": teamcity_release.CERTIFICATION_ID,
        "defaultBranch": True,
        "state": "finished",
        "status": "SUCCESS",
        "revisions": {"revision": [{
            "vcs-root-instance": {"vcs-root-id": VCS_ROOT},
            "vcsBranchName": "refs/heads/main",
            "version": REVISION,
        }]},
        **changes,
    }


def coverage(**changes):
    return json.dumps({"schemaVersion": 1, "status": "passed", "buildId": str(BUILD_ID),
                       "revision": REVISION, "documentationArchiveSHA256": "c" * 64,
                       "prerequisites": {"Linux": "23", "Mac": "24", "Windows": "25"},
                       **changes}).encode()


class TeamCityCertificationTests(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(os.environ, {
            "TEAMCITY_URL": teamcity_release.TEAMCITY_URL,
            "TEAMCITY_TOKEN": "read-results",
            "TEAMCITY_VCS_ROOT_ID": VCS_ROOT,
            "RELEASE_DEFAULT_BRANCH": "main",
            "TEAMCITY_DEFAULT_BRANCH": "true",
            "DISCORDKIT_CI_BUILD_ID": str(BUILD_ID),
        })
        environment.start()
        self.addCleanup(environment.stop)
        self.ci = teamcity_release.TeamCityCertification()
        self.ci.request = Mock()

    def test_selection_and_publication_revalidation_bind_same_build_revision_and_gate(self):
        """Bind the receipt and both release phases to the same build through TeamCity."""
        self.ci.request.side_effect = [
            {"build": [build(defaultBranch=False), build()], "nextHref": None},
            coverage(),
            build(),
            coverage(),
        ]
        evidence = self.ci.find(REVISION)
        self.assertEqual(evidence["provider"], "teamcity")
        self.assertEqual(evidence["head_sha"], REVISION)
        self.assertEqual(evidence["id"], BUILD_ID)
        self.assertEqual(evidence["coverageSHA256"], hashlib.sha256(coverage()).hexdigest())
        self.assertIn("revision:(version:", self.ci.request.call_args_list[0].kwargs["locator"])
        self.assertEqual(self.ci.verify(evidence, REVISION), evidence)
        for call in self.ci.request.call_args_list[1::2]:
            self.assertEqual(call.args, (f"builds/id:{BUILD_ID}/artifacts/content/certification.json",))
            self.assertEqual(call.kwargs, {"raw": True, "responseBuilder": "core"})

    def test_filtered_builds_cannot_certify_partial_nondefault_unfinished_wrong_root_or_wrong_revision(self):
        runs = [build(defaultBranch=False), build(buildTypeId="DiscordKit_PullRequest"),
                build(state="running"), build(status="FAILURE"),
                build(personal=True), build(failedToStart=True), build(canceledInfo={"text": "Canceled"})]
        for key, value in (("vcsBranchName", "refs/pull/10/head"), ("version", OTHER_REVISION),
                           ("vcs-root-instance", {"vcs-root-id": "Other_Root"})):
            wrong = build()
            wrong["revisions"]["revision"][0][key] = value
            runs.append(wrong)
        self.ci.request.return_value = {"build": runs}
        with self.assertRaisesRegex(ValueError, "No successful TeamCity"):
            self.ci.find(REVISION)
        self.ci.request.assert_called_once()

    def test_incomplete_or_changed_coverage_cannot_publish(self):
        for receipt in (coverage(status="failed"), coverage(revision=OTHER_REVISION),
                        coverage(buildId="13"), coverage(prerequisites={})):
            with self.subTest(receipt=receipt):
                self.ci.request.side_effect = [{"build": [build()]}, receipt]
                with self.assertRaisesRegex(ValueError, "complete coverage evidence"):
                    self.ci.find(REVISION)
        self.ci.request.side_effect = [coverage(), build(), coverage(prerequisites={"Linux": "40"})]
        evidence = self.ci.evidence(build(), REVISION)
        with self.assertRaisesRegex(ValueError, "no longer valid"):
            self.ci.verify(evidence, REVISION)

    def test_current_checkout_requires_actual_release_configuration_and_default_branch(self):
        self.ci.request.return_value = build(buildTypeId="DiscordKit_PrepareRelease", state="running")
        with patch.object(teamcity_release.subprocess, "check_output", return_value=f"{REVISION}\n"):
            self.ci.require_current_checkout(Path("."), "DiscordKit_PrepareRelease")
            with self.assertRaisesRegex(ValueError, "current TeamCity default-branch checkout"):
                self.ci.require_current_checkout(Path("."), "DiscordKit_PublishGitHubRelease")
            with patch.dict(os.environ, {"TEAMCITY_DEFAULT_BRANCH": "false"}):
                with self.assertRaisesRegex(ValueError, "Run the release"):
                    self.ci.require_current_checkout(Path("."), "DiscordKit_PrepareRelease")


class InMemoryGitHub:
    """Record only the repository and release calls expected during publication."""

    repository = REPOSITORY

    def __init__(self):
        self.tag = None
        self.available = []
        self.writes = []
        self.draft = None
        self.upload_host = "https://uploads.github.com"
        self.upload_state = "uploaded"
        self.tip = OTHER_REVISION
        self.main_status = "ahead"

    def request(self, path, data=None, missing_ok=False, method=None):
        if path == "":
            return {"full_name": REPOSITORY, "default_branch": "main"}
        if path == "git/ref/heads/main":
            return {"ref": "refs/heads/main", "object": {"type": "commit", "sha": self.tip}}
        if path == f"compare/{REVISION}...{OTHER_REVISION}?per_page=1":
            return {"status": self.main_status, "merge_base_commit": {"sha": REVISION}}
        if path == f"git/ref/tags/{TAG}":
            return self.tag
        if path == "releases?per_page=100&page=1":
            return [] if self.draft is None else [self.draft]
        if path == f"releases/{RELEASE_ID}/assets?per_page=100":
            return self.available
        if path == f"releases/{RELEASE_ID}" and data is None:
            return self.draft
        self.writes.append((path, method))
        if path == "git/refs":
            self.tag = {"ref": data["ref"], "object": {"type": "commit", "sha": data["sha"]}}
            return self.tag
        if path == "releases":
            self.draft = {**data, "id": RELEASE_ID, "upload_url": (
                f"{self.upload_host}/repos/{REPOSITORY}/releases/{RELEASE_ID}/assets{{?name,label}}")}
            return self.draft
        if path == f"releases/{RELEASE_ID}" and method == "PATCH":
            self.draft.update(data)
            return self.draft
        raise AssertionError(f"Unexpected GitHub request: {path}")

    def upload(self, release_id, asset, content_type):
        self.writes.append((f"asset:{release_id}:{asset.name}", None))
        self.available.append({"name": asset.name, "size": asset.stat().st_size,
                               "state": self.upload_state,
                               "digest": f"sha256:{hashlib.sha256(asset.read_bytes()).hexdigest()}"})


class TeamCityPublicationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name)
        self.api = InMemoryGitHub()
        self.evidence = {"provider": "teamcity", "branch": "main", "html_url": "https://ci.aurum-studios.com/build/27"}
        self.assets = tuple(self.output / f"DiscordKit-{VERSION}-source{suffix}"
                            for suffix in (".tar.gz", ".tar.gz.sha256", ".json"))
        for asset in self.assets:
            asset.write_text(asset.name)

    def publish(self):
        github_release.publish_teamcity_release(self.api, VERSION, REVISION, self.assets, self.evidence)

    def test_draft_is_published_only_after_all_three_assets_have_verified(self):
        self.publish()
        self.assertFalse(self.api.draft["draft"])
        self.assertEqual(self.api.tag["object"]["sha"], REVISION)
        self.assertEqual(self.api.writes, [("git/refs", None), ("releases", None),
                         *[(f"asset:{RELEASE_ID}:{asset.name}", None) for asset in self.assets],
                         (f"releases/{RELEASE_ID}", "PATCH")])

    def test_conflict_or_interrupted_upload_never_replaces_tag_or_release(self):
        self.api.upload_state = "starter"
        with self.assertRaisesRegex(ValueError, "complete a release asset"):
            self.publish()
        previous_writes = list(self.api.writes)
        self.assertTrue(self.api.draft["draft"])
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.publish()
        self.assertEqual(self.api.writes, previous_writes)

    def test_foreign_upload_location_is_never_contacted(self):
        self.api.upload_host = "https://example.invalid"
        with self.assertRaisesRegex(ValueError, "unexpected release asset upload endpoint"):
            self.publish()
        self.assertEqual(self.api.writes, [("git/refs", None), ("releases", None)])

    def test_rewritten_default_branch_leaves_prepared_assets_in_draft(self):
        self.api.main_status = "diverged"
        with self.assertRaisesRegex(ValueError, "no longer on GitHub's default branch"):
            self.publish()
        self.assertTrue(self.api.draft["draft"])
        self.assertNotIn((f"releases/{RELEASE_ID}", "PATCH"), self.api.writes)

    def test_preparation_can_read_public_github_repository_without_a_token(self):
        """Allow public metadata reads during preparation and require a token for publishing."""
        with patch.dict(os.environ, {"GITHUB_REPOSITORY": REPOSITORY}, clear=True):
            client = github_release.GitHubAPI(teamcity=True, allow_anonymous=True)
            with patch.object(client, "open", return_value=io.StringIO("{}")) as request:
                client.request("")
                self.assertIsNone(request.call_args.args[0].get_header("Authorization"))
            with self.assertRaisesRegex(ValueError, "build-scoped GitHub release credential"):
                github_release.GitHubAPI(teamcity=True)

    def test_teamcity_publication_uses_the_build_token_for_all_writes(self):
        """Reject legacy-only credentials and ignore them when a build token is present."""
        with patch.dict(os.environ, {"GITHUB_REPOSITORY": REPOSITORY,
                                     "RELEASE_TOKEN": "legacy-token"}, clear=True):
            with self.assertRaisesRegex(ValueError, "build-scoped GitHub release credential"):
                github_release.GitHubAPI(teamcity=True)
            with patch.dict(os.environ, {"GH_TOKEN": "build-token"}):
                client = github_release.GitHubAPI(teamcity=True)
                responses = [io.StringIO("{}"), io.StringIO("{}")]
                with patch.object(client, "open", side_effect=responses) as request:
                    client.request("git/refs", {"sha": REVISION})
                    client.upload(RELEASE_ID, self.assets[0], "application/gzip")
        self.assertEqual(
            [call.args[0].get_header("Authorization") for call in request.call_args_list],
            ["Bearer build-token", "Bearer build-token"],
        )

    def test_no_publication_occurs_without_the_recorded_teamcity_certification(self):
        teamcity = Mock(branch="main")
        teamcity.verify.side_effect = ValueError("Recorded TeamCity certification is no longer valid")
        with patch.object(github_release, "require_commit"), \
                patch.object(github_release, "verify_assets", return_value=(self.assets, self.evidence)):
            with self.assertRaisesRegex(ValueError, "no longer valid"):
                github_release.publish(self.output, self.output, VERSION, REVISION, self.api, teamcity)
        self.assertEqual(self.api.writes, [])

    def test_manifest_with_teamcity_evidence_uses_version_two(self):
        archive, checksum, manifest = self.assets
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        checksum.write_text(f"{digest}  {archive.name}\n")
        metadata = {"schemaVersion": 2, "format": "swiftpm-source", "version": VERSION, "tag": TAG,
                    "revision": REVISION, "archive": archive.name, "sha256": digest, "ciRun": self.evidence}
        manifest.write_text(json.dumps(metadata))
        self.assertEqual(github_release.verify_assets(self.output, VERSION, REVISION), (self.assets, self.evidence))


if __name__ == "__main__":
    unittest.main()
