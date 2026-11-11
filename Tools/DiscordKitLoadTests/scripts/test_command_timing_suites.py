#!/usr/bin/env python3
# File: Tools/DiscordKitLoadTests/scripts/test_command_timing_suites.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Check finite Phase 6 sweeps and retained exact-outcome evidence."""
import copy
from pathlib import Path
import unittest
import run_command_timing_suites as suites


def complete_native():
    """A minimal already-schema-validated participant report used by the matrix projection."""
    return dict(format="DiscordKitLoadTests.command-timing", schemaVersion=1,
        common=dict(status="completed", identity=dict(catalogVersion=6),
        cleanup=dict(completed=True, remainingOwners=0),
        counts=dict(offered=2, admitted=1, completed=2, outcomes=dict(success=1, failure=0,
            cancelled=0, timedOut=0, rejected=1, uncertain=0)), gauges={}, throughputPerSecond=10,
        metrics=[dict(id="interaction.workflow", outcome="success", p50={}, p95={}, p99={}, maximum={},
            distribution=dict(droppedCount=0, counterOverflow=False))]))


class CommandTimingSuiteTests(unittest.TestCase):
    def test_gateway_control_and_recovery_require_actual_native_receipts(self):
        native = complete_native()
        gateway = dict(recoverySucceeded=False, controlWhileHandlerBlocked=True)
        native["measurement"] = dict(gateway={"_0": gateway})
        row = dict(name="gateway.overloadRecovery-c1-r200", case="gateway.overloadRecovery")
        with self.assertRaises(ValueError):
            suites.compact(native, row)
        gateway["recoverySucceeded"] = True
        gateway["controlWhileHandlerBlocked"] = False
        with self.assertRaises(ValueError):
            suites.compact(native, row)
        gateway["controlWhileHandlerBlocked"] = True
        self.assertTrue(suites.compact(native, row)["controlWhileHandlerBlocked"])

    def test_rate_and_concurrency_sweep_is_bounded_and_complete(self):
        for case in ("gateway.slowHandler", "gateway.overloadRecovery"):
            rows = suites.matrix([case])
            self.assertEqual({(row["concurrency"], row["rate"]) for row in rows},
                             {(c, r) for c in (1, 4, 16) for r in (200, 2000, 20000)})
            self.assertEqual(len(rows), 9)

    def test_synthetic_pairs_use_fresh_processes_in_both_orders(self):
        cases = ["synthetic.directImmediate", "synthetic.dslImmediate"]
        rows = suites.matrix(cases)
        self.assertEqual([row["case"] for row in rows], cases + list(reversed(cases)))
        self.assertEqual(len(rows), len({row["name"] for row in rows}))
        self.assertEqual(len(suites.matrix(["interaction.immediate", "interaction.immediate"])), 1)

    def test_partial_outcomes_and_cleanup_fail_closed(self):
        valid = complete_native()
        row = dict(name="interaction.immediate")
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
            lambda value: value["common"]["metrics"][0]["distribution"].update(counterOverflow=True),
            lambda value: value["common"]["identity"].update(catalogVersion=5),
        ]
        for mutation in mutations:
            invalid = copy.deepcopy(valid)
            mutation(invalid)
            with self.assertRaises(ValueError):
                suites.compact(invalid, row)

    def test_participant_options_carry_wall_caps_and_shared_driver_fields(self):
        row = dict(case="gateway.overloadRecovery", concurrency=4, rate=2000)
        command = suites.participant_command(Path("/fixture/tool"), row, 32, 4)
        self.assertEqual(command[:2], ["/fixture/tool", "command-timing"])
        options = dict(zip(command[2::2], command[3::2]))
        self.assertEqual(options["--requests"], "32")
        self.assertEqual(options["--rate"], "2000")
        self.assertEqual(options["--concurrency"], "{concurrency}")
        self.assertEqual(options["--duration-seconds"], "{duration_seconds}")
        self.assertEqual(options["--warmup-seconds"], "{warmup_seconds}")


if __name__ == "__main__":
    unittest.main()
