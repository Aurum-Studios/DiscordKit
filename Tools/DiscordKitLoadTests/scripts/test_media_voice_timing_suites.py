#!/usr/bin/env python3
# File: Tools/DiscordKitLoadTests/scripts/test_media_voice_timing_suites.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Reject biased or relabeled phase-nine captures before summarizing any timing."""
import copy
from pathlib import Path
import unittest

from run_media_voice_timing_suites import compact, matrix, participant_command


class CaptureIntegrityTests(unittest.TestCase):
    """Fault injection checks the completion and identity contract independently of Swift runners."""

    def fixture(self):
        """Create a small explicit media terminal population with an overlapping child metric."""
        row = dict(matrix("media", ["rtp.packetize.roundtrip"])[0], operations=2, warmup_operations=1, seed=1)
        metric = dict(id="media.batch", outcome="success", clockDomain="run-1", p50={}, p95={}, p99={}, maximum={},
                      distribution=dict(observedCount=2, droppedCount=0, counterOverflow=False))
        native = dict(format="DiscordMediaBenchmarks", schemaVersion=1, completedBatches=2, completedCalls=4, warmupBatches=1, warmupCalls=2,
                      configuration=dict(workload=row["case"], profile="smoke", seed=1, durationSeconds=10, warmupSeconds=1,
                                         batches=2, batchSize=2, warmupBatches=1),
                      common=dict(format="DiscordBenchmarkReport", schemaVersion=1, status="completed", clockDomain="run-1",
                                  identity=dict(catalogVersion=9, scenario=row["case"], profile="smoke", concurrency=1, seed=1,
                                                inputSizes=dict(batchSize=2, batchesCap=2, warmupBatchesCap=1, durationCapSeconds=10)),
                                  counts=dict(offered=2, admitted=2, completed=2, deadlineMisses=0,
                                              outcomes=dict(success=2, failure=0, cancelled=0, timedOut=0, rejected=0, uncertain=0)),
                                  cleanup=dict(completed=True, remainingOwners=0), metrics=[metric], gauges={}))
        return row, native

    def test_complete_and_explicit_command(self):
        """Keep separate fresh-process case identity and exact participant warmup/batch controls."""
        row, native = self.fixture()
        self.assertEqual(compact(native, row)["counts"]["completed"], 2)
        command = participant_command(Path("/fixture/tool"), row)
        self.assertEqual(command[0], "/fixture/tool")
        self.assertEqual(command[command.index("--batch-size") + 1], "2")
        self.assertEqual(command[command.index("--warmup-batches") + 1], "1")

    def test_partial_loss_and_wrong_identity_rejected(self):
        """A fast but partial or biased capture cannot enter the summary."""
        _, fixture = self.fixture()
        edits = [
            lambda x: x["common"].update(status="interrupted"),
            lambda x: x["common"]["counts"].update(offered=3),
            lambda x: x["common"]["counts"]["outcomes"].update(failure=1),
            lambda x: x["common"]["counts"].update(completed=True),
            lambda x: x["common"]["cleanup"].update(remainingOwners=1),
            lambda x: x["common"]["metrics"][0]["distribution"].update(droppedCount=1),
            lambda x: x["common"]["metrics"][0]["distribution"].update(counterOverflow=True),
            lambda x: x["common"]["metrics"][0].update(outcome="failure"),
            lambda x: x["common"]["metrics"][0].update(clockDomain="another-run"),
            lambda x: x["common"]["identity"].update(catalogVersion=8),
            lambda x: x["common"]["identity"]["inputSizes"].update(batchSize=4),
            lambda x: x["configuration"].update(warmupBatches=0),
            lambda x: x.update(completedCalls=3),
            lambda x: x.update(warmupCalls=3),
            lambda x: x["common"]["identity"].update(seed=9),
        ]
        row, _ = self.fixture()
        for edit in edits:
            with self.subTest(edit=edit):
                altered = copy.deepcopy(fixture)
                edit(altered)
                with self.assertRaises(ValueError):
                    compact(altered, row)

    def test_outcome_and_child_populations_remain_separate(self):
        """Children cannot mask missing primary failures or multiply terminal work."""
        row, native = self.fixture()
        native["common"]["counts"]["outcomes"].update(success=1, failure=1)
        first = native["common"]["metrics"][0]
        first["distribution"]["observedCount"] = 1
        child = copy.deepcopy(first)
        child.update(id="voice.handshake", outcome="failure")
        native["common"]["metrics"].append(child)
        with self.assertRaises(ValueError):
            compact(native, row)
        failure = copy.deepcopy(first)
        failure["outcome"] = "failure"
        native["common"]["metrics"].append(failure)
        self.assertEqual(compact(native, row)["counts"]["completed"], 2)

    def test_finite_sweeps_and_safe_case_paths(self):
        """Fanout and lifecycle contention are explicit; case IDs cannot escape artifact roots."""
        self.assertEqual({row["batch_size"] for row in matrix("media", ["dave.transition.queue"])}, {2, 8})
        self.assertEqual({row["concurrency"] for row in matrix("voice", ["voice.join"])}, {1, 4})
        queued = matrix("media", ["dave.transition.queue"])
        self.assertTrue(all(row["concurrency"] == row["batch_size"] for row in queued))
        row = dict(queued[-1], operations=2, warmup_operations=1)
        command = participant_command(Path("/fixture/tool"), row)
        self.assertEqual(command[command.index("--concurrency") + 1], "1")
        for family, cases in [("live", ["voice.join"]), ("media", []), ("media", ["../../escape"]), ("media", [".."])]:
            with self.assertRaises(ValueError):
                matrix(family, cases)


if __name__ == "__main__":
    unittest.main()
