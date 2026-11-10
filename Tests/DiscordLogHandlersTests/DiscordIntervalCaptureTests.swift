// File: Tests/DiscordLogHandlersTests/DiscordIntervalCaptureTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogHandlers
import DiscordLogging
import Foundation
import Testing

/// Finite virtual clock and endpoint fixture for replaying real detailed hooks without fabricated events.
private final class CaptureFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: Duration = .zero
    private var stored: [DiscordIntervalEvent] = []

    /// Returns the synchronized virtual monotonic offset without advancing it.
    /// - Returns: Current offset, including deliberate invalid values selected by a test.
    func now() -> Duration { lock.withLock { offset } }

    /// Selects an exact virtual offset before the next real lifecycle hook.
    /// - Parameter value: Requested offset; regression/overflow cases are intentionally permitted.
    func set(_ value: Duration) { lock.withLock { offset = value } }

    /// Retains one event inside a test's explicitly finite population.
    /// - Parameter event: Real event emitted by the model under test.
    func record(_ event: DiscordIntervalEvent) { lock.withLock { stored.append(event) } }

    /// Copies the finite emitted endpoint history.
    /// - Returns: Original genuine events suitable for missing/duplicate/admission test replay.
    func events() -> [DiscordIntervalEvent] { lock.withLock { stored } }

    /// Creates a real detailed observer with this fixture's virtual clock and endpoint storage.
    /// - Parameter domain: Numeric origin identity; defaults to one.
    /// - Returns: Observer that performs no live network, wall-clock or filesystem work.
    func timing(domain: UInt64 = 1) -> DiscordIntervalTiming {
        DiscordIntervalTiming(clockDomain: domain, sink: record, now: now)
    }
}

/// Deterministic bounded retention, coherent head sampling and truthful local timeline exports.
@Suite("Bounded interval capture", .timeLimit(.minutes(1)))
struct DiscordIntervalCaptureTests {
    /// Invalid bounds fail before allocation; export requires explicit application-owned close.
    /// - Throws: Unexpected construction or export failures.
    @Test func configurationAndExplicitClose() throws {
        for configuration in [
            DiscordIntervalCaptureConfiguration(maximumRecords: 0),
            .init(maximumRecords: 65_537), .init(maximumBytes: 0), .init(maximumBytes: 8_388_609),
            .init(maximumBytes: 1), .init(maximumActiveIntervals: 0),
            .init(maximumActiveIntervals: 65_537), .init(sampleEvery: 0)
        ] {
            #expect(throws: DiscordIntervalCaptureError.invalidConfiguration) {
                try DiscordIntervalCapture(configuration: configuration)
            }
        }
        let capture = try DiscordIntervalCapture()
        #expect(throws: DiscordIntervalCaptureError.notClosed) { try capture.ndjson() }
        #expect(throws: DiscordIntervalCaptureError.notClosed) { try capture.chromeTrace() }
        capture.close()
        capture.close()
        let rows = try lines(capture.ndjson())
        #expect(rows.count == 1)
        #expect(rows[0]["retainedRecords"] as? Int == 0)
        #expect(capture.snapshot().isClosed)
        let trace = try #require(JSONSerialization.jsonObject(with: capture.chromeTrace()) as? [String: Any])
        #expect((trace["traceEvents"] as? [[String: Any]])?.isEmpty == true)
    }

    /// Genuine nested owner intervals retain exact offsets, parent/attempt identity and independent outcomes.
    /// - Throws: Unexpected missing JSON fields or export failures.
    @Test func nestedExportAndTimeline() throws {
        let capture = try DiscordIntervalCapture(), clock = CaptureFixture()
        let timing = DiscordIntervalTiming(clockDomain: 47, sink: capture.record, now: clock.now)
        clock.set(.nanoseconds(10))
        let root = timing.begin(.rest, stage: .operation)
        clock.set(.nanoseconds(20))
        let child = timing.begin(.httpExchange, stage: .headers, attempt: 3, parent: root.context)
        clock.set(.nanoseconds(35))
        child.end(.uncertain)
        clock.set(.nanoseconds(50))
        root.end()
        capture.close()
        let rows = try lines(capture.ndjson())
        #expect(rows.count == 3)
        #expect(rows[1]["durationNanoseconds"] as? Int == 40)
        #expect(rows[2]["durationNanoseconds"] as? Int == 15)
        #expect(rows[2]["parentID"] as? UInt64 == root.context.operationID.value)
        #expect(rows[2]["attempt"] as? Int == 3)
        #expect(rows[2]["outcome"] as? String == "uncertain")
        #expect(capture.snapshot().incompleteIntervals == 0)
        let trace = try #require(JSONSerialization.jsonObject(with: capture.chromeTrace()) as? [String: Any])
        let events = try #require(trace["traceEvents"] as? [[String: Any]])
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0["ph"] as? String == "X" })
        #expect(events[0]["dur"] as? Double == 0.04)
        #expect(events[1]["ts"] as? Double == 0.02)
    }

    /// Dropping precisely one terminal preserves an incomplete begin with no invented duration or zero-latency row.
    /// - Throws: Unexpected missing JSON fields or export failures.
    @Test func exactlyOneEndpointDropped() throws {
        let capture = try DiscordIntervalCapture(configuration: .init(maximumRecords: 3))
        let timing = DiscordIntervalTiming(clockDomain: 1, sink: capture.record, now: { .nanoseconds(10) })
        timing.begin(.rest, stage: .operation).end()
        timing.begin(.rest, stage: .operation).end(.failed)
        capture.close()
        let snapshot = capture.snapshot()
        #expect(snapshot.retainedRecords == 3)
        #expect(snapshot.droppedRecords == 1)
        #expect(snapshot.incompleteIntervals == 1)
        #expect(snapshot.unmatchedEndpoints == 1)
        let rows = try lines(capture.ndjson())
        #expect(rows.count == 3)
        #expect(rows[1]["complete"] as? Bool == true)
        #expect(rows[2]["complete"] as? Bool == false)
        #expect(rows[2]["durationNanoseconds"] is NSNull)
        #expect(rows[2]["endNanoseconds"] is NSNull)
        let trace = try #require(JSONSerialization.jsonObject(with: capture.chromeTrace()) as? [String: Any])
        let events = try #require(trace["traceEvents"] as? [[String: Any]])
        #expect(events.map { $0["ph"] as? String } == ["X", "i"])
        #expect(events[1]["dur"] == nil)
    }

    /// Clock regression invalidates duration; fractional offsets retain the model's difference of truncated integer endpoints.
    /// - Throws: Unexpected export failures or missing rows.
    @Test func invalidClockAndFractionalEndpoints() throws {
        let capture = try DiscordIntervalCapture(), clock = CaptureFixture()
        let timing = DiscordIntervalTiming(clockDomain: 1, sink: capture.record, now: clock.now)
        clock.set(.nanoseconds(10))
        let regression = timing.begin(.rest, stage: .operation)
        clock.set(.nanoseconds(9))
        regression.end()
        clock.set(Duration(secondsComponent: 0, attosecondsComponent: 900_000_000))
        let fractional = timing.begin(.rest, stage: .operation)
        clock.set(Duration(secondsComponent: 0, attosecondsComponent: 1_100_000_000))
        fractional.end()
        clock.set(.seconds(-1))
        timing.begin(.rest, stage: .operation).end()
        capture.close()
        let rows = try lines(capture.ndjson())
        #expect(rows[1]["complete"] as? Bool == false)
        #expect(rows[1]["durationNanoseconds"] is NSNull)
        #expect(rows[2]["beginNanoseconds"] as? Int == 0)
        #expect(rows[2]["endNanoseconds"] as? Int == 1)
        #expect(rows[2]["durationNanoseconds"] as? Int == 1)
        #expect(rows[2]["complete"] as? Bool == true)
        #expect(capture.snapshot().incompleteIntervals == 2)
        let trace = try #require(JSONSerialization.jsonObject(with: capture.chromeTrace()) as? [String: Any])
        #expect((trace["traceEvents"] as? [[String: Any]])?.count == 2)
    }

    /// Finite active decisions reject excess starts, absent parents and unmatched/duplicate terminals explicitly.
    /// - Throws: Unexpected capture construction failures.
    @Test func activeBoundsAndUnmatchedEndpoints() throws {
        let clock = CaptureFixture(), timing = clock.timing()
        let root = timing.begin(.rest, stage: .operation)
        let child = timing.begin(.httpExchange, stage: .headers, parent: root.context)
        child.end()
        root.end()
        let events = clock.events()
        let capture = try DiscordIntervalCapture(configuration: .init(maximumActiveIntervals: 1))
        events.forEach(capture.record)
        capture.record(events[3])
        capture.close()
        #expect(capture.snapshot().retainedRecords == 2)
        #expect(capture.snapshot().droppedRecords == 3)
        #expect(capture.snapshot().unmatchedEndpoints == 2)
        let absentParent = try DiscordIntervalCapture()
        absentParent.record(events[1])
        absentParent.record(events[2])
        absentParent.close()
        #expect(absentParent.snapshot().retainedRecords == 0)
        #expect(absentParent.snapshot().missingParentRecords == 1)
        #expect(absentParent.snapshot().droppedRecords == 2)
        #expect(absentParent.snapshot().unmatchedEndpoints == 1)
    }

    /// Closing a live interval releases decisions once and counts late terminal delivery without retention.
    /// - Throws: Unexpected construction or export failures.
    @Test func closeAndLateCallbacks() throws {
        let capture = try DiscordIntervalCapture()
        let timing = DiscordIntervalTiming(clockDomain: 1, sink: capture.record)
        let interval = timing.begin(.rest, stage: .operation)
        capture.close()
        capture.close()
        interval.end()
        #expect(capture.snapshot().activeIntervals == 0)
        #expect(capture.snapshot().incompleteIntervals == 1)
        #expect(capture.snapshot().unmatchedEndpoints == 1)
        #expect(capture.snapshot().lateRecords == 1)
        #expect(capture.snapshot().droppedRecords == 1)
        #expect(capture.snapshot().retainedRecords == 1)
        #expect(try lines(capture.ndjson())[1]["durationNanoseconds"] is NSNull)
    }

    /// Seeded selection is repeatable for the same finite identities and never selects only a child's endpoints.
    /// - Throws: Unexpected construction or export failures.
    @Test func deterministicCoherentHeadSampling() throws {
        let clock = CaptureFixture(), timing = clock.timing()
        for _ in 0..<128 {
            let root = timing.begin(.rest, stage: .operation)
            let child = timing.begin(.httpExchange, stage: .headers, parent: root.context)
            child.end()
            root.end()
        }
        let config = DiscordIntervalCaptureConfiguration(sampleEvery: 2, seed: 1234)
        let first = try DiscordIntervalCapture(configuration: config)
        let second = try DiscordIntervalCapture(configuration: config)
        clock.events().forEach(first.record)
        clock.events().forEach(second.record)
        first.close()
        second.close()
        #expect(try first.ndjson() == second.ndjson())
        let snapshot = first.snapshot()
        #expect(UInt64(snapshot.retainedRecords) + snapshot.sampledOutRecords == 512)
        #expect(snapshot.droppedRecords == 0)
        #expect(snapshot.sampledOutRecords % 4 == 0)
        let rows = try lines(first.ndjson()).dropFirst()
        let roots = rows.filter { $0["parentID"] is NSNull }
        let children = rows.filter { !($0["parentID"] is NSNull) }
        #expect(roots.count == children.count)
        #expect(rows.allSatisfy { $0["complete"] as? Bool == true })
        for child in children {
            #expect(roots.contains { $0["operationID"] as? UInt64 == child["parentID"] as? UInt64 })
        }
    }

    /// A lower byte budget reduces effective endpoint capacity without exceeding the numeric payload cap.
    /// - Throws: Unexpected construction failures.
    @Test func byteBudgetAndDuplicateBegin() throws {
        let capture = try DiscordIntervalCapture(configuration: .init(maximumBytes: 1_024, maximumActiveIntervals: 1))
        #expect(capture.snapshot().recordCapacity > 0)
        #expect(capture.snapshot().recordCapacity < 65_536)
        let clock = CaptureFixture(), timing = clock.timing()
        let interval = timing.begin(.rest, stage: .operation)
        interval.end()
        let events = clock.events()
        capture.record(events[0])
        capture.record(events[0])
        capture.record(events[1])
        capture.close()
        #expect(capture.snapshot().retainedRecords == 2)
        #expect(capture.snapshot().droppedRecords == 1)
        #expect(capture.snapshot().incompleteIntervals == 0)
    }

    /// Concurrent independent owners retain every admitted endpoint and close with no active decisions.
    /// - Throws: Unexpected construction failures.
    @Test func concurrentRecording() async throws {
        let capture = try DiscordIntervalCapture(configuration: .init(maximumActiveIntervals: 64))
        let timing = DiscordIntervalTiming(clockDomain: 1, sink: capture.record)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask { timing.begin(.rest, stage: .operation).end() }
            }
        }
        capture.close()
        #expect(capture.snapshot().retainedRecords == 128)
        #expect(capture.snapshot().droppedRecords == 0)
        #expect(capture.snapshot().activeIntervals == 0)
        #expect(capture.snapshot().incompleteIntervals == 0)
    }

    /// Parses the finite end-of-run NDJSON artifact for semantic field assertions.
    /// - Parameter data: Complete UTF-8 lines returned by explicit capture export.
    /// - Returns: Ordered JSON objects, including the first summary line.
    /// - Throws: JSON decoding or missing-object failures, which fail the enclosing deterministic test.
    private func lines(_ data: Data) throws -> [[String: Any]] {
        try data.split(separator: 0x0A).map { line in
            try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        }
    }
}
