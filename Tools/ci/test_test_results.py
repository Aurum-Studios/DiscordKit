# File: Tools/ci/test_test_results.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Inject selection and execution faults into the pinned Swift Testing ABI mapping.

Fixtures are deliberately synthetic representations of the upstream 6.4.1 ABI,
not claims that any native platform has executed or qualified this phase.
"""

import copy
import json
from pathlib import Path
import tempfile
import unittest

import test_results as results


ONE = "ModuleTests.Suite/first()"
TWO = "ModuleTests.Suite/second(value:)"
SKIPPED = "ModuleTests.Suite/nativeOracle(value:)"
SUITE = "ModuleTests.Suite"


def definition(identifier, parameterized=False, *, kind="function", line=10):
    raw_id = identifier + f"/Fixture.swift:{line}:1" if kind == "function" else identifier
    payload = {"id": raw_id, "kind": kind, "name": identifier.rsplit("/", 1)[-1],
               "sourceLocation": {"fileID": "ModuleTests/Fixture.swift", "filePath": "/fixture/Fixture.swift",
                                  "line": line, "column": 1}}
    if kind == "function":
        payload["isParameterized"] = parameterized
    return {"version": "6.4.0", "kind": "test", "payload": payload}


def event(kind, identifier=None, *, line=10, iteration=None, **extra):
    payload = {"kind": kind, "instant": {"absolute": 0, "since1970": 0}, "messages": [], **extra}
    if identifier is not None:
        payload["testID"] = identifier + f"/Fixture.swift:{line}:1" if identifier.endswith(")") else identifier
    if iteration is not None:
        payload["iteration"] = iteration
    return {"version": "6.4.0", "kind": "event", "payload": payload}


def successful(identifier=ONE, parameterized=False, cases=1):
    records = [definition(SUITE, kind="suite"), definition(identifier, parameterized),
               event("runStarted"), event("testStarted", SUITE), event("testStarted", identifier)]
    if parameterized:
        for _ in range(cases):
            records += [event("testCaseStarted", identifier, iteration=1),
                        event("testCaseEnded", identifier, iteration=1)]
    records += [event("testEnded", identifier), event("testEnded", SUITE), event("runEnded")]
    return records


class StructuredTestResultsTests(unittest.TestCase):
    """Runtime leaf identity must equal selection, with no count-only success path."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "events.jsonl"

    def reconcile(self, records, expected=None, exclusions=None):
        self.path.write_text("".join(json.dumps(record) + "\n" for record in records))
        return results.reconcile([ONE] if expected is None else expected, self.path, exclusions=exclusions)

    def test_nonparameterized_function_has_no_redundant_case_events(self):
        result = self.reconcile(successful())
        self.assertEqual(result["executedLeaves"], [ONE])
        self.assertEqual(result["leaves"], {ONE: {"outcome": "passed", "parameterized": False, "caseCount": 1}})
        self.assertEqual(result["counts"], {"expected": 1, "executed": 1, "passed": 1, "excluded": 0, "cases": 1})
        self.assertIs(results.validate_result([ONE], result), result)

    def test_parameterized_function_maps_many_argument_invocations_to_one_discovery_leaf(self):
        result = self.reconcile(successful(TWO, True, 3), [TWO])
        self.assertEqual(result["counts"]["executed"], 1)
        self.assertEqual(result["counts"]["cases"], 3)
        self.assertEqual(result["leaves"][TWO], {"outcome": "passed", "parameterized": True, "caseCount": 3})

    def test_nested_and_top_level_functions_preserve_discovery_identity(self):
        for identifier in ("ModuleTests.Outer/Inner/check(value:)", "ModuleTests.check()"):
            with self.subTest(identifier=identifier):
                result = self.reconcile(successful(identifier), [identifier])
                self.assertEqual(result["executedLeaves"], [identifier])

    def test_wrong_filter_cannot_pass_from_nonempty_discovery_exit_zero_and_equal_count(self):
        with self.assertRaisesRegex(ValueError, "unexpected.*wrong filter"):
            self.reconcile(successful(TWO), [ONE])

    def test_execution_definitions_are_filtered_before_test_discovered_is_encoded(self):
        records = successful()
        records.insert(2, definition(TWO, True))
        with self.assertRaisesRegex(ValueError, "unexpected.*wrong filter"):
            self.reconcile(records)

    def test_zero_execution_and_missing_selected_leaf_fail(self):
        for records, expected in (([event("runStarted"), event("runEnded")], [ONE]),
                                  (successful(), [ONE, TWO])):
            with self.subTest(expected=expected), self.assertRaisesRegex(ValueError, "missing executed"):
                self.reconcile(records, expected)

    def test_empty_parameter_population_fails_despite_outer_pass(self):
        with self.assertRaisesRegex(ValueError, "zero argument cases"):
            self.reconcile(successful(TWO, True, 0), [TWO])

    def test_duplicate_function_execution_fails(self):
        records = successful()
        records[-2:-2] = [event("testStarted", ONE), event("testEnded", ONE)]
        with self.assertRaisesRegex(ValueError, "duplicate test leaf"):
            self.reconcile(records)

    def test_duplicate_definitions_and_colliding_source_location_mapping_fail(self):
        for extra in (definition(ONE), definition(ONE, line=20)):
            records = successful()
            records.insert(2, extra)
            with self.subTest(raw=extra), self.assertRaisesRegex(ValueError, "duplicate"):
                self.reconcile(records)

    def test_unknown_function_event_identifier_fails(self):
        records = successful()
        records[4] = event("testStarted", TWO)
        with self.assertRaisesRegex(ValueError, "matching test definition"):
            self.reconcile(records)

    def test_unexpected_function_skip_is_never_a_pass(self):
        records = [definition(ONE), event("runStarted"), event("testSkipped", ONE), event("runEnded")]
        with self.assertRaisesRegex(ValueError, "unexpected skipped test leaf"):
            self.reconcile(records)

    def test_suite_skip_cannot_hide_expected_children(self):
        records = [definition(SUITE, kind="suite"), definition(ONE), event("runStarted"),
                   event("testSkipped", SUITE), event("runEnded")]
        with self.assertRaisesRegex(ValueError, "unexpected skipped suite"):
            self.reconcile(records)

    def test_exclusion_declared_before_execution_can_skip_or_be_omitted(self):
        exclusions = {SKIPPED: "Native oracle requires explicit compiler qualification opt-in"}
        for explicit_skip in (False, True):
            records = successful()
            if explicit_skip:
                records.insert(2, definition(SKIPPED, True))
                records.insert(-2, event("testSkipped", SKIPPED))
            with self.subTest(explicit=explicit_skip):
                result = self.reconcile(records, [ONE, SKIPPED], exclusions)
                self.assertEqual(result["excludedLeaves"], exclusions)
                self.assertEqual(result["expectedLeaves"], [ONE])
                self.assertEqual(result["counts"]["excluded"], 1)
                results.validate_result([ONE, SKIPPED], result, exclusions=exclusions)

    def test_excluded_leaf_must_not_execute(self):
        with self.assertRaisesRegex(ValueError, "inventory-excluded leaf executed"):
            self.reconcile(successful(), [ONE, TWO], {ONE: "platform-specific oracle"})

    def test_invalid_exclusions_cannot_shrink_inventory_silently(self):
        for exclusions in ({TWO: "unknown"}, {ONE: ""}, {ONE: " "}, {ONE: None}, {ONE: "all excluded"}, []):
            with self.subTest(exclusions=exclusions), self.assertRaisesRegex(ValueError, "exclusion|nonempty"):
                self.reconcile(successful(), exclusions=exclusions)

    def test_failure_and_cancelled_events_fail_even_if_outer_test_ends(self):
        for fault in (event("issueRecorded", ONE, issue={"isFailure": True, "severity": "error", "isKnown": False}),
                      event("testCancelled", ONE), event("testCaseCancelled", ONE)):
            records = successful()
            records.insert(-3, fault)
            with self.subTest(fault=fault), self.assertRaisesRegex(ValueError, "failing issue|cancelled"):
                self.reconcile(records)

    def test_nonfailure_issue_is_allowed_but_missing_failure_semantics_fails(self):
        records = successful()
        records.insert(-3, event("issueRecorded", ONE, issue={"isFailure": False, "isKnown": True}))
        self.reconcile(records)
        records[-4]["payload"]["issue"].pop("isFailure")
        with self.assertRaisesRegex(ValueError, "missing its failure outcome"):
            self.reconcile(records)

    def test_missing_and_duplicate_case_boundaries_fail(self):
        for fault in ("missing-end", "double-start", "double-end"):
            records = successful(TWO, True)
            if fault == "missing-end":
                del records[6]
            elif fault == "double-start":
                records.insert(6, event("testCaseStarted", TWO))
            else:
                records.insert(7, event("testCaseEnded", TWO))
            with self.subTest(fault=fault), self.assertRaisesRegex(ValueError, "unpaired|unfinished|duplicate"):
                self.reconcile(records, [TWO])

    def test_repetitions_are_not_additional_parameter_cases(self):
        records = successful(TWO, True)
        records[5]["payload"]["iteration"] = 2
        with self.assertRaisesRegex(ValueError, "repetition"):
            self.reconcile(records, [TWO])

    def test_nonparameterized_case_events_are_rejected(self):
        records = successful()
        records.insert(5, event("testCaseStarted", ONE))
        with self.assertRaisesRegex(ValueError, "parameterized case"):
            self.reconcile(records)

    def test_xctest_discovery_requires_serial_structured_observer(self):
        with self.assertRaisesRegex(ValueError, "unsupported XCTest inventory"):
            self.reconcile(successful(), ["ModuleTests.LegacyCase/testExample"])

    def test_multiple_product_streams_merge_without_duplicate_leaf_execution(self):
        records = successful() + successful(TWO, True, 2)[1:]
        # The second product belongs to a distinct suite, as native products do.
        for record in records[len(successful()):]:
            payload = record["payload"]
            if payload.get("testID") == SUITE:
                payload["testID"] = "OtherTests.Suite"
        records.insert(len(successful()), definition("OtherTests.Suite", kind="suite"))
        result = self.reconcile(records, [ONE, TWO])
        self.assertEqual(result["runCount"], 2)
        self.assertEqual(result["counts"]["cases"], 3)

    def test_complete_run_boundary_is_mandatory(self):
        faults = (successful()[:-1], successful()[3:], [event("runEnded")],
                  [event("runStarted"), event("runStarted")])
        for records in faults:
            with self.subTest(records=records), self.assertRaisesRegex(ValueError, "run|unfinished"):
                self.reconcile(records)

    def test_run_ending_with_active_function_fails(self):
        records = successful()[:5] + [event("runEnded")]
        with self.assertRaisesRegex(ValueError, "unfinished"):
            self.reconcile(records)

    def test_unknown_event_requires_parser_review_but_unknown_record_is_ignored_per_abi(self):
        records = successful()
        records.insert(0, {"version": "6.4.0", "kind": "future-record", "payload": {}})
        self.reconcile(records)
        records.insert(5, event("futureExecutionOutcome"))
        with self.assertRaisesRegex(ValueError, "unsupported structured test event"):
            self.reconcile(records)

    def test_missing_empty_truncated_malformed_and_wrong_version_streams_fail(self):
        for content in (None, "", "{}", "{}\n", "{bad}\n", "\n",
                        '{"version":"6.4.0","version":"6.4.0"}\n'):
            if content is None:
                self.path.unlink(missing_ok=True)
            else:
                self.path.write_text(content)
            with self.subTest(content=content), self.assertRaises(ValueError):
                results.reconcile([ONE], self.path)

    def test_input_inventory_cannot_be_empty_duplicate_or_location_dependent(self):
        for inventory in ([], [ONE, ONE], [ONE + "/Fixture.swift:10:1"], [None]):
            with self.subTest(inventory=inventory), self.assertRaises(ValueError):
                self.reconcile(successful(), inventory)

    def test_retained_result_is_revalidated_against_exact_inventory_counts_and_outcomes(self):
        good = self.reconcile(successful())
        mutations = [lambda value: value.update(status="failed"),
                     lambda value: value.update(formatVersion=True),
                     lambda value: value.update(expectedLeaves=[TWO]),
                     lambda value: value.update(executedLeaves=[]),
                     lambda value: value.update(excludedLeaves={ONE: "late exclusion"}),
                     lambda value: value["leaves"].update({TWO: value["leaves"][ONE]}),
                     lambda value: value["leaves"][ONE].update(outcome="skipped"),
                     lambda value: value["leaves"][ONE].update(caseCount=0),
                     lambda value: value["leaves"][ONE].update(caseCount=2),
                     lambda value: value["leaves"][ONE].update(caseCount=True),
                     lambda value: value["counts"].update(executed=2),
                     lambda value: value["counts"].update(cases=True),
                     lambda value: value.update(runCount=0),
                     lambda value: value.update(runCount=True),
                     lambda value: value.update(extraField="unreviewed")]
        for mutate in mutations:
            value = copy.deepcopy(good)
            mutate(value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                results.validate_result([ONE], value)


if __name__ == "__main__":
    unittest.main()
