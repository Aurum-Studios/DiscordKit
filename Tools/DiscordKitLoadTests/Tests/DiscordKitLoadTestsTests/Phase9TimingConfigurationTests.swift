// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/Phase9TimingConfigurationTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation
import Testing
@testable import DiscordKitLoadTests

@Suite struct Phase9TimingConfigurationTests {
    /// The process driver cannot override an explicit finite workload selection.
    @Test func driverPolicy() throws {
        let value = try Phase9TimingConfiguration.parse(["--requests", "2", "--concurrency", "1", "--seed", "9"],
            environment: ["DK_BENCHMARK_PROFILE": "standard", "DK_BENCHMARK_SEED": "7", "DK_BENCHMARK_CONCURRENCY": "6",
                "DK_BENCHMARK_DURATION_SECONDS": "12", "DK_BENCHMARK_WARMUP_SECONDS": "0", "DK_BENCHMARK_ENVELOPE": "common.json"])
        #expect(value.requests == 2 && value.concurrency == 1 && value.seed == 9)
        #expect(value.durationSeconds == 12 && value.warmupSeconds == 0)
        #expect(value.profile == "standard" && value.commonReport == "common.json")
    }

    /// Invalid input fails before session/credential ownership is acquired.
    @Test(arguments: [
        ["--requests"], ["--requests", "2", "--requests", "3"], ["--unknown", "1"], ["--case", "live"],
        ["--requests", "0"], ["--requests", "10001"], ["--concurrency", "0"], ["--concurrency", "9"],
        ["--warmup-requests", "1001"], ["--duration-seconds", "11"], ["--duration-seconds", "0"],
        ["--warmup-seconds", "61"], ["--seed", "-1"], ["--profile", "unknown"],
        ["--output", ""], ["--common-report", ""], ["--output", "same.json", "--common-report", "./same.json"],
    ]) func invalidPolicy(arguments: [String]) {
        #expect(throws: (any Error).self) { try Phase9TimingConfiguration.parse(arguments, environment: [:]) }
    }

    /// Warmup and overlapping child distributions never inflate primary terminal counts.
    @available(macOS 15, *)
    @Test func commonEnvelope() async throws {
        var configuration = Phase9TimingConfiguration()
        configuration.requests = 2; configuration.warmupRequests = 1
        let result = try await Phase9TimingCommand.measure(configuration)
        let counts = try #require(result.common.counts)
        #expect(counts.offered == 2 && counts.completed == 2)
        #expect(result.common.identity.catalogVersion == 9)
        #expect(result.common.cleanup.completed == true && result.common.cleanup.remainingOwners == 0)
        #expect(try DiscordBenchmarkReport.decode(result.common.validatedData()) == result.common)
        var metrics = result.common.metrics
        for index in metrics.indices where metrics[index].id == BenchmarkWorkload.voiceLifecycle.rawValue {
            metrics[index].outcome = .failure
        }
        #expect(throws: (any Error).self) {
            try Phase9TimingCommand.validatePopulation(metrics: metrics, counts: counts, cleanup: result.common.cleanup)
        }
        #expect(throws: (any Error).self) {
            try Phase9TimingCommand.validatePopulation(metrics: result.common.metrics, counts: counts,
                cleanup: .init(completed: true, remainingOwners: 1))
        }
        let data = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(Phase9TimingReport.self, from: data).format == "DiscordKitLoadTests.voice-timing")
    }
}
