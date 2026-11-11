// File: Tools/VoiceSessionQualification/Tests/VoiceSessionQualificationTests/QualificationTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordTransport
import DiscordVoice
import DiscordVoiceCodecs
import Foundation
import Testing
@testable import VoiceSessionQualification

/// The unchanged default keeps schema-two timing geometry and the separate two-second warmup.
@Test func defaultPolicyRetainsLegacyProfile() throws {
    let value = try QualificationConfiguration.parse(["--seconds", "0.02"], environment: [:])
    #expect(!value.attributed && value.frameSamples == 960 && value.channels == 1 && value.frameCount == 1)
    #expect(value.warmupFrames == 100 && value.playoutDelayFrames == 0 && !value.dtx)
}

/// Malformed, duplicate and unbounded policy pairs fail synchronously before any resource creation.
@Test func finiteProfileAdmissionPrecedesResourceCreation() throws {
    for arguments in [
        ["--seconds", "nan"], ["--seconds", "inf"], ["--seconds", "3601"],
        ["--frame-samples", "60"], ["--frame-samples", "120", "--mode", "silk"],
        ["--frame-samples", "240", "--mode", "hybrid"], ["--channels", "3"],
        ["--mode", "unknown"], ["--dtx", "true"], ["--signal", "unknown"],
        ["--loss-every", "-1"], ["--reorder-every", "1001"], ["--jitter-ms", "101"],
        ["--contention-workers", "5"], ["--seconds", "1", "--seconds", "2"], ["--output"],
    ] {
        #expect(throws: (any Error).self) { try QualificationConfiguration.parse(arguments, environment: [:]) }
    }
    #expect(throws: (any Error).self) {
        try QualificationConfiguration.parse([], environment: ["DK_BENCHMARK_ENVELOPE": ""])
    }
    let value = try QualificationConfiguration.parse(["--frame-samples", "120", "--channels", "2", "--jitter-ms", "100"],
        environment: ["DK_BENCHMARK_ENVELOPE": "common.json"])
    #expect(value.attributed && value.frameNanoseconds == 2_500_000 && value.warmupFrames == 800)
    #expect(value.playoutDelayFrames == 40 && value.commonReport == "common.json")
    #expect(value.identity().catalogVersion == 9)
    #expect(value.identity().inputSizes["playoutDelayFrames"] == 40)
}

/// Every admitted mode, frame and channel combination actually encodes the exact harness tone fixture.
@Test func supportedCodecGeometryHasDistinctIdentity() throws {
    for mode in ["celt", "silk", "hybrid"] {
        for channels in [1, 2] {
            for frames in mode == "celt" ? [120, 240, 480, 960] : [480, 960] {
                let value = try QualificationConfiguration.parse(["--mode", mode, "--channels", String(channels),
                    "--frame-samples", String(frames)], environment: [:])
                var encoder = try value.encoder()
                #expect(encoder.frameSampleCount == frames && encoder.channelCount == channels)
                let pcm = (0..<(frames * channels)).map { Float(sin(Double($0 / channels) * 2 * .pi * 440 / 48_000) * 0.2) }
                let encoded = try encoder.encode(pcm)
                let parsed = try OpusPacket(encoded.data)
                #expect(encoded.shouldTransmit && parsed.sampleCount == frames && parsed.channelCount == channels)
                #expect(value.identity().profile == "attributed-\(mode)-tone")
            }
        }
    }
}

/// Actual production DTX decisions match independent media-time hangover, refresh and restart expectations.
@Test func independentCadenceAccountsForSuppressionRefreshAndRestart() throws {
    var configuration = try QualificationConfiguration.parse(["--dtx", "on", "--signal", "talkspurts"], environment: [:])
    for samples in [120, 240, 480, 960] {
        configuration.frameSamples = samples
        var encoder = try configuration.encoder()
        let active = Array(repeating: Float(0.2), count: samples)
        let silent = Array(repeating: Float(0), count: samples)
        _ = try encoder.encode(active)
        var policy = SendCadencePolicy()
        var emitted: [Int] = []
        for frame in 0..<(48_000 / samples) {
            let encoded = try encoder.encode(silent)
            let expected = policy.expectsTransmission(active: false, configuration: configuration)
            #expect(encoded.shouldTransmit == expected)
            if encoded.shouldTransmit { emitted.append(frame) }
        }
        #expect(policy.suppressed > 0 && policy.refreshes == 2)
        #expect(emitted.count == 9_600 / samples + 2)
        let expectedRestart = policy.expectsTransmission(active: true, configuration: configuration)
        let restarted = try encoder.encode(active)
        #expect(expectedRestart && restarted.shouldTransmit)
        #expect(policy.restarts == 1)
    }
}

/// Receiver-side emulation drops selected packets and actually inverts held stream packets within finite bounds.
@Test func receiverEmulationDropsAndReordersWithinFiniteCapacity() throws {
    let configuration = try QualificationConfiguration.parse(["--reorder-every", "2", "--loss-every", "4"], environment: [:])
    let peer = DatagramAddress(host: "127.0.0.1", port: 50000)
    var queue = ImpairmentQueue()
    try queue.enqueue(.init(bytes: Data([1]), peer: peer), tick: 0, ordinal: 1, configuration: configuration)
    #expect(queue.ready(tick: 0).map(\.bytes) == [Data([1])])
    try queue.enqueue(.init(bytes: Data([2]), peer: peer), tick: 1, ordinal: 2, configuration: configuration)
    #expect(queue.ready(tick: 1).isEmpty)
    try queue.enqueue(.init(bytes: Data([3]), peer: peer), tick: 2, ordinal: 3, configuration: configuration)
    #expect(queue.ready(tick: 2).map(\.bytes) == [Data([3]), Data([2])])
    try queue.enqueue(.init(bytes: Data([4]), peer: peer), tick: 3, ordinal: 4, configuration: configuration)
    #expect(queue.dropped == 1 && queue.reordered == 1 && queue.pending.isEmpty)
    #expect(queue.peakCount == 2 && queue.peakBytes == 2)
}

private struct FailingTransformer: VoiceFrameTransformer {
    struct Failure: Error {}
    /// Forces an exact deterministic seal failure without media, network or cryptographic state.
    func seal(_ opus: Data, ssrc: UInt32) async throws -> Data { throw Failure() }
    /// Returns inert test bytes; this fixture never participates in a real receive path.
    func open(_ frame: Data, ssrc: UInt32) async throws -> Data { frame }
}

/// A failed child produces exactly one failure observation after measured collection begins.
@Test func attributionExcludesWarmupAndClassifiesFailedChildExactlyOnce() async throws {
    let statistics = try RunStatistics(workloads: AttributionCapture.workloads)
    let capture = AttributionCapture(statistics: statistics)
    let transformer = AttributedTransformer(base: FailingTransformer(), capture: capture)
    await #expect(throws: FailingTransformer.Failure.self) { try await transformer.seal(Data([1]), ssrc: 1) }
    #expect(statistics.metrics().isEmpty)
    capture.setEnabled(true)
    await #expect(throws: FailingTransformer.Failure.self) { try await transformer.seal(Data([1]), ssrc: 1) }
    let rows = statistics.metrics()
    #expect(rows.count == 1 && rows[0].id == "voice.encrypt" && rows[0].outcome == .failure)
    #expect(rows[0].distribution.observedCount == 1)
    capture.record(.nanoseconds(1), workload: .voiceSend, error: TransportFailure.deadlineExceeded)
    #expect(statistics.metrics().contains { $0.id == "voice.send" && $0.outcome == .timedOut && $0.distribution.observedCount == 1 })
    #expect(VoiceSessionQualification.attributionScopes["voice.receiveDecrypt"]?.contains("jitter insertion") == true)
    #expect(VoiceSessionQualification.attributionScopes["voice.decode"]?.contains("jitter selection") == true)
}

/// Every explicitly owned contender reaches cancellation and a joined terminal value.
@Test func contentionWorkersAreCancelledAndAwaited() async {
    let owner = CPUContention(workers: 2)
    #expect(await owner.close() == 2)
    let allCancelled = owner.tasks.allSatisfy { $0.isCancelled }
    #expect(allCancelled)
}

/// Native/common alias destinations fail admission for both explicit and environment-selected reports.
@Test func standardizedAndSymlinkReportAliasesFailBeforeWork() throws {
    #expect(throws: (any Error).self) {
        try QualificationConfiguration.parse(["--output", "result.json", "--common-report", "./result.json"], environment: [:])
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("discordkit-voice-alias-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appendingPathComponent("original.json"), alias = directory.appendingPathComponent("alias.json")
    try Data().write(to: original)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
    #expect(throws: (any Error).self) {
        try QualificationConfiguration.parse(["--profile", "attributed", "--output", original.path],
            environment: ["DK_BENCHMARK_ENVELOPE": alias.path])
    }
    #expect(throws: (any Error).self) {
        try QualificationConfiguration.parse(["--output", original.path], environment: ["DK_BENCHMARK_ENVELOPE": alias.path])
    }
}

/// Driver seed and duration fallbacks preserve UInt64 precision and reject incompatible warmup policy.
@Test func driverSeedDurationAndFixedWarmupAreExplicit() throws {
    let value = try QualificationConfiguration.parse(["--profile", "attributed"], environment: [
        "DK_BENCHMARK_SEED": String(UInt64.max), "DK_BENCHMARK_DURATION_SECONDS": "0.125", "DK_BENCHMARK_WARMUP_SECONDS": "2",
    ])
    #expect(value.seed == UInt64.max && value.seconds == 0.125)
    #expect(value.identity().seed == UInt64.max)
    #expect(value.identity().inputSizes["requestedDurationNanoseconds"] == 125_000_000)
    #expect(value.identity().requestedWarmupNanoseconds == 2_000_000_000)
    let explicit = try QualificationConfiguration.parse(["--seconds", "0.5", "--seed", "9"], environment: [
        "DK_BENCHMARK_SEED": "10", "DK_BENCHMARK_DURATION_SECONDS": "0.25",
    ])
    #expect(explicit.seed == 9 && explicit.seconds == 0.5)
    for environment in [["DK_BENCHMARK_SEED": "18446744073709551616"],
        ["DK_BENCHMARK_DURATION_SECONDS": "nan"], ["DK_BENCHMARK_WARMUP_SECONDS": "0"]] {
        #expect(throws: (any Error).self) {
            try QualificationConfiguration.parse(["--profile", "attributed"], environment: environment)
        }
    }
}

/// Common cleanup preserves missing native owner receipts and rejects impossible closure counts.
@Test func attributedCleanupReflectsFailedNativeClosureReceipts() throws {
    let complete = try VoiceSessionQualification.attributedCleanup(closedMediaOwners: 2, closedDAVEOwners: 2,
        closedDatagramOwners: 2, configuredContentionWorkers: 2, closedContentionWorkers: 2)
    #expect(complete.completed == true && complete.remainingOwners == 0 && complete.reason == nil)
    let missing = try VoiceSessionQualification.attributedCleanup(closedMediaOwners: 1, closedDAVEOwners: 0,
        closedDatagramOwners: 1, configuredContentionWorkers: 3, closedContentionWorkers: 1)
    #expect(missing.completed == false && missing.remainingOwners == 6 && missing.reason != nil)
    for counts in [[-1, 2, 2, 0, 0], [3, 2, 2, 0, 0], [2, 3, 2, 0, 0],
        [2, 2, 3, 0, 0], [2, 2, 2, 5, 0], [2, 2, 2, 1, 2], [2, 2, 2, 1, -1]] {
        #expect(throws: QualificationFailure.self) {
            try VoiceSessionQualification.attributedCleanup(closedMediaOwners: counts[0], closedDAVEOwners: counts[1],
                closedDatagramOwners: counts[2], configuredContentionWorkers: counts[3], closedContentionWorkers: counts[4])
        }
    }
}

/// The phase-eight loss/reorder/hold trigger now completes real encrypted localhost duplex and joined closure.
@Test func emptyPLCAndReversedArrivalImpairmentRegression() async throws {
    let configuration = try QualificationConfiguration.parse(["--seconds", "0.8", "--mode", "hybrid",
        "--loss-every", "7", "--reorder-every", "5", "--jitter-ms", "20"], environment: [:])
    let statistics = try RunStatistics(workloads: AttributionCapture.workloads)
    let report = try await VoiceSessionQualification.runAttributed(configuration: configuration, statistics: statistics)
    #expect(report.successful && report.framesPerDirection == 40)
    #expect(report.totalSentPackets == 80 && report.totalReceivedPackets == 70)
    #expect(report.decodedSampleFrames == 80 * 960 && report.concealedPackets > 0)
    #expect(report.finalBufferedMediaBytes == 0)
    #expect(report.closedMediaOwners == 2 && report.closedDAVEOwners == 2 && report.closedDatagramOwners == 2)
    #expect(report.attributed?.emulatedDroppedPackets == 10)
    #expect(report.attributed?.emulatedReorderSelections == 14)
    #expect(report.attributed?.closedContentionWorkers == 0)
    #expect(statistics.metrics().first { $0.id == "voice.tick" && $0.outcome == .success }?.distribution.observedCount == 40)
}

/// A deterministic measured failure retains its cause, one terminal observation and actual zero-owner receipts.
@Test(arguments: [false, true])
func attributedFailureJoinsOwnersAndRetainsPartialReceipts(cancelled: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("discordkit-voice-failure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("partial.json")
    let configuration = try QualificationConfiguration.parse(["--seconds", "0.8", "--mode", "hybrid",
        "--loss-every", "7", "--reorder-every", "5", "--jitter-ms", "20", "--contention-workers", "1",
        "--common-report", destination.path], environment: [:])
    let statistics = try RunStatistics(workloads: AttributionCapture.workloads)
    let operation = Task {
        try await VoiceSessionQualification.runAttributed(configuration: configuration, statistics: statistics,
            measuredTick: { index in
                if index == 30 {
                    if cancelled {
                        withUnsafeCurrentTask { $0?.cancel() }
                        throw CancellationError()
                    }
                    throw FailingTransformer.Failure()
                }
            })
    }
    defer { operation.cancel() }
    do {
        _ = try await operation.value
        Issue.record("The measured failure hook did not terminate the run.")
    } catch let failure as AttributedRunFailure {
        #expect(cancelled ? failure.operationError is CancellationError : failure.operationError is FailingTransformer.Failure)
        #expect(failure.cleanup.completed == true && failure.cleanup.remainingOwners == 0)
        try VoiceSessionQualification.writeAttributedPartial(configuration: configuration, statistics: statistics,
            error: failure.operationError, cleanup: failure.cleanup)
        let report = try JSONDecoder().decode(DiscordBenchmarkReport.self, from: Data(contentsOf: destination))
        #expect(report.status == (cancelled ? .interrupted : .failed))
        #expect(report.cleanup == failure.cleanup && report.counts == nil && report.throughputPerSecond == nil)
        #expect(report.metrics.first { $0.id == "voice.tick" && $0.outcome == (cancelled ? .cancelled : .failure) }?
            .distribution.observedCount == 1)
        #expect(report.metrics.first { $0.id == "voice.tick" && $0.outcome == .success }?.distribution.observedCount == 30)
    }
}
