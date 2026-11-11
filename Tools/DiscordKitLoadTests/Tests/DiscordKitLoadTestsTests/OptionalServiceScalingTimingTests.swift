// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/OptionalServiceScalingTimingTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation
import Testing
@testable import DiscordKitLoadTests

/// Explicit owner/cardinality controls preserve genuine outcome and cleanup populations.
@Suite("Optional service scaling timing", .timeLimit(.minutes(1)))
struct OptionalServiceScalingTimingTests {
    /// Checks one shared coordinator's exact caller, refresh and authoritative storage populations.
    /// - Parameter scenario: Versioned same-key, unrelated-key or partial-cancellation policy.
    /// - Throws: Unexpected injected workflow, joined-cleanup or codec validation errors.
    @Test(arguments: [OAuthTimingScenario.sharedRefreshV2, .unrelatedRefreshV2, .partialCancellationV2])
    func sameCoordinatorCohorts(scenario: OAuthTimingScenario) async throws {
        let report = try await OAuthTimingRunner().run(scenario: scenario, requests: 7, concurrency: 3,
            storageDelay: .microseconds(1), backendDelay: .microseconds(2))
        try report.counts.validate()
        let keys = scenario == .unrelatedRefreshV2 ? 7 : 3
        let cancelled = scenario == .partialCancellationV2 ? 2 : 0
        #expect(report.counts.offered == 7 && report.counts.completed == 7)
        #expect(report.counts.outcomes[.success] == UInt64(7 - cancelled))
        #expect(report.counts.outcomes[.cancelled] == UInt64(cancelled))
        #expect(report.refreshCalls == keys && report.storageLoads == keys && report.storageCAS == keys)
        #expect(report.maximumWaiters == 3 && report.coalescedReaders == (scenario == .unrelatedRefreshV2 ? 0 : 4))
        #expect(count(report.metrics, "oauth.lookup") == 7)
        #expect(count(report.metrics, "oauth.refresh.io") == UInt64(keys))
        #expect(count(report.metrics, "oauth.storage.load") == UInt64(keys))
        #expect(count(report.metrics, "oauth.storage.cas") == UInt64(keys))
        #expect(count(report.metrics, "oauth.refreshCohortV2") == 3)
        #expect(count(report.metrics, "oauth.refresh.joined") == 0)
        #expect(report.measuredLookupNanoseconds != nil)
        #expect(report.cleanup.completed == true && report.cleanup.remainingOwners == 0)
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(OAuthTimingReport.self, from: data)
        #expect(decoded.measuredLookupNanoseconds == report.measuredLookupNanoseconds)
        #expect(!String(decoding: data, as: UTF8.self).contains("synthetic-rotated"))
    }

    /// Cancels selected admitted readers while requiring one refresh to serve every surviving reader.
    /// - Parameter concurrency: Single-reader, ordinary fanout or maximum supported V2 cohort.
    /// - Throws: Unexpected coordinator, backend or cleanup failure.
    @Test(arguments: [1, 64, 256])
    func sharedCancellationKeepsSurvivors(concurrency: Int) async throws {
        let report = try await OAuthTimingRunner().run(scenario: .partialCancellationV2,
            requests: concurrency, concurrency: concurrency)
        #expect(report.refreshCalls == 1 && report.storageLoads == 1 && report.storageCAS == 1)
        #expect(report.maximumWaiters == concurrency)
        #expect(report.cancelledReaders == concurrency / 2)
        #expect(report.counts.outcomes[.success] == UInt64(concurrency - concurrency / 2))
        #expect(count(report.metrics, "oauth.refreshCohortV2") == 1)
        #expect(count(report.metrics, "oauth.refresh.joined") == 0)
        #expect(report.cleanup.remainingOwners == 0)
    }

    /// Constant total token count changes group cardinality independently of provider delay.
    /// - Parameter groups: Distinct upstream groups dividing the same 128-token retained state.
    /// - Throws: Unexpected public subscription, provider-write or cleanup receipt discrepancies.
    @Test(arguments: [1, 8, 64])
    func subscriptionGroupsKeepExactProviderWrites(groups: Int) async throws {
        let owners = 128 / groups - 1
        let report = try await RPCActivitiesTimingRunner().run(scenario: .activitiesSubscriptionGroupsV1,
            requests: 2, concurrency: 1, delay: .microseconds(1),
            subscriptionGroups: groups, ownersPerGroup: owners)
        #expect(report.counts.outcomes[.success] == 2 && report.counts.completed == 2)
        #expect(report.acquiredSubscriptions == 256)
        #expect(report.upstreamSubscriptions == 2 * groups && report.upstreamUnsubscriptions == 2 * groups)
        #expect(report.subscriptionAdmissions == UInt64(2 * groups * owners))
        #expect(report.subscriptionAdmissionNanoseconds != nil)
        #expect(count(report.metrics, "activities.subscription", .success) == UInt64(2 * groups * owners))
        #expect(count(report.metrics, "activities.subscription", .rejected) == 2)
        #expect(report.closedPeers == 2 && report.cleanup.remainingOwners == 0)
    }

    /// Keeps native and common reports consistent for every newly introduced workload identity.
    /// - Parameter scenario: Finite versioned OAuth, Activity or RPC workload.
    /// - Throws: Unexpected fixture, report validation or serialization failures.
    @available(macOS 15, *)
    @Test(arguments: ["oauth.sharedRefreshV2", "oauth.unrelatedRefreshV2", "oauth.partialCancellationV2",
        "activities.subscriptionGroupsV1", "rpc.queuedRepliesV1"])
    func commonIdentityIncludesOnlyRelevantDimensions(scenario: String) async throws {
        var configuration = Phase8TimingConfiguration()
        configuration.scenario = scenario; configuration.requests = 2; configuration.warmupRequests = 0
        configuration.concurrency = 1; configuration.delayMicroseconds = 0
        let report = try await Phase8TimingCommand.measure(configuration)
        #expect(report.common.counts?.completed == 2)
        #expect(report.common.cleanup.remainingOwners == 0)
        #expect((report.common.identity.inputSizes["storageDelayMicroseconds"] != nil) == scenario.hasPrefix("oauth."))
        #expect((report.common.identity.inputSizes["subscriptionGroups"] != nil) == scenario.hasPrefix("activities."))
        #expect((report.common.identity.inputSizes["queueDepth"] != nil) == scenario.hasPrefix("rpc."))
        #expect(try DiscordBenchmarkReport.decode(report.common.validatedData()) == report.common)
    }

    /// Checks independent delay parsing, supported high cardinality and old native-config decoding.
    /// - Throws: Unexpected option validation or JSON decoding failures.
    @Test func independentDelayControlsAndLegacyDecode() throws {
        let value = try Phase8TimingConfiguration.parse(["--case", "oauth.unrelatedRefreshV2", "--concurrency", "256",
            "--storage-delay-microseconds", "17", "--backend-delay-microseconds", "23"], environment: [:])
        #expect(value.delayMicroseconds == 0 && value.storageDelayMicroseconds == 17 && value.backendDelayMicroseconds == 23)
        let data = try JSONEncoder().encode(Phase8TimingConfiguration())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["storageDelayMicroseconds", "backendDelayMicroseconds", "subscriptionGroups", "ownersPerGroup", "queueDepth"] {
            object.removeValue(forKey: key)
        }
        let old = try JSONDecoder().decode(Phase8TimingConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old == Phase8TimingConfiguration())
        let groups = try Phase8TimingConfiguration.parse(["--case", "activities.subscriptionGroupsV1",
            "--subscription-groups", "1024", "--owners-per-group", "3"], environment: [:])
        #expect(groups.subscriptionGroups * (groups.ownersPerGroup + 1) == 4096)
    }

    /// Rejects new dimensions outside bounds or attached to a different workload identity.
    /// - Parameter arguments: Invalid CLI policy that must fail before allocating service owners.
    @Test(arguments: [
        ["--storage-delay-microseconds", "1"], ["--queue-depth", "1"], ["--owners-per-group", "2"],
        ["--case", "oauth.sharedRefreshV2", "--delay-microseconds", "1"],
        ["--case", "oauth.sharedRefreshV2", "--storage-delay-microseconds", "1000001"],
        ["--case", "oauth.sharedRefreshV2", "--backend-delay-microseconds", "-1"],
        ["--case", "oauth.sharedRefreshV2", "--concurrency", "257"],
        ["--case", "activities.subscriptionGroupsV1", "--subscription-groups", "4097"],
        ["--case", "activities.subscriptionGroupsV1", "--subscription-groups", "4096", "--owners-per-group", "4096"],
        ["--case", "rpc.queuedRepliesV1", "--queue-depth", "4097"],
    ]) func invalidVersionedDimensions(arguments: [String]) {
        #expect(throws: (any Error).self) { try Phase8TimingConfiguration.parse(arguments, environment: [:]) }
    }

    /// Sums exact full-population observation counts without treating buckets as raw observations.
    /// - Parameters:
    ///   - metrics: Joined native report populations.
    ///   - id: Finite catalog metric identity under test.
    ///   - outcome: Optional terminal partition; nil includes all outcomes.
    /// - Returns: Complete observed mass including censored observations.
    private func count(_ metrics: [BenchmarkMetric], _ id: String, _ outcome: BenchmarkOutcome? = nil) -> UInt64 {
        metrics.filter { $0.id == id && (outcome == nil || $0.outcome == outcome) }
            .reduce(0) { $0 + $1.distribution.observedCount }
    }
}
