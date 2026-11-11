// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/Phase8TimingConfigurationTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation
import Testing
@testable import DiscordKitLoadTests

@Suite struct Phase8TimingConfigurationTests {
    /// Explicit participant policy wins over process-driver defaults without acquiring service owners.
    @Test func explicitValuesOverrideDriver() throws {
        let value = try Phase8TimingConfiguration.parse(["--requests", "2", "--concurrency", "1", "--seed", "9"],
            environment: ["DK_BENCHMARK_PROFILE": "standard", "DK_BENCHMARK_SEED": "7", "DK_BENCHMARK_CONCURRENCY": "6",
                "DK_BENCHMARK_DURATION_SECONDS": "12", "DK_BENCHMARK_WARMUP_SECONDS": "0", "DK_BENCHMARK_ENVELOPE": "common.json"])
        #expect(value.requests == 2 && value.concurrency == 1 && value.seed == 9)
        #expect(value.durationSeconds == 12 && value.warmupSeconds == 0)
        #expect(value.profile == "standard" && value.commonReport == "common.json")
        #expect(try Phase8TimingConfiguration.parse([], environment: [:]).scenario == "oauth.lookup")
    }

    /// Reject unknown operations, duplicate options, unbounded inputs and colliding artifact destinations.
    @Test(arguments: [
        ["--requests"], ["--requests", "2", "--requests", "3"], ["--unknown", "1"], ["--case", "purchase"],
        ["--requests", "0"], ["--requests", "100001"], ["--concurrency", "0"], ["--concurrency", "65"],
        ["--fan-out", "0"], ["--fan-out", "33"], ["--warmup-requests", "10001"], ["--duration-seconds", "11"],
        ["--duration-seconds", "0"], ["--warmup-seconds", "61"], ["--delay-microseconds", "1000001"],
        ["--delay-microseconds", "-1"], ["--seed", "-1"], ["--profile", "unknown"],
        ["--output", ""], ["--common-report", ""], ["--output", "same.json", "--common-report", "./same.json"],
    ]) func invalidPolicy(arguments: [String]) {
        #expect(throws: (any Error).self) { try Phase8TimingConfiguration.parse(arguments, environment: [:]) }
    }

    /// The command advertises each implemented family exactly once and preserves prior inventories.
    @Test func finiteInventory() {
        let cases = Phase8TimingCommand.cases
        #expect(cases.count == Set(cases).count)
        for prefix in ["oauth.", "rpc.", "activities.", "service."] { #expect(cases.contains { $0.hasPrefix(prefix) }) }
        #expect(Set(cases).isDisjoint(with: Set(Phase7TimingCommand.cases)))
        #expect(Phase8TimingCommand.primaryWorkload("rpc.requests") == .rpcRequest)
        #expect(Phase8TimingCommand.primaryWorkload("activities.requests") == .activitiesRequest)
    }

    /// Separate warmup owners cannot inflate measured counts; both native and common reports roundtrip.
    @available(macOS 15, *)
    @Test(arguments: ["oauth.lookup", "rpc.requests", "activities.requests", "service.commerceVerify"])
    func commonEnvelope(scenario: String) async throws {
        var configuration = Phase8TimingConfiguration()
        configuration.scenario = scenario; configuration.requests = 2; configuration.warmupRequests = 1
        configuration.delayMicroseconds = 0
        let result = try await Phase8TimingCommand.measure(configuration)
        #expect(result.common.counts?.offered == 2 && result.common.counts?.completed == 2)
        #expect(result.common.identity.catalogVersion == 8 && result.common.identity.concurrency == 2)
        #expect(result.common.cleanup.completed == true && result.common.cleanup.remainingOwners == 0)
        let primary = Phase8TimingCommand.primaryWorkload(scenario).rawValue
        #expect(result.common.metrics.filter { $0.id == primary }.reduce(0) { $0 + $1.distribution.observedCount } == 2)
        let counts = try #require(result.common.counts)
        var mislabeled = result.common.metrics
        for index in mislabeled.indices where mislabeled[index].id == primary { mislabeled[index].outcome = .failure }
        #expect(throws: (any Error).self) {
            try Phase8TimingCommand.validatePrimary(metrics: mislabeled, counts: counts, scenario: scenario)
        }
        #expect(try DiscordBenchmarkReport.decode(result.common.validatedData()) == result.common)
        let encoded = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(Phase8TimingReport.self, from: encoded).format == "DiscordKitLoadTests.service-timing")
    }
}
