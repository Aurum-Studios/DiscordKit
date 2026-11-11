// File: Tests/DiscordCacheTests/CacheIntervalTimingTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCache
import DiscordCore
import DiscordLogging
import DiscordTestSupport
import Foundation
import Testing

/// Virtual instrumentation time and finite endpoint storage; callbacks never reenter cache owners.
private final class CacheIntervalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: Duration = .zero
    private var reads = 0
    private var events: [DiscordIntervalEvent] = []

    /// Counts each instrumentation-clock read independently of the cache freshness clock.
    /// - Returns: Explicitly controlled monotonic offset.
    func now() -> Duration { lock.withLock { reads += 1; return offset } }

    /// Advances only virtual instrumentation time, without suspension or timers.
    /// - Parameter duration: Nonnegative duration supplied by the test or prompt sink.
    func advance(_ duration: Duration) { lock.withLock { offset += duration } }

    /// Appends one bounded test endpoint outside the observer's internal locks.
    /// - Parameter event: Actual lifecycle boundary emitted by the cache owner.
    func record(_ event: DiscordIntervalEvent) { lock.withLock { events.append(event) } }

    /// Returns a consistent snapshot for assertions without mutating measurement time.
    /// - Returns: Recorded endpoints and exact instrumentation-clock reads.
    func snapshot() -> (events: [DiscordIntervalEvent], reads: Int) { lock.withLock { (events, reads) } }

    /// Configures one real observer without reading its clock or delivering endpoints.
    /// - Returns: Observer in this test's explicit run-local clock domain.
    func timing() -> DiscordIntervalTiming { .init(clockDomain: 7, sink: record, now: now) }
}

/// Deterministic actual owner boundaries, optional hooks, single-flight identity and cancellation cleanup.
@Suite("Cache interval timing", .timeLimit(.minutes(1)))
struct CacheIntervalTimingTests {
    /// Disabled timing preserves task context, reads no instrumentation clock and leaves freshness semantics intact.
    /// - Throws: Unexpected cache setup, loader or freshness-advance error.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func disabledTimingAndFreshness() async throws {
        let recorder = CacheIntervalRecorder(), timing = recorder.timing(), freshness = ManualClock()
        let cache = try EntityCache(clock: freshness, intervals: nil)
        let scope = CacheScope(identity: "fixture", intents: 0), key = EntityKey(kind: .user, id: 1)
        try await cache.apply(.init(fields: [:]), for: key, scope: scope, timeToLive: .seconds(1))
        #expect(await cache.value(for: key, scope: scope) != nil)
        try freshness.advance(by: .seconds(1))
        #expect(await cache.value(for: key, scope: scope) == nil)
        #expect(recorder.snapshot().reads == 0 && recorder.snapshot().events.isEmpty)
        let parent = timing.begin(.rest, stage: .operation)
        _ = try await DiscordIntervalScope.$context.withValue(parent.context) {
            try await cache.refresh(key: key, scope: scope) {
                #expect(DiscordIntervalScope.context == parent.context)
                return .init(fields: [:])
            }
        }
        parent.end()
        #expect(recorder.snapshot().reads == 2 && recorder.snapshot().events.count == 2)
        await cache.close()
        #expect(await cache.statistics().waiters == 0)
    }

    /// Timestamp capture includes the start callback but excludes the end callback; nested projection remains distinct.
    /// - Throws: Unexpected cache observation, malformed fixture or policy validation failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func exactCallbackBoundariesAndSynchronousErrors() async throws {
        let recorder = CacheIntervalRecorder()
        let timing = DiscordIntervalTiming(clockDomain: 7, sink: { event in
            recorder.record(event)
            recorder.advance(.nanoseconds(event.kind == .began ? 3 : 5))
        }, now: recorder.now)
        let cache = try EntityCache(clock: ManualClock(), intervals: timing)
        let scope = CacheScope(identity: "fixture", intents: 0), key = EntityKey(kind: .user, id: 1)
        #expect(await cache.value(for: key, scope: scope) == nil)
        let lookup = try #require(recorder.snapshot().events.last)
        #expect(lookup.stage == .cacheLookup && lookup.elapsedNanoseconds == 3 && lookup.outcome == .succeeded)
        try await cache.observeGateway(name: "USER_UPDATE", data: .object(["id": .string("1"), "username": .string("fixture")]),
            scope: scope, shard: 0, generation: 0, sequence: nil)
        let projection = try #require(recorder.snapshot().events.first { $0.kind == .began && $0.stage == .cacheProjection })
        let merge = try #require(recorder.snapshot().events.last { $0.kind == .began && $0.stage == .cacheMerge })
        #expect(merge.context.parentID == projection.context.operationID)
        await #expect(throws: EntityCacheFailure.invalidNullField) {
            try await cache.apply(.init(fields: ["name": .null]), for: key, scope: scope)
        }
        #expect(recorder.snapshot().events.last?.outcome == .failed)
        await #expect(throws: EntityCacheFailure.invalidOrder) {
            try await cache.observeGateway(name: "USER_UPDATE", data: .object([:]), scope: scope,
                shard: -1, generation: 0, sequence: nil)
        }
        #expect(recorder.snapshot().events.last?.stage == .cacheProjection)
        #expect(recorder.snapshot().events.last?.outcome == .failed)
        await cache.invalidateLocalWrite(keys: [key], scope: scope)
        await cache.invalidateVisibility(identity: scope.identity)
        await cache.invalidateGuild(.init(rawValue: 1), scope: scope)
        await cache.invalidate(scope: scope)
        #expect(recorder.snapshot().events.filter { $0.kind == .ended && $0.stage == .cacheInvalidation }.count == 4)
        let events = recorder.snapshot().events
        #expect(events.filter { $0.kind == .began }.count == events.filter { $0.kind == .ended }.count)
        #expect(events.allSatisfy { $0.validity == .valid })
        await cache.close()
    }

    /// Two callers retain independent intervals while one actual loader is fenced by a newer complete observation.
    /// - Throws: Unexpected barrier/cache failure or a violated finite admission condition.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func singleFlightFencingAndExactLoaderDuration() async throws {
        let recorder = CacheIntervalRecorder(), started = TestBarrier(), release = TestBarrier()
        let cache = try EntityCache(clock: ManualClock(), intervals: recorder.timing())
        let scope = CacheScope(identity: "fixture", intents: 0), key = EntityKey(kind: .user, id: 1)
        let old = EntitySnapshot(fields: ["name": .string("old")], completeness: .complete)
        let new = EntitySnapshot(fields: ["name": .string("new")], completeness: .complete)
        let first = Task {
            try await cache.refresh(key: key, scope: scope) {
                started.open()
                try await release.wait()
                return old
            }
        }
        try await started.wait()
        let second = Task { try await cache.refresh(key: key, scope: scope) { Issue.record("Coalesced loader ran"); return old } }
        try await admitted(cache, waiters: 2)
        recorder.advance(.nanoseconds(41))
        try await cache.apply(new, for: key, scope: scope)
        release.open()
        #expect(try await first.value.fields == new.fields)
        #expect(try await second.value.fields == new.fields)
        let ended = recorder.snapshot().events.filter { $0.kind == .ended }
        let loaders = ended.filter { $0.stage == .cacheLoader }
        let callers = ended.filter { $0.stage == .cacheRefresh }
        #expect(loaders.count == 1 && callers.count == 2)
        #expect(loaders.first?.elapsedNanoseconds == 41)
        #expect(callers.allSatisfy { $0.outcome == .succeeded })
        #expect(callers.contains { $0.context.operationID == loaders.first?.context.parentID })
        let usage = await cache.statistics()
        #expect(usage.staleCompletions == 1 && usage.coalescedReads == 1 && usage.waiters == 0 && usage.refreshes == 0)
        await cache.close()
    }

    /// Failed loaders and pre/during cancellation retain once-only terminal outcomes after joined cleanup.
    /// - Throws: Unexpected setup, barrier or finite admission error.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func failureCancellationAndJoinedClose() async throws {
        let recorder = CacheIntervalRecorder()
        let cache = try EntityCache(clock: ManualClock(), intervals: recorder.timing())
        let scope = CacheScope(identity: "fixture", intents: 0), key = EntityKey(kind: .user, id: 1)
        await #expect(throws: TestSupportFailure.self) {
            try await cache.refresh(key: key, scope: scope) { throw TestSupportFailure.scripted("fixture") }
        }
        #expect(recorder.snapshot().events.filter { $0.kind == .ended && $0.stage == .cacheLoader }.map(\.outcome) == [.failed])
        let started = TestBarrier(), blocked = TestBarrier()
        let caller = Task {
            try await cache.refresh(key: key, scope: scope) {
                started.open()
                try await blocked.wait()
                return .init(fields: [:])
            }
        }
        try await started.wait()
        recorder.advance(.nanoseconds(17))
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(blocked.waitingCount == 0)
        let cancelled = recorder.snapshot().events.filter { $0.kind == .ended && $0.outcome == .cancelled }
        #expect(cancelled.filter { $0.stage == .cacheLoader }.count == 1)
        #expect(cancelled.filter { $0.stage == .cacheRefresh }.count == 1)
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cache.refresh(key: key, scope: scope) { Issue.record("Cancelled loader ran"); return .init(fields: [:]) }
        }
        await #expect(throws: CancellationError.self) { try await preCancelled.value }
        let closingStarted = TestBarrier(), closingBlocked = TestBarrier()
        let closingCaller = Task {
            try await cache.refresh(key: key, scope: scope) {
                closingStarted.open()
                try await closingBlocked.wait()
                return .init(fields: [:])
            }
        }
        try await closingStarted.wait()
        await cache.close(); await cache.close()
        await #expect(throws: CancellationError.self) { try await closingCaller.value }
        #expect(closingBlocked.waitingCount == 0)
        let usage = await cache.statistics()
        #expect(usage.entries == 0 && usage.waiters == 0 && usage.refreshes == 0)
        let endpoints = recorder.snapshot().events
        #expect(endpoints.filter { $0.kind == .began }.count == endpoints.filter { $0.kind == .ended }.count)
        #expect(recorder.snapshot().reads == endpoints.count)
    }

    /// Yields for deterministic actor admission with a finite test-only iteration ceiling.
    /// - Parameters:
    ///   - cache: Test-owned authority, never queried through an observation callback.
    ///   - waiters: Exact expected concurrently retained caller count.
    /// - Throws: A bounded fixture failure if admission never becomes observable.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    private func admitted(_ cache: EntityCache<ManualClock>, waiters: Int) async throws {
        for _ in 0..<100_000 {
            if await cache.statistics().waiters == waiters { return }
            await Task.yield()
        }
        throw TestSupportFailure.scripted("Cache admission did not complete")
    }
}
