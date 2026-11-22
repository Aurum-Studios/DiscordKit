# copyright:begin
# File: Tools/ci/test_teamcity_native.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com
# copyright:end

"""Exercise grouped TeamCity tests' SwiftPM restore boundary."""

from pathlib import Path
import subprocess
import tempfile
import unittest

import teamcity_native


class TeamCityNativeTests(unittest.TestCase):
    def test_cleanup_preserves_teamcity_state_and_other_graphs(self):
        """A later root suite may restore the same archive without losing staged inputs or reports."""
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=repository, check=True)
            paths = [
                ".build/arm64-apple-macosx/debug/previous-test",
                ".build/teamcity/in/root.tar.gz",
                ".build/teamcity/out/evidence/check/root-01/result.json",
                "Packages/DiscordDSLMacros/.build/debug/compiled",
                "source.swift",
            ]
            for relative in paths:
                path = repository / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(relative)
            subprocess.run(["git", "add", "source.swift"], cwd=repository, check=True)

            teamcity_native.clean_check_outputs(repository, "root-02")

            self.assertFalse((repository / paths[0]).exists())
            for relative in paths[1:]:
                self.assertEqual((repository / relative).read_text(), relative)
