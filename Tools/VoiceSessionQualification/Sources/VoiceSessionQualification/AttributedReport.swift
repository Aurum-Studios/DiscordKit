// File: Tools/VoiceSessionQualification/Sources/VoiceSessionQualification/AttributedReport.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation

extension VoiceSessionQualification {
    /// Derives remaining logical owners from independently observed native closure receipts.
    /// - Parameters:
    ///   - closedMediaOwners: Closed pipeline receipts, within the two owned directions.
    ///   - closedDAVEOwners: Closed DAVE adapter receipts, within the two owned directions.
    ///   - closedDatagramOwners: EOF receipts after closing the two UDP owners.
    ///   - configuredContentionWorkers: Admitted CPU worker count, in zero through four.
    ///   - closedContentionWorkers: Canceled workers whose terminal values were awaited.
    /// - Returns: Complete zero-owner cleanup only when every expected receipt is present.
    /// - Throws: Invariant failure for negative, excess or contradictory owner counts; performs no I/O.
    static func attributedCleanup(closedMediaOwners: Int, closedDAVEOwners: Int, closedDatagramOwners: Int,
        configuredContentionWorkers: Int, closedContentionWorkers: Int) throws -> BenchmarkCleanup {
        guard (0...2).contains(closedMediaOwners), (0...2).contains(closedDAVEOwners),
            (0...2).contains(closedDatagramOwners), (0...4).contains(configuredContentionWorkers),
            (0...configuredContentionWorkers).contains(closedContentionWorkers) else {
            throw QualificationFailure.invariant
        }
        let remaining = 6 - closedMediaOwners - closedDAVEOwners - closedDatagramOwners
            + configuredContentionWorkers - closedContentionWorkers
        return BenchmarkCleanup(completed: remaining == 0, remainingOwners: UInt64(remaining),
            reason: remaining == 0 ? nil : "Native closure receipts remain incomplete for media, DAVE, datagram or contention owners.")
    }

    /// Writes only after complete awaited media/key/socket/contention shutdown.
    static func writeAttributedCommon(configuration: QualificationConfiguration, report: QualificationReport,
        statistics: RunStatistics) throws {
        guard let destination = configuration.commonReport else { return }
        guard let attributed = report.attributed else { throw QualificationFailure.invariant }
        let cleanup = try attributedCleanup(closedMediaOwners: report.closedMediaOwners,
            closedDAVEOwners: report.closedDAVEOwners, closedDatagramOwners: report.closedDatagramOwners,
            configuredContentionWorkers: configuration.contentionWorkers, closedContentionWorkers: attributed.closedContentionWorkers)
        var identity = configuration.identity()
        identity.warmupNanoseconds = try BenchmarkTime.nanoseconds(seconds: report.warmupElapsedSeconds)
        identity.measuredNanoseconds = try BenchmarkTime.nanoseconds(seconds: report.elapsedSeconds)
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        outcomes[.success] = UInt64(report.framesPerDirection)
        let count = UInt64(report.framesPerDirection)
        let common = DiscordBenchmarkReport(identity: identity, provenance: .capture(), adapter: "VoiceSessionQualification.v3",
            clockDomain: statistics.clockDomain, status: report.successful && cleanup.completed == true ? .completed : .failed,
            counts: .init(offered: count, admitted: count, completed: count, outcomes: outcomes,
                deadlineMisses: UInt64(report.processingBudgetOverruns)), metrics: statistics.metrics(),
            gauges: [
                "processCPU": .init(value: nil, unit: "nanoseconds", method: "unavailable", scope: "process",
                    unavailableReason: "CPU utilization is not measured; contention worker count is an explicit input."),
                "processResidentBytes": .init(value: report.rssAfterResourceCloseBytes, unit: "bytes", method: "native OS resident probe", scope: "after awaited closure"),
                "processPeakResidentBytes": .init(value: nil, unit: "bytes", method: "unavailable", scope: "process-lifetime",
                    unavailableReason: "Native report contains sampled-high RSS, not an actual process lifetime peak."),
                "sampledHighResidentBytes": .init(value: report.rssSampledHighBytes, unit: "bytes", method: "native OS resident probe approximately once per second", scope: "post-warmup through drain"),
            ], cleanup: cleanup,
            throughputPerSecond: Double(count) / report.elapsedSeconds, qualificationLimitations: [
                "Local synthetic localhost software duplex only; no audio hardware, acoustic measurement, live Discord, independent client interoperability or cryptographic security qualification.",
                "Direct tick and child public boundaries overlap; percentiles cannot be summed or subtracted. DAVE-only encrypt excludes concrete transport AEAD. Receive includes jitter insertion; decode includes jitter pop and PCM saturation.",
                "Exact standalone jitter cost belongs to the media batch suite; no fabricated isolated pipeline jitter distribution is emitted.",
                "Loss/reorder/jitter are deterministic receiver-side emulation after actual UDP receipt, never a claim about network impairment. Warmup uses uninterrupted tone; impairment and signal policy begin at measurement.",
                "Fixed playout delay is retained in the profile; final delayed media drains outside tick histograms. Decoded/concealed totals include drain; metrics include only scheduled measured ticks and their child operations.",
                "Native pipeline encoder deadlines and raw 40ms dispatch-gap counters include warmup. Policy cadence separately compares actual send decisions to 200ms silence hangover and 400ms refresh; intentional suppression is not loss.",
                "Observed deadline misses use the actual selected frame interval, with no universal realtime guarantee or baseline regression claim.",
            ])
        try common.validatedData().write(to: URL(fileURLWithPath: destination), options: .atomic)
    }

    /// Retains terminal observations after cleanup while preserving the original operation error.
    /// - Parameters:
    ///   - configuration: Validated identity and optional common destination; absent disables I/O.
    ///   - statistics: Partial measured observations; no complete throughput/counts are invented.
    ///   - error: Original operation error used for failure/cancellation classification.
    ///   - cleanup: Native read-back receipts after joined closure, or nil before such receipts exist.
    /// - Throws: Schema/atomic-write failures; the caller retains the original operation error.
    static func writeAttributedPartial(configuration: QualificationConfiguration, statistics: RunStatistics,
        error: any Error, cleanup: BenchmarkCleanup? = nil) throws {
        guard let destination = configuration.commonReport else { return }
        if let cleanup {
            let report = DiscordBenchmarkReport(identity: configuration.identity(), provenance: .capture(),
                adapter: "VoiceSessionQualification.v3", clockDomain: statistics.clockDomain,
                status: error is CancellationError ? .interrupted : .failed, metrics: statistics.metrics(),
                cleanup: cleanup, qualificationLimitations: [
                    "Partial run: complete outcome, resource and throughput accounting unavailable.",
                    "Cleanup receipts observe closed/empty media, closed/drained DAVE, UDP EOF and awaited contention workers; they do not establish successful media qualification.",
                ])
            try report.validatedData().write(to: URL(fileURLWithPath: destination), options: .atomic)
            return
        }
        try statistics.writePartialSidecar(identity: configuration.identity(), adapter: "VoiceSessionQualification.v3",
            cancelled: error is CancellationError, environment: ["DK_BENCHMARK_ENVELOPE": destination])
    }
}
