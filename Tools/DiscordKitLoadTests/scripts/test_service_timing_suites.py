#!/usr/bin/env python3
# File: Tools/DiscordKitLoadTests/scripts/test_service_timing_suites.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Check finite Phase 8 sweeps and fail-closed projections of supervised evidence."""
import copy
import importlib.util
from pathlib import Path
import sys
import unittest
import run_service_timing_suites as suites


def complete_row(case="oauth.lookup"):
    """Return the exact selected policy expected from one supervised matrix participant."""
    return dict(suites.matrix([case])[0], requests=2, warmup_requests=1)


def complete_native(case="oauth.lookup"):
    """Build a schema-validated projection fixture with exact scenario, dimensions and outcomes."""
    row = complete_row(case)
    configuration = dict(scenario=case, concurrency=4, fanOut=2, delayMicroseconds=2000,
        profile="smoke", durationSeconds=10, warmupSeconds=1, requests=2, warmupRequests=1)
    dimensions = dict(requests=2, warmupRequests=1, configuredConcurrency=4, fanOut=2,
        delayMicroseconds=2000, durationCapSeconds=10)
    configuration.update(concurrency=row["concurrency"], delayMicroseconds=row["delay_microseconds"])
    dimensions.update(configuredConcurrency=row["concurrency"], delayMicroseconds=row["delay_microseconds"])
    extra = suites.versioned_dimensions(row)
    configuration.update({key: value for key, value in extra.items() if key != "replyCohort"})
    dimensions.update(extra)
    return dict(format="DiscordKitLoadTests.service-timing", schemaVersion=1, configuration=configuration,
        common=dict(status="completed", identity=dict(catalogVersion=8, scenario=case, profile="smoke",
        concurrency=min(row["concurrency"], 2), inputSizes=dimensions), cleanup=dict(completed=True, remainingOwners=0),
        counts=dict(offered=2, admitted=1, completed=2, outcomes=dict(success=1, failure=0,
            cancelled=0, timedOut=0, rejected=1, uncertain=0)), gauges={}, throughputPerSecond=10,
        metrics=[dict(id=suites.primary_metric(case), outcome=outcome, p50={}, p95={}, p99={}, maximum={},
            distribution=dict(droppedCount=0, counterOverflow=False, observedCount=1))
            for outcome in ("success", "rejected")]))


class ServiceTimingSuiteTests(unittest.TestCase):
    def test_dimensions_are_finite_and_distinct(self):
        """Contention, fanout and injected wait sweeps retain their explicit independent labels."""
        rows = suites.matrix(["oauth.singleFlight", "rpc.requests", "rpc.events", "activities.subscriptions", "service.gameMembers"])
        self.assertEqual(len(rows), len({row["name"] for row in rows}))
        self.assertEqual({row["concurrency"] for row in rows}, {1, 4, 8, 32})
        self.assertEqual({row["fan_out"] for row in rows}, {1, 2, 8, 32})
        self.assertEqual({row["delay_microseconds"] for row in rows}, {0, 2000, 10000})
        self.assertEqual(len(suites.matrix(["oauth.lookup", "oauth.lookup"])), 1)
        with self.assertRaises(ValueError):
            suites.matrix(["purchase"])

    def test_primary_populations_keep_family_identity(self):
        """Each optional product keeps its own complete caller population and catalog identity."""
        for case, metric in (("oauth.lookup", "oauth.lookup"), ("oauth.storage", "oauth.install"),
                             ("oauth.revoke", "oauth.revoke"), ("rpc.requests", "rpc.request"),
                             ("activities.requests", "activities.request"), ("service.gameMembers", "service.operation")):
            native = complete_native(case)
            compact = suites.compact(native, complete_row(case))
            self.assertEqual(compact["counts"]["outcomes"]["rejected"], 1)
            self.assertEqual(compact["terminalOutcomesPerSecond"], 10)

    def test_incomplete_evidence_is_rejected(self):
        """Unknown versions, terminal loss, aggregate loss and retained owners cannot become a passing row."""
        mutations = [
            lambda value: value.update(format="DiscordKitLoadTests.cache-client-timing"),
            lambda value: value.update(schemaVersion=True),
            lambda value: value["common"].update(status="interrupted"),
            lambda value: value["common"]["cleanup"].update(completed=False),
            lambda value: value["common"]["cleanup"].update(remainingOwners=1),
            lambda value: value["common"]["counts"].update(completed=1),
            lambda value: value["common"]["counts"]["outcomes"].update(rejected=0),
            lambda value: value["common"]["counts"]["outcomes"].update(rejected=True),
            lambda value: value["common"]["metrics"][0]["distribution"].update(droppedCount=1),
            lambda value: value["common"]["metrics"][0]["distribution"].update(observedCount=0),
            lambda value: value["common"]["metrics"][0].update(id="rpc.request"),
            lambda value: value["common"]["metrics"][0]["distribution"].update(counterOverflow=True),
            lambda value: value["common"]["identity"].update(catalogVersion=7),
            lambda value: value["common"]["metrics"][1].update(outcome="success"),
            lambda value: value["configuration"].update(scenario="oauth.singleFlight"),
            lambda value: value["configuration"].update(concurrency=8),
            lambda value: value["common"]["identity"].update(scenario="oauth.singleFlight"),
            lambda value: value["common"]["identity"].update(concurrency=4),
            lambda value: value["common"]["identity"]["inputSizes"].update(delayMicroseconds=10000),
        ]
        for mutation in mutations:
            native = copy.deepcopy(complete_native())
            mutation(native)
            with self.assertRaises(ValueError):
                suites.compact(native, complete_row())

    def test_participant_options_preserve_wait_and_wall_caps(self):
        """Subprocess substitutions retain shared-driver policy and selected injected backend waits."""
        command = suites.participant_command(Path("/fixture/tool"), dict(case="rpc.requests", fan_out=8,
            delay_microseconds=10000), 32, 4)
        self.assertEqual(command[:2], ["/fixture/tool", "service-timing"])
        options = dict(zip(command[2::2], command[3::2]))
        self.assertEqual(options["--delay-microseconds"], "10000")
        self.assertEqual(options["--fan-out"], "8")
        self.assertEqual(options["--requests"], "32")
        self.assertEqual(options["--concurrency"], "{concurrency}")
        self.assertEqual(options["--duration-seconds"], "{duration_seconds}")
        self.assertEqual(options["--warmup-seconds"], "{warmup_seconds}")

    def test_versioned_matrix_discriminates_owner_dimensions(self):
        """Same-owner grants, fixed token groups and parked queues retain independent finite policies."""
        rows = suites.matrix(["oauth.sharedRefreshV2", "activities.subscriptionGroupsV1", "rpc.queuedRepliesV1"])
        self.assertEqual(len(rows), len({row["name"] for row in rows}))
        oauth = [row for row in rows if row["case"] == "oauth.sharedRefreshV2"]
        self.assertEqual({row["concurrency"] for row in oauth}, {1, 4, 64, 256})
        self.assertTrue(all(row["delay_microseconds"] == 0 for row in oauth))
        self.assertTrue(any(row["storage_delay_microseconds"] == 10000 and row["backend_delay_microseconds"] == 0 for row in oauth))
        self.assertTrue(any(row["backend_delay_microseconds"] == 10000 and row["storage_delay_microseconds"] == 0 for row in oauth))
        groups = [row for row in rows if "tokens4096" in row["name"]]
        self.assertEqual({row["subscription_groups"] for row in groups}, {1, 16, 256, 1024})
        self.assertTrue(all(row["subscription_groups"] * (row["owners_per_group"] + 1) == 4096 for row in groups))
        queues = [row for row in rows if row["case"] == "rpc.queuedRepliesV1"]
        self.assertEqual({row["queue_depth"] for row in queues}, {0, 64, 1024, 4096})
        self.assertTrue(all(row["requests"] == 2 and row["warmup_requests"] == 1 for row in groups + queues))

    def test_matrix_profiles_fit_actual_single_arm_supervisor_schedule(self):
        """A 256-reader row selects the bounded one-process cap profile accepted by the real supervisor."""
        path = Path(__file__).resolve().parents[2] / "DiscordBenchmarkSupport" / "scripts" / "run_benchmarks.py"
        spec = importlib.util.spec_from_file_location("service_timing_shared_runner", path)
        shared = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = shared
        spec.loader.exec_module(shared)
        for row in suites.matrix(sorted(suites.OAUTH_SCALING_CASES)):
            profile = shared.PROFILES[row["profile"]]
            self.assertLessEqual(row["concurrency"], profile.active_cohort_cap)
            self.assertLessEqual(row["duration_seconds"], profile.measured_cap_seconds)
            self.assertLessEqual(row["warmup_seconds"], profile.warmup_cap_seconds)
            self.assertEqual(len(shared.schedule(profile, seed=1, paired=False)), 1)
            self.assertEqual(row["profile"], "soak" if row["concurrency"] == 256 else "smoke")

    def test_versioned_primary_and_dimension_validation(self):
        """Every new dimension is checked in both participant policy and strict common identity."""
        for case in ["oauth.sharedRefreshV2", "oauth.unrelatedRefreshV2", "oauth.partialCancellationV2",
                     "activities.subscriptionGroupsV1", "rpc.queuedRepliesV1"]:
            row, native = complete_row(case), complete_native(case)
            suites.compact(native, row)
            extra = suites.versioned_dimensions(row)
            for key, value in extra.items():
                changed = copy.deepcopy(native)
                changed["common"]["identity"]["inputSizes"][key] = value + 1
                with self.assertRaises(ValueError):
                    suites.compact(changed, row)
                if key != "replyCohort":
                    changed = copy.deepcopy(native)
                    changed["configuration"][key] = value + 1
                    with self.assertRaises(ValueError):
                        suites.compact(changed, row)
            command = suites.participant_command(Path("/fixture/tool"), row, 2, 1)
            options = dict(zip(command[2::2], command[3::2]))
            if case.startswith("oauth."):
                self.assertEqual(options["--storage-delay-microseconds"], "0")
                self.assertEqual(options["--backend-delay-microseconds"], "0")
            elif case.startswith("activities."):
                self.assertEqual(options["--subscription-groups"], "1")
                self.assertEqual(options["--owners-per-group"], "1")
            else:
                self.assertEqual(options["--queue-depth"], "0")
                self.assertEqual(suites.primary_metric(case), "rpc.queuedReplyCohortV1")
                changed = copy.deepcopy(native)
                changed["common"]["metrics"][0]["id"] = "rpc.request"
                with self.assertRaises(ValueError):
                    suites.compact(changed, row)


if __name__ == "__main__":
    unittest.main()
