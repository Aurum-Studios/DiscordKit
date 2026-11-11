// File: Tools/DiscordBenchmarkSupport/Tests/DiscordBenchmarkSupportTests/RunStatisticsTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation
import Testing

/// Verifies shared tool adoption without timing-dependent assertions or external processes.
@Suite struct RunStatisticsTests {
    /// The disabled factory creates no collector, and malformed explicit destinations are rejected.
    /// - Throws: Unexpected factory admission error.
    @Test func optInAndFiniteKeys() throws {
        #expect(try RunStatistics.requested(workloads: [.transport], environment: [:]) == nil)
        #expect(throws: (any Error).self) {
            try RunStatistics.requested(workloads: [.transport], environment: ["DK_BENCHMARK_ENVELOPE": ""])
        }
        #expect(BenchmarkWorkload.authoring(mode: "direct", handlers: 10) == .direct10)
        #expect(BenchmarkWorkload.authoring(mode: "remote-url", handlers: 10) == nil)
        #expect(BenchmarkWorkload.authoring(mode: "dsl", handlers: 11) == nil)
        let statistics = try RunStatistics(workloads: [.transport, .gatewayDecode, .commandRoute])
        #expect(statistics.metrics().isEmpty)
    }

    /// Concurrent workers retain the complete measured population while failures and invalid clocks stay visible.
    /// - Throws: Unexpected bounded collector initialization failure.
    @Test func concurrentFullPopulation() async throws {
        let statistics = try RunStatistics(workloads: [.transport])
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    for _ in 0..<100 { statistics.record(.microseconds(20), workload: .transport, outcome: .success) }
                }
            }
        }
        statistics.record(.seconds(2), workload: .transport, outcome: .failure)
        statistics.record(.nanoseconds(-1), workload: .transport, outcome: .cancelled)
        let metrics = statistics.metrics()
        #expect(metrics.count == 3)
        #expect(metrics.first { $0.outcome == .success }?.distribution.observedCount == 1_600)
        #expect(metrics.first { $0.outcome == .failure }?.distribution.overflowCount == 1)
        #expect(metrics.first { $0.outcome == .cancelled }?.distribution.droppedCount == 1)
        #expect(Set(metrics.map(\.clockDomain)) == [statistics.clockDomain])
    }

    /// Partial evidence retains completed observations while unknown final counts and gauges stay unavailable.
    /// - Throws: Unexpected temporary-file, bounded serialization or decoding failure.
    @Test func partialFailureAndCancellation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("partial.json")
        let statistics = try RunStatistics(workloads: [.voice])
        statistics.record(.milliseconds(2), workload: .voice, outcome: .success)
        statistics.record(.milliseconds(5), workload: .voice, outcome: .cancelled)
        for cancelled in [false, true] {
            try statistics.writePartialSidecar(identity: .init(scenario: "local-duplex", profile: "smoke"),
                adapter: LegacyReportFormat.voiceVersion2.rawValue, cancelled: cancelled,
                environment: ["DK_BENCHMARK_ENVELOPE": destination.path])
            let report = try DiscordBenchmarkReport.decode(Data(contentsOf: destination))
            #expect(report.status == (cancelled ? .interrupted : .failed))
            #expect(report.metrics.count == 2)
            #expect(report.metrics.reduce(UInt64(0)) { $0 + $1.distribution.observedCount } == 2)
            #expect(report.counts == nil)
            #expect(report.gauges["processCPU"]?.value == nil)
            #expect(report.gauges["processCPU"]?.unavailableReason != nil)
            #expect(!report.comparison(with: report).isCompatible)
        }
    }
}
