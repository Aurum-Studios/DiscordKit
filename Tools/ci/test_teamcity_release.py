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
from urllib.parse import quote

import github_release
import teamcity_release


REVISION = "a" * 40
OTHER_REVISION = "b" * 40
VCS_ROOT = "DiscordKit_GitHub"
BASE_VERSION = "1.2.3"
BUILD_NUMBER = "7"
VERSION = f"{BASE_VERSION}+{BUILD_NUMBER}"
TAG = f"v{VERSION}"
BUILD_ID = 27
PREPARE_ID = 28
PUBLISH_ID = 29
PREPARE_CONFIG = "DiscordKit_PrepareRelease"
PUBLISH_CONFIG = "DiscordKit_PublishGitHubRelease"
RELEASE_ID = 41
REPOSITORY = github_release.GITHUB_REPOSITORY


def build(**changes):
    """Return a successful certification with overrides for REST response tests."""
    return {
        "id": BUILD_ID,
        "number": BUILD_NUMBER,
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


def release_build(build_id=PREPARE_ID, configuration=PREPARE_CONFIG):
    """Return the running release job with a newer source checkout and its selected dependency."""
    dependencies = [{"id": BUILD_ID, "buildTypeId": teamcity_release.CERTIFICATION_ID}]
    if configuration == PUBLISH_CONFIG:
        dependencies.append({"id": PREPARE_ID, "buildTypeId": PREPARE_CONFIG})
    current = build(id=build_id, buildTypeId=configuration, state="running",
                    **{"snapshot-dependencies": {"build": dependencies}})
    current["revisions"]["revision"][0]["version"] = OTHER_REVISION
    return current


def coverage(**changes):
    """Encode the attestation from the certified build with optional changes."""
    return json.dumps({"schemaVersion": 1, "status": "passed", "buildId": str(BUILD_ID),
                       "revision": REVISION, "documentationArchiveSHA256": "c" * 64,
                       "prerequisites": {"Linux": "23", "Mac": "24", "Windows": "25"},
                       **changes}).encode()


class TeamCityCertificationTests(unittest.TestCase):
    def setUp(self):
        """Use a scripted TeamCity client and a pinned checkout revision."""
        environment = patch.dict(os.environ, {
            "TEAMCITY_URL": teamcity_release.TEAMCITY_URL,
            "TEAMCITY_TOKEN": "read-results",
            "TEAMCITY_VCS_ROOT_ID": VCS_ROOT,
            "RELEASE_DEFAULT_BRANCH": "main",
            "TEAMCITY_DEFAULT_BRANCH": "true",
            "DISCORDKIT_CI_BUILD_ID": str(PREPARE_ID),
        })
        environment.start()
        self.addCleanup(environment.stop)
        self.ci = teamcity_release.TeamCityCertification()
        self.ci.request = Mock()
        checkout = patch.object(teamcity_release.subprocess, "check_output", return_value=f"{OTHER_REVISION}\n")
        checkout.start()
        self.addCleanup(checkout.stop)

    def test_selection_and_publication_revalidation_bind_same_build_revision_and_gate(self):
        """Recheck the exact promoted build in both phases even when the checkout is newer."""
        self.ci.request.side_effect = [
            release_build(), build(), coverage(),
            release_build(PUBLISH_ID, PUBLISH_CONFIG), build(), coverage(),
        ]
        evidence = self.ci.promoted(Path("."), PREPARE_CONFIG)
        self.assertEqual(evidence["provider"], "teamcity")
        self.assertEqual(evidence["head_sha"], REVISION)
        self.assertEqual(evidence["id"], BUILD_ID)
        self.assertEqual(evidence["number"], BUILD_NUMBER)
        self.assertEqual(evidence["coverageSHA256"], hashlib.sha256(coverage()).hexdigest())
        with patch.dict(os.environ, {"DISCORDKIT_CI_BUILD_ID": str(PUBLISH_ID)}):
            self.assertEqual(self.ci.promoted(Path("."), PUBLISH_CONFIG), evidence)
        receipt_path = f"builds/id:{BUILD_ID}/artifacts/content/certification.json"
        self.assertEqual([call.args[0] for call in self.ci.request.call_args_list], [
            f"builds/id:{PREPARE_ID}", f"builds/id:{BUILD_ID}", receipt_path,
            f"builds/id:{PUBLISH_ID}", f"builds/id:{BUILD_ID}", receipt_path,
        ])
        self.assertIn("snapshot-dependencies(build(id,buildTypeId))",
                      self.ci.request.call_args_list[0].kwargs["fields"])
        self.assertIn("number", self.ci.request.call_args_list[1].kwargs["fields"].split(","))
        for call in self.ci.request.call_args_list[2::3]:
            self.assertEqual(call.kwargs, {"raw": True, "responseBuilder": "core"})

    def test_promoted_dependency_must_identify_one_certification(self):
        """Reject missing, ambiguous or mismatched certification dependencies without a receipt read."""
        selected = {"id": BUILD_ID, "buildTypeId": teamcity_release.CERTIFICATION_ID}
        alternatives = ([], [{"id": BUILD_ID, "buildTypeId": PREPARE_CONFIG}],
                        [selected, {**selected, "id": BUILD_ID - 1}], [{**selected, "id": 0}])
        for dependencies in alternatives:
            with self.subTest(dependencies=dependencies):
                current = release_build()
                current["snapshot-dependencies"]["build"] = dependencies
                self.ci.request.reset_mock()
                self.ci.request.side_effect = [current]
                with self.assertRaises(ValueError):
                    self.ci.promoted(Path("."), PREPARE_CONFIG)
                self.ci.request.assert_called_once()

    def test_only_successful_default_branch_certification_with_canonical_build_number_is_accepted(self):
        """Refuse a selected build that does not represent a successful certification of main."""
        runs = [build(defaultBranch=False), build(buildTypeId="DiscordKit_PullRequest"),
                build(state="running"), build(status="FAILURE"),
                build(personal=True), build(failedToStart=True), build(canceledInfo={"text": "Canceled"}),
                build(number=7), build(number=""), build(number="0"), build(number="7.1"),
                build(number="07"), build(id=BUILD_ID - 1)]
        for key, value in (("vcsBranchName", "refs/pull/10/head"), ("version", "abbreviated"),
                           ("vcs-root-instance", {"vcs-root-id": "Other_Root"})):
            wrong = build()
            wrong["revisions"]["revision"][0][key] = value
            runs.append(wrong)
        for selected in runs:
            with self.subTest(selected=selected):
                self.ci.request.reset_mock()
                self.ci.request.side_effect = [release_build(), selected]
                with self.assertRaises(ValueError):
                    self.ci.promoted(Path("."), PREPARE_CONFIG)
                self.assertEqual(self.ci.request.call_count, 2)

    def test_incomplete_or_mismatched_coverage_is_refused(self):
        """Require an intact receipt attesting to both the selected build ID and revision."""
        for receipt in (coverage(status="failed"), coverage(revision=OTHER_REVISION),
                        coverage(buildId="13"), coverage(prerequisites={})):
            with self.subTest(receipt=receipt):
                self.ci.request.side_effect = [release_build(), build(), receipt]
                with self.assertRaisesRegex(ValueError, "complete coverage evidence"):
                    self.ci.promoted(Path("."), PREPARE_CONFIG)

    def test_current_checkout_requires_actual_release_configuration_and_default_branch(self):
        """Trust only the active release configuration's own default-branch checkout."""
        current = release_build()
        self.ci.request.return_value = current
        self.assertEqual(self.ci.require_current_checkout(Path("."), PREPARE_CONFIG), current)
        with self.assertRaisesRegex(ValueError, "current TeamCity default-branch checkout"):
            self.ci.require_current_checkout(Path("."), PUBLISH_CONFIG)
        with patch.dict(os.environ, {"TEAMCITY_DEFAULT_BRANCH": "false"}):
            with self.assertRaisesRegex(ValueError, "Run the release"):
                self.ci.require_current_checkout(Path("."), PREPARE_CONFIG)


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
        if path == f"git/ref/tags/{quote(TAG, safe='')}":
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
        """Stage isolated fixtures for the version derived from the promoted build."""
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name)
        self.api = InMemoryGitHub()
        self.evidence = {"provider": "teamcity", "id": BUILD_ID, "number": BUILD_NUMBER,
                         "buildTypeId": teamcity_release.CERTIFICATION_ID, "vcsRootId": VCS_ROOT,
                         "branch": "main", "html_url": f"https://ci.aurum-studios.com/build/{BUILD_ID}",
                         "head_sha": REVISION, "coverageSHA256": hashlib.sha256(coverage()).hexdigest()}
        self.assets = tuple(self.output / f"DiscordKit-{BASE_VERSION}-build.{BUILD_NUMBER}-source{suffix}"
                            for suffix in (".tar.gz", ".tar.gz.sha256", ".json"))
        for asset in self.assets:
            asset.write_text(asset.name)

    def publish(self):
        github_release.publish_teamcity_release(self.api, VERSION, REVISION, self.assets, self.evidence)

    def test_draft_is_published_only_after_all_three_assets_have_verified(self):
        """Read back the metadata-bearing tag and the exact three asset names before publishing."""
        self.publish()
        self.assertFalse(self.api.draft["draft"])
        self.assertEqual(self.api.tag["object"]["sha"], REVISION)
        self.assertEqual(self.api.tag["ref"], f"refs/tags/{TAG}")
        self.assertEqual(self.api.draft["tag_name"], TAG)
        self.assertEqual(self.api.draft["name"], f"DiscordKit {VERSION}")
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

    def test_prepare_packages_revision_and_number_from_promoted_certification(self):
        """Use only the promoted dependency to choose the source commit and version suffix."""
        teamcity = Mock(branch="main")
        teamcity.promoted.return_value = self.evidence
        with patch.object(github_release, "require_commit") as require_commit, \
                patch("package_release.package_release", return_value=self.assets) as package:
            self.assertEqual(github_release.prepare(self.output, self.output, f"v{BASE_VERSION}",
                                                   self.api, teamcity), self.assets)
        teamcity.promoted.assert_called_once_with(self.output, PREPARE_CONFIG)
        require_commit.assert_called_once_with(self.output, REVISION)
        package.assert_called_once_with(self.output, self.output, VERSION, REVISION, self.evidence)
        self.assertEqual(self.api.writes, [])

    def write_manifest(self):
        """Seal the staged archive with the selected certification and its checksum."""
        archive, checksum, manifest = self.assets
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        checksum.write_text(f"{digest}  {archive.name}\n")
        metadata = {"schemaVersion": 2, "format": "swiftpm-source", "version": VERSION, "tag": TAG,
                    "revision": REVISION, "archive": archive.name, "sha256": digest, "ciRun": self.evidence}
        manifest.write_text(json.dumps(metadata))

    def test_no_publication_occurs_if_promoted_certification_has_changed(self):
        """Reject an altered receipt or a different selected run even when the version matches."""
        self.write_manifest()
        alternatives = ({"coverageSHA256": "e" * 64}, {"id": BUILD_ID - 1})
        for changes in alternatives:
            with self.subTest(changes=changes), patch.object(github_release, "require_commit"):
                teamcity = Mock(branch="main")
                teamcity.promoted.return_value = {**self.evidence, **changes}
                with self.assertRaisesRegex(ValueError, "no longer valid"):
                    github_release.publish(self.output, self.output, BASE_VERSION, self.api, teamcity)
                teamcity.promoted.assert_called_once_with(self.output, PUBLISH_CONFIG)
                self.assertEqual(self.api.writes, [])

    def test_publish_accepts_sealed_release_with_same_promoted_certification(self):
        """Publish the sealed artifacts after confirming their current TeamCity provenance."""
        self.write_manifest()
        teamcity = Mock(branch="main")
        teamcity.promoted.return_value = self.evidence
        with patch.object(github_release, "require_commit"):
            github_release.publish(self.output, self.output, BASE_VERSION, self.api, teamcity)
        teamcity.promoted.assert_called_once_with(self.output, PUBLISH_CONFIG)
        self.assertFalse(self.api.draft["draft"])
        self.assertEqual(self.api.draft["tag_name"], TAG)

    def test_manifest_with_teamcity_evidence_uses_version_two(self):
        """Preserve the version suffix in the release manifest and read sanitized asset names."""
        self.write_manifest()
        self.assertEqual(github_release.verify_assets(self.output, VERSION, REVISION), (self.assets, self.evidence))


if __name__ == "__main__":
    unittest.main()
