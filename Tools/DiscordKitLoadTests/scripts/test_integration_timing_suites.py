#!/usr/bin/env python3
# File: Tools/DiscordKitLoadTests/scripts/test_integration_timing_suites.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Adversarial accounting, artifact and real external-process checks for phase ten."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import run_integration_timing_suites as suites


def fixture():
    """Two complete cycles contain queue rejection and actual submitted cancellation."""
    row = dict(profile="smoke", duration_seconds=8, cycle_seconds=4, seed=7,
               maximum_rss_bytes=1024 * 1024 * 1024, maximum_cpu_seconds=62, observer_mode="aggregate")
    def band(name):
        value = dict(name=name, offered=10, submitted=8, completed=10, successful=6, rejected=3,
                     cancelled=1, peakActive=4, peakPending=8, peakPendingAgeNanoseconds=1000,
                     recoveryNanoseconds=100, schedulerMaximumLatenessNanoseconds=99, generatorCensored=0,
                     controlProgress=2, elapsedNanoseconds=1_000_000_000,
                     successfulPerSecond=6.0, completedPerSecond=10.0, offeredPerSecond=10.0,
                     outcomes=dict(success=6, failure=0, cancelled=1, timedOut=0, rejected=3, uncertain=0))
        return value
    cycles = [dict(ordinal=index, bands=[band(name) for name in suites.BANDS], cacheEntries=64,
                   cacheRefreshes=0, cacheWaiters=0, gatewayBufferedEvents=32, remainingArrivalOwners=0)
              for index in range(2)]
    aggregate = copy.deepcopy(cycles[0]["bands"])
    for value in aggregate:
        for key in ("offered", "submitted", "completed", "successful", "rejected", "cancelled", "controlProgress", "elapsedNanoseconds"):
            value[key] *= 2
        value["outcomes"] = {key: count * 2 for key, count in value["outcomes"].items()}
    metrics = [dict(id=metric_id, version=1, outcome=outcome, clockDomain="run-1", p50={}, p95={}, p99={}, maximum={},
                    distribution=dict(observedCount=count, droppedCount=0, counterOverflow=False))
               for metric_id in ("arrival.scheduledResponse", "arrival.submittedResponse", "arrival.lateness")
               for outcome, count in (("success", 48), ("cancelled", 8), ("rejected", 8))]
    counts = dict(offered=80, admitted=64, completed=80, deadlineMisses=0,
                  outcomes=dict(success=48, failure=0, cancelled=8, timedOut=0, rejected=24, uncertain=0))
    cleanup = dict(completed=True, remainingOwners=0)
    common = dict(format="DiscordBenchmarkReport", schemaVersion=1, status="completed", clockDomain="run-1",
                  identity=dict(catalogVersion=9, scenario=suites.SCENARIO, profile="smoke", seed=7, concurrency=8,
                                scheduler=suites.SCHEDULER, instrumentation="driver-aggregate+operation-aggregate",
                                measuredNanoseconds=8_100_000_000,
                                inputSizes=dict(durationSeconds=8, cycleSeconds=4, maximumActive=8, maximumPending=8,
                                                workingSet=64, maximumRSSBytes=row["maximum_rss_bytes"], maximumCPUSeconds=62)),
                  counts=counts, cleanup=cleanup, metrics=metrics)
    measurement = dict(counts=counts, metrics=metrics, clockDomain="run-1", durationNanoseconds=8_100_000_000,
                       completedCycles=2, cycles=cycles, bands=aggregate, controlProgress=17, controlFailure=False,
                       resources=dict(maximumRSSBytes=20_000_000, cpuSeconds=1.5, capExceeded=False), cleanup=cleanup,
                       restCleanup=dict.fromkeys(("active", "queued", "ordered", "flights", "waiters", "cacheEntries", "transportBodies", "transportActive"), 0),
                       gatewayCleanup=dict.fromkeys(("subscriptions", "bufferedEvents", "bufferedBytes", "waitingConsumers"), 0),
                       cacheEntriesAfterClose=0, cancelled=False)
    native = dict(format="DiscordKitLoadTests.integration-timing", schemaVersion=1,
                  configuration=dict(profile="smoke", seed=7, durationSeconds=8, cycleSeconds=4,
                                     maximumRSSBytes=row["maximum_rss_bytes"], maximumCPUSeconds=62, observerMode="aggregate"),
                  measurement=measurement, common=common)
    return row, native


class IntegrationIntegrityTests(unittest.TestCase):
    def test_complete_cycles_retain_outcomes_censoring_and_unattributed_control_progress(self):
        """Slow consumers may retain a bounded queue during a cycle; final owners must be zero."""
        row, native = fixture()
        result = suites.compact(native, row)
        self.assertEqual(result["counts"]["outcomes"]["rejected"], 24)
        self.assertEqual(result["controlProgressOutsideBands"], 1)
        self.assertEqual(result["completedCycles"], 2)
        self.assertAlmostEqual(result["successfulPerSecond"], 48 / 8.1)

    def test_partial_biased_capped_and_retained_evidence_is_rejected(self):
        """Independently mutate receipts so one optimistic scalar cannot hide contradictory evidence."""
        mutations = [
            lambda x: x.update(schemaVersion=True),
            lambda x: x["configuration"].update(durationSeconds=4),
            lambda x: x["common"].update(status="interrupted"),
            lambda x: x["measurement"].update(cancelled=True),
            lambda x: x["measurement"].update(controlFailure=True),
            lambda x: x["measurement"].update(durationNanoseconds=7_999_999_999),
            lambda x: x["common"]["identity"].update(scheduler="closed-loop"),
            lambda x: x["common"]["identity"].update(seed=True),
            lambda x: x["common"]["identity"]["inputSizes"].update(workingSet=128),
            lambda x: x["common"]["counts"].update(completed=True),
            lambda x: x["common"]["counts"]["outcomes"].update(uncertain=1),
            lambda x: x["measurement"]["cleanup"].update(remainingOwners=1),
            lambda x: x["measurement"]["restCleanup"].update(waiters=1),
            lambda x: x["measurement"]["gatewayCleanup"].update(bufferedBytes=1),
            lambda x: x["measurement"].update(cacheEntriesAfterClose=1),
            lambda x: x["measurement"]["resources"].update(capExceeded=True),
            lambda x: x["measurement"]["resources"].update(cpuSeconds=float("nan")),
            lambda x: x["measurement"]["resources"].update(maximumRSSBytes=2**40),
            lambda x: x["measurement"].update(completedCycles=1),
            lambda x: x["measurement"].update(omittedCycles=1),
            lambda x: x["measurement"]["cycles"][1].update(ordinal=0),
            lambda x: x["measurement"]["cycles"][0].update(cacheEntries=65),
            lambda x: x["measurement"]["cycles"][0].update(cacheRefreshes=1),
            lambda x: x["measurement"]["cycles"][0].update(gatewayBufferedEvents=65),
            lambda x: x["measurement"]["cycles"][0].update(remainingArrivalOwners=1),
            lambda x: x["measurement"]["cycles"][0]["bands"].pop(),
            lambda x: x["measurement"]["cycles"][0]["bands"][0].update(controlProgress=0),
            lambda x: x["measurement"]["cycles"][0]["bands"][0].update(peakPending=9),
            lambda x: x["measurement"]["bands"][0].update(offered=21),
            lambda x: x["measurement"]["bands"][0].update(generatorCensored=1),
            lambda x: x["measurement"]["bands"][0].update(recoveryNanoseconds=101),
            lambda x: x["measurement"]["bands"][0].update(successfulPerSecond=99.0),
            lambda x: x["measurement"].update(controlProgress=0),
            lambda x: x["common"]["metrics"][0]["distribution"].update(droppedCount=1),
            lambda x: x["common"]["metrics"][0]["distribution"].update(counterOverflow=True),
            lambda x: x["common"]["metrics"][0]["distribution"].update(observedCount=47),
            lambda x: x["common"]["metrics"][0].update(clockDomain="another-run"),
            lambda x: x["common"]["metrics"][0].update(version=2),
            lambda x: x["common"]["metrics"].append(copy.deepcopy(x["common"]["metrics"][0])),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                row, native = fixture()
                mutate(native)
                with self.assertRaises(ValueError):
                    suites.compact(native, row)

    def test_operation_observer_disabled_preserves_driver_population(self):
        """Disabling wrapper metrics never removes mandatory driver counts or recovery evidence."""
        row, native = fixture()
        row["observer_mode"] = "disabled"
        native["configuration"]["observerMode"] = "disabled"
        native["common"]["identity"]["instrumentation"] = "driver-aggregate+operation-disabled"
        native["measurement"]["metrics"] = native["common"]["metrics"] = []
        self.assertEqual(suites.compact(native, row)["counts"]["admitted"], 64)

    def test_strict_bounded_json_and_soak_floor(self):
        """Syntactically plausible duplicates, nonfinite numbers and short soaks fail closed."""
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "report.json"
            for payload in ('{"a":1,"a":2}', '{"a":NaN}', '{"a":1e999}', '[]', '{"a":'):
                path.write_text(payload)
                with self.assertRaises(ValueError):
                    suites.read_json(path)
            path.write_text('{"a":"' + "x" * 100 + '"}')
            with self.assertRaises(ValueError):
                suites.read_json(path, cap=32)
        row, native = fixture()
        row["profile"] = native["configuration"]["profile"] = native["common"]["identity"]["profile"] = "soak"
        with self.assertRaisesRegex(ValueError, "1800"):
            suites.compact(native, row)
        for duration, cycle in ((1800, 8), (3600, 16), (4, 4)):
            self.assertEqual(suites.choose_cycle(duration, None), cycle)
        for duration, cycle in ((1800, 4), (8, 3), (8, 16)):
            with self.assertRaises(ValueError):
                suites.choose_cycle(duration, cycle)

    def test_artifact_replacement_is_detected_even_when_valid_json(self):
        """Post-capture rewrites cannot silently replace immutable native/envelope evidence."""
        row, native = fixture()
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            directory = output / "00-single"
            directory.mkdir()
            native_path, common_path = directory / "native-report.json", directory / "benchmark-envelope.json"
            native_path.write_text(json.dumps(native))
            common_path.write_text(json.dumps(native["common"]))
            process = dict(status="completed", exit_code=0, elapsed_ns=9_000_000_000,
                cleanup=dict(owner_reaped=True, unexpected_descendants=False, group_has_live_members_after_cleanup=False),
                dropped_bytes=dict(stdout=0, stderr=0, report_files=0),
                observation=dict(repetition=0, position=0, arm="single", seed=7),
                reports=[suites.driver.artifact(path) for path in (native_path, common_path)])
            self.assertEqual(suites.inspect_process(output, process, row)["status"], "completed")
            native_path.write_text(json.dumps(native) + "\n")
            with self.assertRaisesRegex(ValueError, "artifact changed"):
                suites.inspect_process(output, process, row)

    def test_external_timeout_and_output_cap_retain_failure_and_join_owner(self):
        """Real uncooperative children remain failed evidence after bounded SIGTERM/SIGKILL teardown."""
        programs = [
            ("import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(5)", "timed_out"),
            ("import os;os.write(1,b'x'*65536)", "diagnostic_limit_exceeded"),
        ]
        with tempfile.TemporaryDirectory() as temporary:
            for index, (program, status) in enumerate(programs):
                directory = Path(temporary) / str(index)
                result = suites.driver.run_process([sys.executable, "-c", program], directory,
                    suites.driver.ProcessLimits(timeout_seconds=.15, grace_seconds=.05, diagnostic_bytes=1024))
                self.assertEqual(result["status"], status)
                self.assertTrue(result["cleanup"]["owner_reaped"])
                self.assertFalse(result["cleanup"]["group_has_live_members_after_cleanup"])
                self.assertTrue((directory / "process.json").is_file())
                self.assertLessEqual((directory / "stdout.log").stat().st_size, 1024)
                result["observation"] = dict(repetition=0, position=0, arm="single", seed=7)
                with self.assertRaises(ValueError):
                    suites.inspect_process(Path(temporary), result, fixture()[0])

    def test_release_failure_gets_durable_summary_without_launching(self):
        """Missing or stale release receipts yield a truthful retained failed summary."""
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "capture"
            with mock.patch.object(suites.driver, "run_suite", side_effect=ValueError("stale release receipt")):
                status = suites.main(["--executable", sys.executable, "--receipt", str(output / "missing.json"), "--output-dir", str(output)])
            self.assertEqual(status, 1)
            summary = suites.read_json(output / "integration-summary.json")
            self.assertEqual(summary["status"], "failed")
            self.assertTrue(summary["informationalOnly"])
            self.assertEqual(summary["policyMode"], "reporting-only")
            self.assertEqual(summary["cases"], [])
            self.assertIn("stale release receipt", summary["failures"][0]["reason"])


if __name__ == "__main__":
    unittest.main()
