# copyright:begin
# File: Tools/ci/test_teamcity_pipeline.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com
# copyright:end

"""Exercise clean source identity, failure and split-file publication for TeamCity jobs."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import teamcity_pipeline as pipeline


@unittest.skipIf(os.name == "nt", "Pipeline jobs run under Bash, including on Windows WSL")
class TeamCityPipelineTests(unittest.TestCase):
    """Use disposable Git checkouts and short shell jobs instead of hosted agents."""

    def setUp(self):
        """Create one exact candidate and one incoming same-chain artifact."""
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.repository = Path(directory.name).resolve()
        self.git("init", "-q")
        self.source = self.repository / "source"
        self.source.write_text("candidate\n")
        self.git("add", "source")
        self.git("-c", "user.name=CI", "-c", "user.email=ci@example.invalid", "commit", "-qm", "candidate")
        self.revision = self.git("rev-parse", "HEAD").strip()
        self.state = self.repository / pipeline.STATE
        self.output = self.state / "out"
        self.artifacts = self.output / "pipeline/Documentation"
        self.receipt = self.artifacts / "receipts/Documentation.json"
        self.incoming = self.state / "in/archive.part-001"
        self.incoming.parent.mkdir(parents=True)
        self.incoming.write_bytes(b"current DocC input")

    def git(self, *arguments):
        """Run Git only in the test's disposable checkout."""
        return subprocess.check_output(["git", *arguments], cwd=self.repository, text=True)

    def run_job(self, command, *patterns, build="81", timeout=5):
        """Invoke a bounded job with the exact or explicitly overridden build identity."""
        environment = {"CI": "true", "DISCORDKIT_VCS_REVISION": self.revision, "DISCORDKIT_CI_BUILD_ID": build}
        with patch.dict(os.environ, environment):
            pipeline.run_job(self.repository, "Documentation", timeout, patterns, command)

    def test_stages_regular_parts_and_exact_receipt(self):
        """Keep current inputs and relative paths while uploading individual output files."""
        self.run_job(f"""
            mkdir -p {pipeline.STATE}/out/archive-parts
            cp {pipeline.STATE}/in/archive.part-001 {pipeline.STATE}/out/archive-parts/archive.part-001
            printf second > {pipeline.STATE}/out/archive-parts/archive.part-002
        """, "archive-parts", "archive-parts/archive.part-002")
        self.assertEqual(self.incoming.read_bytes(), b"current DocC input")
        self.assertEqual((self.artifacts / "archive-parts/archive.part-001").read_bytes(), self.incoming.read_bytes())
        self.assertEqual((self.artifacts / "archive-parts/archive.part-002").read_bytes(), b"second")
        self.assertEqual(json.loads(self.receipt.read_text()), {"schemaVersion": 1, "buildId": "81",
            "revision": self.revision, "job": "Documentation", "status": "passed"})
        self.assertTrue((self.artifacts / "runner.log").is_file())

    def test_failed_retry_discards_old_outputs_and_retains_current_diagnostics(self):
        """Publish current diagnostics without the success receipt or archive from an earlier run."""
        self.run_job(f"touch {pipeline.STATE}/out/archive.part-001", "archive.part-001")
        self.assertTrue(self.receipt.is_file())
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_job(f"printf failed > {pipeline.STATE}/out/evidence; exit 7", "evidence", "archive.part-001",
                         build="82")
        self.assertFalse(self.receipt.exists())
        self.assertFalse((self.artifacts / "archive.part-001").exists())
        self.assertEqual((self.artifacts / "evidence").read_text(), "failed")
        self.assertEqual(json.loads((self.artifacts / "runner.receipt.json").read_text())["exitCode"], 7)

    def test_times_out_and_withholds_receipt(self):
        """Stop a blocking child and keep its supervisor evidence as a failed attempt."""
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_job("sleep 20", timeout=0.3)
        self.assertFalse(self.receipt.exists())
        self.assertEqual(json.loads((self.artifacts / "runner.receipt.json").read_text())["status"], "failed")

    def test_rejects_modified_candidate_before_cleaning(self):
        """Leave local files intact if tracked source differs from the assigned candidate."""
        self.source.write_text("uncommitted\n")
        untracked = self.repository / "untracked"
        untracked.write_text("keep\n")
        with self.assertRaisesRegex(ValueError, "checkout"):
            self.run_job("exit 0")
        self.assertTrue(untracked.is_file())
        self.assertFalse(self.artifacts.exists())

    def test_failed_publication_has_no_receipt(self):
        """Reject missing output and symlinks without recording a successful job."""
        for command, message in (("exit 0", "Missing pipeline artifacts"),
                                 (f"ln -s ../../../../source {pipeline.STATE}/out/part", "Unexpected pipeline artifact")):
            with self.subTest(command=command), self.assertRaisesRegex(ValueError, message):
                self.run_job(command, "part")
            self.assertFalse(self.receipt.exists())
