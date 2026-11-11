// File: Tools/AppleAudioQualification/Sources/QualificationSupport/BenchmarkEvidence.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation

/// Development-only codec populations; constructing this recorder never accesses native devices.
public final class AppleAudioBenchmarkCapture: @unchecked Sendable {
    private let statistics: RunStatistics
    private let lock = NSLock()
    private var codecDeadlineMisses: UInt64 = 0

    /// Allocates one bounded population before explicitly authorized native work begins.
    /// - Throws: A histogram configuration or aggregate storage-budget failure.
    public init() throws { statistics = try RunStatistics(workloads: [.appleAudioCodec]) }

    /// Records a directly measured synchronous encode/decode attempt after its terminal timestamp.
    /// - Parameters:
    ///   - duration: ContinuousClock interval around the actual codec calls and output validation.
    ///   - outcome: Exact terminal result, including a partially failed codec operation.
    /// No capture, resampling, queueing, playback completion or hardware latency is inferred.
    public func recordCodec(_ duration: Duration, outcome: BenchmarkOutcome) {
        lock.lock()
        if duration >= .milliseconds(20), codecDeadlineMisses < UInt64.max { codecDeadlineMisses += 1 }
        statistics.record(duration, workload: .appleAudioCodec, outcome: outcome)
        lock.unlock()
    }

    /// Builds a common envelope without reading a device, copying PCM or promoting native p99 values.
    /// - Parameters:
    ///   - mode: Reviewed native workflow; probe/fault modes contain no codec population.
    ///   - requestedSeconds: Validated configured observation duration.
    ///   - elapsed: Direct measured codec-loop wall interval, excluding native start and drain; nil if not entered.
    ///   - evidence: Actual count, resource and native qualification evidence, or nil before duplex entry.
    ///   - nativeIOStarted: True only after native start returned successfully.
    ///   - passed: Existing native-mode assessment, not an acoustic or lossless-delivery guarantee.
    ///   - failed: Whether the native workflow recorded a terminal error.
    ///   - cleanup: Awaited native stop receipt with explicit queue state, or unavailable evidence.
    ///   - provenance: Captured build/host receipts; runtime facts cannot attest compiler settings.
    /// - Returns: Catalog-nine envelope retaining only bounded numeric/categorical codec evidence.
    /// - Throws: Invalid duration/counts, mode/population mismatch or envelope validation errors.
    public func report(mode: QualificationMode, requestedSeconds: Int, elapsed: Duration?,
        evidence: DuplexEvidence?, nativeIOStarted: Bool, passed: Bool, failed: Bool,
        cleanup: BenchmarkCleanup, provenance: BenchmarkProvenance) throws -> DiscordBenchmarkReport {
        lock.lock()
        let metrics = statistics.metrics()
        let deadlineMisses = codecDeadlineMisses
        lock.unlock()
        guard requestedSeconds > 0, mode == .duplex || metrics.isEmpty,
              metrics.isEmpty || (nativeIOStarted && elapsed != nil),
              evidence.map({ $0.capturedFrames >= 0 && $0.processedFrames >= 0 && $0.playedFrames >= 0 }) ?? true else {
            throw QualificationError.invalidArguments
        }
        let measured = try elapsed.map { try BenchmarkTime.nanoseconds(duration: $0) }
        let population = metrics.reduce(UInt64(0)) { $0 + $1.distribution.observedCount }
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        for metric in metrics { outcomes[metric.outcome, default: 0] += metric.distribution.observedCount }
        let counts: BenchmarkCounts? = mode == .duplex && elapsed != nil ? .init(offered: population,
            admitted: population, completed: population, outcomes: outcomes,
            deadlineMisses: deadlineMisses) : nil
        let identity = ReportIdentity(scenario: "appleAudio.\(mode.rawValue)", profile: "native-opt-in", profileVersion: 1,
            inputSizes: ["requestedSeconds": UInt64(requestedSeconds), "codecFrameSamples": 960,
                "codecPacketBytes": 161, "nativeIOStarted": nativeIOStarted ? 1 : 0],
            instrumentation: "direct-continuous-clock-codec-histogram", scheduler: "native-capture-with-bounded-playback-admission",
            concurrency: 1, warmupNanoseconds: 0, requestedWarmupNanoseconds: 0,
            measuredNanoseconds: measured, repetitions: 1)
        var report = DiscordBenchmarkReport(identity: identity, provenance: provenance,
            adapter: "AppleAudioQualification.native", clockDomain: metrics.isEmpty ? nil : statistics.clockDomain,
            status: failed || (mode != .probe && !passed) ? .failed : mode == .duplex && !metrics.isEmpty ? .completed : .unqualified,
            counts: counts, metrics: metrics,
            gauges: [
                "processCPU": .init(value: nil, unit: "nanoseconds", method: "unavailable", scope: "codec-loop",
                    unavailableReason: "Native qualification does not collect process CPU time."),
                "processResidentBytes": .init(value: evidence?.residentMemory.finalBytes, unit: "bytes",
                    method: "mach_task_basic_info", scope: "final-after-native-stop",
                    unavailableReason: evidence?.residentMemory.finalBytes == nil ? "No native RSS sample captured." : nil),
                "processPeakResidentBytes": .init(value: nil, unit: "bytes", method: "unavailable", scope: "process-lifetime",
                    unavailableReason: "Native qualification collects sampled RSS, not a process high-water mark."),
                "processSampledMaximumResidentBytes": .init(value: evidence?.residentMemory.maximumBytes, unit: "bytes",
                    method: "sampled-mach_task_basic_info", scope: "native-duplex-sampled-maximum",
                    unavailableReason: evidence?.residentMemory.maximumBytes == nil ? "No native RSS sample captured." : nil),
                "capturedFrames": .init(value: evidence.map { UInt64($0.capturedFrames) }, unit: "sample-frames", method: "native-read-count", scope: "duplex",
                    unavailableReason: evidence == nil ? "No duplex capture population." : nil),
                "processedFrames": .init(value: evidence.map { UInt64($0.processedFrames) }, unit: "sample-frames", method: "codec-output-count", scope: "duplex",
                    unavailableReason: evidence == nil ? "No duplex codec population." : nil),
                "playedFrames": .init(value: evidence.map { UInt64($0.playedFrames) }, unit: "sample-frames", method: "native-completion-accounting", scope: "duplex",
                    unavailableReason: evidence == nil ? "No duplex playback population." : nil),
            ], cleanup: cleanup,
            throughputPerSecond: measured.flatMap { $0 > 0 ? Double(population) * 1e9 / Double($0) : nil },
            qualificationLimitations: [
                "Explicitly opt-in native Apple qualification; ordinary tests never start devices or request permission.",
                "appleAudio.codec measures actual synchronous codec calls and output validation only; no histogram is reconstructed from the legacy processing summary.",
                "No hardware render-underrun telemetry, lossless-delivery guarantee, perceptual assessment, acoustic latency, minimum-OS/mobile or live Discord qualification.",
                "Probe and fault observations have no codec population or throughput. RSS is a sampled process observation, not a leak proof or process peak high-water mark.",
                "Runtime source/executable hashes do not attest the compiled source graph or compiler/build configuration."
            ])
        report.identity.catalogVersion = 9
        try report.validate()
        return report
    }
}
