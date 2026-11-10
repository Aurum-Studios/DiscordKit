// File: Tests/DiscordLogHandlersTests/DiscordIntervalSignpostTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogHandlers
import DiscordLogging
import Dispatch
import Foundation
import Testing

/// Finite genuine hook-event fixture with a synchronized virtual offset.
private final class SignpostClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: Duration = .zero
    private var stored: [DiscordIntervalEvent] = []

    /// Reads the virtual offset without live-clock work.
    /// - Returns: Current test-selected offset.
    func now() -> Duration { lock.withLock { offset } }

    /// Selects the next virtual offset, including intentional regression cases.
    /// - Parameter value: Exact offset to return at the next lifecycle hook.
    func set(_ value: Duration) { lock.withLock { offset = value } }

    /// Retains a genuine model event within the finite test workload.
    /// - Parameter event: Detailed begin/end event, with no fabricated memberwise construction.
    func record(_ event: DiscordIntervalEvent) { lock.withLock { stored.append(event) } }

    /// Copies the emitted events for deliberate missing/duplicate replay.
    /// - Returns: Genuine endpoints in delivery order.
    func events() -> [DiscordIntervalEvent] { lock.withLock { stored } }

    /// Constructs a detailed observer using this fixture's synchronized virtual clock.
    /// - Returns: Observer with numeric domain one and no network/filesystem work.
    func timing() -> DiscordIntervalTiming { DiscordIntervalTiming(clockDomain: 1, sink: record, now: now) }
}

/// Fake profiler that records exact begin/terminal cleanup semantics outside the adapter lock.
private final class SignpostProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var begins = 0
    private var ends = 0
    private var incomplete = 0
    private var inspect: (@Sendable () -> Void)?

    /// Installs optional callback inspection after adapter construction.
    /// - Parameter body: Snapshot-only inspection, or nil to release its captured adapter after a test.
    func inspect(using body: (@Sendable () -> Void)?) { lock.withLock { inspect = body } }

    /// Records one accepted start and returns the matching bounded fake ending state.
    /// - Parameter event: Genuine begin, unused beyond its acceptance because tests inspect model identity separately.
    /// - Returns: Once-only finalizer recording whether the adapter supplied a genuine end or incomplete cleanup.
    func begin(_ event: DiscordIntervalEvent) -> (@Sendable (DiscordIntervalEvent?) -> Void) {
        let callback = lock.withLock { begins += 1; return inspect }
        callback?()
        return { terminal in self.finish(terminal) }
    }

    /// Records one paired real terminal or explicit incomplete cleanup, then allows snapshot reentrancy.
    /// - Parameter terminal: Actual valid terminal, or nil for shutdown/invalid pairing cleanup.
    private func finish(_ terminal: DiscordIntervalEvent?) {
        let callback = lock.withLock {
            if terminal == nil { incomplete += 1 } else { ends += 1 }
            return inspect
        }
        callback?()
    }

    /// Copies the finite fake profiler accounting.
    /// - Returns: Exact accepted starts, genuine endings and incomplete cleanups.
    func snapshot() -> (begins: Int, ends: Int, incomplete: Int) {
        lock.withLock { (begins, ends, incomplete) }
    }
}

/// Portable pairing, deterministic lifecycle races and actual Apple API smoke coverage.
@Suite("Genuine interval signposts", .timeLimit(.minutes(1)))
struct DiscordIntervalSignpostTests {
    /// All constructor paths reject invalid active ceilings before calling any emitter.
    /// - Throws: Unexpected fixture construction failures.
    @Test func invalidConfiguration() throws {
        let probe = SignpostProbe()
        for maximum in [0, 65_537] {
            #expect(throws: DiscordIntervalSignpostError.invalidConfiguration) {
                try DiscordIntervalSignposts(maximumActiveIntervals: maximum, begin: probe.begin)
            }
        }
        #expect(probe.snapshot().begins == 0)
    }

    /// Genuine pairs and snapshot-only reentrancy invoke each emitter outside adapter locks.
    /// - Throws: Unexpected adapter construction failures.
    @Test func genuinePairsAndSnapshotInspection() throws {
        let probe = SignpostProbe()
        let adapter = try DiscordIntervalSignposts(begin: probe.begin)
        probe.inspect(using: { _ = adapter.snapshot() })
        let timing = DiscordIntervalTiming(clockDomain: 1, sink: adapter.record)
        let root = timing.begin(.rest, stage: .operation)
        let child = timing.begin(.httpExchange, stage: .headers, attempt: 2, parent: root.context)
        child.end(.uncertain)
        root.end()
        adapter.close()
        adapter.close()
        probe.inspect(using: nil)
        #expect(probe.snapshot().begins == 2)
        #expect(probe.snapshot().ends == 2)
        #expect(probe.snapshot().incomplete == 0)
        #expect(adapter.snapshot().begunIntervals == 2)
        #expect(adapter.snapshot().endedIntervals == 2)
        #expect(adapter.snapshot().activeIntervals == 0)
        #expect(adapter.snapshot().droppedRecords == 0)
    }

    /// Saturation drops one begin, then explicitly rejects its unmatched end and duplicate terminal.
    /// - Throws: Unexpected adapter construction failures.
    @Test func saturationAndUnmatched() throws {
        let probe = SignpostProbe(), clock = SignpostClock(), timing = clock.timing()
        let root = timing.begin(.rest, stage: .operation)
        let excess = timing.begin(.rest, stage: .operation)
        root.end()
        excess.end()
        let events = clock.events()
        let adapter = try DiscordIntervalSignposts(maximumActiveIntervals: 1, begin: probe.begin)
        events.forEach(adapter.record)
        adapter.record(events[2])
        adapter.close()
        #expect(probe.snapshot().begins == 1)
        #expect(probe.snapshot().ends == 1)
        #expect(adapter.snapshot().droppedRecords == 3)
        #expect(adapter.snapshot().unmatchedEndpoints == 2)
        #expect(adapter.snapshot().incompleteIntervals == 0)
        #expect(adapter.snapshot().activeIntervals == 0)
    }

    /// Invalid genuine ends close profiler state as incomplete; invalid begins never start profiler intervals.
    /// - Throws: Unexpected adapter construction failures.
    @Test func invalidClockAndIncompleteShutdown() throws {
        let probe = SignpostProbe(), clock = SignpostClock()
        let adapter = try DiscordIntervalSignposts(begin: probe.begin)
        let timing = DiscordIntervalTiming(clockDomain: 1, sink: adapter.record, now: clock.now)
        clock.set(.nanoseconds(10))
        let invalidEnd = timing.begin(.rest, stage: .operation)
        clock.set(.nanoseconds(9))
        invalidEnd.end()
        clock.set(.nanoseconds(20))
        let unfinished = timing.begin(.rest, stage: .operation)
        clock.set(.seconds(-1))
        timing.begin(.rest, stage: .operation).end()
        adapter.close()
        adapter.close()
        unfinished.end()
        #expect(probe.snapshot().begins == 2)
        #expect(probe.snapshot().ends == 0)
        #expect(probe.snapshot().incomplete == 2)
        #expect(adapter.snapshot().incompleteIntervals == 2)
        #expect(adapter.snapshot().droppedRecords == 4)
        #expect(adapter.snapshot().unmatchedEndpoints == 1)
        #expect(adapter.snapshot().activeIntervals == 0)
    }

    /// Close racing an executing begin retains its reservation until the real state receives incomplete cleanup.
    /// - Throws: Unexpected adapter construction failures.
    @Test func closeDuringBeginDelivery() async throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let probe = SignpostProbe(), clock = SignpostClock(), timing = clock.timing()
        let interval = timing.begin(.rest, stage: .operation)
        interval.end()
        let event = clock.events()[0]
        let adapter = try DiscordIntervalSignposts(maximumActiveIntervals: 1, begin: { event in
            entered.signal()
            release.wait()
            return probe.begin(event)
        })
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                adapter.record(event)
                continuation.resume()
            }
            entered.wait()
            adapter.close()
            #expect(adapter.snapshot().isClosed)
            #expect(adapter.snapshot().activeIntervals == 1)
            #expect(probe.snapshot().incomplete == 0)
            release.signal()
        }
        #expect(probe.snapshot().begins == 1)
        #expect(probe.snapshot().incomplete == 1)
        #expect(adapter.snapshot().incompleteIntervals == 1)
        #expect(adapter.snapshot().activeIntervals == 0)
    }

    /// An actual live state remains capacity-accounted until a delayed ending callback returns.
    /// - Throws: Unexpected adapter construction failures.
    @Test func endingDeliveryRetainsCapacity() async throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let probe = SignpostProbe(), clock = SignpostClock(), timing = clock.timing()
        let first = timing.begin(.rest, stage: .operation)
        first.end()
        let next = timing.begin(.rest, stage: .operation)
        next.end()
        let events = clock.events()
        let adapter = try DiscordIntervalSignposts(maximumActiveIntervals: 1, begin: { event in
            let ending = probe.begin(event)
            return { terminal in
                entered.signal()
                release.wait()
                ending(terminal)
            }
        })
        adapter.record(events[0])
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                adapter.record(events[1])
                continuation.resume()
            }
            entered.wait()
            #expect(adapter.snapshot().activeIntervals == 1)
            adapter.record(events[2])
            #expect(adapter.snapshot().droppedRecords == 1)
            #expect(probe.snapshot().begins == 1)
            adapter.close()
            #expect(adapter.snapshot().activeIntervals == 1)
            release.signal()
        }
        #expect(probe.snapshot().ends == 1)
        #expect(adapter.snapshot().activeIntervals == 0)
        #expect(adapter.snapshot().endedIntervals == 1)
        #expect(adapter.snapshot().incompleteIntervals == 0)
    }

    /// A terminal racing begin delivery is queued numerically and invokes one genuine end after begin returns.
    /// - Throws: Unexpected adapter construction failures.
    @Test func terminalDuringBeginDelivery() async throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let probe = SignpostProbe(), clock = SignpostClock(), timing = clock.timing()
        timing.begin(.rest, stage: .operation).end()
        let events = clock.events()
        let adapter = try DiscordIntervalSignposts(begin: { event in
            entered.signal()
            release.wait()
            return probe.begin(event)
        })
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                adapter.record(events[0])
                continuation.resume()
            }
            entered.wait()
            adapter.record(events[1])
            #expect(adapter.snapshot().activeIntervals == 1)
            #expect(probe.snapshot().ends == 0)
            release.signal()
        }
        adapter.close()
        #expect(probe.snapshot().ends == 1)
        #expect(probe.snapshot().incomplete == 0)
        #expect(adapter.snapshot().activeIntervals == 0)
    }

    /// Independent concurrent owners finish every bounded fake profiler state without remaining resources.
    /// - Throws: Unexpected adapter construction failures.
    @Test func concurrentGenuinePairs() async throws {
        let probe = SignpostProbe()
        let adapter = try DiscordIntervalSignposts(maximumActiveIntervals: 64, begin: probe.begin)
        let timing = DiscordIntervalTiming(clockDomain: 1, sink: adapter.record)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 { group.addTask { timing.begin(.rest, stage: .operation).end() } }
        }
        adapter.close()
        #expect(probe.snapshot().begins == 64)
        #expect(probe.snapshot().ends == 64)
        #expect(adapter.snapshot().activeIntervals == 0)
        #expect(adapter.snapshot().droppedRecords == 0)
    }

    #if canImport(os)
    /// Invokes the actual native Apple API for paired completion and labeled incomplete shutdown.
    /// - Throws: Unexpected native adapter configuration failures.
    ///
    /// This local smoke checks live API execution and bounded state accounting; it does not claim that
    /// Instruments recorded a session or that an external profiler trace was inspected.
    @available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    @Test func appleLiveAPISmoke() throws {
        let adapter = try DiscordIntervalSignposts(maximumActiveIntervals: 2,
            subsystem: "DiscordKit.Tests", category: "IntervalSmoke")
        let timing = DiscordIntervalTiming(clockDomain: 42, sink: adapter.record)
        timing.begin(.httpExchange, stage: .headers, attempt: 1).end(.uncertain)
        _ = timing.begin(.interactionResponse, stage: .initialResponse)
        adapter.close()
        #expect(adapter.snapshot().begunIntervals == 2)
        #expect(adapter.snapshot().endedIntervals == 1)
        #expect(adapter.snapshot().incompleteIntervals == 1)
        #expect(adapter.snapshot().activeIntervals == 0)
        #expect(adapter.snapshot().droppedRecords == 0)
    }
    #endif
}
