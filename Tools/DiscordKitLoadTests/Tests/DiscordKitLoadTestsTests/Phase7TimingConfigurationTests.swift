// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/Phase7TimingConfigurationTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation
import Testing
@testable import DiscordKitLoadTests

@Suite struct Phase7TimingConfigurationTests {
    /// The shared driver owns defaults while explicit participant options take precedence.
    @Test func explicitValuesOverrideSharedDriver() throws {
        let configuration = try Phase7TimingConfiguration.parse(["--requests", "2", "--concurrency", "1", "--seed", "9"],
            environment: ["DK_BENCHMARK_PROFILE": "standard", "DK_BENCHMARK_SEED": "7", "DK_BENCHMARK_CONCURRENCY": "6",
                "DK_BENCHMARK_DURATION_SECONDS": "12", "DK_BENCHMARK_WARMUP_SECONDS": "0", "DK_BENCHMARK_ENVELOPE": "common.json"])
        #expect(configuration.requests == 2 && configuration.concurrency == 1 && configuration.seed == 9)
        #expect(configuration.durationSeconds == 12 && configuration.warmupSeconds == 0)
        #expect(configuration.profile == "standard" && configuration.commonReport == "common.json")
        #expect(try Phase7TimingConfiguration.parse([], environment: [:]).scenario == "cache.lookup")
    }

    /// Invalid policy must fail before workload or output ownership is acquired.
    @Test(arguments: [
        ["--requests"], ["--requests", "2", "--requests", "3"], ["--unknown", "1"], ["--case", "rest.noCache"],
        ["--requests", "0"], ["--requests", "100001"], ["--concurrency", "0"], ["--concurrency", "65"],
        ["--working-set", "17"], ["--identities", "0"], ["--identities", "33"],
        ["--hit-percent", "75"], ["--fan-out", "0"], ["--fan-out", "33"], ["--slow-subscriber", "yes"], ["--warmup-requests", "-1"], ["--duration-seconds", "11"],
        ["--warmup-seconds", "61"], ["--delay-microseconds", "1000001"], ["--seed", "-1"],
        ["--profile", "unknown"], ["--output", ""], ["--common-report", ""],
        ["--output", "same.json", "--common-report", "./same.json"],
    ]) func invalidPolicy(arguments: [String]) {
        #expect(throws: (any Error).self) { try Phase7TimingConfiguration.parse(arguments, environment: [:]) }
    }

    /// Case inventory is finite, unique and excludes every historical transport/REST command.
    @Test func finiteCaseInventory() {
        let cases = Phase7TimingCommand.cases
        #expect(cases.count == Set(cases).count)
        #expect(cases.contains("cache.singleFlight"))
        #expect(cases.contains("client.lifecycle"))
        #expect(cases.contains("client.cancelledDiscovery"))
        #expect(Set(cases).isDisjoint(with: Set(Phase5TimingCommand.cases)))
    }

    /// Both local report families use catalog seven, complete counts and lossless joined cleanup.
    @available(macOS 15, *)
    @Test(arguments: ["cache.lookup", "cache.singleFlight", "client.lifecycle", "client.discoveryFailure"])
    func smallPopulationsAndCommonRoundtrip(scenario: String) async throws {
        var configuration = Phase7TimingConfiguration()
        configuration.scenario = scenario; configuration.requests = 2; configuration.warmupRequests = 1
        configuration.delayMicroseconds = 0
        let result = try await Phase7TimingCommand.measure(configuration)
        #expect(result.common.counts?.offered == 2)
        #expect(result.common.counts?.completed == 2)
        #expect(result.common.identity.catalogVersion == 7)
        #expect(result.common.identity.concurrency == 2)
        #expect(result.common.cleanup.completed == true && result.common.cleanup.remainingOwners == 0)
        #expect(!result.common.metrics.isEmpty)
        #expect(result.common.metrics.allSatisfy { $0.distribution.droppedCount == 0 && !$0.distribution.counterOverflow })
        #expect(try DiscordBenchmarkReport.decode(result.common.validatedData()) == result.common)
        let native = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(Phase7TimingReport.self, from: native).format == "DiscordKitLoadTests.cache-client-timing")
    }
}
