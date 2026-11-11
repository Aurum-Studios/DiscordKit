// File: Tests/DiscordCacheTests/EntityCacheScalingTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Testing
import DiscordCore
import DiscordTestSupport
@testable import DiscordCache

/// Independent scan-model checks for indexed retention under mixed expiry, scope and budget churn.
@Suite struct EntityCacheScalingTests {
    /// Full-scan reference decisions remain equivalent while arbitrary heap removals and LRU promotions interleave.
    @Test func mixedOperationsMatchScanReference() async throws {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else { return }
        let clock = ManualClock()
        let limits = CacheLimits(maximumEntries: 17, maximumBytes: 2_200,
            maximumEntriesPerIdentity: 4, maximumBytesPerIdentity: 600, maximumTimeToLive: .seconds(12))
        let cache = try EntityCache(clock: clock, policy: .bounded(limits))
        var model = EntityCacheScanReference(limits: limits)
        for step in 0..<900 {
            let scope = CacheScope(identity: "identity-\((step * 7 + step / 11) % 6)",
                intents: UInt64(step / 3 % 2), visibilityGeneration: UInt64(step / 13 % 3))
            let key = EntityKey(kind: .user, id: UInt64((step * 17 + step / 7) % 29))
            if step % 9 == 0 {
                try clock.advance(by: .seconds(1))
                model.now += 1
            }
            _ = await cache.statistics()
            model.prune()
            switch step % 13 {
            case 0:
                await cache.invalidate(scope: scope)
                model.entries = model.entries.filter { $0.key.scope != scope }
            case 1:
                await cache.invalidateVisibility(identity: scope.identity)
                model.entries = model.entries.filter { $0.key.scope.identity != scope.identity }
            case 2:
                if let retained = model.entries.min(by: { $0.value.access < $1.value.access })?.key {
                    #expect(await cache.value(for: retained.entity, scope: retained.scope)
                        == model.value(for: retained.entity, scope: retained.scope))
                }
            case 3:
                #expect(await cache.value(for: key, scope: scope) == model.value(for: key, scope: scope))
            default:
                let payload = String(repeating: "x", count: step % 3 == 0 ? 1 : step * 53 % 800)
                let snapshot = EntitySnapshot(fields: ["v": .string(payload)], completeness: .complete)
                let ttl = step % 31 == 0 ? 0 : step * 11 % 16 + 1
                let expected = model.apply(snapshot, for: key, scope: scope, ttl: ttl,
                    bytes: 73 + payload.utf8.count + scope.identity.utf8.count)
                #expect(try await cache.apply(snapshot, for: key, scope: scope, timeToLive: .seconds(ttl)) == expected)
                if step % 4 == 0 {
                    #expect(await cache.value(for: key, scope: scope) == model.value(for: key, scope: scope))
                }
            }
            let stats = await cache.statistics()
            #expect(stats.entries == model.entries.count)
            #expect(stats.bytes == model.bytes)
            #expect(stats.evictions == model.evictions)
            #expect(stats.expirations == model.expirations)
            let indexes = await cache.retainedIndexCounts()
            #expect(indexes.expiry == model.entries.count)
            #expect(indexes.identities == Set(model.entries.keys.map(\.scope.identity)).count)
            #expect(indexes.refreshIdentities == 0)
        }
        try clock.advance(by: .seconds(12))
        #expect(await cache.statistics().entries == 0)
        #expect(await cache.statistics().bytes == 0)
        #expect(await cache.retainedIndexCounts().expiry == 0)
        #expect(await cache.retainedIndexCounts().identities == 0)
        // A drained heap and identity registry can be reused without retaining old ordering state.
        let scope = CacheScope(identity: "recovered", intents: 0)
        let key = EntityKey(kind: .user, id: 1)
        try await cache.apply(EntitySnapshot(fields: [:]), for: key, scope: scope)
        #expect(await cache.value(for: key, scope: scope) != nil)
        await cache.close()
        #expect(await cache.retainedIndexCounts().expiry == 0)
        #expect(await cache.retainedIndexCounts().identities == 0)
    }

    /// Extending and shortening one deadline thousands of times retains only its current index record.
    @Test func repeatedReplacementBoundsMetadataAndKeepsInclusiveExpiry() async throws {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else { return }
        let clock = ManualClock()
        let cache = try EntityCache(clock: clock)
        let scope = CacheScope(identity: "replacement", intents: 0)
        let key = EntityKey(kind: .user, id: 1)
        for step in 0..<2_000 {
            try await cache.apply(EntitySnapshot(fields: ["v": .string(String(step))], completeness: .complete),
                for: key, scope: scope, timeToLive: .seconds(step % 2 == 0 ? 1 : 20))
            let indexes = await cache.retainedIndexCounts()
            #expect(indexes.expiry == 1)
            #expect(indexes.identities == 1)
        }
        try clock.advance(by: .seconds(1))
        #expect(await cache.value(for: key, scope: scope)?.fields["v"] == .string("1999"))
        try clock.advance(by: .seconds(19))
        #expect(await cache.value(for: key, scope: scope) == nil)
        #expect(await cache.statistics().expirations == 1)
        #expect(await cache.retainedIndexCounts().expiry == 0)
        #expect(await cache.retainedIndexCounts().identities == 0)
    }

    /// Success and failure both release per-identity refresh admission even when entity retention is disabled.
    @Test func completedRefreshIdentityCountersDoNotAccumulate() async throws {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else { return }
        let cache = try EntityCache(clock: ManualClock(), policy: .bounded(.init(maximumEntries: 0,
            maximumRefreshes: 1, maximumRefreshesPerIdentity: 1)))
        let key = EntityKey(kind: .user, id: 1)
        for identity in 0..<100 {
            let scope = CacheScope(identity: "refresh-\(identity)", intents: 0)
            await #expect(throws: EntityCacheScalingFailure.loader) {
                try await cache.refresh(key: key, scope: scope) { throw EntityCacheScalingFailure.loader }
            }
            _ = try await cache.refresh(key: key, scope: scope) { EntitySnapshot(fields: [:]) }
            #expect(await cache.statistics().refreshes == 0)
            #expect(await cache.retainedIndexCounts().refreshIdentities == 0)
        }
        await cache.close()
    }
}

/// Explicit injected loader failure, independent of concurrency or external services.
private enum EntityCacheScalingFailure: Error { case loader }

/// Deliberately scan-based reference policy, independent of the production heap and linked lists.
private struct EntityCacheScanReference {
    struct Key: Hashable {
        let entity: EntityKey
        let scope: CacheScope
    }
    struct Entry {
        let snapshot: EntitySnapshot
        let deadline: Int
        let bytes: Int
        var access: Int
    }
    let limits: CacheLimits
    var entries: [Key: Entry] = [:]
    var now = 0
    var access = 0
    var evictions: UInt64 = 0
    var expirations: UInt64 = 0
    /// Recomputes the independent model charge by scanning live entries; empty state returns zero.
    var bytes: Int { entries.values.reduce(0) { $0 + $1.bytes } }

    /// Prunes every inclusively expired record using the independent integer clock.
    mutating func prune() {
        let expired = entries.filter { $0.value.deadline <= now }.map(\.key)
        for key in expired { entries.removeValue(forKey: key) }
        expirations += UInt64(expired.count)
    }

    /// Reads and promotes exact scoped evidence using the reference access counter.
    /// - Parameters:
    ///   - entity: Exact resource key.
    ///   - scope: Exact identity, intent and visibility partition.
    /// - Returns: Current retained evidence or nil; no other partition can satisfy the read.
    mutating func value(for entity: EntityKey, scope: CacheScope) -> EntitySnapshot? {
        let key = Key(entity: entity, scope: scope)
        guard let entry = entries[key] else { return nil }
        access += 1
        entries[key]?.access = access
        return entry.snapshot
    }

    /// Applies the documented complete-replacement policy with full scans for quota and oldest selection.
    /// - Parameters:
    ///   - snapshot: Complete unordered fixture projection.
    ///   - entity: Resource being replaced.
    ///   - scope: Exact partition charged to its shared identity budget.
    ///   - ttl: Requested integer seconds, capped at the fixture's 12-second policy ceiling.
    ///   - retainedBytes: Independently calculated JSON and metadata charge for the fixture.
    /// - Returns: The expected public retention outcome.
    mutating func apply(_ snapshot: EntitySnapshot, for entity: EntityKey, scope: CacheScope,
        ttl: Int, bytes retainedBytes: Int) -> CacheWriteResult {
        let key = Key(entity: entity, scope: scope)
        entries.removeValue(forKey: key)
        guard ttl > 0, retainedBytes <= min(limits.maximumBytes, limits.maximumBytesPerIdentity) else {
            return .notRetained
        }
        while true {
            let own = entries.filter { $0.key.scope.identity == scope.identity }
            if own.count < limits.maximumEntriesPerIdentity,
               own.values.reduce(0, { $0 + $1.bytes }) <= limits.maximumBytesPerIdentity - retainedBytes { break }
            guard let oldest = own.min(by: { $0.value.access < $1.value.access })?.key else { return .notRetained }
            entries.removeValue(forKey: oldest)
            evictions += 1
        }
        while entries.count >= limits.maximumEntries || bytes > limits.maximumBytes - retainedBytes {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key else { return .notRetained }
            entries.removeValue(forKey: oldest)
            evictions += 1
        }
        access += 1
        entries[key] = Entry(snapshot: snapshot, deadline: now + min(ttl, 12), bytes: retainedBytes, access: access)
        return .stored
    }
}
