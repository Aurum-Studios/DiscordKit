# File: Tools/ci/test_documentation_site.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Check the complete static-export pipeline without a compiler or network."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import build_documentation_site as site


class DocumentationSiteTests(unittest.TestCase):
    """Exercise package scope, static routes and safe failure behavior."""

    def modules(self, repository, package):
        """Supply each synthetic package's evaluated public library targets."""
        return ["DiscordKit", "DiscordCore"] if package.resolve() == repository.resolve() else [package.name]

    def existing_graphs(self, repository):
        """Materialize public graph inputs without invoking the compiler or converter."""
        for relative in site.PACKAGES:
            package = repository / relative
            graphs = package / ".build/out/symbolgraph"
            graphs.mkdir(parents=True)
            for module in self.modules(repository, package):
                (graphs / f"{module}.symbols.json").write_text(json.dumps({"module": {"name": module}}))
            (graphs / "Unrelated.symbols.json").write_text('{"module":{"name":"Unrelated"}}')

    def fake_toolchain(self, commands):
        """Materialize the artifacts emitted by the existing converter and DocC."""
        def execute(command, repository):
            command = list(map(str, command))
            commands.append(command)
            if "build_docc.py" in Path(command[1]).name:
                output = Path(command[command.index("--output") + 1])
                package = Path(command[command.index("--repository") + 1])
                modules = self.modules(repository, package)
                output.mkdir()
                for module in [*modules, "DiscordKitLibrary"]:
                    (output / f"{module}.doccarchive").mkdir()
                (output / "build-report.json").write_text(json.dumps({
                    "modules": modules, "failedModules": [], "mergeStatus": "succeeded"}))
            elif command[1] == "merge":
                Path(command[command.index("--output-path") + 1]).mkdir()
            elif "transform-for-static-hosting" in command:
                output = Path(command[command.index("--output-path") + 1])
                page = output / "documentation/discordkit/index.html"
                page.parent.mkdir(parents=True)
                page.write_text("symbol page")
                (output / "documentation/index.html").write_text("library landing")
                (output / "index.html").write_text("DocC application")
        return execute

    def test_all_packages_are_checked_and_individual_archives_share_one_static_site(self):
        """Authoring modules share the library navigator and all deep routes survive."""
        with tempfile.TemporaryDirectory(prefix="documentation test ") as temporary:
            repository = Path(temporary)
            output = repository / ".build/site export"
            for relative in site.PACKAGES:
                graphs = repository / relative / ".build/out/symbolgraph"
                graphs.mkdir(parents=True)
                (graphs / "Stale.symbols.json").write_text("old graph")
                (graphs / "keep.txt").write_text("unrelated generated evidence")
            commands = []
            with patch.object(site, "run", side_effect=self.fake_toolchain(commands)):
                site.build_site(repository, output, "docc tool", "/DiscordKit")
            emitters = [command for command in commands if Path(command[1]).name == "emit_symbol_graphs.py"]
            self.assertEqual(len(emitters), 3)
            self.assertEqual([Path(command[command.index("--repository") + 1]) for command in emitters],
                             [repository.resolve() / package for package in site.PACKAGES])
            self.assertTrue(all(command[-2:] == ["--jobs", str(site.native_jobs.bounded_jobs(5))]
                                for command in emitters))
            checks = [command for command in commands if Path(command[1]).name == "curate_docc.py"]
            self.assertEqual(len(checks), 3)
            self.assertTrue(all("--check" in command and "--write" not in command for command in checks))
            examples = [command for command in commands if Path(command[1]).name == "documentation_examples.py"]
            self.assertEqual(len(examples), 1)
            self.assertEqual(Path(examples[0][-1]), repository.resolve())
            merge = next(command for command in commands if command[1] == "merge")
            merged_inputs = merge[2:merge.index("--output-path")]
            self.assertEqual([Path(path).name for path in merged_inputs], [
                "DiscordKit.doccarchive", "DiscordCore.doccarchive", "DiscordDSLMacros.doccarchive",
                "DiscordDSLExtensions.doccarchive"])
            transform = commands[-1]
            self.assertEqual(transform[-2:], ["--hosting-base-path", "/DiscordKit"])
            self.assertEqual((output / "documentation/discordkit/index.html").read_text(), "symbol page")
            self.assertEqual((output / "documentation/index.html").read_text(), "library landing")
            self.assertIn('href="documentation/"', (output / "index.html").read_text())
            self.assertTrue((output / ".nojekyll").is_file())
            self.assertEqual((output / site.MARKER).read_text(), site.MARKER_CONTENT)
            for relative in site.PACKAGES:
                graphs = repository / relative / ".build/out/symbolgraph"
                # The emitter owns graph replacement; the site builder never deletes inputs.
                self.assertEqual((graphs / "Stale.symbols.json").read_text(), "old graph")
                self.assertTrue((graphs / "keep.txt").is_file())
            self.assertEqual(sorted(path.name for path in output.parent.iterdir()), ["out", "site export"])

    def test_fresh_graph_emission_receives_the_bounded_job_limit(self):
        """All packages receive the shared resource cap rather than the raw request."""
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            commands = []
            with patch.object(site.native_jobs, "bounded_jobs", return_value=3) as bound, \
                    patch.object(site, "run", side_effect=self.fake_toolchain(commands)):
                site.build_site(repository, repository / "site", "docc", "/DiscordKit", jobs=20)
            bound.assert_called_once_with(20)
            emitters = [command for command in commands if Path(command[1]).name == "emit_symbol_graphs.py"]
            self.assertEqual(len(emitters), 3)
            self.assertTrue(all(command[-2:] == ["--jobs", "3"] for command in emitters))

    def test_reused_graphs_are_validated_without_emission_or_deletion(self):
        """Artifact consumers convert the exact existing graphs and never rebuild packages."""
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            self.existing_graphs(repository)
            original = {path: path.read_bytes() for path in repository.rglob("*.symbols.json")}
            commands = []
            with patch.object(site, "run", side_effect=self.fake_toolchain(commands)), \
                    patch.object(site.build_docc, "public_modules", side_effect=lambda package: self.modules(repository, package)):
                site.build_site(repository, repository / "site", "docc", "/DiscordKit", skip_symbol_graphs=True)
            self.assertEqual({path: path.read_bytes() for path in repository.rglob("*.symbols.json")}, original)
            self.assertFalse(any(command[0] == "swift" or Path(command[1]).name == "emit_symbol_graphs.py"
                                 for command in commands))
            self.assertEqual(len([command for command in commands if Path(command[1]).name == "curate_docc.py"]), 3)
            self.assertTrue((repository / "site/documentation/index.html").is_file())

    def test_reused_missing_or_invalid_graphs_fail_without_rebuilding(self):
        """Missing directories, missing primary graphs and wrong module bytes cannot fall back to compilation."""
        for invalid in ("directory", "primary", "module", "json", "symlink"):
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as temporary:
                repository = Path(temporary)
                self.existing_graphs(repository)
                graphs = repository / ".build/out/symbolgraph"
                primary = graphs / "DiscordKit.symbols.json"
                if invalid == "directory":
                    graphs.rename(graphs.with_name("unselected"))
                elif invalid == "primary":
                    primary.unlink()
                elif invalid == "module":
                    primary.write_text('{"module":{"name":"Other"}}')
                elif invalid == "json":
                    primary.write_text("invalid graph JSON")
                else:
                    primary.unlink()
                    primary.symlink_to(graphs / "DiscordCore.symbols.json")
                output = repository / "site"
                output.mkdir()
                (output / site.MARKER).write_text(site.MARKER_CONTENT)
                (output / "index.html").write_text("old successful site")
                with patch.object(site, "run") as run, \
                        patch.object(site.build_docc, "public_modules", side_effect=lambda package: self.modules(repository, package)):
                    with self.assertRaises(ValueError):
                        site.build_site(repository, output, "docc", "/DiscordKit", skip_symbol_graphs=True)
                    run.assert_not_called()
                self.assertFalse(output.exists())

    def test_nonpositive_job_counts_fail_before_any_commands(self):
        """Invalid compiler resource limits never start conversion or emission."""
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            with patch.object(site, "run") as run:
                for jobs in (0, -1):
                    with self.subTest(jobs=jobs), self.assertRaisesRegex(ValueError, "positive integer"):
                        site.build_site(repository, repository / "site", "docc", "/DiscordKit", jobs=jobs)
                run.assert_not_called()

    def test_failed_rebuild_leaves_no_previous_site_or_partial_export(self):
        """A failing command cannot make an earlier successful tree look current."""
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            output = repository / ".build/site"
            output.mkdir(parents=True)
            (output / site.MARKER).write_text(site.MARKER_CONTENT)
            (output / "index.html").write_text("stale successful site")
            commands = []
            fake = self.fake_toolchain(commands)

            def fail_transform(command, root):
                if "transform-for-static-hosting" in command:
                    raise subprocess.CalledProcessError(1, command)
                fake(command, root)

            with patch.object(site, "run", side_effect=fail_transform):
                with self.assertRaises(subprocess.CalledProcessError):
                    site.build_site(repository, output, "docc", "/")
            self.assertFalse(output.exists())
            self.assertEqual(list(output.parent.iterdir()), [])

    def test_unowned_outputs_and_symlinks_are_preserved(self):
        """An output typo cannot delete source files or follow a symbolic link."""
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            existing = repository / "existing"
            existing.mkdir()
            (existing / "index.html").write_text("authored page")
            linked = repository / "linked"
            linked.symlink_to(existing, target_is_directory=True)
            with patch.object(site, "run") as run:
                for output in [existing, linked]:
                    with self.assertRaises(ValueError):
                        site.build_site(repository, output, "docc", "/DiscordKit")
                run.assert_not_called()
            self.assertEqual((existing / "index.html").read_text(), "authored page")
            self.assertTrue(linked.is_symlink())

    def test_missing_static_landing_is_not_published(self):
        """Successful subprocess status alone is insufficient for a usable export."""
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            output = repository / "site"
            fake = self.fake_toolchain([])

            def omit_landing(command, root):
                fake(command, root)
                if "transform-for-static-hosting" in command:
                    transformed = Path(command[command.index("--output-path") + 1])
                    (transformed / "documentation/index.html").unlink()

            with patch.object(site, "run", side_effect=omit_landing):
                with self.assertRaisesRegex(ValueError, "landing page"):
                    site.build_site(repository, output, "docc", "/DiscordKit")
            self.assertFalse(output.exists())

    def test_empty_base_path_hosts_at_domain_root(self):
        """Domain-root deployments pass DocC's empty base path through unchanged."""
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            output = repository / "site"
            commands = []
            with patch.object(site, "run", side_effect=self.fake_toolchain(commands)):
                site.build_site(repository, output, "docc", "")
            self.assertEqual(commands[-1][-2:], ["--hosting-base-path", ""])
            self.assertIn('href="documentation/"', (output / "index.html").read_text())


if __name__ == "__main__":
    unittest.main()
