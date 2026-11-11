// File: Tests/DiscordHTTPTests/ReadCacheScalingTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordTestSupport
import Foundation
import Testing
@testable import DiscordHTTP

/// Exercises exact indexed retention against an independent full-scan reference model.
@Suite(.timeLimit(.minutes(1))) struct ReadCacheScalingTests {
    /// Hits promote both LRU orders; scoped eviction cannot select another identity's older entry.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func globalAndIdentityCountEviction() async {
        let cache = ReadCache(clock: ManualClock(), policy: .init(maximumEntries: 4, maximumBytes: 100,
                              maximumEntriesPerIdentity: 2, maximumBytesPerIdentity: 100))
        let a = RateLimitIdentity(), b = RateLimitIdentity(), c = RateLimitIdentity()
        let a1 = HTTPReadKey(identity: a, representation: "1"), a2 = HTTPReadKey(identity: a, representation: "2")
        let a3 = HTTPReadKey(identity: a, representation: "3"), b1 = HTTPReadKey(identity: b, representation: "1")
        let b2 = HTTPReadKey(identity: b, representation: "2"), c1 = HTTPReadKey(identity: c, representation: "1")
        for key in [a1, a2, b1, b2] {
            await cache.insert(Data([1]), for: key, timeToLive: .seconds(100), tags: [], generation: 0)
        }
        #expect(await cache.value(for: a1) == Data([1]))
        await cache.insert(Data([3]), for: a3, timeToLive: .seconds(100), tags: [], generation: 0)
        #expect(await cache.value(for: a2) == nil)
        await cache.insert(Data([4]), for: c1, timeToLive: .seconds(100), tags: [], generation: 0)
        #expect(await cache.value(for: b1) == nil)
        for key in [a1, a3, b2, c1] { #expect(await cache.value(for: key) != nil) }
        #expect(await cache.snapshot().entries == 4)
        #expect(await cache.indexSnapshot().expiryEntries == 4)
        #expect(await cache.indexSnapshot().identities == 3)
    }

    /// Byte budgets use exact counters and may evict multiple global entries after scoped eviction.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func identityAndGlobalByteEviction() async {
        let cache = ReadCache(clock: ManualClock(), policy: .init(maximumEntries: 10, maximumBytes: 10,
                              maximumEntriesPerIdentity: 10, maximumBytesPerIdentity: 7))
        let a = RateLimitIdentity(), b = RateLimitIdentity()
        let a1 = HTTPReadKey(identity: a, representation: "1"), a2 = HTTPReadKey(identity: a, representation: "2")
        let a3 = HTTPReadKey(identity: a, representation: "3"), b1 = HTTPReadKey(identity: b, representation: "1")
        let b2 = HTTPReadKey(identity: b, representation: "2")
        for key in [a1, a2, b1] {
            await cache.insert(Data(repeating: 1, count: 3), for: key, timeToLive: .seconds(100), tags: [], generation: 0)
        }
        #expect(await cache.value(for: a1) != nil)
        await cache.insert(Data(repeating: 2, count: 4), for: a3, timeToLive: .seconds(100), tags: [], generation: 0)
        #expect(await cache.value(for: a2) == nil)
        #expect(await cache.snapshot().bytes == 10)
        await cache.insert(Data(repeating: 3, count: 4), for: b2, timeToLive: .seconds(100), tags: [], generation: 0)
        #expect(await cache.value(for: b1) == nil)
        #expect(await cache.value(for: a1) == nil)
        #expect(await cache.value(for: a3) == Data(repeating: 2, count: 4))
        #expect(await cache.value(for: b2) == Data(repeating: 3, count: 4))
        #expect(await cache.snapshot().entries == 2)
        #expect(await cache.snapshot().bytes == 8)
    }

    /// Rejected replacements preserve the existing payload, and accepted replacement expires inclusively.
    /// Invalidating any scope fences old generations without deleting another scope's retained value.
    /// - Throws: Unexpected virtual clock advancement failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func rejectedReplacementAndConservativeGenerationFence() async throws {
        let clock = ManualClock(), identity = RateLimitIdentity()
        let key = HTTPReadKey(identity: identity, representation: "read")
        let cache = ReadCache(clock: clock, policy: .init(maximumBytes: 8, maximumBytesPerIdentity: 8))
        await cache.insert(Data([1, 2]), for: key, timeToLive: .seconds(10), tags: ["old"], generation: 0)
        await cache.insert(Data(repeating: 0, count: 9), for: key, timeToLive: .seconds(1), tags: [], generation: 0)
        await cache.insert(Data([0]), for: key, timeToLive: .zero, tags: [], generation: 0)
        await cache.insert(Data([0]), for: key, timeToLive: .seconds(1), tags: [], generation: 1)
        await cache.insert(Data([0]), for: key, timeToLive: .seconds(1),
                           tags: Set((0..<129).map(String.init)), generation: 0)
        await cache.insert(Data([0]), for: key, timeToLive: .seconds(1),
                           tags: [String(repeating: "a", count: 65_537)], generation: 0)
        #expect(await cache.value(for: key) == Data([1, 2]))
        await cache.invalidate(identity: RateLimitIdentity())
        await cache.insert(Data([0]), for: key, timeToLive: .seconds(1), tags: [], generation: 0)
        #expect(await cache.value(for: key) == Data([1, 2]))
        await cache.insert(Data(repeating: 3, count: 5), for: key, timeToLive: .seconds(2), tags: ["new"], generation: 1)
        await cache.invalidate(identity: identity, tags: ["old"])
        #expect(await cache.snapshot().bytes == 5)
        try clock.advance(by: .seconds(2))
        #expect(await cache.value(for: key) == nil)
        #expect(await cache.snapshot().bytes == 0)
        #expect(await cache.indexSnapshot().expiryEntries == 0)
        #expect(await cache.indexSnapshot().identities == 0)
    }

    /// Repeated replacement and complete expiry storms retain exactly one index record per live entry.
    /// - Parameter capacity: Odd, even, singleton and deeper heap shapes.
    /// - Throws: Unexpected virtual clock advancement failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [1, 2, 3, 4, 15, 32]) func mixedOperationsMatchReference(capacity: Int) async throws {
        let clock = ManualClock()
        let policy = ReadCachePolicy(maximumEntries: capacity, maximumBytes: capacity * 5,
                                    maximumEntriesPerIdentity: max(1, capacity / 2), maximumBytesPerIdentity: capacity * 3)
        let cache = ReadCache(clock: clock, policy: policy)
        let identities = (0..<4).map { _ in RateLimitIdentity() }
        let keys = (0..<capacity * 3 + 7).map { HTTPReadKey(identity: identities[$0 % identities.count], representation: String($0)) }
        var model = ReadCacheReference(policy: policy), random = ReadCacheRandom(seed: UInt64(capacity))
        var now = 0
        // Start every heap shape at its entry limit before payload churn makes byte limits dominant.
        for index in 0..<capacity {
            let key = keys[index], payload = Data([UInt8(index)])
            let ttl = index * 7 % 11 + 1
            let tags: Set<String> = [String(index % 3)]
            await cache.insert(payload, for: key, timeToLive: .seconds(ttl), tags: tags, generation: 0)
            model.insert(payload, for: key, ttl: ttl, tags: tags, generation: 0, now: now)
        }
        #expect(await cache.snapshot().entries == capacity)
        #expect(await cache.indexSnapshot().expiryEntries == capacity)
        for step in 0..<1_500 {
            let key = keys[random.next(keys.count)]
            switch random.next(12) {
            case 0...5:
                let payload = Data(repeating: UInt8(step % 256), count: random.next(capacity * 3 + 2))
                let ttl = random.next(8) - 1
                let tags: Set<String> = [String(random.next(3))]
                let generation = random.next(5) == 0 ? model.revision &+ 1 : model.revision
                await cache.insert(payload, for: key, timeToLive: .seconds(ttl), tags: tags, generation: generation)
                model.insert(payload, for: key, ttl: ttl, tags: tags, generation: generation, now: now)
            case 6...7:
                let expected = model.value(for: key, now: now)
                #expect(await cache.value(for: key) == expected)
            case 8:
                let tags: Set<String> = random.next(3) == 0 ? [] : [String(random.next(3))]
                await cache.invalidate(identity: key.identity, tags: tags)
                model.invalidate(identity: key.identity, tags: tags)
            case 9...10:
                let elapsed = random.next(4)
                try clock.advance(by: .seconds(elapsed))
                now += elapsed
            default:
                if step % 17 == 0 {
                    await cache.removeAll()
                    model.removeAll()
                } else {
                    let expected = model.value(for: key, now: now)
                    #expect(await cache.value(for: key) == expected)
                }
            }
            model.prune(now: now)
            let actual = await cache.snapshot(), index = await cache.indexSnapshot()
            #expect(actual.entries == model.entries.count)
            #expect(actual.bytes == model.bytes)
            #expect(index.expiryEntries == actual.entries)
            #expect(index.identities == Set(model.entries.keys.map(\.identity)).count)
            #expect(await cache.generation() == model.revision)
        }
        for key in keys {
            let expected = model.value(for: key, now: now)
            #expect(await cache.value(for: key) == expected)
        }
        try clock.advance(by: .seconds(100))
        #expect(await cache.snapshot().entries == 0)
        #expect(await cache.snapshot().bytes == 0)
        #expect(await cache.indexSnapshot().expiryEntries == 0)
        #expect(await cache.indexSnapshot().identities == 0)
    }

    /// Same-key updates change expiry in both directions without retaining old deadlines or scoped states.
    /// - Throws: Unexpected virtual clock advancement failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func repeatedReplacementsReleaseAllMetadata() async throws {
        let clock = ManualClock(), cache = ReadCache(clock: clock)
        let identity = RateLimitIdentity(), foreign = RateLimitIdentity()
        let key = HTTPReadKey(identity: identity, representation: "replaced")
        let other = HTTPReadKey(identity: foreign, representation: "same-deadline")
        for cycle in 0..<256 {
            let generation = await cache.generation()
            for iteration in 0..<8 {
                await cache.insert(Data([UInt8(iteration)]), for: key, timeToLive: .seconds(iteration % 2 == 0 ? 100 : 1),
                                   tags: ["replaced"], generation: generation)
                await cache.insert(Data([1]), for: other, timeToLive: .seconds(1), tags: [], generation: generation)
                #expect(await cache.indexSnapshot().expiryEntries == 2)
                #expect(await cache.indexSnapshot().identities == 2)
            }
            if cycle % 2 == 0 {
                await cache.invalidate(identity: identity, tags: ["replaced"])
                #expect(await cache.indexSnapshot().expiryEntries == 1)
                #expect(await cache.value(for: other) == Data([1]))
            }
            try clock.advance(by: .seconds(1))
            #expect(await cache.snapshot().entries == 0)
            #expect(await cache.indexSnapshot().expiryEntries == 0)
            #expect(await cache.indexSnapshot().identities == 0)
        }
    }
}

/// Intentionally scan-based oracle that shares policy semantics but no production index structure.
private struct ReadCacheReference {
    struct Entry {
        let data: Data
        let expires: Int
        let tags: Set<String>
        var access: Int
    }
    let policy: ReadCachePolicy
    var entries: [HTTPReadKey: Entry] = [:]
    var revision: UInt64 = 0
    private var access = 0
    /// Recomputes the independent model charge by scanning live entries; empty state returns zero.
    var bytes: Int { entries.values.reduce(0) { $0 + $1.data.count } }

    /// Starts an independent empty reference cache with the production numeric budgets.
    /// - Parameter policy: Finite positive entry bounds used by the mixed-operation fixtures.
    init(policy: ReadCachePolicy) { self.policy = policy }

    /// Removes all deadlines at or before the explicit reference clock boundary.
    /// - Parameter now: Test-owned monotonic whole seconds.
    mutating func prune(now: Int) { entries = entries.filter { $0.value.expires > now } }

    /// Performs one independent scan-based lookup and recency promotion.
    /// - Parameters:
    ///   - key: Scoped fixture key.
    ///   - now: Test-owned whole seconds.
    /// - Returns: Fresh retained bytes, if present.
    mutating func value(for key: HTTPReadKey, now: Int) -> Data? {
        prune(now: now)
        guard var entry = entries[key] else { return nil }
        access += 1
        entry.access = access
        entries[key] = entry
        return entry.data
    }

    /// Applies existing admission and scoped-first/global-second LRU rules using full scans.
    /// - Parameters:
    ///   - data: Fixture payload, including oversized and empty cases.
    ///   - key: Scoped fixture key.
    ///   - ttl: Requested lifetime in whole seconds, including rejected nonpositive values.
    ///   - tags: Fixture invalidation tags.
    ///   - generation: Current or deliberately stale insertion generation.
    ///   - now: Test-owned whole seconds.
    mutating func insert(_ data: Data, for key: HTTPReadKey, ttl: Int, tags: Set<String>, generation: UInt64, now: Int) {
        prune(now: now)
        guard generation == revision, ttl > 0,
              data.count <= min(policy.maximumBytes, policy.maximumBytesPerIdentity) else { return }
        entries.removeValue(forKey: key)
        while true {
            let scoped = entries.filter { $0.key.identity == key.identity }
            guard scoped.count >= policy.maximumEntriesPerIdentity || scoped.values.reduce(0, { $0 + $1.data.count }) > policy.maximumBytesPerIdentity - data.count,
                  let victim = scoped.min(by: { $0.value.access < $1.value.access })?.key else { break }
            entries.removeValue(forKey: victim)
        }
        while entries.count >= policy.maximumEntries || bytes > policy.maximumBytes - data.count {
            guard let victim = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
            entries.removeValue(forKey: victim)
        }
        access += 1
        entries[key] = Entry(data: data, expires: now + ttl, tags: tags, access: access)
    }

    /// Advances the conservative generation and scans only matching scoped tags for removal.
    /// - Parameters:
    ///   - identity: Scope being invalidated.
    ///   - tags: Intersecting tags, or empty for all scoped entries.
    mutating func invalidate(identity: RateLimitIdentity, tags: Set<String>) {
        revision &+= 1
        entries = entries.filter { $0.key.identity != identity || (!tags.isEmpty && $0.value.tags.isDisjoint(with: tags)) }
    }

    /// Clears retained entries while fencing every previously captured generation.
    mutating func removeAll() {
        revision &+= 1
        entries.removeAll()
    }
}

/// Fixed-seed generator makes every mixed operation and failure reproducible.
private struct ReadCacheRandom {
    var seed: UInt64

    /// Advances an overflow-defined LCG and returns one bounded fixture choice.
    /// - Parameter bound: Positive exclusive upper bound.
    /// - Returns: Deterministic choice using high bits to avoid short low-bit cycles.
    mutating func next(_ bound: Int) -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((seed >> 32) % UInt64(bound))
    }
}
