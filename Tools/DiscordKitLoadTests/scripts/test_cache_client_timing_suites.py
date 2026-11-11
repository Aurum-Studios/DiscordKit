#!/usr/bin/env python3
# File: Tools/DiscordKitLoadTests/scripts/test_cache_client_timing_suites.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Check finite Phase 7 sweeps and retained exact-outcome evidence."""
import copy
from pathlib import Path
import unittest
import run_cache_client_timing_suites as suites


def complete_native():
    """A minimal already-schema-validated participant report used by the matrix projection."""
    return dict(format="DiscordKitLoadTests.cache-client-timing", schemaVersion=1,
        common=dict(status="completed", identity=dict(catalogVersion=7),
        cleanup=dict(completed=True, remainingOwners=0),
        counts=dict(offered=2, admitted=1, completed=2, outcomes=dict(success=1, failure=0,
            cancelled=0, timedOut=0, rejected=1, uncertain=0)), gauges={}, throughputPerSecond=10,
        metrics=[dict(id="cache.call", outcome="success", p50={}, p95={}, p99={}, maximum={},
            distribution=dict(droppedCount=0, counterOverflow=False, observedCount=2))]))


class CacheClientTimingSuiteTests(unittest.TestCase):
    def test_dimensions_have_finite_distinct_rows(self):
        """Working set, hit ratio, identity, contention and subscriber sweeps retain exact dimensions."""
        rows = suites.matrix(["cache.lookup", "cache.singleFlight", "cache.broadcast", "client.lifecycle"])
        self.assertEqual(len(rows), len({row["name"] for row in rows}))
        self.assertEqual({row["working_set"] for row in rows}, {16, 256, 4096})
        self.assertEqual({row["hit_percent"] for row in rows}, {0, 50, 100})
        self.assertEqual({row["identities"] for row in rows}, {1, 8})
        self.assertEqual({row["concurrency"] for row in rows}, {1, 4, 8, 32})
        broadcast = [row for row in rows if row["case"] == "cache.broadcast"]
        self.assertTrue({(fan, slow) for fan in (1, 8, 32) for slow in (False, True)}.issubset(
            {(row["fan_out"], row["slow_subscriber"]) for row in broadcast}))
        self.assertEqual(len(suites.matrix(["client.lifecycle", "client.lifecycle"])), 1)
        large = next(row for row in rows if row["working_set"] == 4096)
        self.assertEqual((large["profile"], large["duration_seconds"], large["warmup_seconds"]), ("soak", 60, 60))
        self.assertTrue(all(row["profile"] == "smoke" for row in rows if row is not large))

    def test_partial_outcomes_and_cleanup_fail_closed(self):
        valid = complete_native()
        row = dict(name="cache.lookup")
        result = suites.compact(valid, row)
        self.assertEqual(result["counts"]["outcomes"]["rejected"], 1)
        self.assertEqual(result["terminalOutcomesPerSecond"], 10)
        mutations = [
            lambda value: value.update(format="DiscordKitLoadTests.timing"),
            lambda value: value.update(schemaVersion=True),
            lambda value: value["common"].update(status="interrupted"),
            lambda value: value["common"]["cleanup"].update(remainingOwners=1),
            lambda value: value["common"]["counts"].update(completed=1),
            lambda value: value["common"]["counts"]["outcomes"].update(rejected=0),
            lambda value: value["common"]["metrics"][0]["distribution"].update(droppedCount=1),
            lambda value: value["common"]["metrics"][0]["distribution"].update(observedCount=1),
            lambda value: value["common"]["metrics"][0].update(id="unrelated.population"),
            lambda value: value["common"]["metrics"][0]["distribution"].update(counterOverflow=True),
            lambda value: value["common"]["identity"].update(catalogVersion=5),
        ]
        for mutation in mutations:
            invalid = copy.deepcopy(valid)
            mutation(invalid)
            with self.assertRaises(ValueError):
                suites.compact(invalid, row)

    def test_participant_options_carry_wall_caps_and_shared_driver_fields(self):
        row = dict(case="cache.lookup", concurrency=4, working_set=256, identities=8,
                   hit_percent=50, fan_out=2, slow_subscriber=False)
        command = suites.participant_command(Path("/fixture/tool"), row, 32, 4)
        self.assertEqual(command[:2], ["/fixture/tool", "cache-client-timing"])
        options = dict(zip(command[2::2], command[3::2]))
        self.assertEqual(options["--requests"], "32")
        self.assertEqual(options["--working-set"], "256")
        self.assertEqual(options["--identities"], "8")
        self.assertEqual(options["--hit-percent"], "50")
        self.assertEqual(options["--slow-subscriber"], "false")
        self.assertEqual(options["--concurrency"], "{concurrency}")
        self.assertEqual(options["--duration-seconds"], "{duration_seconds}")
        self.assertEqual(options["--warmup-seconds"], "{warmup_seconds}")


if __name__ == "__main__":
    unittest.main()
