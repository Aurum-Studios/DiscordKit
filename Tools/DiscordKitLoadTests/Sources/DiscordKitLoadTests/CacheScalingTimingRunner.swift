// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/CacheScalingTimingRunner.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordCache
import DiscordCore
import DiscordHTTP
import DiscordLogging
import Foundation

/// Finite direct-call evidence; setup and recovery counters never enter measured call populations.
struct CacheScalingTimingMeasurement: Codable, Sendable {
    let counts: BenchmarkCounts
    let metrics: [BenchmarkMetric]
    let clockDomain: String
    let durationNanoseconds: UInt64
    let initialEntries: Int
    let retainedBeforeCleanup: Int
    let accountedBytesBeforeCleanup: Int
    let measuredExpiryRemovals: Int
    let measuredCapacityEvictions: Int
    let recoveryReads: Int
    let setupWrites: Int
    let cleanup: CacheTimingCleanup
}

/// Fixture-only opaque scoped key; its numeric identity is never derived from credentials.
private struct CacheScalingKey: Equatable, Sendable {
    let id: Int
    let identity: Int
    let representation: String
    let tags: Set<String>
    let entity: EntityKey

    /// Prepares key strings, tags and resource keys outside selected call timers.
    /// - Parameters:
    ///   - id: Finite resource identifier; unique new identifiers drive capacity eviction.
    ///   - identity: Index into the separately prepared fixed identity collection.
    init(id: Int, identity: Int) {
        self.id = id; self.identity = identity
        representation = "key-\(id)"
        tags = [representation]
        entity = .init(kind: .user, id: UInt64(id))
    }
}

/// Prevents setup, diagnostic reads and recovery from entering entity-owner timing populations.
private enum CacheScalingMeasurementScope { @TaskLocal static var enabled = false }

/// Uniform fixture operations retain the real owners' distinct payload and invalidation contracts.
@available(macOS 15, *)
private enum CacheScalingStore: Sendable {
    case entity(EntityCache<CacheLoadClock>, [CacheScope], [EntitySnapshot])
    case read(ReadCache<CacheLoadClock>, [RateLimitIdentity], [Data])

    /// Installs a prepared complete payload; no JSON or response fixture construction is timed here.
    /// - Parameters:
    ///   - key: Exact scoped key selected by the finite driver.
    ///   - updated: Selects a second equal-size payload to verify replacement behavior.
    ///   - generation: Read-owner generation acquired outside the selected call timer.
    /// - Throws: Entity observation failures; both owners' retention is verified after the call.
    func store(_ key: CacheScalingKey, updated: Bool = false, generation: UInt64) async throws {
        switch self {
        case .entity(let cache, let scopes, let snapshots):
            _ = try await cache.apply(snapshots[updated ? 1 : 0], for: key.entity, scope: scopes[key.identity])
        case .read(let cache, let identities, let payloads):
            await cache.insert(payloads[updated ? 1 : 0], for: .init(identity: identities[key.identity], representation: key.representation),
                               timeToLive: .seconds(1), tags: key.tags, generation: generation)
        }
    }

    /// Acquires an HTTP fetch fence outside insert timing; entity observations need no external fence.
    /// - Returns: Current public read-cache generation, or zero for the entity fixture.
    func generation() async -> UInt64 {
        switch self { case .entity: return 0; case .read(let cache, _, _): return await cache.generation() }
    }

    /// Reads one real owner and returns its immutable result for verification after the timer stops.
    /// - Parameter key: Exact scoped key, including deliberately absent lookup representations.
    /// - Returns: Entity or retained response data with no fabricated owner interval.
    func load(_ key: CacheScalingKey) async -> CacheScalingValue {
        switch self {
        case .entity(let cache, let scopes, _):
            return .entity(await cache.value(for: key.entity, scope: scopes[key.identity]))
        case .read(let cache, let identities, _):
            return .read(await cache.value(for: .init(identity: identities[key.identity], representation: key.representation)))
        }
    }

    /// Checks exact replacement contents after the measured caller and owner intervals have ended.
    /// - Parameters:
    ///   - value: Immutable result from the completed call.
    ///   - updated: Whether the second prepared payload is expected.
    /// - Returns: Exact equality with the selected fixture payload.
    func matches(_ value: CacheScalingValue, updated: Bool = false) -> Bool {
        switch (self, value) {
        case (.entity(_, _, let snapshots), .entity(let snapshot)): snapshot == snapshots[updated ? 1 : 0]
        case (.read(_, _, let payloads), .read(let data)): data == payloads[updated ? 1 : 0]
        default: false
        }
    }

    /// Invalidates exactly one prepared representation through the owner's public write boundary.
    /// - Parameter key: Entity local-write key or uniquely tagged HTTP representation.
    func invalidate(_ key: CacheScalingKey) async {
        switch self {
        case .entity(let cache, let scopes, _):
            await cache.invalidateLocalWrite(keys: [key.entity], scope: scopes[key.identity])
        case .read(let cache, let identities, _):
            await cache.invalidate(identity: identities[key.identity], tags: key.tags)
        }
    }

    /// Captures accounted retention after the selected call; both snapshots perform lazy pruning.
    /// - Returns: Exact retained count/charged bytes, excluding allocator and index overhead.
    func usage() async -> (entries: Int, bytes: Int) {
        switch self {
        case .entity(let cache, _, _):
            let value = await cache.statistics(); return (value.entries, value.bytes)
        case .read(let cache, _, _): return await cache.snapshot()
        }
    }

    /// Releases all retained entries and joins entity refresh ownership before reporting cleanup.
    /// - Returns: Exact zero-entry/refresh/waiter evidence, with no broadcast resources involved.
    func close() async -> CacheTimingCleanup {
        switch self {
        case .entity(let cache, _, _):
            await cache.close()
            let value = await cache.statistics()
            return .init(entries: value.entries, refreshes: value.refreshes, waiters: value.waiters, subscriptions: 0, bufferedEvents: 0)
        case .read(let cache, _, _):
            await cache.removeAll()
            return .init(entries: await cache.snapshot().entries, refreshes: 0, waiters: 0, subscriptions: 0, bufferedEvents: 0)
        }
    }
}

/// Immutable results cross the timer boundary before fixture equality or missing-value checks.
private enum CacheScalingValue: Sendable {
    case entity(EntitySnapshot?), read(Data?)
    /// Reports actual absence without inspecting payload contents within measured calls.
    var isAbsent: Bool {
        switch self { case .entity(let value): value == nil; case .read(let value): value == nil }
    }
}

/// Sequential public calls isolate cache service from task-wave scheduling and loader/provider waits.
@available(macOS 15, *)
struct CacheScalingTimingRunner: Sendable {
    /// Measures a finite prefilled owner, independently varying aggregate keys, scopes, bytes and churn.
    /// - Parameters:
    ///   - configuration: Explicit owner, scenario and bounded fixture dimensions.
    ///   - requests: Optional warmup override, subject to the same aggregate workload limits.
    /// - Returns: Complete call/owner histograms, recovery evidence and joined zero-owner cleanup.
    /// - Throws: Invalid configuration, cancellation during setup, owner errors or exact-state failure.
    ///   Lookup timers exclude population, payload construction, replacement churn, checks and recovery.
    ///   Entity writes retain their real serialization/charging cost. Read writes use prepared bytes.
    func run(_ configuration: CacheScalingTimingConfiguration, requests: Int? = nil) async throws -> CacheScalingTimingMeasurement {
        var finite = configuration
        finite.requests = requests ?? configuration.requests
        // This runner owns exactly one population; the command validates combined warmup/measured work.
        finite.warmupRequests = 0
        try finite.validate()
        try Task.checkCancellation()
        let scenario = CacheScalingTimingScenario(rawValue: finite.scenario)!
        let statistics = try RunStatistics(workloads: [.cacheCall, .cacheOwner])
        let wall = ContinuousClock(), start = wall.now, freshness = CacheLoadClock()
        let intervals = DiscordIntervalTiming(clockDomain: UInt64.random(in: 1...UInt64.max), sink: { event in
            guard CacheScalingMeasurementScope.enabled, event.kind == .ended, event.operation == .entityCache,
                  event.stage == scenario.ownerStage else { return }
            statistics.record(event.validity == .valid ? event.elapsedNanoseconds.map(Duration.nanoseconds) ?? .seconds(-1) : .seconds(-1),
                              workload: .cacheOwner, outcome: event.outcome == .succeeded ? .success : .failure)
        }, now: { start.duration(to: wall.now) })
        let perIdentity = (finite.workingSet + finite.identities - 1) / finite.identities
        let chargedBytes = finite.payloadBytes + 1_024
        let store: CacheScalingStore
        switch finite.owner {
        case .entity:
            let cache = try EntityCache(clock: freshness, policy: .bounded(.init(maximumEntries: finite.workingSet,
                maximumBytes: finite.workingSet * chargedBytes, maximumEntriesPerIdentity: perIdentity,
                maximumBytesPerIdentity: perIdentity * chargedBytes, maximumTimeToLive: .seconds(1))), intervals: intervals)
            let scopes = (0..<finite.identities).map { CacheScope(identity: "cache-scaling-\($0)", intents: 1 << 15) }
            let snapshots = [0, 1].map { version in EntitySnapshot(fields: ["payload": .string(String(repeating: "x", count: finite.payloadBytes)),
                "version": .string(String(version))], completeness: .complete) }
            store = .entity(cache, scopes, snapshots)
        case .read:
            let cache = ReadCache(clock: freshness, policy: .init(maximumEntries: finite.workingSet,
                maximumBytes: finite.workingSet * chargedBytes, maximumEntriesPerIdentity: perIdentity,
                maximumBytesPerIdentity: perIdentity * chargedBytes))
            store = .read(cache, (0..<finite.identities).map { _ in RateLimitIdentity() },
                          [Data(repeating: 120, count: finite.payloadBytes), Data(repeating: 121, count: finite.payloadBytes)])
        }
        var keys = (0..<finite.workingSet).map { CacheScalingKey(id: $0 + 1, identity: $0 % finite.identities) }
        var setupWrites = 0, completed = 0, expiryRemovals = 0, evictions = 0, recovery = 0
        do {
            var generation = await store.generation()
            for key in keys { try Task.checkCancellation(); try await store.store(key, generation: generation); setupWrites += 1 }
            let initial = await store.usage()
            guard initial.entries == finite.workingSet else { throw CacheScalingTimingError.integrityFailure("Incomplete prefilled working set") }
            for ordinal in 0..<finite.requests {
                try Task.checkCancellation()
                if scenario == .expiryStorm, ordinal > 0 {
                    for key in keys { try Task.checkCancellation(); try await store.store(key, generation: generation); setupWrites += 1 }
                }
                // The driver keeps exact oldest-to-newest order outside the selected public call.
                for offset in 0..<finite.churnUpdates {
                    try Task.checkCancellation()
                    let index = (ordinal + offset) % keys.count
                    let key = keys.remove(at: index)
                    try await store.store(key, generation: generation); setupWrites += 1
                    keys.append(key)
                }
                let key = keys[ordinal % keys.count]
                let selected: CacheScalingKey
                var victim: CacheScalingKey?
                if scenario == .capacity {
                    let identity = ordinal % finite.identities
                    selected = .init(id: finite.workingSet + ordinal + 1, identity: identity)
                    let candidates = keys.indices.filter { keys[$0].identity == identity }
                    let index = candidates.count >= perIdentity ? candidates[0] : 0
                    victim = keys.remove(at: index)
                } else if scenario == .miss {
                    selected = .init(id: finite.workingSet + finite.requests + 1, identity: key.identity)
                } else { selected = key }
                if scenario == .expiryStorm { freshness.advance(by: .seconds(1)) }
                let value = try await CacheScalingMeasurementScope.$enabled.withValue(true) {
                    let submitted = wall.now
                    let result: CacheScalingValue?
                    switch scenario {
                    case .hotHit, .miss, .expiryStorm: result = await store.load(selected)
                    case .update: try await store.store(selected, updated: true, generation: generation); result = nil
                    case .capacity: try await store.store(selected, generation: generation); result = nil
                    case .invalidation: await store.invalidate(selected); result = nil
                    }
                    let terminal = wall.now
                    statistics.record(submitted.duration(to: terminal), workload: .cacheCall, outcome: .success)
                    return result
                }
                completed += 1
                switch scenario {
                case .hotHit:
                    guard let value, store.matches(value) else { throw CacheScalingTimingError.integrityFailure("Hot lookup changed payload") }
                    keys.removeAll { $0 == selected }; keys.append(selected)
                case .miss, .expiryStorm:
                    guard value?.isAbsent == true else { throw CacheScalingTimingError.integrityFailure("Absent lookup unexpectedly retained") }
                    if scenario == .expiryStorm { expiryRemovals += finite.workingSet }
                case .update:
                    guard store.matches(await store.load(selected), updated: true) else { throw CacheScalingTimingError.integrityFailure("Replacement mismatch") }
                    keys.removeAll { $0 == selected }; keys.append(selected)
                case .capacity:
                    guard let victim, await store.load(victim).isAbsent, store.matches(await store.load(selected)) else {
                        throw CacheScalingTimingError.integrityFailure("Capacity eviction violated LRU")
                    }
                    keys.append(selected); evictions += 1
                case .invalidation:
                    guard await store.load(selected).isAbsent else { throw CacheScalingTimingError.integrityFailure("Invalidated key survived") }
                    generation = await store.generation()
                    try await store.store(selected, generation: generation); setupWrites += 1
                    guard store.matches(await store.load(selected)) else { throw CacheScalingTimingError.integrityFailure("Invalidation recovery failed") }
                    keys.removeAll { $0 == selected }; keys.append(selected); recovery += 1
                }
                let expected = scenario == .expiryStorm ? 0 : finite.workingSet
                guard await store.usage().entries == expected else { throw CacheScalingTimingError.integrityFailure("Retained working set changed") }
            }
            let final = await store.usage()
            // Expiry recovery is checked after its selected lookup population, without a second storm.
            if scenario == .expiryStorm, let key = keys.first {
                try await store.store(key, generation: generation); setupWrites += 1
                guard store.matches(await store.load(key)) else { throw CacheScalingTimingError.integrityFailure("Expiry recovery failed") }
                recovery += 1
            }
            let cleanup = await store.close()
            guard cleanup.isEmpty else { throw CacheScalingTimingError.integrityFailure("Cache cleanup retained ownership") }
            var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
            outcomes[.success] = UInt64(completed)
            return .init(counts: .init(offered: UInt64(completed), admitted: UInt64(completed), completed: UInt64(completed),
                                      outcomes: outcomes, deadlineMisses: 0), metrics: statistics.metrics(),
                clockDomain: statistics.clockDomain, durationNanoseconds: try BenchmarkTime.nanoseconds(duration: start.duration(to: wall.now)),
                initialEntries: initial.entries, retainedBeforeCleanup: final.entries, accountedBytesBeforeCleanup: final.bytes,
                measuredExpiryRemovals: expiryRemovals, measuredCapacityEvictions: evictions, recoveryReads: recovery,
                setupWrites: setupWrites, cleanup: cleanup)
        } catch {
            _ = await store.close()
            throw error
        }
    }
}
