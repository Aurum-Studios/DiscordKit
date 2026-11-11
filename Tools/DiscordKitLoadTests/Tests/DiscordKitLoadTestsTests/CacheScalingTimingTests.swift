// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/CacheScalingTimingTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation
import Testing
@testable import DiscordKitLoadTests

/// Verifies workload meaning and exact owner accounting, without elapsed-time performance gates.
@Suite("Cache scaling timing", .serialized, .timeLimit(.minutes(1)))
struct CacheScalingTimingTests {
    /// Explicit owner and dimensions override only their corresponding shared driver defaults.
    @Test func parsesIndependentControls() throws {
        let value = try CacheScalingTimingConfiguration.parse([
            "--case", "cache.capacityV1", "--owner", "read", "--profile", "standard", "--seed", "9",
            "--requests", "7", "--warmup-requests", "2", "--working-set", "17", "--identities", "3",
            "--payload-bytes", "256", "--churn-updates", "5", "--duration-seconds", "4", "--warmup-seconds", "0",
        ], environment: ["DK_BENCHMARK_PROFILE": "stress", "DK_BENCHMARK_CONCURRENCY": "64",
            "DK_BENCHMARK_SEED": "7", "DK_BENCHMARK_ENVELOPE": "common.json"])
        #expect(value.owner == .read && value.scenario == "cache.capacityV1")
        #expect(value.workingSet == 17 && value.identities == 3 && value.payloadBytes == 256 && value.churnUpdates == 5)
        #expect(value.requests == 7 && value.warmupRequests == 2 && value.profile == "standard" && value.seed == 9)
        #expect(value.durationSeconds == 4 && value.warmupSeconds == 0 && value.commonReport == "common.json")
    }

    /// Malformed or excessive fixture inputs fail before owners acquire retained state.
    @Test(arguments: [
        ["--requests"], ["--requests", "2", "--requests", "3"], ["--unknown", "1"],
        ["--owner", "unknown"], ["--case", "cache.lookup"], ["--profile", "unknown"], ["--seed", "-1"],
        ["--requests", "0"], ["--requests", "100001"], ["--requests", "x"], ["--warmup-requests", "10001"],
        ["--working-set", "0"], ["--working-set", "4097"], ["--identities", "0"], ["--identities", "33"],
        ["--working-set", "2", "--identities", "3"], ["--payload-bytes", "-1"], ["--payload-bytes", "65537"],
        ["--working-set", "4096", "--payload-bytes", "4096"], ["--churn-updates", "-1"], ["--churn-updates", "65"],
        ["--duration-seconds", "0"], ["--duration-seconds", "301"], ["--warmup-seconds", "61"],
        ["--case", "cache.expiryStormV1", "--working-set", "4096", "--requests", "100000"],
        ["--output", ""], ["--common-report", ""], ["--output", "same.json", "--common-report", "./same.json"],
    ]) func rejectsInvalidInputs(arguments: [String]) {
        #expect(throws: CacheScalingTimingError.invalidConfiguration) {
            try CacheScalingTimingConfiguration.parse(arguments, environment: [:])
        }
    }

    /// Every selected owner/case validates full payloads, LRU, bounded retention and recovery after churn.
    /// - Parameters:
    ///   - scenario: One finite public operation class.
    ///   - owner: Entity projection or successful-response cache authority.
    /// - Throws: Fixture or report failures; no real service or credentials are used.
    @available(macOS 15, *)
    @Test(arguments: CacheScalingTimingScenario.allCases, CacheScalingTimingOwner.allCases)
    func finiteScenarios(scenario: CacheScalingTimingScenario, owner: CacheScalingTimingOwner) async throws {
        var configuration = CacheScalingTimingConfiguration()
        configuration.scenario = scenario.rawValue; configuration.owner = owner
        configuration.requests = 9; configuration.workingSet = 7; configuration.identities = 3
        configuration.payloadBytes = 17; configuration.churnUpdates = 5
        let value = try await CacheScalingTimingRunner().run(configuration)
        try value.counts.validate()
        #expect(value.counts.offered == 9 && value.counts.completed == 9 && value.counts.outcomes[.success] == 9)
        #expect(value.initialEntries == 7 && value.retainedBeforeCleanup == (scenario == .expiryStorm ? 0 : 7))
        #expect(value.measuredCapacityEvictions == (scenario == .capacity ? 9 : 0))
        #expect(value.measuredExpiryRemovals == (scenario == .expiryStorm ? 63 : 0))
        #expect(value.recoveryReads == (scenario == .expiryStorm ? 1 : scenario == .invalidation ? 9 : 0))
        #expect(value.setupWrites == 7 + 45 + (scenario == .expiryStorm ? 57 : scenario == .invalidation ? 9 : 0))
        #expect(value.cleanup.isEmpty)
        #expect(value.metrics.filter { $0.id == "cache.call" }.reduce(0) { $0 + $1.distribution.observedCount } == 9)
        #expect(value.metrics.filter { $0.id == "cache.owner" }.reduce(0) { $0 + $1.distribution.observedCount } == (owner == .entity ? 9 : 0))
        #expect(value.metrics.allSatisfy { $0.clockDomain == value.clockDomain && $0.distribution.droppedCount == 0 && !$0.distribution.counterOverflow })
        let encoded = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(CacheScalingTimingMeasurement.self, from: encoded).counts == value.counts)
    }

    /// Identity sweeps preserve the aggregate working set, including zero-length response payloads.
    @available(macOS 15, *)
    @Test(arguments: CacheScalingTimingOwner.allCases)
    func identitiesDoNotMultiplyRetainedState(owner: CacheScalingTimingOwner) async throws {
        for identities in [1, 4, 16] {
            var configuration = CacheScalingTimingConfiguration()
            configuration.owner = owner; configuration.workingSet = 16; configuration.identities = identities
            configuration.payloadBytes = 0; configuration.requests = 2
            let value = try await CacheScalingTimingRunner().run(configuration)
            #expect(value.initialEntries == 16 && value.retainedBeforeCleanup == 16 && value.cleanup.isEmpty)
        }
    }

    /// Native/common receipts distinguish owners and retain independent dimensions with separate warmup.
    @available(macOS 15, *)
    @Test(arguments: CacheScalingTimingOwner.allCases)
    func reportIdentityAndRoundTrip(owner: CacheScalingTimingOwner) async throws {
        var configuration = CacheScalingTimingConfiguration()
        configuration.owner = owner; configuration.requests = 3; configuration.warmupRequests = 1
        configuration.identities = 4; configuration.payloadBytes = 7; configuration.churnUpdates = 2
        let value = try await CacheScalingTimingCommand.measure(configuration)
        #expect(value.common.identity.scenario == "cache.hotHitV1.\(owner.rawValue)")
        #expect(value.common.identity.concurrency == 1 && value.common.identity.inputSizes["workingSet"] == 16)
        #expect(value.common.identity.inputSizes["identities"] == 4 && value.common.identity.inputSizes["payloadBytes"] == 7)
        #expect(value.common.identity.inputSizes["churnUpdates"] == 2 && (value.common.identity.warmupNanoseconds ?? 0) > 0)
        #expect(value.common.status == .completed && value.common.cleanup.remainingOwners == 0)
        #expect(try DiscordBenchmarkReport.decode(value.common.validatedData()) == value.common)
        #expect(try JSONDecoder().decode(CacheScalingTimingReport.self, from: JSONEncoder().encode(value)).format == "DiscordKitLoadTests.cache-scaling-timing")
        #expect(Set(CacheScalingTimingCommand.cases).count == 6)
        #expect(Set(CacheScalingTimingCommand.cases).isDisjoint(with: Phase7TimingCommand.cases))
    }

    /// Warmup overrides cannot bypass work limits; pre-cancelled work acquires no owners.
    @available(macOS 15, *)
    @Test func boundedOverridesAndCancellation() async {
        var configuration = CacheScalingTimingConfiguration()
        configuration.scenario = CacheScalingTimingScenario.expiryStorm.rawValue
        configuration.requests = 1; configuration.workingSet = 4_096
        let finite = configuration
        await #expect(throws: CacheScalingTimingError.invalidConfiguration) {
            try await CacheScalingTimingRunner().run(finite, requests: 100_000)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CacheScalingTimingRunner().run(finite)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// The setup guard counts final expiry recovery and each active warmup owner's independent setup.
    @Test func exactSetupWriteBoundary() throws {
        var configuration = CacheScalingTimingConfiguration()
        configuration.scenario = CacheScalingTimingScenario.expiryStorm.rawValue
        configuration.workingSet = 100; configuration.requests = 100_000; configuration.warmupRequests = 0
        // Ten million refill writes plus the single final recovery write exceeds the limit.
        #expect(throws: CacheScalingTimingError.invalidConfiguration) { try configuration.validate() }
        configuration.workingSet = 2_151; configuration.requests = 4_649
        // 2,151 * 4,649 + 1 == 10,000,000 exactly.
        try configuration.validate()
        configuration.warmupRequests = 1
        #expect(throws: CacheScalingTimingError.invalidConfiguration) { try configuration.validate() }
        configuration.warmupSeconds = 0
        try configuration.validate()
        configuration.requests += 1
        #expect(throws: CacheScalingTimingError.invalidConfiguration) { try configuration.validate() }
    }
}
