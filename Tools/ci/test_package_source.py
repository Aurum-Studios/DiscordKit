# File: Tools/ci/test_package_source.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Exercise real Git archives and SwiftPM layout without a compiler or network."""

from contextlib import contextmanager, ExitStack, redirect_stdout
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import package_source


class SourcePackageTests(unittest.TestCase):
    """Require exact source, complete package relationships and no local state."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repository = Path(self.temporary.name) / "repository with spaces"
        self.repository.mkdir()
        self.output = self.repository / ".build/packages"
        self.tracked = {
            ".gitignore": ".build/\ncredentials.txt\n",
            "Package.swift": "// root package\n",
            "Package.resolved": '{"pins": []}\n',
            "Sources/DiscordKit/DiscordKit.swift": "// library\n",
            "Tests/Fixtures/sample.json": "{}\n",
            "Packages/DiscordDSLMacros/Package.swift": '// path: "../.."\n',
            "Packages/DiscordDSLMacros/Package.resolved": '{"pins": []}\n',
            "Packages/DiscordDSLExtensions/Package.swift": '// path: "../.."\n',
            "LICENSE": "License terms\n",
            "NOTICE": "DiscordKit\nCreated by Carson Rau.\nCopyright (c) 2026 Aurum Studios.\n",
            "AUTHORS.md": "Carson Rau\n",
            "COPYRIGHT": "Copyright (c) 2026 Aurum Studios.\n",
            "Licenses/dependency.txt": "Dependency terms\n",
            "THIRD_PARTY_NOTICES.md": "Attribution\n",
            ".air/private-plan.md": "Private task data\n",
        }
        for relative, content in self.tracked.items():
            path = self.repository / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        self.run_git("init", "--quiet")
        self.run_git("add", ".")
        self.run_git("-c", "user.name=CI test", "-c", "user.email=ci@example.invalid",
                     "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "fixture")
        self.check_output = subprocess.check_output
        self.revision = self.run_git("rev-parse", "HEAD").decode().strip()
        environment = patch.dict(os.environ, {"GITHUB_SHA": self.revision,
                                             "GITHUB_RUN_ID": "42", "GITHUB_RUN_ATTEMPT": "2"})
        environment.start()
        self.addCleanup(environment.stop)

    def run_git(self, *arguments):
        return subprocess.check_output(["git", "-C", str(self.repository), *arguments])

    @contextmanager
    def native_environment(self, native_platform, *, system=None, machine=None, triple=None):
        """Simulate host/compiler facts while Git still creates and inspects real archives."""
        expected_system, expected_machine, expected_triple = {
            "linux-x64": ("Linux", "x86_64", "x86_64-unknown-linux-gnu"),
            "macos-arm64": ("Darwin", "arm64", "arm64-apple-macosx26.0"),
            "windows-x64": ("Windows", "AMD64", "x86_64-unknown-windows-msvc"),
        }[native_platform]
        selected_triple = triple or expected_triple

        def compiler_output(command, **kwargs):
            if command == ["swift", "-print-target-info"]:
                return json.dumps({"target": {"triple": selected_triple}})
            if command == ["swift", "--version"]:
                return f"Swift version 6.4.1\nTarget: {selected_triple}\n"
            return self.check_output(command, **kwargs)

        with ExitStack() as patches:
            patches.enter_context(patch("package_source.subprocess.check_output", side_effect=compiler_output))
            patches.enter_context(patch("package_source.platform.system", return_value=system or expected_system))
            patches.enter_context(patch("package_source.platform.machine", return_value=machine or expected_machine))
            patches.enter_context(patch("package_source.platform.release", return_value="native release"))
            patches.enter_context(patch("package_source.platform.version", return_value="native version"))
            linux = patches.enter_context(patch("package_source.platform.freedesktop_os_release",
                return_value={"ID": "ubuntu", "VERSION_ID": "24.04"}))
            macos = patches.enter_context(patch("package_source.platform.mac_ver", return_value=("26.0", (), "arm64")))
            windows = patches.enter_context(patch("package_source.platform.win32_ver",
                return_value=("2025Server", "10.0.26100", "", "Multiprocessor Free")))
            yield selected_triple, (linux, macos, windows)

    def test_archive_preserves_source_and_pins_with_revision_and_checksum(self):
        """Extract actual packaged bytes; ignored/untracked/private files stay out."""
        (self.repository / "credentials.txt").write_text("local credential")
        (self.repository / "untracked.swift").write_text("local source")
        expected = {f"DiscordKit/{path}": content for path, content in self.tracked.items()
                    if not path.startswith(".air/")}
        source_archives = []
        for native_platform in package_source.PLATFORMS:
            with self.subTest(native_platform=native_platform), self.native_environment(native_platform) as (triple, host_queries):
                output = self.output / native_platform
                archive, checksum, manifest = package_source.package_source(self.repository, output, native_platform)
                first = archive.read_bytes()
                package_source.package_source(self.repository, output, native_platform)
                self.assertEqual(first, archive.read_bytes())
                source_archives.append(first)
                digest = hashlib.sha256(first).hexdigest()
                self.assertEqual(checksum.read_text(), f"{digest}  {archive.name}\n")
                metadata = json.loads(manifest.read_text())
                self.assertEqual(metadata["schemaVersion"], 2)
                self.assertEqual(metadata["revision"], self.revision)
                self.assertEqual(metadata["sha256"], digest)
                self.assertEqual(metadata["archive"], archive.name)
                self.assertEqual(metadata["targetTriple"], triple)
                self.assertEqual(metadata["platform"], native_platform)
                self.assertEqual((metadata["runID"], metadata["runAttempt"]), ("42", "2"))
                suffix = "linux-source" if native_platform == "linux-x64" else f"{native_platform}-source"
                self.assertEqual(archive.name, f"DiscordKit-{self.revision}-{suffix}.tar.gz")
                host = metadata["host"]
                self.assertEqual(host["system"], package_source.PLATFORMS[native_platform][0])
                self.assertEqual(host["release"], "native release")
                if native_platform == "linux-x64":
                    self.assertEqual(host["distribution"], {"ID": "ubuntu", "VERSION_ID": "24.04"})
                elif native_platform == "macos-arm64":
                    self.assertEqual(host["macOSVersion"], "26.0")
                else:
                    self.assertEqual(host["windows"]["version"], "10.0.26100")
                for query, query_platform in zip(host_queries, package_source.PLATFORMS):
                    self.assertEqual(query.call_count, 2 if query_platform == native_platform else 0)
                with tarfile.open(archive) as bundle:
                    files = {member.name: bundle.extractfile(member).read().decode()
                             for member in bundle.getmembers() if member.isfile()}
                self.assertEqual(files, expected)
        self.assertTrue(all(source == source_archives[0] for source in source_archives))

    def test_linux_api_default_preserves_existing_archive_name(self):
        """Existing Linux callers keep their default behavior and archive convention."""
        with self.native_environment("linux-x64"):
            archive, _, manifest = package_source.package_source(self.repository, self.output)
        self.assertEqual(archive.name, f"DiscordKit-{self.revision}-linux-source.tar.gz")
        self.assertEqual(json.loads(manifest.read_text())["platform"], "linux-x64")

    def test_cli_exports_the_explicit_platform(self):
        """The workflow CLI forwards --platform rather than defaulting every export to Linux."""
        arguments = ["package_source.py", "--repository", str(self.repository),
                     "--output", str(self.output), "--platform", "windows-x64"]
        with self.native_environment("windows-x64"), patch.object(sys, "argv", arguments), redirect_stdout(io.StringIO()) as printed:
            package_source.main()
        self.assertEqual(len(printed.getvalue().splitlines()), 3)
        manifest, = self.output.glob("*.json")
        self.assertEqual(json.loads(manifest.read_text())["platform"], "windows-x64")

    def test_dirty_tracked_source_is_rejected(self):
        """Both unstaged and staged changes must never be mislabeled as tested HEAD."""
        (self.repository / "Package.swift").write_text("changed\n")
        for staged in [False, True]:
            if staged:
                self.run_git("add", "Package.swift")
            with self.assertRaisesRegex(ValueError, "clean tracked checkout"):
                package_source.package_source(self.repository, self.output)
        self.assertFalse(self.output.exists())

    def test_foreign_compiler_targets_are_rejected(self):
        """Both target OS and architecture must match the requested source-package label."""
        cases = [("linux-x64", "x86_64-apple-macosx26.0"),
                 ("linux-x64", "aarch64-unknown-linux-gnu"),
                 ("macos-arm64", "x86_64-apple-macosx26.0"),
                 ("macos-arm64", "arm64-unknown-linux-gnu"),
                 ("windows-x64", "arm64-unknown-windows-msvc"),
                 ("windows-x64", "x86_64-unknown-linux-gnu")]
        for native_platform, triple in cases:
            with self.subTest(native_platform=native_platform, triple=triple), self.native_environment(native_platform, triple=triple):
                with self.assertRaisesRegex(ValueError, "Swift target matching"):
                    package_source.package_source(self.repository, self.output, native_platform)
        self.assertFalse(self.output.exists())

    def test_foreign_hosts_are_rejected_even_with_matching_swift_target(self):
        """Cross-compilers cannot make a platform-qualified source export look native."""
        for native_platform in package_source.PLATFORMS:
            for facts in ({"system": "foreign OS"}, {"machine": "foreign architecture"}):
                with self.subTest(native_platform=native_platform, facts=facts), self.native_environment(native_platform, **facts):
                    with self.assertRaisesRegex(ValueError, "host does not match"):
                        package_source.package_source(self.repository, self.output, native_platform)
        self.assertFalse(self.output.exists())

    def test_wrong_executing_revision_is_rejected(self):
        """A clean checkout at another commit must not inherit this run's qualification."""
        with patch.dict(os.environ, {"GITHUB_SHA": "f" * 40}), self.assertRaisesRegex(ValueError, "GitHub SHA"):
            package_source.package_source(self.repository, self.output)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
