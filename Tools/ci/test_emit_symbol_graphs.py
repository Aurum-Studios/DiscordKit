# File: Tools/ci/test_emit_symbol_graphs.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Exercise native symbol graph normalization with failures before generated replacement."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import emit_symbol_graphs as graphs


class EmitSymbolGraphsTests(unittest.TestCase):
    """Compilation and normalization must preserve existing output until replacements are valid."""

    def setUp(self):
        """Create an isolated Swift package with prior generated documentation evidence."""
        self.temporary = tempfile.TemporaryDirectory(prefix="symbol graph package ")
        self.addCleanup(self.temporary.cleanup)
        self.repository = Path(self.temporary.name).resolve()
        (self.repository / "Package.swift").write_text("// fixture manifest\n")
        self.source = self.repository / ".build/arm64-apple-macosx/symbolgraph"
        self.destination = self.repository / ".build/out/symbolgraph"
        self.source.mkdir(parents=True)
        self.destination.mkdir(parents=True)
        (self.destination / "Previous.symbols.json").write_text("previous known graphs")
        self.calls = []

    def write_graph(self, name="Library.symbols.json", content=None):
        """Write one independent primary or extension graph into the compiler's native location."""
        (self.source / name).write_text(json.dumps(content or {
            "module": {"name": "Library"}, "symbols": [], "relationships": []}))

    def compiler(self, arguments, **options):
        """Record bounded tool invocations and return the native binary directory."""
        self.calls.append((arguments, options))
        if "--show-bin-path" in arguments:
            self.emitted = {path.name: path.read_bytes() for path in self.source.glob("*.symbols.json")
                            if path.is_file() and not path.is_symlink()}
        else:
            self.source.mkdir(parents=True, exist_ok=True)
            for name, content in self.emitted.items():
                (self.source / name).write_bytes(content)
        return subprocess.CompletedProcess(arguments, 0,
            str(self.source.parent / "debug") + "\n" if "--show-bin-path" in arguments else "", "")

    def assert_previous(self):
        """Require the prior generated graph directory to remain intact after rejection."""
        self.assertEqual((self.destination / "Previous.symbols.json").read_text(), "previous known graphs")

    def test_native_output_is_normalized_with_pins_and_resource_limits(self):
        """Primary and extension graph bytes replace only the owned normalized output directory."""
        self.write_graph()
        self.write_graph("Swift@Library.symbols.json")
        package_before = (self.repository / "Package.swift").read_bytes()
        names = graphs.emit(self.repository, 7, self.compiler)
        self.assertEqual(names, ["Library.symbols.json", "Swift@Library.symbols.json"])
        self.assertFalse((self.destination / "Previous.symbols.json").exists())
        for name in names:
            self.assertEqual((self.destination / name).read_bytes(), (self.source / name).read_bytes())
        self.assertEqual((self.repository / "Package.swift").read_bytes(), package_before)
        self.assertEqual(len(self.calls), 2)
        for arguments, options in self.calls:
            self.assertEqual(arguments[arguments.index("--jobs") + 1], "7")
            self.assertEqual(arguments[arguments.index("--build-system") + 1], "native")
            self.assertIn("--force-resolved-versions", arguments)
            self.assertIn("--disable-experimental-prebuilts", arguments)
            self.assertEqual(options["cwd"], self.repository)
            self.assertTrue(options["check"])
        self.assertEqual(self.calls[0][1]["timeout"], 120)
        self.assertEqual(self.calls[1][1]["timeout"], 3600)
        self.assertEqual(self.calls[1][0][-4:],
                         ["dump-symbol-graph", "--emit-extension-block-symbols", "--minimum-access-level", "public"])

    def test_foreign_extension_namespaces_survive_a_compiler_default_that_omits_blocks(self):
        """DocC's external namespace nodes must be requested explicitly and retained."""
        self.write_graph()
        extension = {"identifier": {"precise": "s:e:Swift:Sequence:Library"},
                     "kind": {"identifier": "swift.extension"}, "pathComponents": ["Sequence"],
                     "swiftExtension": {"extendedModule": "Swift", "typeKind": "swift.protocol"}}
        method = {"identifier": {"precise": "s:Library:Sequence:read"},
                  "kind": {"identifier": "swift.method"}, "pathComponents": ["Sequence", "read()"]}

        def compiler(arguments, **options):
            """Model SwiftPM omitting extension blocks unless the caller opts in."""
            result = self.compiler(arguments, **options)
            if "dump-symbol-graph" in arguments:
                symbols = [extension, method] if "--emit-extension-block-symbols" in arguments else [method]
                self.write_graph("Library@Swift.symbols.json", {
                    "module": {"name": "Library"}, "symbols": symbols, "relationships": []})
            return result

        names = graphs.emit(self.repository, run=compiler)
        self.assertEqual(names, ["Library.symbols.json", "Library@Swift.symbols.json"])
        document = json.loads((self.destination / "Library@Swift.symbols.json").read_text())
        self.assertEqual(document["symbols"], [extension, method])

    def test_compile_failure_or_timeout_preserves_previous_graphs(self):
        """A failed native compiler cannot replace previous evidence with partial output."""
        self.write_graph()
        for failure in (subprocess.CalledProcessError(1, ["swift", "package"]),
                        subprocess.TimeoutExpired(["swift", "package"], 3600)):
            with self.subTest(failure=type(failure).__name__):
                def compiler(arguments, **options):
                    """Fail only graph emission, after native location discovery succeeds."""
                    if arguments[1] == "package":
                        raise failure
                    return self.compiler(arguments, **options)
                with self.assertRaises(type(failure)):
                    graphs.emit(self.repository, run=compiler)
                self.assert_previous()

    def test_empty_extension_only_or_malformed_graphs_do_not_replace_output(self):
        """A graph collection needs a genuine primary JSON module, not just successful compiler exit."""
        for case in ("empty", "extension", "malformed", "module-missing"):
            with self.subTest(case=case):
                for graph in self.source.iterdir():
                    graph.unlink()
                if case == "extension":
                    self.write_graph("Swift@Library.symbols.json")
                elif case == "malformed":
                    (self.source / "Library.symbols.json").write_text("invalid JSON")
                elif case == "module-missing":
                    self.write_graph(content={"symbols": []})
                with self.assertRaises(ValueError):
                    graphs.emit(self.repository, run=self.compiler)
                self.assert_previous()

    def test_copy_failure_preserves_previous_graphs(self):
        """Failed staging cannot erase an otherwise usable generated graph set."""
        self.write_graph()
        with patch.object(graphs.shutil, "copy2", side_effect=OSError("copy failed")), self.assertRaises(OSError):
            graphs.emit(self.repository, run=self.compiler)
        self.assert_previous()

    def test_deleted_module_graphs_cannot_survive_a_fresh_emission(self):
        """Only newly emitted modules enter normalized output when a package target disappears."""
        self.write_graph("Deleted.symbols.json")

        def compiler(arguments, **options):
            """Emit one current graph and leave any stale compiler output otherwise untouched."""
            if "--show-bin-path" in arguments:
                return self.compiler(arguments, **options)
            self.source.mkdir(parents=True, exist_ok=True)
            self.write_graph("Current.symbols.json")
            return subprocess.CompletedProcess(arguments, 0, "", "")

        self.assertEqual(graphs.emit(self.repository, run=compiler), ["Current.symbols.json"])
        self.assertFalse((self.destination / "Deleted.symbols.json").exists())

    def test_invalid_binary_paths_are_rejected_without_replacing_graphs(self):
        """Unexpected compiler paths cannot direct generated-file writes outside the selected package."""
        for location in ("", "relative/debug", str(self.repository.parent / "outside/debug"), "first\nsecond"):
            with self.subTest(location=location):
                def compiler(arguments, **options):
                    """Return the selected unsafe location without executing a toolchain."""
                    return subprocess.CompletedProcess(arguments, 0, location, "")
                with self.assertRaises(ValueError):
                    graphs.emit(self.repository, run=compiler)
                self.assert_previous()

    def test_symlinked_source_or_destination_is_rejected(self):
        """Generated graph copies must not follow links to another producer's output."""
        self.write_graph()
        try:
            link = self.source / "Linked.symbols.json"
            link.symlink_to(self.source / "Library.symbols.json")
        except (NotImplementedError, OSError):
            self.skipTest("symbolic links are unavailable")
        with self.assertRaisesRegex(ValueError, "symbolic links"):
            graphs.emit(self.repository, run=self.compiler)
        self.assert_previous()
        link.unlink()
        previous = self.destination.parent / "saved"
        self.destination.rename(previous)
        self.destination.symlink_to(previous, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symbolic links"):
            graphs.emit(self.repository, run=self.compiler)
        self.assertEqual((previous / "Previous.symbols.json").read_text(), "previous known graphs")

    def test_invalid_jobs_fail_before_tool_execution(self):
        """Invalid compiler budgets must never fall back to unbounded SwiftPM defaults."""
        for jobs in (0, -1, True, "5", 1.5):
            with self.subTest(jobs=jobs), self.assertRaises(ValueError):
                graphs.emit(self.repository, jobs, self.compiler)
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
