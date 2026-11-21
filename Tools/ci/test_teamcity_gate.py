# copyright:begin
# File: Tools/ci/test_teamcity_gate.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com
# copyright:end

"""Exercise TeamCity's candidate receipt and documentation artifact boundary."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import teamcity_gate as gate


class TeamCityGateTests(unittest.TestCase):
    def setUp(self):
        """Create a disposable candidate with two successful same-chain receipts."""
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.repo = Path(directory.name)
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        tracked = self.repo / "source"
        tracked.write_text("committed\n")
        self.git("add", "source")
        self.git("-c", "user.name=CI", "-c", "user.email=ci@example.invalid", "commit", "-qm", "candidate")
        self.revision = self.git("rev-parse", "HEAD").strip().decode()
        self.state = self.repo / gate.STATE
        self.artifact = self.state / "out/certification.json"
        for name, build in [("LinuxQualify", "10"), ("MacQualify", "11")]:
            with patch.dict(os.environ, self.identity(build)):
                gate.record(self.repo, name)
        (self.state / "out/receipts").rename(self.state / "in")
        receipts = self.state / "in/receipts"
        receipts.mkdir()
        for name in ("LinuxQualify", "MacQualify"):
            (self.state / f"in/{name}.json").rename(receipts / f"{name}.json")
        (self.state / "in/DiscordKitLibrary.doccarchive.tar.gz").write_bytes(b"DocC artifact")

    def git(self, *args):
        """Execute a Git operation in the isolated test checkout."""
        return subprocess.check_output(["git", *args], cwd=self.repo)

    def identity(self, build):
        """Represent the TeamCity parameters assigned to an individual test job."""
        return {"DISCORDKIT_VCS_REVISION": self.revision, "DISCORDKIT_CI_BUILD_ID": build}

    def test_certifies_complete_exact_candidate(self):
        """Emit a DocC archive digest and exact stage build IDs for the certified SHA."""
        with patch.dict(os.environ, self.identity("12")):
            gate.certify(self.repo, ["LinuxQualify=10", "MacQualify=11"])
        receipt = json.loads(self.artifact.read_text())
        self.assertEqual(receipt, {
            "schemaVersion": 1, "status": "passed", "buildId": "12", "revision": self.revision,
            "documentationArchiveSHA256": hashlib.sha256(b"DocC artifact").hexdigest(),
            "prerequisites": {"LinuxQualify": "10", "MacQualify": "11"},
        })

    def test_rejects_missing_misidentified_or_duplicate_prerequisites(self):
        """Withhold certification if TeamCity selected a different or incomplete chain."""
        for expected in (["LinuxQualify=10"], ["LinuxQualify=11", "MacQualify=10"],
                         ["LinuxQualify=10", "MacQualify=10"], ["LinuxQualify=%unresolved%"]):
            with self.subTest(expected=expected), patch.dict(os.environ, self.identity("12")):
                with self.assertRaises(ValueError):
                    gate.certify(self.repo, expected)
                self.assertFalse(self.artifact.exists())

    def test_rejects_modified_checkout(self):
        """Prevent a tracked mutation from acquiring a successful job receipt."""
        (self.repo / "source").write_text("modified\n")
        with patch.dict(os.environ, self.identity("12")), self.assertRaisesRegex(ValueError, "checkout"):
            gate.record(self.repo, "CheckSource")
        self.assertFalse((self.state / "out/receipts/CheckSource.json").exists())
