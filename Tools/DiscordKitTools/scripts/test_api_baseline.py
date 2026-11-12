# File: Tools/DiscordKitTools/scripts/test_api_baseline.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Regression tests for scoped symbol-graph extraction and conservative source semver."""

import copy
from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import api_baseline as api


class APIBaselineTests(unittest.TestCase):
    """Test graph shards, source-significant fingerprints and breaking/additive version admission."""

    def test_reviewed_separate_authoring_api_scope_excludes_plugin_and_tests(self):
        """Root and macro snapshots keep independently reviewed complete module sets."""
        policy = {"targets": {"Runtime": []}, "authoringPackages": {"Packages/Macros": {
            "products": {"Macros": ["Authoring"]},
            "targets": {"Authoring": ["Plugin"], "Plugin": [], "Tests": ["Authoring"]},
            "targetTypes": {"Authoring": "regular", "Plugin": "macro", "Tests": "test"},
        }}}
        self.assertEqual(api.snapshot_modules(policy), {"Runtime"})
        self.assertEqual(api.snapshot_modules(policy, "Packages/Macros"), {"Authoring"})
        with self.assertRaisesRegex(ValueError, "Unknown authoring"):
            api.snapshot_modules(policy, "Packages/Missing")
        for roots in ({}, {"Compiler": ["Plugin"]}, {"Tests": ["Tests"]}, {"Missing": ["Absent"]}):
            candidate = copy.deepcopy(policy)
            candidate["authoringPackages"]["Packages/Macros"]["products"] = roots
            with self.subTest(roots=roots), self.assertRaisesRegex(ValueError, "regular library"):
                api.snapshot_modules(candidate, "Packages/Macros")

    def setUp(self):
        """Construct an owned public symbol graph independently of the installed Swift compiler."""
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.symbol = {"identifier": {"precise": "s:Owned.type"}, "accessLevel": "public", "kind": {"identifier": "swift.struct", "displayName": "Structure"}, "pathComponents": ["Value"], "declarationFragments": [{"kind": "keyword", "spelling": "struct"}, {"kind": "identifier", "spelling": "Value"}]}
        self.graph = {"module": {"name": "Owned", "platform": {"architecture": "arm64", "operatingSystem": {"name": "macosx"}}}, "symbols": [self.symbol], "relationships": []}
        self.write_graph()
        self.baseline = api.snapshot(self.directory, {"Owned"}, "1.2.0")

    def write_graph(self, graph=None, name="Owned.symbols.json"):
        """Write one deterministic graph shard used by extraction scenarios."""
        (self.directory / name).write_text(json.dumps(self.graph if graph is None else graph))

    def candidate(self, version):
        """Clone the reference snapshot under a proposed semantic version."""
        value = copy.deepcopy(self.baseline)
        value["version"] = version
        return value

    def test_snapshot_excludes_private_and_dependency_symbols(self):
        """Public owned modules are complete while private and external graphs stay outside scope."""
        self.graph["symbols"].append(dict(self.symbol, accessLevel="private", identifier={"precise": "s:hidden"}))
        self.write_graph()
        self.write_graph(dict(self.graph, module={"name": "External"}), "External.symbols.json")
        result = api.snapshot(self.directory, {"Owned"}, "1.2.0")
        self.assertEqual(list(result["modules"]["Owned"]["symbols"]), ["s:Owned.type"])

    def test_doc_location_changes_do_not_change_source_fingerprint(self):
        """Comment and source-line-only edits remain compatible while declaration changes do not."""
        before = api.fingerprint(self.symbol)
        self.symbol.update(docComment={"lines": [{"text": "new docs"}]}, location={"uri": "file:///different", "position": {"line": 99}})
        self.assertEqual(api.fingerprint(self.symbol), before)
        self.symbol["accessLevel"] = "open"
        self.assertNotEqual(api.fingerprint(self.symbol), before)

    def test_async_isolation_remains_source_significant(self):
        """A real isolation change retains distinct hashes and fails same-version admission."""
        self.symbol["declarationFragments"] = [
            {"kind": "keyword", "spelling": "nonisolated(nonsending)"},
            {"kind": "text", "spelling": " () async -> Void"},
        ]
        self.write_graph()
        baseline = api.snapshot(self.directory, {"Owned"}, "0.15.0")
        self.symbol["declarationFragments"][0]["spelling"] = "nonisolated"
        self.write_graph()
        candidate = api.snapshot(self.directory, {"Owned"}, "0.15.0")
        with self.assertRaises(api.APICompatibilityError) as rejected:
            api.compare(baseline, candidate, "0.15.0")
        self.assertEqual(rejected.exception.report["requiredIncrement"], "major")
        self.assertEqual(rejected.exception.report["changes"]["changed"], ["Owned:s:Owned.type"])

    def test_compact_snapshot_roundtrip_is_deterministic(self):
        """Line-oriented normalized JSON roundtrips losslessly and writes identical bytes twice."""
        path = self.directory / "baseline.json"
        api.write_snapshot(path, self.baseline)
        first = path.read_bytes()
        self.assertEqual(json.loads(first), self.baseline)
        api.write_snapshot(path, self.baseline)
        self.assertEqual(first, path.read_bytes())

    def test_missing_module_mixed_platform_and_conflicting_shard_fail(self):
        """Incomplete or incompatible compiler output cannot seed a baseline."""
        with self.assertRaisesRegex(ValueError, "module coverage"):
            api.snapshot(self.directory, {"Owned", "Missing"}, "1.2.0")
        other = copy.deepcopy(self.graph)
        other["module"]["platform"]["architecture"] = "x86_64"
        self.write_graph(other, "Owned@Other.symbols.json")
        with self.assertRaisesRegex(ValueError, "Mixed"):
            api.snapshot(self.directory, {"Owned"}, "1.2.0")
        other = copy.deepcopy(self.graph)
        other["symbols"][0]["accessLevel"] = "open"
        self.write_graph(other, "Owned@Other.symbols.json")
        with self.assertRaisesRegex(ValueError, "Conflicting"):
            api.snapshot(self.directory, {"Owned"}, "1.2.0")

    def test_unchanged_version_and_patch_are_allowed(self):
        """Identical APIs permit candidate revalidation and ordinary patch versions."""
        for version in ("1.2.0", "1.2.1"):
            result = api.compare(self.baseline, self.candidate(version), version)
            self.assertEqual(result["requiredIncrement"], "none")

    def test_added_public_member_requires_minor(self):
        """An ordinary additive symbol cannot pass under a patch-only increment."""
        candidate = self.candidate("1.2.1")
        candidate["modules"]["Owned"]["symbols"]["s:Owned.added"] = copy.deepcopy(candidate["modules"]["Owned"]["symbols"]["s:Owned.type"])
        with self.assertRaisesRegex(ValueError, "minor"):
            api.compare(self.baseline, candidate, "1.2.1")
        candidate["version"] = "1.3.0"
        self.assertEqual(api.compare(self.baseline, candidate, "1.3.0")["requiredIncrement"], "minor")

    def test_removed_or_changed_symbol_requires_major(self):
        """Removed and same-identity changed declaration signatures require a major release."""
        for mutation in ("remove", "change"):
            with self.subTest(mutation=mutation):
                candidate = self.candidate("1.3.0")
                if mutation == "remove":
                    candidate["modules"] = {"Other": self.candidate("1.3.0")["modules"]["Owned"]}
                else:
                    candidate["modules"]["Owned"]["symbols"]["s:Owned.type"]["signatureSHA256"] = "0" * 64
                with self.assertRaisesRegex(ValueError, "Breaking"):
                    api.compare(self.baseline, candidate, "1.3.0")
                candidate["version"] = "2.0.0"
                self.assertEqual(api.compare(self.baseline, candidate, "2.0.0")["requiredIncrement"], "major")

    def test_required_protocol_member_and_enum_case_are_breaking(self):
        """New conformer requirements and exhaustive-switch cases cannot masquerade as minor additions."""
        for kind, edges in (("swift.enum.case", []), ("swift.method", [["s:new", "requirementOf", "s:protocol"]])):
            candidate = self.candidate("1.3.0")
            symbol = copy.deepcopy(candidate["modules"]["Owned"]["symbols"]["s:Owned.type"])
            symbol["kind"] = kind
            candidate["modules"]["Owned"]["symbols"]["s:new"] = symbol
            candidate["modules"]["Owned"]["relationships"] = edges
            with self.subTest(kind=kind), self.assertRaisesRegex(ValueError, "Breaking"):
                api.compare(self.baseline, candidate, "1.3.0")

    def test_relationship_removal_and_pre_one_policy(self):
        """Removing an existing conformance is breaking; pre-1.0 breakage needs a minor increment."""
        self.baseline["version"] = "0.14.0"
        self.baseline["modules"]["Owned"]["relationships"] = [["s:Owned.type", "conformsTo", "s:protocol"]]
        candidate = self.candidate("0.14.1")
        candidate["modules"]["Owned"]["relationships"] = []
        with self.assertRaisesRegex(ValueError, "Breaking"):
            api.compare(self.baseline, candidate, "0.14.1")
        candidate["version"] = "0.15.0"
        self.assertEqual(api.compare(self.baseline, candidate, "0.15.0")["requiredIncrement"], "major")

    def test_cli_comparison_report_preserves_rejected_diff_and_failure_exit(self):
        """CI can retain exact incompatibilities while semver admission still fails closed."""
        baseline = self.directory / "baseline.json"
        candidate_path = self.directory / "candidate.json"
        api.write_snapshot(baseline, self.baseline)
        for mutation in ("unchanged", "changed", "added", "scope"):
            with self.subTest(mutation=mutation):
                output = self.directory / mutation / "reports" / "comparison.json"
                candidate = self.candidate("1.2.0")
                symbols = candidate["modules"]["Owned"]["symbols"]
                if mutation == "changed":
                    symbols["s:Owned.type"]["signatureSHA256"] = "0" * 64
                elif mutation == "added":
                    symbols["s:Owned.new"] = copy.deepcopy(symbols["s:Owned.type"])
                elif mutation == "scope":
                    candidate["platform"]["architecture"] = "x86_64"
                api.write_snapshot(candidate_path, candidate)
                arguments = ["api_baseline.py", "check", "--baseline", str(baseline),
                             "--candidate", str(candidate_path), "--version", "1.2.0", "--output", str(output)]
                with patch.object(sys, "argv", arguments), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    if mutation == "unchanged":
                        api.main()
                    else:
                        with self.assertRaises(SystemExit) as rejected:
                            api.main()
                        self.assertEqual(rejected.exception.code, 1)
                report = json.loads(output.read_text())
                self.assertEqual(report["status"], "passed" if mutation == "unchanged" else "failed")
                if mutation == "scope":
                    self.assertIn("platform scopes", report["error"])
                    self.assertNotIn("changes", report)
                else:
                    self.assertEqual(report["baselineVersion"], "1.2.0")
                    self.assertEqual(report["candidateVersion"], "1.2.0")
                    required = {"unchanged": "none", "changed": "major", "added": "minor"}[mutation]
                    self.assertEqual(report["requiredIncrement"], required)
                    if mutation != "unchanged":
                        expected = "Owned:s:Owned.type" if mutation == "changed" else "Owned:s:Owned.new"
                        self.assertEqual(report["changes"][mutation], [expected])
                        self.assertIn("requires", report["error"])

    def test_scope_mismatch_decreasing_version_and_malformed_snapshot_fail(self):
        """Platform scope, malformed hashes and version drift reject the check before compatibility claims."""
        candidate = self.candidate("1.1.0")
        with self.assertRaisesRegex(ValueError, "decreases"):
            api.compare(self.baseline, candidate, "1.1.0")
        candidate = self.candidate("1.2.0")
        candidate["platform"]["architecture"] = "x86_64"
        with self.assertRaisesRegex(ValueError, "platform scopes"):
            api.compare(self.baseline, candidate, "1.2.0")
        candidate = self.candidate("1.2.0")
        candidate["modules"]["Owned"]["symbols"]["s:Owned.type"]["signatureSHA256"] = "invalid"
        with self.assertRaisesRegex(ValueError, "fingerprint"):
            api.compare(self.baseline, candidate, "1.2.0")
        for version in ("v1.2.0", "1.02.0", "1.2", "1.2.0-beta.1", "1.2.0+metadata"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                api.semantic_version(version)


if __name__ == "__main__":
    unittest.main()
