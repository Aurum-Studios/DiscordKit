// File: Tools/DiscordTimingBenchmarks/Tests/DiscordTimingBenchmarksTests/TimingHarnessTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordLogging
import Foundation
import Testing
@testable import DiscordTimingBenchmarks

/// Small deterministic integrity runs; these tests assert accounting and cleanup, never numerical performance.
@Suite struct TimingHarnessTests {
    /// Known independent rotate/multiply vectors keep optimized work and expected checksums reviewable.
    @Test func fixtureKnownVectors() {
        #expect(TimingHarness.fixture(0) == 8_741_214_397_723_571_342)
        #expect(TimingHarness.fixture(1) == 12_474_609_708_933_878_322)
        #expect(TimingHarness.fixture(2) == 4_629_750_735_897_985_233)
        #expect(TimingHarness.fixture(123_456_789) == 6_725_696_938_392_760_159)
    }

    /// Configuration respects explicit options over the shared driver, rejects unknown options and finite-limit violations.
    /// - Throws: Unexpected parsing failure for valid bounded options.
    @Test func finiteConfigurationAndDriverPolicy() throws {
        let configuration = try TimingConfiguration.parse(["--mode", "callbackContention", "--concurrency", "4", "--seed", "8"],
            environment: ["DK_BENCHMARK_CONCURRENCY": "2", "DK_BENCHMARK_SEED": "99", "DK_BENCHMARK_ENVELOPE": "report.json"])
        #expect(configuration.seed == 8 && configuration.concurrency == 4)
        #expect(configuration.commonReport == "report.json")
        #expect(configuration.collectorScope == .shared)
        #expect(try TimingConfiguration.parse(["--collector-scope", "perWorker"], environment: [:]).collectorScope == .perWorker)
        for arguments in [["--mode", "unknown"], ["--iterations", "0"], ["--iterations", "1000001"],
            ["--concurrency", "65"], ["--warmup-seconds", "61"], ["--duration-seconds", "11"],
            ["--profile", "unknown"], ["--output", ""], ["--mode", "callbackContention"],
            ["--collector-scope", "unknown"], ["--seed", "-1"], ["--seed", "1", "--seed", "2"], ["--unknown", "1"], ["--mode"]] {
            #expect(throws: (any Error).self) { try TimingConfiguration.parse(arguments, environment: [:]) }
        }
    }

    /// Cohorts 1/4/16 preserve exact populations across nil, no-op, diagnostic, collector and output controls.
    /// - Parameters:
    ///   - scope: Original shared ownership or explicitly versioned per-worker collectors.
    ///   - cohort: Supported Stage 0 observer-control cohort size.
    /// - Throws: Unexpected configuration, adapter, report-schema or lifecycle integrity error.
    @Test(arguments: TimingCollectorScope.allCases, [1, 4, 16])
    func observerControlCohorts(_ scope: TimingCollectorScope, _ cohort: Int) async throws {
        for mode in [TimingMode.disabled, .noop, .aggregate, .sampled, .filtered, .callback,
                     .combined, .saturation, .rotatingFile, .sinkFailure, .scalarAggregate] {
            var configuration = TimingConfiguration()
            configuration.mode = mode
            configuration.collectorScope = scope
            configuration.concurrency = cohort
            configuration.iterations = 4
            configuration.warmupIterations = 1
            let result = try await TimingHarness.run(configuration)
            let count = UInt64(cohort * 4)
            #expect(result.completedOperations == count)
            #expect(result.warmupOperations == UInt64(cohort))
            #expect(result.outputCounters["collectorOwners"] == UInt64(scope == .shared ? 1 : cohort))
            #expect(result.common.identity.instrumentation == mode.rawValue
                + (scope == .shared ? "" : ".per-worker-collectors-v1"))
            #expect(result.common.cleanup.remainingOwners == 0)
            #expect(result.common.metrics[0].distribution.observedCount == count)
            #expect(try DiscordBenchmarkReport.decode(result.common.validatedData()) == result.common)
            if mode == .saturation {
                #expect(result.outputCounters["captureRetained"] == UInt64(scope == .shared ? 3 : cohort * 3))
            }
            if let bytes = result.outputCounters["captureMaximumBytes"] {
                #expect(bytes <= 8 * 1_024 * 1_024)
                #expect(result.outputCounters["captureMaximumActiveIntervals", default: .max] <= 256)
                #expect(result.outputCounters["captureMaximumRecords", default: .max] <= 65_536)
            }
            #expect(result.outputCounters["aggregateStorageUpperBoundBytes", default: 0] < 2 * 1_024 * 1_024)
        }
    }

    /// Maximum-cohort partitioning preserves total capture bounds and uses only actual aggregate fixture rows.
    /// - Throws: Unexpected bounded output allocation, validation or close/export failure.
    @Test func maximumCohortRetainsOneTotalCaptureBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for mode in [TimingMode.sampled, .combined, .saturation, .scalarAggregate] {
            let destination = directory.appendingPathComponent(mode.rawValue)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            var configuration = TimingConfiguration()
            configuration.mode = mode
            configuration.collectorScope = .perWorker
            configuration.concurrency = 64
            let outputs = try TimingOutputCohort(configuration: configuration, directory: destination)
            for owner in outputs.owners {
                if let aggregate = owner.aggregate {
                    #expect(aggregate.snapshot().configuration.maximumKeys == (mode == .scalarAggregate ? 4 : 1))
                }
                if let capture = owner.capture {
                    #expect(capture.configuration.maximumRecords == (mode == .saturation ? 3 : 1_024))
                    #expect(capture.configuration.maximumActiveIntervals == 4)
                }
            }
            let counters = try outputs.close(exportDirectory: nil)
            #expect(counters["captureMaximumBytes", default: 0] <= 8 * 1_024 * 1_024)
            #expect(counters["captureMaximumActiveIntervals", default: 0] <= 256)
            #expect(counters["captureMaximumRecords", default: 0] <= 65_536)
            let aggregateBytes = counters["aggregateStorageUpperBoundBytes", default: 0]
            #expect(aggregateBytes < 2 * 1_024 * 1_024)
            #expect(aggregateBytes + counters["captureMaximumBytes", default: 0] < 10 * 1_024 * 1_024)
        }
    }

    /// Per-worker routing preserves the shared identity namespace, nested correlation and task-local restoration.
    /// - Throws: Unexpected output construction, export or exact-accounting error.
    @Test func collectorRoutingPreservesCorrelationAndCleanup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = TimingConfiguration()
        configuration.mode = .combined
        configuration.collectorScope = .perWorker
        configuration.concurrency = 4
        let outputs = try TimingOutputCohort(configuration: configuration, directory: directory)
        let timing = try #require(outputs.timing)
        var namespace: UInt64?
        var identifiers: [UInt64] = []
        for worker in 0..<configuration.concurrency {
            let owner = outputs.owner(for: worker)
            TimingWorkerScope.$outputs.withValue(owner) {
                let parent = timing.begin(.rest, stage: .operation, parent: nil)
                if let namespace { #expect(parent.context.operationID.namespace == namespace) }
                namespace = parent.context.operationID.namespace
                identifiers.append(parent.context.operationID.value)
                DiscordIntervalScope.$context.withValue(parent.context) {
                    let child = timing.begin(.rest, stage: .operation)
                    #expect(child.context.parentID == parent.context.operationID)
                    #expect(child.context.operationID != parent.context.operationID)
                    child.end()
                    #expect(DiscordIntervalScope.context == parent.context)
                }
                parent.end()
            }
            #expect(TimingWorkerScope.outputs == nil)
            #expect(DiscordIntervalScope.context == nil)
            #expect(owner.aggregate?.snapshot().acceptedCount == 2)
            #expect(owner.callbacks.snapshot() == 4)
        }
        #expect(Set(identifiers).count == 4)
        let counters = try outputs.close(exportDirectory: directory)
        try TimingHarness.verifyOutputs(.combined, count: 8, counters: counters, outputOwners: 4)
        #expect(counters["captureActiveAfterClose"] == 0)
        #expect(counters["captureIncomplete"] == 0)
        for worker in 0..<configuration.concurrency {
            let owner = directory.appendingPathComponent("worker-\(worker)")
            #expect(FileManager.default.fileExists(atPath: owner.appendingPathComponent("aggregate.json").path))
            #expect(FileManager.default.fileExists(atPath: owner.appendingPathComponent("timeline.json").path))
        }
        #expect(try outputs.close(exportDirectory: nil) == counters)
    }

    /// Every portable mode preserves exact work, whole-population histograms, separate warmup and closed output counts.
    /// - Parameter mode: Fixed mode; Apple profiler/unified output and console are separately invoked local smoke checks.
    /// - Throws: Unexpected fixture, adapter or common-envelope integrity failure.
    @Test(arguments: TimingMode.allCases.filter { ![.console, .unifiedLog, .signposts].contains($0) })
    func modesPreserveAccounting(_ mode: TimingMode) async throws {
        var configuration = TimingConfiguration()
        configuration.mode = mode
        configuration.iterations = 16
        configuration.warmupIterations = 3
        configuration.concurrency = 2
        let result = try await TimingHarness.run(configuration)
        #expect(result.completedOperations == 32)
        #expect(result.warmupOperations == 6)
        #expect(result.checksum == result.expectedChecksum)
        #expect(result.common.metrics.count == 1)
        #expect(result.common.metrics[0].distribution.observedCount == 32)
        #expect(result.common.counts?.completed == 32)
        #expect(result.common.cleanup.completed == true)
        #expect(result.common.cleanup.remainingOwners == 0)
        #expect(result.common.identity.catalogVersion == 3)
        #expect(try DiscordBenchmarkReport.decode(result.common.validatedData()) == result.common)
        #expect(result.common.gauges["allocationEvents"]?.value == nil)
        #expect(result.common.gauges["allocationEvents"]?.unavailableReason != nil)
        if mode == .saturation {
            #expect(result.outputCounters["captureRetained"] == 3)
            #expect(result.outputCounters["captureDropped"] == 61)
            #expect(result.outputCounters["captureIncomplete", default: 0] >= 1)
        }
        if mode == .scalarAggregate { #expect(result.outputCounters["aggregateAccepted"] == 128) }
    }

    /// File output actually rotates within finite retention, while end-of-run aggregate/timeline artifacts require new ownership.
    /// - Throws: Unexpected local output or bounded capture error.
    @Test func rotationAndExplicitExports() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        for mode in [TimingMode.rotatingFile, .combined] {
            var configuration = TimingConfiguration()
            configuration.mode = mode
            configuration.iterations = 128
            configuration.warmupIterations = 0
            configuration.artifactDirectory = parent.appendingPathComponent(mode.rawValue).path
            let result = try await TimingHarness.run(configuration)
            if mode == .rotatingFile {
                #expect(result.outputCounters["fileRotations", default: 0] > 0)
                let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: configuration.artifactDirectory!),
                    includingPropertiesForKeys: [.fileSizeKey])
                #expect(urls.count <= 3)
                for url in urls { #expect((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 16_384) }
            } else {
                let directory = URL(fileURLWithPath: configuration.artifactDirectory!)
                let aggregate = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("aggregate.json"))) as? [String: Any]
                #expect(aggregate?["acceptedCount"] as? Int == 128)
                let timeline = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("timeline.json"))) as? [String: Any]
                #expect(timeline?["traceEvents"] is [[String: Any]])
                #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("intervals.ndjson").path))
            }
            await #expect(throws: (any Error).self) { try await TimingHarness.run(configuration) }
        }
    }

    /// Cancellation requested before worker admission joins children, closes warmup outputs and creates no measured artifacts.
    /// - Parameter scope: Shared or independently owned worker outputs, all closed on cancellation.
    /// - Throws: Unexpected temporary-directory error; cancellation itself must be observed as CancellationError.
    @Test(arguments: TimingCollectorScope.allCases)
    func cancellationClosesBeforeMeasuredAdmission(_ scope: TimingCollectorScope) async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        var configuration = TimingConfiguration()
        configuration.mode = .rotatingFile
        configuration.collectorScope = scope
        configuration.concurrency = 4
        configuration.artifactDirectory = parent.appendingPathComponent("measured").path
        let configured = configuration
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TimingHarness.run(configured)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: configuration.artifactDirectory!))
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    /// A cold-process policy can skip warmup, and fabricated output counts cannot pass integrity validation.
    /// - Throws: Unexpected disabled-fixture failure.
    @Test func noWarmupAndFailClosedAccounting() async throws {
        var configuration = TimingConfiguration()
        configuration.iterations = 1
        configuration.warmupSeconds = 0
        let result = try await TimingHarness.run(configuration)
        #expect(result.completedOperations == 1 && result.warmupOperations == 0)
        #expect(throws: (any Error).self) {
            try TimingHarness.verifyOutputs(.callback, count: 1, counters: ["callbackRecords": 1])
        }
        #expect(throws: (any Error).self) {
            try TimingHarness.verifyOutputs(.aggregate, count: 1, counters: ["aggregateAccepted": 0])
        }
    }
}
