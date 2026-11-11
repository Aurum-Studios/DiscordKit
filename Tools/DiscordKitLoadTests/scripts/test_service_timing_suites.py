#!/usr/bin/env python3
# File: Tools/DiscordKitLoadTests/scripts/test_service_timing_suites.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Check finite Phase 8 sweeps and fail-closed projections of supervised evidence."""
import copy
from pathlib import Path
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
    return dict(format="DiscordKitLoadTests.service-timing", schemaVersion=1, configuration=configuration,
        common=dict(status="completed", identity=dict(catalogVersion=8, scenario=case, profile="smoke",
        concurrency=2, inputSizes=dimensions), cleanup=dict(completed=True, remainingOwners=0),
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


if __name__ == "__main__":
    unittest.main()
