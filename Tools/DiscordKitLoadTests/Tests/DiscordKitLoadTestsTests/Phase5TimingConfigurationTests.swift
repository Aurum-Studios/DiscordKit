// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/Phase5TimingConfigurationTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation
import Testing
@testable import DiscordKitLoadTests

@Suite struct Phase5TimingConfigurationTests {
    /// Driver requests are honored while explicit options take precedence and defaults stay finite.
    @Test func explicitOptionsOverrideDriverEnvironment() throws {
        let value = try Phase5TimingConfiguration.parse(["--requests", "32", "--concurrency", "2", "--seed", "9"],
            environment: ["DK_BENCHMARK_CONCURRENCY": "6", "DK_BENCHMARK_PROFILE": "standard", "DK_BENCHMARK_SEED": "7"])
        #expect(value.requests == 32 && value.concurrency == 2 && value.seed == 9)
        #expect(value.profile == "standard" && value.adapter == "scripted")
        #expect(try Phase5TimingConfiguration.parse([], environment: [:]).durationSeconds == 10)
    }

    /// Invalid and contradictory options fail before any peer or output ownership begins.
    @Test(arguments: [
        ["--requests"], ["--requests", "1", "--requests", "2"], ["--unknown", "1"],
        ["--requests", "0"], ["--requests", "100001"], ["--concurrency", "65"],
        ["--pending", "1024"], ["--pending", "9223372036854775807"], ["--rate", "0"], ["--rate", "1000001"],
        ["--warmup-requests", "-1"], ["--duration-seconds", "11"], ["--warmup-seconds", "61"],
        ["--delay-microseconds", "1000001"], ["--seed", "-1"], ["--tls", "yes"],
        ["--case", "unknown"], ["--adapter", "unknown"], ["--connection-mode", "cold"],
        ["--case", "transport.empty", "--adapter", "foundation", "--tls", "true"],
        ["--output", ""], ["--output", "same.json", "--common-report", "./same.json"],
    ]) func invalidPolicies(arguments: [String]) {
        #expect(throws: (any Error).self) { try Phase5TimingConfiguration.parse(arguments, environment: [:]) }
    }

    /// Real cold native runs require a serial cohort; TLS retains strict NIO trust configuration.
    @Test func explicitNativePolicies() throws {
        let cold = try Phase5TimingConfiguration.parse(["--case", "transport.smallBody", "--adapter", "nio",
            "--connection-mode", "cold", "--concurrency", "1"], environment: [:])
        #expect(cold.connectionMode == "cold")
        let tls = try Phase5TimingConfiguration.parse(["--case", "transport.empty", "--adapter", "nio",
            "--tls", "true"], environment: [:])
        #expect(tls.tls)
    }

    /// A parent cancellation preserves cooperative partial evidence after its owner joins.
    @Test func boundedCancellationKeepsPartialEvidence() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Phase5TimingCommand.bounded(seconds: 1) { 42 }
        }
        let (value, capped) = try await task.value
        #expect(value == 42 && !capped)
    }

    /// Small measured and warmup populations clamp their worker cohort without failing setup.
    @Test func smallRESTPopulationsAndCommonRoundtrip() async throws {
        var configuration = Phase5TimingConfiguration()
        configuration.requests = 1; configuration.warmupRequests = 1; configuration.delayMicroseconds = 0
        let result = try await Phase5TimingCommand.measure(configuration)
        #expect(result.common.counts?.completed == 1)
        #expect(result.common.cleanup.completed == true)
        #expect(result.common.metrics.contains { $0.id == "rest.request" })
        #expect(result.common.identity.catalogVersion == 5)
        #expect(try DiscordBenchmarkReport.decode(result.common.validatedData()) == result.common)
    }
}
