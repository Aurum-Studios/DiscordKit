// File: Sources/DiscordLogHandlers/DiscordIntervalCapture.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging
import Foundation

/// Finite numeric payload limits and reproducible root head-sampling policy.
public struct DiscordIntervalCaptureConfiguration: Sendable, Equatable {
    /// Maximum retained endpoints, within `1...65_536`.
    public let maximumRecords: Int
    /// Maximum retained numeric payload bytes, within `1...8_388_608`, including active decisions.
    /// Collection containers and allocator bookkeeping are additional bounded implementation overhead.
    public let maximumBytes: Int
    /// Maximum simultaneously tracked sampled or excluded intervals, within `1...65_536`.
    public let maximumActiveIntervals: Int
    /// Select approximately one root in this many using the recorded seed and numeric root identity.
    public let sampleEvery: UInt64
    /// Reproducible sampling seed; this is diagnostic configuration rather than an identity or secret.
    public let seed: UInt64

    /// Stores limits without allocating buffers, reading clocks, formatting records or opening files.
    /// - Parameters:
    ///   - maximumRecords: Positive endpoint ceiling, at most 65,536; defaults to that ceiling.
    ///   - maximumBytes: Positive numeric payload budget, at most 8 MiB; defaults to that ceiling.
    ///     Active decisions consume this budget before endpoint retention.
    ///   - maximumActiveIntervals: Positive concurrent decision ceiling, at most 65,536; defaults to 1,024.
    ///   - sampleEvery: Positive deterministic sampling denominator; one retains every root.
    ///   - seed: Recorded root-selection seed; defaults to zero. Children inherit their tracked root's choice.
    public init(maximumRecords: Int = 65_536, maximumBytes: Int = 8 * 1_024 * 1_024,
                maximumActiveIntervals: Int = 1_024, sampleEvery: UInt64 = 1, seed: UInt64 = 0) {
        self.maximumRecords = maximumRecords
        self.maximumBytes = maximumBytes
        self.maximumActiveIntervals = maximumActiveIntervals
        self.sampleEvery = sampleEvery
        self.seed = seed
    }
}

/// Sanitized capture failures; no observed payload, destination path or system error is retained.
public enum DiscordIntervalCaptureError: Error, Sendable, Equatable {
    /// Limits are outside their documented ranges or cannot retain one endpoint plus active decisions.
    case invalidConfiguration
    /// End-of-run serialization requires explicit close and joined producers.
    case notClosed
    /// The bounded numeric data could not be represented by the selected JSON export.
    case encodingFailed
    /// A serialized artifact exceeded the fixed 32 MiB export ceiling.
    case exportTooLarge
}

/// Coherent loss/accounting observation; counters saturate at `UInt64.max`.
public struct DiscordIntervalCaptureSnapshot: Sendable, Equatable {
    /// Numeric endpoints currently retained; the capture never overwrites earlier evidence.
    public let retainedRecords: Int
    /// Effective endpoint capacity after reserving the configured active-decision payload budget.
    public let recordCapacity: Int
    /// Endpoints rejected by record/active bounds, missing parents, invalid pairing or closed admission.
    public let droppedRecords: UInt64
    /// Endpoints deliberately excluded by deterministic root sampling, distinct from collection loss.
    public let sampledOutRecords: UInt64
    /// Selected intervals with loss/invalid endpoints or unfinished at close; active intervals are provisional.
    public let incompleteIntervals: UInt64
    /// Retained lone endpoints or terminal endpoints without a tracked begin; never fabricated pairs.
    public let unmatchedEndpoints: UInt64
    /// Endpoints rejected because their parent decision was unavailable; these cannot be sampled independently.
    public let missingParentRecords: UInt64
    /// Endpoints rejected after explicit close, included in `droppedRecords`.
    public let lateRecords: UInt64
    /// Currently tracked decisions, including excluded intervals required for coherent child sampling.
    public let activeIntervals: Int
    /// Whether explicit close has stopped admission and classified remaining selected intervals.
    public let isClosed: Bool
}

/// Application-owned, bounded numeric lifecycle capture with end-of-run JSON exports.
///
/// `record` performs bounded numeric retention only: no strings, clock reads, I/O, queues or tasks.
/// One lock protects all state and invokes no application code. Active decisions use a bounded array;
/// lookup cost is linear in the configured concurrent interval ceiling. Numeric payload bytes include
/// the reserved active-decision capacity and retained endpoints; bounded Array allocation metadata is
/// additional. Saturation drops new endpoints without changing the observed operation's result.
///
/// Head sampling hashes the seed plus a root's ephemeral namespace/sequence. Every tracked child
/// follows that root's decision, including excluded roots. A missing/overflowed parent is counted as
/// loss, never independently resampled. Supply one capture to all cooperating same-domain observers.
/// Producers must emit each begin before its end and child begins while their direct parent remains
/// tracked. Invalid, missing, duplicate or mismatched endpoints cannot establish a duration.
///
/// Applications stop and join producers, call `close`, and export/write returned Data themselves.
/// Closing is idempotent and retains partial evidence. Late callbacks are counted without retention.
/// No filesystem lifetime or implicit global logging bootstrap is owned here.
public final class DiscordIntervalCapture: @unchecked Sendable {
    /// Immutable limits and sampling provenance validated on construction.
    public let configuration: DiscordIntervalCaptureConfiguration
    private struct Decision {
        let event: DiscordIntervalEvent
        let selected: Bool
        let retained: Bool
    }
    private let lock = NSLock()
    private let capacity: Int
    private var records: [DiscordIntervalEvent] = []
    private var active: [Decision] = []
    private var dropped: UInt64 = 0
    private var excluded: UInt64 = 0
    private var incomplete: UInt64 = 0
    private var unmatched: UInt64 = 0
    private var missingParent: UInt64 = 0
    private var late: UInt64 = 0
    private var closed = false

    /// Validates finite limits and reserves bounded numeric storage without emitting observations.
    /// - Parameter configuration: Endpoint/byte/concurrent-decision limits and deterministic sampling policy.
    /// - Throws: `DiscordIntervalCaptureError.invalidConfiguration` before retaining any observations.
    public init(configuration: DiscordIntervalCaptureConfiguration = .init()) throws {
        let c = configuration
        guard (1...65_536).contains(c.maximumRecords), (1...8_388_608).contains(c.maximumBytes),
              (1...65_536).contains(c.maximumActiveIntervals), c.sampleEvery > 0 else {
            throw DiscordIntervalCaptureError.invalidConfiguration
        }
        let decisionBytes = MemoryLayout<Decision>.stride * c.maximumActiveIntervals
        let count = min(c.maximumRecords, (c.maximumBytes - decisionBytes) / MemoryLayout<DiscordIntervalEvent>.stride)
        guard c.maximumBytes > decisionBytes, count > 0 else {
            throw DiscordIntervalCaptureError.invalidConfiguration
        }
        self.configuration = c
        self.capacity = count
        records.reserveCapacity(count)
        active.reserveCapacity(c.maximumActiveIntervals)
    }

    /// Consumes a genuine endpoint synchronously without formatting, I/O or external callbacks.
    /// - Parameter event: Finite numeric lifecycle observation; concurrent independent intervals may interleave.
    ///   Producers must preserve per-interval begin-before-end ordering. Missing parents and exhausted
    ///   bounds count loss; intentional head exclusions have separate counters. Closed captures count late loss.
    public func record(_ event: DiscordIntervalEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { Self.increment(&dropped); Self.increment(&late); return }
        switch event.kind {
        case .began: begin(event)
        case .ended: end(event)
        }
    }

    /// Returns current finite counters without exporting or invoking application code.
    /// - Returns: Coherent retention/loss state. Unfinished intervals become incomplete only on explicit close.
    public func snapshot() -> DiscordIntervalCaptureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DiscordIntervalCaptureSnapshot(retainedRecords: records.count, recordCapacity: capacity,
            droppedRecords: dropped, sampledOutRecords: excluded, incompleteIntervals: incomplete,
            unmatchedEndpoints: unmatched, missingParentRecords: missingParent, lateRecords: late,
            activeIntervals: active.count, isClosed: closed)
    }

    /// Stops admission, marks remaining selected intervals incomplete and releases every active decision.
    ///
    /// Repeated calls do nothing. This synchronous bounded operation owns no producer tasks to join;
    /// applications join them first when final counters must include every callback. Retained endpoints
    /// remain available for export; a concurrent/later callback increments late/drop counters only.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        for decision in active where decision.selected {
            Self.increment(&incomplete)
            if decision.retained { Self.increment(&unmatched) }
        }
        active.removeAll(keepingCapacity: false)
    }

    /// Encodes one summary line followed by paired or explicitly incomplete interval lines.
    /// - Returns: UTF-8 NDJSON, including seed, limits and loss counters; no files are opened.
    ///   Durations occur only for complete, valid, same-domain pairs with matching numeric identity.
    /// - Throws: `notClosed`, `encodingFailed` or `exportTooLarge`; numeric evidence remains available.
    ///
    /// Serialization allocates bounded end-of-run strings and JSON objects on the caller. Stop and join
    /// producers before close/export for stable final loss counters. The artifact ceiling is 32 MiB.
    public func ndjson() throws -> Data {
        let captured = try exportState()
        var result = Data()
        try Self.appendJSON(summary(captured.snapshot), to: &result)
        for pair in Self.pairs(captured.events) {
            try Self.appendJSON(Self.json(pair), to: &result)
        }
        return result
    }

    /// Exports a Chrome Trace Event timeline using genuine monotonic offsets, never wall-clock time.
    /// - Returns: UTF-8 JSON containing complete `X` intervals and `i` markers for incomplete evidence.
    ///   Nanoseconds convert to trace-format microseconds only here; exact integer offsets remain in args.
    ///   Different clock domains occupy separate tracks and are never paired together.
    /// - Throws: `notClosed`, `encodingFailed` or `exportTooLarge`; no I/O is performed.
    ///
    /// Unlike live Instruments signposts, this local timeline preserves supplied endpoint offsets.
    /// Missing/invalid pairs receive no duration. Unrepresentable timestamps appear only in the summary
    /// and NDJSON evidence, never as invented timeline offsets. Applications own writing the returned data.
    public func chromeTrace() throws -> Data {
        let captured = try exportState()
        let events: [[String: Any]] = Self.pairs(captured.events).compactMap { pair -> [String: Any]? in
            let e = pair.begin ?? pair.end!
            guard let timestamp = pair.begin?.timestampNanoseconds ?? pair.end?.timestampNanoseconds,
                  timestamp >= 0 else { return nil }
            var value: [String: Any] = ["name": "\(e.operation).\(e.stage)", "cat": "DiscordKit.interval",
                "pid": 0, "tid": String(e.context.clockDomain), "args": Self.json(pair)]
            if let duration = Self.duration(pair), let start = pair.begin?.timestampNanoseconds {
                value["ph"] = "X"
                value["ts"] = Double(start) / 1_000
                value["dur"] = Double(duration) / 1_000
            } else {
                value["ph"] = "i"
                value["s"] = "t"
                value["ts"] = Double(timestamp) / 1_000
            }
            return value
        }
        return try Self.encode(["traceEvents": events, "displayTimeUnit": "ns", "metadata": summary(captured.snapshot)])
    }

    /// Tracks one begin while the caller holds the capture lock; no external code executes.
    /// - Parameter event: Actual begin; a tracked direct parent is required for coherent child selection.
    private func begin(_ event: DiscordIntervalEvent) {
        guard !active.contains(where: { $0.event.context.operationID == event.context.operationID }),
              active.count < configuration.maximumActiveIntervals else {
            Self.increment(&dropped)
            return
        }
        let selected: Bool
        if let parent = event.context.parentID {
            guard let owner = active.first(where: {
                $0.event.context.operationID == parent && $0.event.context.clockDomain == event.context.clockDomain
            }) else {
                Self.increment(&dropped)
                Self.increment(&missingParent)
                return
            }
            selected = owner.selected
        } else {
            let id = event.context.operationID
            selected = Self.mix(Self.mix(configuration.seed ^ id.namespace) ^ id.value) % configuration.sampleEvery == 0
        }
        let retained = selected && records.count < capacity
        active.append(Decision(event: event, selected: selected, retained: retained))
        if retained { records.append(event) }
        else if selected { Self.increment(&dropped) }
        else { Self.increment(&excluded) }
    }

    /// Completes one tracked decision while the caller holds the capture lock.
    /// - Parameter event: Genuine terminal endpoint; mismatched ownership/domain is rejected without ending its begin.
    private func end(_ event: DiscordIntervalEvent) {
        guard let index = active.firstIndex(where: { $0.event.context.operationID == event.context.operationID }) else {
            Self.increment(&dropped)
            Self.increment(&unmatched)
            return
        }
        let decision = active[index], begin = decision.event
        guard begin.context == event.context, begin.operation == event.operation, begin.stage == event.stage else {
            Self.increment(&dropped)
            Self.increment(&unmatched)
            return
        }
        active.swapAt(index, active.count - 1)
        active.removeLast()
        guard decision.selected else { Self.increment(&excluded); return }
        let retained = records.count < capacity
        if retained { records.append(event) } else { Self.increment(&dropped) }
        if decision.retained != retained { Self.increment(&unmatched) }
        let pair = Pair(begin: begin, end: event)
        if !decision.retained || !retained || Self.duration(pair) == nil { Self.increment(&incomplete) }
    }

    /// Copies immutable closed evidence and its synchronized counters for caller-owned serialization.
    /// - Returns: Bounded endpoint storage and summary; late callbacks can only change later snapshots.
    /// - Throws: `notClosed` when admission remains open.
    private func exportState() throws -> (events: [DiscordIntervalEvent], snapshot: DiscordIntervalCaptureSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        guard closed else { throw DiscordIntervalCaptureError.notClosed }
        return (records, DiscordIntervalCaptureSnapshot(retainedRecords: records.count, recordCapacity: capacity,
            droppedRecords: dropped, sampledOutRecords: excluded, incompleteIntervals: incomplete,
            unmatchedEndpoints: unmatched, missingParentRecords: missingParent, lateRecords: late,
            activeIntervals: active.count, isClosed: closed))
    }

    /// Builds finite machine-readable provenance and loss fields outside the recording path.
    /// - Parameter snapshot: Coherent counters captured with the exported numeric records.
    /// - Returns: Content-free summary object; all identities remain run-local diagnostic values.
    private func summary(_ snapshot: DiscordIntervalCaptureSnapshot) -> [String: Any] {
        ["format": "discordkit.interval-capture", "schemaVersion": 1, "kind": "summary",
         "seed": configuration.seed, "sampleEvery": configuration.sampleEvery,
         "maximumRecords": configuration.maximumRecords, "maximumBytes": configuration.maximumBytes,
         "maximumActiveIntervals": configuration.maximumActiveIntervals, "recordCapacity": snapshot.recordCapacity,
         "retainedRecords": snapshot.retainedRecords, "droppedRecords": snapshot.droppedRecords,
         "sampledOutRecords": snapshot.sampledOutRecords, "incompleteIntervals": snapshot.incompleteIntervals,
         "unmatchedEndpoints": snapshot.unmatchedEndpoints, "missingParentRecords": snapshot.missingParentRecords,
         "lateRecords": snapshot.lateRecords, "isClosed": snapshot.isClosed]
    }

    private struct Pair {
        let begin: DiscordIntervalEvent?
        let end: DiscordIntervalEvent?
    }

    /// Matches retained endpoints in their original begin order without manufacturing missing boundaries.
    /// - Parameter events: Closed bounded numeric storage with producer ordering preserved.
    /// - Returns: Pairs and explicit lone endpoints; dictionary storage exists only during export.
    private static func pairs(_ events: [DiscordIntervalEvent]) -> [Pair] {
        var indices: [DiscordIntervalID: Int] = [:]
        var result: [Pair] = []
        for event in events {
            if event.kind == .began {
                indices[event.context.operationID] = result.count
                result.append(Pair(begin: event, end: nil))
            } else if let index = indices.removeValue(forKey: event.context.operationID) {
                result[index] = Pair(begin: result[index].begin, end: event)
            } else { result.append(Pair(begin: nil, end: event)) }
        }
        return result
    }

    /// Validates paired boundaries before exposing any qualifying duration.
    /// - Parameter pair: Genuine retained endpoints, either of which may be missing.
    /// - Returns: Checked endpoint difference only for valid matching observations and reported elapsed time.
    private static func duration(_ pair: Pair) -> Int64? {
        guard let begin = pair.begin, let end = pair.end,
              begin.validity == .valid, end.validity == .valid,
              begin.context == end.context, begin.operation == end.operation, begin.stage == end.stage,
              let start = begin.timestampNanoseconds, let finish = end.timestampNanoseconds,
              start >= 0, finish >= start, let reported = end.elapsedNanoseconds,
              reported == finish - start, end.outcome != nil else { return nil }
        return reported
    }

    /// Constructs one honest interval representation outside all recording locks.
    /// - Parameter pair: Complete or partial retained lifecycle evidence.
    /// - Returns: Exact numeric offsets and nullable duration with finite owner/result spellings.
    private static func json(_ pair: Pair) -> [String: Any] {
        let event = pair.begin ?? pair.end!
        let duration = duration(pair)
        return ["kind": "interval", "operation": String(describing: event.operation), "stage": String(describing: event.stage),
            "clockDomain": event.context.clockDomain, "namespace": event.context.operationID.namespace,
            "operationID": event.context.operationID.value,
            "parentNamespace": event.context.parentID.map { $0.namespace as Any } ?? NSNull(),
            "parentID": event.context.parentID.map { $0.value as Any } ?? NSNull(),
            "attempt": event.context.attempt.map { $0 as Any } ?? NSNull(),
            "beginNanoseconds": pair.begin?.timestampNanoseconds.map { $0 as Any } ?? NSNull(),
            "endNanoseconds": pair.end?.timestampNanoseconds.map { $0 as Any } ?? NSNull(),
            "durationNanoseconds": duration.map { $0 as Any } ?? NSNull(), "complete": duration != nil,
            "outcome": pair.end?.outcome.map { String(describing: $0) as Any } ?? NSNull(),
            "beginValidity": pair.begin.map { String(describing: $0.validity) as Any } ?? NSNull(),
            "endValidity": pair.end.map { String(describing: $0.validity) as Any } ?? NSNull()]
    }

    /// Appends one complete NDJSON line while enforcing the artifact ceiling.
    /// - Parameters:
    ///   - object: Content-free JSON object constructed during end-of-run export.
    ///   - result: Owned accumulating artifact; receives no partial line on bounds failure.
    /// - Throws: `encodingFailed` or `exportTooLarge` without mutating retained numeric evidence.
    private static func appendJSON(_ object: [String: Any], to result: inout Data) throws {
        let line = try encode(object)
        guard line.count < 32 * 1_024 * 1_024 - result.count else {
            throw DiscordIntervalCaptureError.exportTooLarge
        }
        result.append(line)
        result.append(0x0A)
    }

    /// Serializes JSON only during explicit export and rejects oversized artifacts.
    /// - Parameter object: Finite JSON-compatible output object with no untrusted application payload.
    /// - Returns: Deterministic key-sorted UTF-8 JSON, bounded to 32 MiB.
    /// - Throws: `encodingFailed` or `exportTooLarge`; no filesystem operations occur.
    private static func encode(_ object: [String: Any]) throws -> Data {
        let result: Data
        do { result = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        catch { throw DiscordIntervalCaptureError.encodingFailed }
        guard result.count <= 32 * 1_024 * 1_024 else { throw DiscordIntervalCaptureError.exportTooLarge }
        return result
    }

    /// Applies a fixed SplitMix64 finalizer with intentional modular arithmetic for stable sampling.
    /// - Parameter value: Recorded seed/finite root identity combination; never payload or persistent user identity.
    /// - Returns: Deterministic mixed bits; this diagnostic hash provides no cryptographic guarantee.
    private static func mix(_ value: UInt64) -> UInt64 {
        var result = value
        result = (result ^ (result >> 30)) &* 0xbf58476d1ce4e5b9
        result = (result ^ (result >> 27)) &* 0x94d049bb133111eb
        return result ^ (result >> 31)
    }

    /// Saturates one accounting counter rather than wrapping during a long application lifetime.
    /// - Parameter counter: Lock-owned counter to increment once for the documented observation.
    private static func increment(_ counter: inout UInt64) {
        if counter < .max { counter += 1 }
    }
}
