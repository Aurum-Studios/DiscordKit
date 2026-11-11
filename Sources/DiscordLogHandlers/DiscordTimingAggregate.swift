// File: Sources/DiscordLogHandlers/DiscordTimingAggregate.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging
import Foundation

/// Invalid bounded aggregate configuration; construction fails before allocating histogram storage.
public enum DiscordTimingAggregateError: Error, Equatable {
    /// The finite range, key count, observation cap or memory allowance cannot be honored.
    case invalidConfiguration
}

/// Explicit limits for one constant-space numeric aggregate; no benchmark support dependency is needed.
public struct DiscordTimingAggregateConfiguration: Sendable, Codable, Equatable {
    /// Smallest supported integer nanosecond value; smaller valid durations remain censored underflow.
    public let lowerBoundNanoseconds: Int64
    /// Largest supported integer nanosecond value; larger valid durations remain censored overflow.
    public let upperBoundNanoseconds: Int64
    /// Maximum retained metric/outcome rows; later identities share this explicit finite capacity.
    public let maximumKeys: Int
    /// Per-key received-observation cap, including invalid observations; subsequent values count as drops.
    public let maximumObservationsPerKey: UInt64
    /// Maximum retained aggregate storage, conservatively accounting for cells, keys and counters.
    public let storageBudgetBytes: Int

    /// Stores a proposed finite profile; the aggregate validates it before allocation.
    /// - Parameters:
    ///   - lowerBoundNanoseconds: Inclusive nonnegative supported minimum; defaults to zero.
    ///   - upperBoundNanoseconds: Inclusive maximum, at least the minimum; defaults to 60 seconds.
    ///   - maximumKeys: Allowed row count in 1...256; defaults to 236 retained combinations; excess keys count as loss.
    ///   - maximumObservationsPerKey: Positive explicit saturation cap; defaults to UInt64.max.
    ///   - storageBudgetBytes: Positive retained-state allowance, at most 16 MiB; defaults to 16 MiB.
    public init(lowerBoundNanoseconds: Int64 = 0, upperBoundNanoseconds: Int64 = 60_000_000_000,
                maximumKeys: Int = 236, maximumObservationsPerKey: UInt64 = .max,
                storageBudgetBytes: Int = 16 * 1_024 * 1_024) {
        self.lowerBoundNanoseconds = lowerBoundNanoseconds
        self.upperBoundNanoseconds = upperBoundNanoseconds
        self.maximumKeys = maximumKeys
        self.maximumObservationsPerKey = maximumObservationsPerKey
        self.storageBudgetBytes = storageBudgetBytes
    }
}

/// A finite histogram row. Buckets are logarithmic and represent ranges, never exact percentile values.
public struct DiscordTimingAggregateRow: Sendable, Codable, Equatable {
    /// Fixed source family: `scalar` or `interval`.
    public let source: String
    /// Finite scalar phase or detailed operation identity; never an application-supplied string.
    public let operation: String
    /// Finite detailed boundary; nil for scalar samples, which have no detailed endpoint.
    public let stage: String?
    /// Finite result at this measured boundary only.
    public let outcome: String
    /// Valid observations, including censored underflow and overflow mass.
    public let count: UInt64
    /// Invalid elapsed values, excluded from all finite buckets and extrema.
    public let invalidCount: UInt64
    /// Valid observations below the configured supported range.
    public let underflowCount: UInt64
    /// Valid observations above the configured supported range.
    public let overflowCount: UInt64
    /// Exactly 64 counts: index zero is zero; index i>0 covers 2^(i-1)...2^i-1 nanoseconds.
    /// The configured range can clip the first/last populated bucket. Censored mass is separate.
    public let buckets: [UInt64]
    /// Smallest in-range observation; nil when no in-range values were accepted.
    public let minimumFiniteNanoseconds: Int64?
    /// Largest in-range observation, not a complete maximum when censored or dropped mass exists.
    public let maximumFiniteNanoseconds: Int64?
}

/// An immutable, machine-readable end-of-run summary. Encoding is explicit application-owned work.
public struct DiscordTimingAggregateSnapshot: Sendable, Codable, Equatable {
    /// Version of the summary and finite metric/bucket interpretation.
    public let schemaVersion: Int
    /// Exact supported range and selected finite limits.
    public let configuration: DiscordTimingAggregateConfiguration
    /// Conservative retained-state bound for the live aggregate, excluding this exported copy.
    public let storageUpperBoundBytes: Int
    /// All accepted valid observations, including censored mass.
    public let acceptedCount: UInt64
    /// Invalid durations or detailed endpoints; these never become zero latency.
    public let invalidCount: UInt64
    /// Observations lost to key/counter/explicit per-row capacity; loss prevents complete qualification.
    public let droppedCount: UInt64
    /// Detailed begin events ignored for distributions; aggregation uses actual terminal elapsed values.
    public let ignoredBeginCount: UInt64
    /// Checked counter exhaustion occurrences; this counter itself saturates instead of wrapping.
    public let counterSaturationCount: UInt64
    /// Rows sorted by their finite metric/outcome identity, independent of concurrent arrival order.
    public let rows: [DiscordTimingAggregateRow]
}

/// Bounded synchronous numeric aggregation with no per-observation formatting, output or task creation.
///
/// Scalar and actual detailed terminal samples may be used independently. Combining both measures both
/// populations explicitly; they are separate rows and must not be summed as unique operations. A single
/// short lock protects all numeric storage. It invokes no user code, clock or external sink. Capture
/// snapshots after joining producers to establish a final population; snapshot copies and JSON encoding
/// allocate outside the observation path. This is not suitable for a hard realtime audio callback.
public final class DiscordTimingAggregate: @unchecked Sendable {
    private struct RowState {
        var key = -1
        var received: UInt64 = 0
        var count: UInt64 = 0
        var invalid: UInt64 = 0
        var underflow: UInt64 = 0
        var overflow: UInt64 = 0
        var minimum: Int64?
        var maximum: Int64?
    }

    private let configuration: DiscordTimingAggregateConfiguration
    private let storageUpperBoundBytes: Int
    private let lock = NSLock()
    private static let keyCapacity = (14 + TimingOutputNames.operations.count * TimingOutputNames.stages.count) * 4
    private var keySlots = Array(repeating: -1, count: DiscordTimingAggregate.keyCapacity)
    private var states: [RowState]
    private var cells: [UInt64]
    private var usedKeys = 0
    private var acceptedCount: UInt64 = 0
    private var invalidCount: UInt64 = 0
    private var droppedCount: UInt64 = 0
    private var ignoredBeginCount: UInt64 = 0
    private var counterSaturationCount: UInt64 = 0

    /// Validates limits and allocates all histogram/key/counter capacity before the first observation.
    /// - Parameter configuration: Finite range/storage/key limits; defaults retain up to 236 distinct rows and count excess keys as loss.
    /// - Throws: `DiscordTimingAggregateError.invalidConfiguration` if the requested profile is invalid
    ///   or its conservative storage bound exceeds the selected allowance or 16 MiB ceiling.
    public init(configuration: DiscordTimingAggregateConfiguration = .init()) throws {
        guard configuration.lowerBoundNanoseconds >= 0,
              configuration.upperBoundNanoseconds >= configuration.lowerBoundNanoseconds,
              (1...256).contains(configuration.maximumKeys),
              configuration.maximumObservationsPerKey > 0,
              (1...(16 * 1_024 * 1_024)).contains(configuration.storageBudgetBytes) else {
            throw DiscordTimingAggregateError.invalidConfiguration
        }
        // Includes contiguous cells/rows, finite key lookup, object/array headers and conservative slack.
        let bytes = configuration.maximumKeys * (64 * MemoryLayout<UInt64>.stride + 128)
            + Self.keyCapacity * MemoryLayout<Int>.stride + 8_192
        guard bytes <= configuration.storageBudgetBytes else {
            throw DiscordTimingAggregateError.invalidConfiguration
        }
        self.configuration = configuration
        self.storageUpperBoundBytes = bytes
        self.states = Array(repeating: RowState(), count: configuration.maximumKeys)
        self.cells = Array(repeating: 0, count: configuration.maximumKeys * 64)
    }

    /// Adds a scalar duration without inventing an interval identity or reading a clock.
    /// - Parameter observation: Content-free finite boundary/result and checked elapsed value.
    ///   Invalid durations, capacity loss and censored mass remain explicit in the snapshot.
    public func record(_ observation: DiscordTimingObservation) {
        let phase = TimingOutputNames.scalarPhaseIndex(observation.phase)
        let outcome = TimingOutputNames.scalarOutcomeIndex(observation.outcome)
        record(key: phase * 4 + outcome, elapsed: observation.elapsedNanoseconds)
    }

    /// Adds an actual terminal interval; begins do not require retained identities or pairing state.
    /// - Parameter event: Actual lifecycle endpoint. Invalid terminal clock/parent relationships count
    ///   separately and never enter a finite bucket; begun intervals need not ever terminate here.
    public func record(_ event: DiscordIntervalEvent) {
        guard event.kind == .ended else {
            lock.withLock {
                if !Self.increment(&ignoredBeginCount) { _ = Self.increment(&counterSaturationCount) }
            }
            return
        }
        guard let outcome = event.outcome else {
            lock.withLock {
                if !Self.increment(&invalidCount) { _ = Self.increment(&counterSaturationCount) }
            }
            return
        }
        let operation = TimingOutputNames.operationIndex(event.operation)
        let stage = TimingOutputNames.stageIndex(event.stage)
        let result = TimingOutputNames.outcomeIndex(outcome)
        record(key: (14 + operation * TimingOutputNames.stages.count + stage) * 4 + result,
               elapsed: event.validity == .valid ? event.elapsedNanoseconds : nil)
    }

    /// Copies a coherent bounded summary; it neither resets observations nor writes output.
    /// - Returns: Codable finite rows and explicit invalid/censored/loss counts. Concurrent producers
    ///   may continue after the copy; join them first when this must describe a complete run.
    public func snapshot() -> DiscordTimingAggregateSnapshot {
        let copied = lock.withLock {
            (states.map { $0 }, cells.map { $0 }, usedKeys, acceptedCount, invalidCount, droppedCount,
             ignoredBeginCount, counterSaturationCount)
        }
        let rows = copied.0.prefix(copied.2).enumerated().sorted { $0.element.key < $1.element.key }.map { entry in
            let state = entry.element
            let metric = state.key / 4
            let outcome = DiscordTimingObservation.Outcome.allCases[state.key % 4].rawValue
            let operation: String
            let stage: String?
            if metric < 14 {
                operation = DiscordTimingObservation.Phase.allCases[metric].rawValue
                stage = nil
            } else {
                operation = TimingOutputNames.operations[(metric - 14) / TimingOutputNames.stages.count]
                stage = TimingOutputNames.stages[(metric - 14) % TimingOutputNames.stages.count]
            }
            return DiscordTimingAggregateRow(source: metric < 14 ? "scalar" : "interval",
                operation: operation, stage: stage, outcome: outcome, count: state.count,
                invalidCount: state.invalid, underflowCount: state.underflow,
                overflowCount: state.overflow,
                buckets: Array(copied.1[(entry.offset * 64)..<(entry.offset * 64 + 64)]),
                minimumFiniteNanoseconds: state.minimum, maximumFiniteNanoseconds: state.maximum)
        }
        return DiscordTimingAggregateSnapshot(schemaVersion: 1, configuration: configuration,
            storageUpperBoundBytes: storageUpperBoundBytes, acceptedCount: copied.3,
            invalidCount: copied.4, droppedCount: copied.5, ignoredBeginCount: copied.6,
            counterSaturationCount: copied.7, rows: rows)
    }

    /// Applies one finite numeric update atomically, with first-arrival key admission and counted loss.
    /// - Parameters:
    ///   - key: Internal index in the finite key table; no user string participates in admission.
    ///   - elapsed: Nonnegative valid duration; nil denotes invalid clock/conversion.
    private func record(key: Int, elapsed: Int64?) {
        lock.withLock {
            var slot = keySlots[key]
            if slot < 0 {
                guard usedKeys < configuration.maximumKeys else { drop(); return }
                slot = usedKeys
                usedKeys += 1
                keySlots[key] = slot
                states[slot].key = key
            }
            guard states[slot].received < configuration.maximumObservationsPerKey else { drop(); return }
            guard let elapsed, elapsed >= 0 else {
                guard invalidCount < .max else { saturate(); drop(); return }
                states[slot].received += 1
                states[slot].invalid += 1
                invalidCount += 1
                return
            }
            guard acceptedCount < .max else { saturate(); drop(); return }
            states[slot].received += 1
            states[slot].count += 1
            acceptedCount += 1
            if elapsed < configuration.lowerBoundNanoseconds { states[slot].underflow += 1 }
            else if elapsed > configuration.upperBoundNanoseconds { states[slot].overflow += 1 }
            else {
                let bucket = elapsed == 0 ? 0 : 64 - UInt64(elapsed).leadingZeroBitCount
                cells[slot * 64 + bucket] += 1
                states[slot].minimum = min(states[slot].minimum ?? elapsed, elapsed)
                states[slot].maximum = max(states[slot].maximum ?? elapsed, elapsed)
            }
        }
    }

    /// Counts one observation rejected by a finite capacity; caller must already hold `lock`.
    private func drop() {
        if !Self.increment(&droppedCount) { saturate() }
    }

    /// Counts checked integer exhaustion without recursive logging or counter wrap; lock must be held.
    private func saturate() { _ = Self.increment(&counterSaturationCount) }

    /// Increments a numeric counter without wrapping, leaving UInt64.max unchanged on exhaustion.
    /// - Parameter counter: Locked mutable counter.
    /// - Returns: True if incremented, false if the counter was already saturated.
    private static func increment(_ counter: inout UInt64) -> Bool {
        guard counter < .max else { return false }
        counter += 1
        return true
    }
}

/// Shared closed identity mapping for optional outputs; no application content enters these tables.
enum TimingOutputNames {
    static let operations = ["rest", "httpExchange", "httpSubscriber", "gatewayDispatch", "interactionResponse", "gatewaySession", "gatewayFrame", "gatewayPublication", "signedIngress", "interactionHTTP", "commandRouting", "entityCache", "clientLifecycle"]
    static let stages = ["operation", "admission", "headers", "body", "subscriber", "localQueue", "handler", "initialResponse", "originalEdit", "socketReceipt", "decode", "ingestionQueue", "hubResidence", "heartbeatACK", "reconnect", "shutdown", "signatureVerification", "replayAdmission", "preparation", "firstResponse", "cacheLookup", "cacheMerge", "cacheProjection", "cacheInvalidation", "cacheRefresh", "cacheLoader", "construction", "discovery", "ingestion", "localReady"]

    /// Maps a finite scalar phase directly without allocating an all-cases array on the hot path.
    /// - Parameter phase: Legacy scalar owner boundary.
    /// - Returns: Stable index in the declaration order of the 14 finite phases.
    static func scalarPhaseIndex(_ phase: DiscordTimingObservation.Phase) -> Int {
        switch phase {
        case .gatewayLocalQueue: 0
        case .gatewaySharedAdmission: 1
        case .gatewayReceiveToAdmission: 2
        case .gatewayReceiveToAcknowledgement: 3
        case .gatewayAdmissionToAcknowledgement: 4
        case .gatewayRunJoined: 5
        case .interactionInitialResponse: 6
        case .interactionOriginalEdit: 7
        case .interactionAcknowledgementToOriginalEdit: 8
        case .httpAdmission: 9
        case .httpHeaders: 10
        case .httpBody: 11
        case .httpCoalescedSubscriber: 12
        case .httpExecutionJoined: 13
        }
    }

    /// Maps a finite scalar outcome without allocating an all-cases array.
    /// - Parameter outcome: Boundary result established by its owner.
    /// - Returns: Stable succeeded/failed/cancelled/uncertain index.
    static func scalarOutcomeIndex(_ outcome: DiscordTimingObservation.Outcome) -> Int {
        switch outcome {
        case .succeeded: 0
        case .failed: 1
        case .cancelled: 2
        case .uncertain: 3
        }
    }

    /// Maps every detailed family to a stable numeric slot without string work.
    /// - Parameter operation: Finite lifecycle owner.
    /// - Returns: Index in the fixed operations table.
    static func operationIndex(_ operation: DiscordIntervalOperation) -> Int {
        switch operation {
        case .rest: 0
        case .httpExchange: 1
        case .httpSubscriber: 2
        case .gatewayDispatch: 3
        case .interactionResponse: 4
        case .gatewaySession: 5
        case .gatewayFrame: 6
        case .gatewayPublication: 7
        case .signedIngress: 8
        case .interactionHTTP: 9
        case .commandRouting: 10
        case .entityCache: 11
        case .clientLifecycle: 12
        }
    }

    /// Maps every detailed boundary to a stable numeric slot without string work.
    /// - Parameter stage: Finite lifecycle boundary.
    /// - Returns: Index in the fixed stages table.
    static func stageIndex(_ stage: DiscordIntervalStage) -> Int {
        switch stage {
        case .operation: 0
        case .admission: 1
        case .headers: 2
        case .body: 3
        case .subscriber: 4
        case .localQueue: 5
        case .handler: 6
        case .initialResponse: 7
        case .originalEdit: 8
        case .socketReceipt: 9
        case .decode: 10
        case .ingestionQueue: 11
        case .hubResidence: 12
        case .heartbeatACK: 13
        case .reconnect: 14
        case .shutdown: 15
        case .signatureVerification: 16
        case .replayAdmission: 17
        case .preparation: 18
        case .firstResponse: 19
        case .cacheLookup: 20
        case .cacheMerge: 21
        case .cacheProjection: 22
        case .cacheInvalidation: 23
        case .cacheRefresh: 24
        case .cacheLoader: 25
        case .construction: 26
        case .discovery: 27
        case .ingestion: 28
        case .localReady: 29
        }
    }

    /// Maps every detailed outcome to the scalar output's matching finite result slot.
    /// - Parameter outcome: Result at the measured boundary only.
    /// - Returns: Stable index in the succeeded/failed/cancelled/uncertain order.
    static func outcomeIndex(_ outcome: DiscordIntervalOutcome) -> Int {
        switch outcome {
        case .succeeded: 0
        case .failed: 1
        case .cancelled: 2
        case .uncertain: 3
        }
    }

    /// Returns a finite validity spelling without exposing arbitrary error descriptions.
    /// - Parameter validity: Clock/parent qualification established by the lifecycle owner.
    /// - Returns: One fixed diagnostic metadata value.
    static func validity(_ validity: DiscordIntervalValidity) -> String {
        switch validity {
        case .valid: "valid"
        case .timestampOutOfRange: "timestampOutOfRange"
        case .clockRegression: "clockRegression"
        case .mixedClockDomain: "mixedClockDomain"
        }
    }
}
