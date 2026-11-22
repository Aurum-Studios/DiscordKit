# File: Tools/ci/test_teamcity_pages.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Exercise certified Pages input admission and Git delivery using a local remote."""

import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import native_jobs
import teamcity_artifact_transport
import teamcity_pages as pages


class TeamCityPagesTests(unittest.TestCase):
    def setUp(self):
        """Prepare an exact local checkout, simulated TeamCity artifact, and bare Git remote."""
        workspace = tempfile.TemporaryDirectory()
        self.addCleanup(workspace.cleanup)
        self.root = Path(workspace.name).resolve()
        self.repository = self.root / "source"
        self.repository.mkdir()
        self.remote = self.root / "remote.git"
        self.git(self.repository, "init", "-q", "-b", "main", "--template=")
        self.git(self.repository, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "-q", "--allow-empty", "-m", "Certified revision")
        self.revision = self.git(self.repository, "rev-parse", "HEAD")
        self.git(self.root, "clone", "-q", "--bare", self.repository, self.remote)
        self.archive = self.root / pages.DOCC_TAR
        with tarfile.open(self.archive, "w:gz") as archive:
            raw = b'{}'
            member = tarfile.TarInfo(pages.DOCC_BUNDLE + "/metadata.json")
            member.size = len(raw)
            archive.addfile(member, io.BytesIO(raw))
        self.receipt = self.root / "certification.json"
        self.write_receipt(**{pages.DOCC_DIGEST: native_jobs.file_digest(self.archive)})

    def git(self, repository, *arguments):
        """Read or update only the isolated Git fixture."""
        return subprocess.check_output(["git", "-C", str(repository), *map(str, arguments)], text=True).strip()

    def write_receipt(self, **fields):
        """Store a candidate receipt with the supplied digest fields."""
        self.receipt.write_text(json.dumps({"schemaVersion": 1, "status": "passed",
                                           "buildId": "42", "revision": self.revision, **fields}))

    def transform(self, arguments, **kwargs):
        """Simulate DocC static transformation without network or compilation."""
        self.assertEqual(arguments[:3], ["test-docc", "process-archive", "transform-for-static-hosting"])
        self.assertEqual(arguments[-2:], ["--hosting-base-path", "/DiscordKit"])
        self.assertEqual((arguments[3] / "metadata.json").read_text(), "{}")
        self.assertNotIn("GH_TOKEN", kwargs["env"])
        site = arguments[5]
        (site / "documentation").mkdir(parents=True)
        (site / "documentation/index.html").write_text("<html>Verified DocC</html>")

    def publish(self, archive):
        """Exercise the normal publisher with a synthetic credential and local remote."""
        return pages.publish(self.repository, archive, self.receipt, self.revision, "42", "local-test-token",
                             remote=str(self.remote), docc="test-docc")

    def test_certified_split_archive_publishes_and_unchanged_run_reuses_commit(self):
        """Join native TeamCity parts, transform once per invocation, and publish idempotently."""
        parts = self.root / pages.DOCC_PARTS
        teamcity_artifact_transport.split(self.archive, parts, part_size=31)
        with patch.object(pages.subprocess, "run", side_effect=self.transform) as transform:
            published = self.publish(parts)
            repeated = self.publish(parts)
        self.assertEqual(transform.call_count, 2)
        self.assertEqual(published["status"], "published")
        self.assertEqual(repeated["status"], "unchanged")
        self.assertEqual(published["pagesCommit"], repeated["pagesCommit"])
        self.assertEqual(self.git(self.remote, "show", "gh-pages:documentation/index.html"),
                         "<html>Verified DocC</html>")

    def test_missing_or_wrong_digest_stops_before_docc_and_git_remote(self):
        """A passing candidate alone cannot authorize unrelated documentation bytes."""
        with (patch.object(pages, "checked_refs") as checked,
              patch.object(pages.subprocess, "run") as transform):
            self.write_receipt()
            with self.assertRaisesRegex(ValueError, "requires a valid documentation archive digest"):
                self.publish(self.archive)
            self.write_receipt(**{pages.DOCC_DIGEST: "0" * 64})
            with self.assertRaisesRegex(ValueError, "differs from its certification digest"):
                self.publish(self.archive)
            transform.assert_not_called()
            checked.assert_not_called()


if __name__ == "__main__":
    unittest.main()
