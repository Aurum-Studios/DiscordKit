// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/EventHubTimingTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation
import Testing
@testable import DiscordKitLoadTests

/// Finite public-API experiments preserve independent workload dimensions and exact owner receipts.
@Suite("Event hub timing", .serialized, .timeLimit(.minutes(1)))
struct EventHubTimingTests {
    /// Explicit options take precedence over driver defaults without inventing publisher concurrency.
    @Test func parsesIndependentDimensions() throws {
        let value = try EventHubTimingConfiguration.parse([
            "--case", "gateway.hubQueuedV1", "--profile", "stress", "--seed", "9",
            "--requests", "7", "--warmup-requests", "2", "--subscriptions", "3", "--hubs", "2",
            "--queued-depth", "4", "--payload-bytes", "256", "--policy", "dropOldest",
            "--delay-microseconds", "100", "--duration-seconds", "3", "--warmup-seconds", "0",
        ], environment: ["DK_BENCHMARK_PROFILE": "standard", "DK_BENCHMARK_SEED": "7",
            "DK_BENCHMARK_DURATION_SECONDS": "12", "DK_BENCHMARK_WARMUP_SECONDS": "4",
            "DK_BENCHMARK_CONCURRENCY": "64", "DK_BENCHMARK_ENVELOPE": "common.json"])
        #expect(value.profile == "stress" && value.seed == 9)
        #expect(value.requests == 7 && value.warmupRequests == 2)
        #expect(value.subscriptions == 3 && value.hubs == 2 && value.queuedDepth == 4)
        #expect(value.payloadBytes == 256 && value.policy == .dropOldest && value.delayMicroseconds == 100)
        #expect(value.durationSeconds == 3 && value.warmupSeconds == 0 && value.commonReport == "common.json")
        let inherited = try EventHubTimingConfiguration.parse([], environment: ["DK_BENCHMARK_PROFILE": "standard",
            "DK_BENCHMARK_SEED": "17", "DK_BENCHMARK_DURATION_SECONDS": "12", "DK_BENCHMARK_WARMUP_SECONDS": "0"])
        #expect(inherited.profile == "standard" && inherited.seed == 17 && inherited.durationSeconds == 12)
        #expect(inherited.warmupSeconds == 0)
    }

    /// Bounds reject malformed, duplicate, aliased-output and excessive retained/work populations before setup.
    @Test(arguments: [
        ["--requests"], ["--requests", "2", "--requests", "3"], ["--unknown", "1"],
        ["--case", "gateway.burst"], ["--policy", "unknown"], ["--profile", "unknown"],
        ["--seed", "-1"], ["--requests", "0"], ["--requests", "100001"], ["--requests", "x"],
        ["--warmup-requests", "-1"], ["--warmup-requests", "10001"],
        ["--subscriptions", "0"], ["--subscriptions", "257"], ["--hubs", "0"], ["--hubs", "9"],
        ["--subscriptions", "256", "--hubs", "3"], ["--queued-depth", "-1"], ["--queued-depth", "4097"],
        ["--payload-bytes", "-1"], ["--payload-bytes", "65537"],
        ["--delay-microseconds", "-1"], ["--delay-microseconds", "1000001"],
        ["--duration-seconds", "0"], ["--duration-seconds", "301"], ["--warmup-seconds", "61"],
        ["--subscriptions", "256", "--hubs", "2", "--queued-depth", "4096"],
        ["--subscriptions", "256", "--queued-depth", "4", "--payload-bytes", "65536"],
        ["--requests", "100000", "--subscriptions", "101"],
        ["--output", ""], ["--common-report", ""],
        ["--output", "same.json", "--common-report", "./same.json"],
    ]) func rejectsInvalidDimensions(arguments: [String]) {
        #expect(throws: EventHubTimingError.invalidConfiguration) {
            try EventHubTimingConfiguration.parse(arguments, environment: [:])
        }
    }

    /// Registration is finite, unique and disjoint from the older command-timing socket scripts.
    @Test func finiteCaseInventory() {
        #expect(EventHubTimingCommand.cases.count == 4)
        #expect(Set(EventHubTimingCommand.cases).count == 4)
        #expect(Set(EventHubTimingCommand.cases).isDisjoint(with: Phase6TimingCommand.cases))
    }

    /// Each policy exposes admitted, dropped, evicted, consumed and cancelled copies independently.
    @Test(arguments: EventHubTimingScenario.allCases, EventHubTimingPolicy.allCases)
    func finiteScenarios(scenario: EventHubTimingScenario, policy: EventHubTimingPolicy) async throws {
        var configuration = EventHubTimingConfiguration()
        configuration.scenario = scenario.rawValue; configuration.policy = policy
        configuration.requests = 6; configuration.subscriptions = 3; configuration.hubs = 2
        configuration.queuedDepth = 2; configuration.payloadBytes = 17
        let report = try await EventHubTimingRunner().run(configuration)
        try report.counts.validate()
        #expect(report.cleanup.isEmpty)
        #expect(report.publicationCalls == 12)
        #expect(report.counts.offered == 36 && report.counts.completed == 36)
        #expect(report.metrics.allSatisfy { $0.clockDomain == report.clockDomain && $0.distribution.droppedCount == 0 && !$0.distribution.counterOverflow })
        #expect(report.metrics.filter { $0.id == "gateway.publication" }.reduce(0) { $0 + $1.distribution.observedCount } == 12)
        let residences = report.metrics.filter { $0.id == "gateway.hubResidence" }
        switch scenario {
        case .queued:
            #expect(report.setupCopies == 12 && report.admittedCopies == 36)
            #expect(report.retainedBeforeDrain.bufferedEvents == 12)
            #expect(report.counts.outcomes[.success] == 36)
            #expect(report.consumers.allSatisfy { $0.measuredEvents == 6 && $0.setupEvents == 2 && $0.firstSequence == 0 && $0.lastSequence == 7 })
            #expect(residences.first { $0.outcome == .success }?.distribution.observedCount == 48)
            #expect(report.pullCall.observedCount == 48)
        case .waiting:
            #expect(report.retainedBeforeDrain.bufferedEvents == 0 && report.retainedBeforeDrain.waitingConsumers == 0)
            #expect(report.setupCopies == 0 && report.admittedCopies == 36)
            #expect(report.counts.outcomes[.success] == 36)
            #expect(report.consumers.allSatisfy { $0.measuredEvents == 6 && $0.firstSequence == 0 && $0.lastSequence == 5 })
            #expect(residences.isEmpty)
            #expect(report.pullCall.observedCount == 36)
        case .overflow, .cancelled:
            let cancelled = scenario == .cancelled
            switch policy {
            case .dropNewest:
                #expect(report.admittedCopies == 12 && report.publicationDrops == 24)
                #expect(report.discardedAdmittedCopies == 0 && report.terminatedSubscriptions == 0)
                #expect(report.counts.outcomes[.rejected] == 24)
                if !cancelled { #expect(report.consumers.allSatisfy { $0.measuredEvents == 2 && $0.firstSequence == 0 && $0.lastSequence == 1 }) }
            case .dropOldest:
                #expect(report.admittedCopies == 36 && report.publicationDrops == 0)
                #expect(report.discardedAdmittedCopies == 24 && report.terminatedSubscriptions == 0)
                #expect(report.counts.outcomes[.rejected] == 24)
                #expect(residences.first { $0.outcome == .failure }?.distribution.observedCount == 24)
                if !cancelled { #expect(report.consumers.allSatisfy { $0.measuredEvents == 2 && $0.firstSequence == 4 && $0.lastSequence == 5 }) }
            case .resynchronize:
                #expect(report.admittedCopies == 12 && report.publicationDrops == 0)
                #expect(report.discardedAdmittedCopies == 12 && report.terminatedSubscriptions == 6)
                #expect(report.resynchronizationErrors == (cancelled ? 0 : 6))
                #expect(report.counts.outcomes[.rejected] == 36)
                #expect(residences.first { $0.outcome == .failure }?.distribution.observedCount == 12)
            }
            let retained = policy == .resynchronize ? 0 : 12
            #expect(report.retainedBeforeDrain.bufferedEvents == retained)
            #expect(report.counts.outcomes[.success] == UInt64(cancelled ? 0 : retained))
            #expect(report.counts.outcomes[.cancelled] == UInt64(cancelled ? retained : 0))
            #expect(report.cancelledRetainedCopies == (cancelled ? retained : 0))
            if cancelled && retained > 0 {
                #expect(residences.first { $0.outcome == .cancelled }?.distribution.observedCount == UInt64(retained))
            }
        }
        let data = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(EventHubTimingMeasurement.self, from: data).counts == report.counts)
    }

    /// Zero backlog stays lossless while payload and multi-hub fan-out remain independent inputs.
    @Test func zeroBacklogAndEmptyPayload() async throws {
        var configuration = EventHubTimingConfiguration()
        configuration.requests = 3; configuration.subscriptions = 2; configuration.hubs = 3
        configuration.queuedDepth = 0; configuration.payloadBytes = 0
        let report = try await EventHubTimingRunner().run(configuration)
        #expect(report.counts.outcomes[.success] == 18 && report.setupCopies == 0)
        #expect(report.retainedBeforeDrain.bufferedEvents == 0 && report.cleanup.isEmpty)
    }

    /// Common reports describe one sequential publisher, preserve dimensions, and round-trip both schemas.
    @Test func commonReportIdentityAndWarmup() async throws {
        var configuration = EventHubTimingConfiguration()
        configuration.requests = 3; configuration.warmupRequests = 1
        configuration.subscriptions = 2; configuration.hubs = 2; configuration.queuedDepth = 1
        let report = try await EventHubTimingCommand.measure(configuration)
        #expect(report.measurement.counts.offered == 12 && report.measurement.publicationCalls == 6)
        #expect(report.common.identity.concurrency == 1)
        #expect(report.common.identity.scheduler == "sequential-publication-fixed-backlog-v1")
        #expect(report.common.identity.inputSizes["subscriptionsPerHub"] == 2)
        #expect(report.common.identity.inputSizes["hubs"] == 2 && report.common.identity.inputSizes["queuedDepth"] == 1)
        #expect((report.common.identity.warmupNanoseconds ?? 0) > 0)
        #expect(report.common.cleanup.completed == true && report.common.cleanup.remainingOwners == 0)
        #expect(report.common.status == .completed)
        #expect(try DiscordBenchmarkReport.decode(report.common.validatedData()) == report.common)
        let data = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(EventHubTimingReport.self, from: data).format == "DiscordKitLoadTests.gateway-hub-timing")
    }

    /// Cancellation resolves suspended pull tasks and releases retained queues before returning partial counts.
    @Test(arguments: [EventHubTimingScenario.queued, .waiting])
    func externalCancellationJoinsOwners(scenario: EventHubTimingScenario) async throws {
        var configuration = EventHubTimingConfiguration()
        configuration.scenario = scenario.rawValue; configuration.requests = 100_000
        configuration.subscriptions = 2; configuration.hubs = 1; configuration.queuedDepth = 3
        if scenario == .queued { configuration.delayMicroseconds = 1_000_000 }
        let finite = configuration
        let task = Task { try await EventHubTimingRunner().run(finite) }
        try await ContinuousClock().sleep(for: .milliseconds(10))
        task.cancel()
        let report = try await task.value
        try report.counts.validate()
        #expect(report.cleanup.isEmpty)
        #expect(report.counts.offered < 200_000 && report.counts.completed == report.counts.offered)
        #expect(report.counts.outcomes[.cancelled, default: 0] + report.counts.outcomes[.success, default: 0] == report.counts.offered)
    }

    /// A cooperative wall cap returns interrupted evidence after joining the intentionally held FIFO.
    @Test func wallCapHasJoinedPartialPopulation() async throws {
        var configuration = EventHubTimingConfiguration()
        configuration.requests = 8; configuration.warmupRequests = 0; configuration.warmupSeconds = 0
        configuration.subscriptions = 2; configuration.queuedDepth = 16
        configuration.delayMicroseconds = 1_000_000; configuration.durationSeconds = 1
        let report = try await EventHubTimingCommand.measure(configuration)
        #expect(report.common.status == .interrupted)
        #expect(report.measurement.cleanup.isEmpty && report.common.cleanup.remainingOwners == 0)
        #expect(report.measurement.counts.outcomes[.cancelled, default: 0] > 0)
        #expect(report.measurement.counts.offered < 16)
        #expect(report.measurement.cancelledRetainedCopies > Int(report.measurement.counts.offered))
        #expect(report.measurement.discardedAdmittedCopies == 0)
    }

    /// A caller-supplied request override remains subject to the same aggregate offered-copy bound.
    @Test func overrideCannotBypassWorkBudget() async {
        var configuration = EventHubTimingConfiguration()
        configuration.requests = 1; configuration.subscriptions = 256
        await #expect(throws: EventHubTimingError.invalidConfiguration) {
            try await EventHubTimingRunner().run(configuration, requests: 100_000)
        }
    }
}
