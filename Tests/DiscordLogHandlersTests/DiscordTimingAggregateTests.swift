// File: Tests/DiscordLogHandlersTests/DiscordTimingAggregateTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging
import DiscordTransport
import Foundation
import Logging
import Testing
@testable import DiscordLogHandlers

/// Proves finite aggregate populations, clock validity, capacity loss and content-safe lazy output.
@Suite struct DiscordTimingAggregateTests {
    private static let legacyPhases: [OperationTimingSample.Phase] = [
        .gatewayLocalQueue, .gatewaySharedAdmission, .gatewayReceiveToAdmission,
        .gatewayReceiveToAcknowledgement, .gatewayAdmissionToAcknowledgement, .gatewayRunJoined,
        .interactionInitialResponse, .interactionOriginalEdit, .interactionAcknowledgementToOriginalEdit,
        .httpAdmission, .httpHeaders, .httpBody, .httpCoalescedSubscriber, .httpExecutionJoined,
    ]
    private static let legacyOutcomes: [OperationTimingSample.Outcome] = [.succeeded, .failed, .cancelled, .uncertain]
    private static let operations: [DiscordIntervalOperation] = [.rest, .httpExchange, .httpSubscriber, .gatewayDispatch, .interactionResponse]
    private static let stages: [DiscordIntervalStage] = [.operation, .admission, .headers, .body, .subscriber, .localQueue, .handler, .initialResponse, .originalEdit]
    private static let outcomes: [DiscordIntervalOutcome] = [.succeeded, .failed, .cancelled, .uncertain]

    /// Protects deterministic injected clocks and captured outputs; no global logging state is changed.
    private final class Box<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        /// Stores an initial value without invoking external code.
        /// - Parameter value: Initial captured state.
        init(_ value: Value) { self.value = value }

        /// Reads one coherent copy of the captured state.
        /// - Returns: A value copy made while holding the lock.
        func read() -> Value { lock.withLock { value } }

        /// Mutates captured state synchronously; the closure must not recursively access this box.
        /// - Parameter body: Isolated mutation invoked under the test-only lock.
        func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }

        /// Removes the first scripted duration; every clock read must have a predeclared value.
        /// - Returns: The earliest remaining duration for a duration-sequence box.
        func next() -> Duration where Value == [Duration] { lock.withLock { value.removeFirst() } }
    }

    /// Detects accidental rendering of task context unrelated to the adapter's explicitly supplied logger.
    private struct SecretDescription: Sendable, CustomStringConvertible {
        let calls: Box<Int>

        /// Records a privacy failure if this unrelated context value is rendered by a timing adapter.
        var description: String {
            calls.update { $0 += 1 }
            return "DO-NOT-LOG-credential-route-user-error"
        }
    }

    /// Checks every 14x4 legacy bridge without changing regression-clamp compatibility or inventing IDs.
    @Test func scalarBridgePreservesEveryBoundaryAndOutcome() {
        for (phaseIndex, phase) in Self.legacyPhases.enumerated() {
            for (outcomeIndex, outcome) in Self.legacyOutcomes.enumerated() {
                let sample = OperationTimingSample(phase: phase, outcome: outcome, elapsed: .nanoseconds(7))
                let observed = sample.observation
                #expect(observed.phase == DiscordTimingObservation.Phase.allCases[phaseIndex])
                #expect(observed.outcome == DiscordTimingObservation.Outcome.allCases[outcomeIndex])
                #expect(observed.elapsedNanoseconds == 7)
            }
        }
        let clamped = OperationTimingSample(phase: .httpHeaders, outcome: .failed, elapsed: .nanoseconds(-1))
        #expect(clamped.observation.elapsedNanoseconds == 0)
        #expect(DiscordTimingObservation(phase: .httpHeaders, outcome: .failed, elapsed: .nanoseconds(-1)).elapsedNanoseconds == nil)
        #expect(DiscordTimingObservation(phase: .httpHeaders, outcome: .failed, elapsed: .seconds(Int64.max)).elapsedNanoseconds == nil)
        #expect(DiscordTimingObservation(phase: .httpHeaders, outcome: .failed, elapsed: Duration(secondsComponent: 0, attosecondsComponent: 1_000_000_001)).elapsedNanoseconds == 1)
    }

    /// Confirms the original scalar/detailed combinations retain their exported names and fit the default cap.
    /// - Throws: Unexpected aggregate construction or JSON serialization failures.
    @Test func allFiniteKeysFitAndSummaryRoundTrips() throws {
        let aggregate = try DiscordTimingAggregate()
        for phase in DiscordTimingObservation.Phase.allCases {
            for outcome in DiscordTimingObservation.Outcome.allCases {
                aggregate.record(.init(phase: phase, outcome: outcome, elapsed: .nanoseconds(4)))
            }
        }
        let detailed = DiscordIntervalTiming(clockDomain: 999, sink: { aggregate.record($0) }, now: { .nanoseconds(4) })
        for operation in Self.operations {
            for stage in Self.stages {
                for outcome in Self.outcomes { detailed.begin(operation, stage: stage, parent: nil).end(outcome) }
            }
        }
        let summary = aggregate.snapshot()
        #expect(summary.rows.count == 236)
        #expect(summary.acceptedCount == 236)
        #expect(summary.ignoredBeginCount == 180)
        #expect(summary.invalidCount == 0)
        #expect(summary.droppedCount == 0)
        #expect(summary.counterSaturationCount == 0)
        #expect(summary.storageUpperBoundBytes < 16 * 1_024 * 1_024)
        #expect(summary.rows.allSatisfy { $0.count == 1 && $0.buckets.count == 64 && $0.buckets.reduce(0, +) == 1 })
        let bytes = try JSONEncoder().encode(summary)
        #expect(try JSONDecoder().decode(DiscordTimingAggregateSnapshot.self, from: bytes) == summary)
        let json = String(decoding: bytes, as: UTF8.self)
        #expect(!json.contains("namespace"))
        #expect(!json.contains("clockDomain"))
        #expect(!json.contains("operationID"))
        #expect(summary == aggregate.snapshot())
    }

    /// New high ordinal identities cannot collide with legacy rows or escape explicit retained-key limits.
    /// - Throws: Unexpected aggregate construction or missing mapped rows.
    @Test func expandedIdentitiesPreserveCapacityAndMapping() throws {
        let aggregate = try DiscordTimingAggregate(configuration: .init(maximumKeys: 2))
        let timing = DiscordIntervalTiming(clockDomain: 6, sink: { aggregate.record($0) }, now: { .nanoseconds(4) })
        timing.begin(.interactionResponse, stage: .originalEdit).end(.uncertain)
        timing.begin(.commandRouting, stage: .firstResponse).end()
        timing.begin(.gatewayFrame, stage: .decode).end()
        let summary = aggregate.snapshot()
        #expect(summary.acceptedCount == 2 && summary.droppedCount == 1)
        #expect(summary.rows.count == 2)
        #expect(summary.rows.contains { $0.operation == "interactionResponse" && $0.stage == "originalEdit" && $0.outcome == "uncertain" })
        #expect(summary.rows.contains { $0.operation == "commandRouting" && $0.stage == "firstResponse" && $0.outcome == "succeeded" })
        #expect(summary.storageUpperBoundBytes < 16 * 1_024 * 1_024)
    }

    /// The new high ordinal lease boundary maps independently without shifting existing exported names.
    /// - Throws: Unexpected bounded aggregate construction failure.
    @Test func leaseValidationMapping() throws {
        let aggregate = try DiscordTimingAggregate()
        let timing = DiscordIntervalTiming(clockDomain: 6, sink: { aggregate.record($0) }, now: { .nanoseconds(4) })
        timing.begin(.gatewaySession, stage: .leaseValidation).end(.failed)
        let snapshot = aggregate.snapshot()
        #expect(snapshot.acceptedCount == 1 && snapshot.droppedCount == 0)
        #expect(snapshot.rows.map(\.operation) == ["gatewaySession"])
        #expect(snapshot.rows.map(\.stage) == ["leaseValidation"])
        #expect(snapshot.rows.map(\.outcome) == ["failed"])
    }

    /// Cache and client identities map to independent bounded rows with their full finite stage set.
    /// - Throws: Unexpected aggregate admission or missing mapped row.
    @Test func phaseSevenOwnerMappings() throws {
        let aggregate = try DiscordTimingAggregate(configuration: .init(maximumKeys: 10))
        let timing = DiscordIntervalTiming(clockDomain: 7, sink: { aggregate.record($0) }, now: { .nanoseconds(7) })
        for stage: DiscordIntervalStage in [.cacheLookup, .cacheMerge, .cacheProjection, .cacheInvalidation,
            .cacheRefresh, .cacheLoader] {
            timing.begin(.entityCache, stage: stage).end()
        }
        for stage: DiscordIntervalStage in [.construction, .discovery, .ingestion, .localReady] {
            timing.begin(.clientLifecycle, stage: stage).end()
        }
        let result = aggregate.snapshot()
        #expect(result.acceptedCount == 10 && result.rows.count == 10 && result.droppedCount == 0)
        #expect(result.rows.filter { $0.operation == "entityCache" }.count == 6)
        #expect(result.rows.filter { $0.operation == "clientLifecycle" }.count == 4)
        #expect(Set(result.rows.map(\.stage)).count == 10)
    }

    /// Exercises histogram edges and censored mass without fabricating a finite tail or invalid zero.
    /// - Throws: Unexpected configuration rejection or missing row.
    @Test func histogramInvalidAndCensoredValues() throws {
        let aggregate = try DiscordTimingAggregate(configuration: .init(lowerBoundNanoseconds: 2, upperBoundNanoseconds: 8))
        for value: Int64 in [-1, 0, 1, 2, 3, 4, 7, 8, 9, 10] {
            aggregate.record(.init(phase: .httpBody, outcome: .uncertain, elapsed: .nanoseconds(value)))
        }
        let summary = aggregate.snapshot()
        let row = try #require(summary.rows.first)
        #expect(summary.acceptedCount == 9)
        #expect(summary.invalidCount == 1)
        #expect(row.count == 9 && row.invalidCount == 1)
        #expect(row.underflowCount == 2 && row.overflowCount == 2)
        #expect(row.buckets[2] == 2)
        #expect(row.buckets[3] == 2)
        #expect(row.buckets[4] == 1)
        #expect(row.buckets.reduce(0, +) == 5)
        #expect(row.minimumFiniteNanoseconds == 2)
        #expect(row.maximumFiniteNanoseconds == 8)
        #expect(row.outcome == "uncertain")
    }

    /// Shows finite per-key saturation and first-arrival key admission count every rejected observation.
    /// - Throws: Unexpected aggregate construction failure.
    @Test func keyAndObservationSaturationAreExplicit() throws {
        let aggregate = try DiscordTimingAggregate(configuration: .init(maximumKeys: 1, maximumObservationsPerKey: 2))
        let sample = DiscordTimingObservation(phase: .httpHeaders, outcome: .succeeded, elapsed: .nanoseconds(1))
        aggregate.record(sample)
        let retained = aggregate.snapshot()
        aggregate.record(sample)
        aggregate.record(sample)
        aggregate.record(.init(phase: .httpBody, outcome: .succeeded, elapsed: .nanoseconds(2)))
        let summary = aggregate.snapshot()
        #expect(summary.rows.count == 1)
        #expect(summary.acceptedCount == 2)
        #expect(summary.droppedCount == 2)
        #expect(summary.rows[0].buckets[1] == 2)
        #expect(retained.acceptedCount == 1 && retained.rows[0].buckets[1] == 1)
        #expect(summary.counterSaturationCount == 0)
    }

    /// Rejects invalid profiles before any retained histogram allocation, including too-small budgets.
    @Test func invalidProfilesAreRejected() {
        let invalid: [DiscordTimingAggregateConfiguration] = [
            .init(lowerBoundNanoseconds: -1), .init(lowerBoundNanoseconds: 2, upperBoundNanoseconds: 1),
            .init(maximumKeys: 0), .init(maximumKeys: 257), .init(maximumObservationsPerKey: 0),
            .init(storageBudgetBytes: 0), .init(storageBudgetBytes: 1), .init(storageBudgetBytes: 16 * 1_024 * 1_024 + 1),
        ]
        for configuration in invalid {
            #expect(throws: DiscordTimingAggregateError.invalidConfiguration) {
                _ = try DiscordTimingAggregate(configuration: configuration)
            }
        }
    }

    /// Keeps terminal clock regression, out-of-range offsets and mixed-domain parents out of buckets.
    /// - Throws: Unexpected aggregate construction or missing output row.
    @Test func detailedInvalidClocksRemainInvalid() throws {
        let aggregate = try DiscordTimingAggregate()
        let regressing = Box<[Duration]>([.nanoseconds(4), .nanoseconds(3)])
        let badRange = Box<[Duration]>([.nanoseconds(-1), .zero])
        DiscordIntervalTiming(clockDomain: 1, sink: { aggregate.record($0) }, now: { regressing.next() })
            .begin(.rest, stage: .operation, parent: nil).end(.failed)
        DiscordIntervalTiming(clockDomain: 1, sink: { aggregate.record($0) }, now: { badRange.next() })
            .begin(.rest, stage: .operation, parent: nil).end(.cancelled)
        let parent = DiscordIntervalTiming(clockDomain: 1, sink: { _ in }, now: { .zero })
            .begin(.rest, stage: .operation, parent: nil)
        DiscordIntervalTiming(clockDomain: 2, sink: { aggregate.record($0) }, now: { .nanoseconds(1) })
            .begin(.rest, stage: .operation, parent: parent.context).end(.uncertain)
        parent.end()
        let summary = aggregate.snapshot()
        #expect(summary.acceptedCount == 0)
        #expect(summary.invalidCount == 3)
        #expect(summary.ignoredBeginCount == 3)
        #expect(summary.rows.count == 3)
        #expect(summary.rows.allSatisfy { $0.invalidCount == 1 && $0.count == 0 && $0.buckets.allSatisfy { $0 == 0 } })
        #expect(Set(summary.rows.map(\.outcome)) == Set(["failed", "cancelled", "uncertain"]))
    }

    /// Concurrent callers retain their full populations and snapshots stay coherent without background work.
    /// - Throws: Unexpected aggregate construction failure.
    @Test func concurrentNumericUpdatesRemainComplete() async throws {
        let aggregate = try DiscordTimingAggregate()
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for value in 0..<100 {
                        aggregate.record(.init(phase: .httpHeaders, outcome: .succeeded,
                            elapsed: .nanoseconds(worker * 100 + value)))
                    }
                }
            }
        }
        let summary = aggregate.snapshot()
        #expect(summary.acceptedCount == 800)
        #expect(summary.rows.count == 1)
        #expect(summary.rows.first?.buckets.reduce(0, +) == 800)
        #expect(summary.rows.first?.minimumFiniteNanoseconds == 0)
        #expect(summary.rows.first?.maximumFiniteNanoseconds == 799)
        #expect(summary.droppedCount == 0 && summary.invalidCount == 0)
    }

    /// Filtered logs skip providers; accepted timing records use fixed events and ignore arbitrary task context.
    /// - Throws: Unexpected missing log record or invalid JSON encoding.
    @Test func logRecordsAreLazyAndContentFree() throws {
        let records = Box<[DiscordLogRecord]>([])
        let providers = Box(0)
        let secretRenders = Box(0)
        let filtered = Logger(label: "timing.test") { label in
            DiscordCallbackLogHandler(label: label, logLevel: .info, metadataProvider: .init {
                providers.update { $0 += 1 }
                return [:]
            }) { record in records.update { $0.append(record) } }
        }
        let scalar = DiscordTimingObservation(phase: .httpBody, outcome: .uncertain, elapsed: .nanoseconds(8))
        DiscordTimingLogAdapter(logger: filtered).record(scalar)
        let filteredIntervals = DiscordIntervalTiming(clockDomain: 1, sink: { DiscordTimingLogAdapter(logger: filtered).record($0) }, now: { .zero })
        filteredIntervals.begin(.rest, stage: .operation, parent: nil).end()
        #expect(records.read().isEmpty && providers.read() == 0)
        var accepted = filtered
        accepted.logLevel = .trace
        let adapter = DiscordTimingLogAdapter(logger: accepted)
        DiscordLog.$context.withValue(["raw-route": .stringConvertible(SecretDescription(calls: secretRenders))]) {
            adapter.record(scalar)
            let clock = Box<[Duration]>([.nanoseconds(1), .nanoseconds(5)])
            let timing = DiscordIntervalTiming(clockDomain: 42, sink: { adapter.record($0) }, now: { clock.next() })
            timing.begin(.httpExchange, stage: .headers, attempt: 2, parent: nil).end(.uncertain)
            adapter.record(.init(phase: .httpHeaders, outcome: .failed, elapsed: .seconds(Int64.max)))
        }
        let logged = records.read()
        #expect(logged.count == 4 && providers.read() == 4)
        #expect(secretRenders.read() == 0)
        #expect(logged.allSatisfy { $0.message == "Timing observation" && !$0.hasError })
        #expect(logged.map { $0.metadata["dk.event"] } == ["timing.scalar", "timing.interval.began", "timing.interval.ended", "timing.scalar"])
        #expect(logged[0].metadata["dk.duration_ns"] == "8")
        #expect(logged[2].metadata["dk.duration_ns"] == "4")
        #expect(logged[2].metadata["dk.outcome"] == "uncertain")
        #expect(logged[2].metadata["dk.timing.attempt"] == "2")
        #expect(logged[3].metadata["dk.duration_ns"] == nil)
        #expect(logged[3].metadata["dk.timing.validity"] == "timestampOutOfRange")
        #expect(logged.allSatisfy { $0.metadata["raw-route"] == nil })
        let text = logged.map { String(describing: $0.metadata) }.joined()
        #expect(!text.contains("DO-NOT-LOG"))
    }

    /// Detailed diagnostic output preserves numeric parent identity and refuses invalid duration values.
    /// - Throws: Unexpected missing captured terminal records.
    @Test func detailedLogParentAndInvalidClockMetadata() throws {
        let records = Box<[DiscordLogRecord]>([])
        let logger = Logger(label: "timing.validity") { label in
            DiscordCallbackLogHandler(label: label, logLevel: .trace) { record in
                records.update { $0.append(record) }
            }
        }
        let adapter = DiscordTimingLogAdapter(logger: logger)
        let parentTiming = DiscordIntervalTiming(clockDomain: 1, sink: { _ in }, now: { .zero })
        let parent = parentTiming.begin(.rest, stage: .operation, attempt: 3, parent: nil)
        let childTiming = DiscordIntervalTiming(clockDomain: 1, sink: { adapter.record($0) }, now: { .nanoseconds(2) })
        childTiming.begin(.httpExchange, stage: .headers, parent: parent.context).end(.failed)
        let regress = Box<[Duration]>([.nanoseconds(3), .nanoseconds(2)])
        DiscordIntervalTiming(clockDomain: 1, sink: { adapter.record($0) }, now: { regress.next() })
            .begin(.rest, stage: .operation, parent: nil).end(.cancelled)
        DiscordIntervalTiming(clockDomain: 2, sink: { adapter.record($0) }, now: { .zero })
            .begin(.rest, stage: .operation, parent: parent.context).end(.uncertain)
        DiscordIntervalTiming(clockDomain: 1, sink: { adapter.record($0) }, now: { .seconds(-1) })
            .begin(.rest, stage: .operation, parent: nil).end()
        parent.end()
        let captured = records.read()
        let child = try #require(captured.first)
        #expect(child.metadata["dk.timing.parent_namespace"] == .string(String(parent.context.operationID.namespace)))
        #expect(child.metadata["dk.timing.parent_id"] == .string(String(parent.context.operationID.value)))
        #expect(child.metadata["dk.timing.attempt"] == "3")
        let terminals = captured.filter { $0.metadata["dk.event"] == "timing.interval.ended" }
        #expect(terminals.count == 4)
        #expect(terminals[0].metadata["dk.timing.validity"] == "valid")
        #expect(terminals[1].metadata["dk.timing.validity"] == "clockRegression")
        #expect(terminals[2].metadata["dk.timing.validity"] == "mixedClockDomain")
        #expect(terminals[3].metadata["dk.timing.validity"] == "timestampOutOfRange")
        #expect(terminals.dropFirst().allSatisfy { $0.metadata["dk.duration_ns"] == nil })
        #expect(terminals[2].metadata["dk.timing.parent_id"] == nil)
        #expect(terminals[3].metadata["dk.timing.timestamp_ns"] == nil)
    }

}
