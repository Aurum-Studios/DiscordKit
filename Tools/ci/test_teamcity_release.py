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
PREPARE_CONFIG = "DiscordKit_PrepareRelease"
PUBLISH_CONFIG = "DiscordKit_PublishGitHubRelease"
RELEASE_ID = 41
REPOSITORY = github_release.GITHUB_REPOSITORY


def coverage(**changes):
    """Encode the attestation from the certified build with optional changes."""
    return json.dumps({"schemaVersion": 1, "status": "passed", "buildId": str(BUILD_ID),
                       "revision": REVISION, "documentationArchiveSHA256": "c" * 64,
                       "prerequisites": {"Linux": "23", "Mac": "24", "Windows": "25"},
                       **changes}).encode()


class TeamCityCertificationTests(unittest.TestCase):
    def setUp(self):
        """Stage TeamCity's selected certification inputs with a newer tooling checkout."""
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.repository = Path(temporary.name)
        self.receipt = self.repository / ".build/teamcity/in/certification/certification.json"
        self.receipt.parent.mkdir(parents=True)
        self.receipt.write_bytes(coverage())
        environment = patch.dict(os.environ, {
            "TEAMCITY_VCS_ROOT_ID": VCS_ROOT,
            "RELEASE_DEFAULT_BRANCH": "main",
            "TEAMCITY_BUILD_TYPE_ID": PREPARE_CONFIG,
            "TEAMCITY_DEFAULT_BRANCH": "true",
            "DISCORDKIT_VCS_REVISION": OTHER_REVISION,
            "TEAMCITY_CERTIFICATION_BUILD_ID": str(BUILD_ID),
            "TEAMCITY_CERTIFICATION_BUILD_NUMBER": BUILD_NUMBER,
            "TEAMCITY_CERTIFICATION_DEFAULT_BRANCH": "true",
            "TEAMCITY_CERTIFICATION_REVISION": REVISION,
        }, clear=True)
        environment.start()
        self.addCleanup(environment.stop)
        checkout = patch.object(teamcity_release.subprocess, "check_output", return_value=f"{OTHER_REVISION}\n")
        checkout.start()
        self.addCleanup(checkout.stop)

    def promoted(self, configuration=PREPARE_CONFIG):
        """Read the same-chain evidence as the specified release phase."""
        return teamcity_release.TeamCityCertification().promoted(self.repository, configuration)

    def test_selection_and_publication_revalidation_bind_same_build_revision_and_gate(self):
        """Use the historical dependency and its real build number in both release phases."""
        evidence = self.promoted()
        self.assertEqual(evidence, {
            "provider": "teamcity",
            "id": BUILD_ID,
            "number": BUILD_NUMBER,
            "buildTypeId": teamcity_release.CERTIFICATION_ID,
            "vcsRootId": VCS_ROOT,
            "branch": "main",
            "coverageSHA256": hashlib.sha256(coverage()).hexdigest(),
            "html_url": f"https://ci.aurum-studios.com/build/{BUILD_ID}",
            "head_sha": REVISION,
        })
        with patch.dict(os.environ, {"TEAMCITY_BUILD_TYPE_ID": PUBLISH_CONFIG}):
            self.assertEqual(self.promoted(PUBLISH_CONFIG), evidence)

    def test_promoted_dependency_requires_canonical_identity_and_default_branch(self):
        """Reject invalid, absent or unresolved values for TeamCity's selected dependency."""
        invalid = {
            "TEAMCITY_CERTIFICATION_BUILD_ID": ("0", "027", "%dep.build.id%"),
            "TEAMCITY_CERTIFICATION_BUILD_NUMBER": ("0", "07", "7.1"),
            "TEAMCITY_CERTIFICATION_DEFAULT_BRANCH": ("false", ""),
            "TEAMCITY_CERTIFICATION_REVISION": ("a" * 39, "A" * 40, "main"),
        }
        for name, values in invalid.items():
            for value in values:
                with self.subTest(name=name, value=value), patch.dict(os.environ, {name: value}):
                    with self.assertRaises(ValueError):
                        self.promoted()
        with patch.dict(os.environ):
            del os.environ["TEAMCITY_CERTIFICATION_BUILD_ID"]
            with self.assertRaises((KeyError, ValueError)):
                self.promoted()

    def test_incomplete_or_mismatched_coverage_is_refused(self):
        """Require a complete, matching receipt from the successful selected build."""
        alternatives = (
            coverage(schemaVersion=2),
            coverage(status="failed"),
            coverage(revision=OTHER_REVISION),
            coverage(buildId="13"),
            coverage(documentationArchiveSHA256="invalid"),
            coverage(prerequisites={}),
            coverage(prerequisites={"Linux": "23", "Mac": "23"}),
            coverage(prerequisites={"Linux": str(BUILD_ID)}),
        )
        for receipt in alternatives:
            with self.subTest(receipt=receipt):
                self.receipt.write_bytes(receipt)
                with self.assertRaisesRegex(ValueError, "complete coverage evidence"):
                    self.promoted()
        self.receipt.unlink()
        with self.assertRaises(OSError):
            self.promoted()

    def test_current_checkout_requires_actual_release_configuration_and_default_branch(self):
        """Refuse a release phase when its configuration, branch or checkout differs."""
        invalid = (
            {"TEAMCITY_BUILD_TYPE_ID": PUBLISH_CONFIG},
            {"TEAMCITY_DEFAULT_BRANCH": "false"},
            {"DISCORDKIT_VCS_REVISION": REVISION},
        )
        for changes in invalid:
            with self.subTest(changes=changes), patch.dict(os.environ, changes):
                with self.assertRaises(ValueError):
                    self.promoted()


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
