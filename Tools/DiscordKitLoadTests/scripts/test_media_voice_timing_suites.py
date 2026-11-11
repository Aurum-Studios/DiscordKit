#!/usr/bin/env python3
# File: Tools/DiscordKitLoadTests/scripts/test_media_voice_timing_suites.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Reject biased or relabeled phase-nine captures before summarizing any timing."""
import copy
from pathlib import Path
import unittest

from run_media_voice_timing_suites import compact, matrix, participant_command, versioned_media_dimensions


class CaptureIntegrityTests(unittest.TestCase):
    """Fault injection checks the completion and identity contract independently of Swift runners."""

    def fixture(self, case="rtp.packetize.roundtrip"):
        """Create a small explicit media terminal population with an overlapping child metric."""
        row = dict(matrix("media", [case])[0], operations=2, warmup_operations=1, seed=1)
        metric = dict(id="mls.transition" if case.startswith("mls.") or case == "dave.transition.queue" else "media.batch",
                      outcome="success", clockDomain="run-1", p50={}, p95={}, p99={}, maximum={},
                      distribution=dict(observedCount=2, droppedCount=0, counterOverflow=False))
        native = dict(format="DiscordMediaBenchmarks", schemaVersion=1, completedBatches=2, completedCalls=4, warmupBatches=1, warmupCalls=2,
                      configuration=dict(workload=row["case"], profile="smoke", seed=1, durationSeconds=10, warmupSeconds=1,
                                         batches=2, batchSize=2, warmupBatches=1),
                      common=dict(format="DiscordBenchmarkReport", schemaVersion=1, status="completed", clockDomain="run-1",
                                  identity=dict(catalogVersion=9, scenario=row["case"], profile="smoke", concurrency=row["concurrency"],
                                                scheduler=row["scheduler"], seed=1,
                                                inputSizes=dict(batchSize=2, batchesCap=2, warmupBatchesCap=1, durationCapSeconds=10)),
                                  counts=dict(offered=2, admitted=2, completed=2, deadlineMisses=0,
                                              outcomes=dict(success=2, failure=0, cancelled=0, timedOut=0, rejected=0, uncertain=0)),
                                  cleanup=dict(completed=True, remainingOwners=0), metrics=[metric], gauges={}))
        native["common"]["identity"]["inputSizes"].update(versioned_media_dimensions(case))
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
            lambda x: x["common"]["identity"].update(scheduler="wrong-owner-policy"),
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

    def test_stream_and_joined_job_schedulers_match_native_policies(self):
        """Supervisor receipts declare actual owner/job policies while the participant's outer loop remains serial."""
        cases = {
            "dave.transition.queue": ("joined-concurrent-signaling-batches", 2),
            "resample.v2.continuous.44100.48000.stereo": ("serial-population-stream-v2", 1),
            "opus.v2.continuous.decode.celt.960.mono": ("serial-population-stream-v2", 1),
            "dave.v2.frame.open.replay8192": ("serial-population-stream-v2", 1),
            "resample.v3.continuous.48000.47999.stereo.irregular": ("serial-population-stream-v3", 1),
            "pcm.v3.queue.occupancy4096": ("serial-population-stream-v3", 1),
            "resample.v3.startup.44100.48000.mono": ("serial-wrapper-batches", 1),
            "dave.v4.open.steady.replay64": ("serial-population-stream-v4", 1),
            "dave.v4.expiry.replay8192": ("serial-wrapper-batches", 1),
            "mls.v4.add1.dense.members16": ("serial-wrapper-batches", 1),
            "mls.v4.mixed.dense.members8": ("joined-concurrent-transition-media-batches-v4", 2),
        }
        for case, (scheduler, concurrency) in cases.items():
            with self.subTest(case=case):
                row, native = self.fixture(case)
                self.assertEqual((row["scheduler"], row["concurrency"]), (scheduler, concurrency))
                self.assertEqual(compact(native, row)["scheduler"], scheduler)
                command = participant_command(Path("/fixture/tool"), row)
                self.assertEqual(command[command.index("--concurrency") + 1], "1")
                for incorrect in (dict(row, scheduler="serial-wrapper-batches-wrong"), dict(row, concurrency=concurrency + 1)):
                    with self.assertRaises(ValueError):
                        compact(native, incorrect)

    def test_version_four_dimensions_survive_compaction_and_relabeling_is_rejected(self):
        """Window, expiry, tree shape, proposal counts and media fanout cannot silently relabel a distribution."""
        cases = ["dave.v4.open.steady.replay64", "dave.v4.open.reorderDuplicate.replay1024",
                 "dave.v4.open.authenticationFailure.replay8192", "dave.v4.expiry.replay1024",
                 "mls.v4.add1.dense.members16", "mls.v4.remove3.dense.members8", "mls.v4.remove1.sparse.members4",
                 "mls.v4.mixed.dense.members8", "rtp.v4.accounting.serialize.payload80",
                 "jitter.v4.accounting.insertPop.payload16000"]
        for case in cases:
            row, native = self.fixture(case)
            dimensions = versioned_media_dimensions(case)
            self.assertTrue(dimensions)
            self.assertEqual(compact(native, row)["inputSizes"], native["common"]["identity"]["inputSizes"])
            for key, value in dimensions.items():
                with self.subTest(case=case, dimension=key):
                    altered = copy.deepcopy(native)
                    altered["common"]["identity"]["inputSizes"][key] = value + 1
                    with self.assertRaises(ValueError):
                        compact(altered, row)
                    del altered["common"]["identity"]["inputSizes"][key]
                    with self.assertRaises(ValueError):
                        compact(altered, row)


if __name__ == "__main__":
    unittest.main()
