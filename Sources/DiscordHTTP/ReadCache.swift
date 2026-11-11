// File: Sources/DiscordHTTP/ReadCache.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging
import Foundation

/// An opaque authentication scope and exact request representation. Never log its contents.
public struct HTTPReadKey: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let identity: RateLimitIdentity
    let representation: String

    /// Separates private results by credential generation and complete request representation.
    /// - Parameters:
    ///   - identity: Shared opaque identity; rotate when credentials or scopes change.
    ///   - representation: Canonical route, query, body and representation metadata.
    public init(identity: RateLimitIdentity, representation: String) {
        self.identity = identity
        self.representation = representation
    }

    /// Conceals paths, queries and authentication scope from ordinary diagnostics.
    public var description: String { "HTTPReadKey(redacted)" }
    /// Conceals the same information in debug output.
    public var debugDescription: String { description }
    /// Prevents reflection from revealing key components.
    public var customMirror: Mirror { Mirror(self, children: ["redacted": true]) }
}

/// Numeric retained-payload budgets; actor/index overhead must be measured separately.
public struct ReadCachePolicy: Sendable {
    public let maximumEntries: Int
    public let maximumBytes: Int
    public let maximumEntriesPerIdentity: Int
    public let maximumBytesPerIdentity: Int

    /// Configures finite total and per-identity LRU budgets. Zero disables retention.
    /// - Parameters:
    ///   - maximumEntries: Aggregate retained entries, default 256.
    ///   - maximumBytes: Aggregate payload bytes, default 4 MiB.
    ///   - maximumEntriesPerIdentity: One identity's retained entries, default 64.
    ///   - maximumBytesPerIdentity: One identity's payload bytes, default 1 MiB.
    /// - Precondition: All bounds are nonnegative.
    public init(maximumEntries: Int = 256, maximumBytes: Int = 4 * 1_024 * 1_024,
                maximumEntriesPerIdentity: Int = 64, maximumBytesPerIdentity: Int = 1_024 * 1_024) {
        precondition(min(maximumEntries, maximumBytes, maximumEntriesPerIdentity, maximumBytesPerIdentity) >= 0)
        self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes
        self.maximumEntriesPerIdentity = maximumEntriesPerIdentity
        self.maximumBytesPerIdentity = maximumBytesPerIdentity
    }
}

/// A bounded opt-in response cache. Snapshots never establish current authorization.
///
/// TTL bounds unobserved external changes. Consumers must invalidate after observed
/// visibility/scope changes; local successful writes invalidate their declared tags.
/// A global revision fences completions started before any invalidation, conservatively
/// declining their insertion even when another identity was invalidated.
/// Fresh lookups inspect only the earliest expiry and promote constant-time global and
/// scoped LRU links. Each retained entry owns exactly one expiry record; replacements,
/// invalidation and eviction remove index metadata immediately without tombstones.
public actor ReadCache<C: Clock> where C.Duration == Duration {
    /// Actor-owned payload and its exact positions in the expiry and two LRU indexes.
    private final class Entry {
        let key: HTTPReadKey
        let data: Data
        let expires: C.Instant
        let tags: Set<String>
        var expiryIndex: Int
        var previous: HTTPReadKey?
        var next: HTTPReadKey?
        var identityPrevious: HTTPReadKey?
        var identityNext: HTTPReadKey?

        /// Creates one unlinked retained entry before the actor installs all index memberships.
        /// - Parameters:
        ///   - key: Complete scoped representation key.
        ///   - data: Validated retained payload.
        ///   - expires: Inclusive removal boundary.
        ///   - tags: Endpoint invalidation tags.
        ///   - expiryIndex: Initial final position in the expiry heap before upward restoration.
        init(key: HTTPReadKey, data: Data, expires: C.Instant, tags: Set<String>, expiryIndex: Int) {
            self.key = key
            self.data = data
            self.expires = expires
            self.tags = tags
            self.expiryIndex = expiryIndex
        }
    }
    private struct IdentityState {
        var count = 0
        var bytes = 0
        var oldest: HTTPReadKey?
        var newest: HTTPReadKey?
    }
    private let clock: C
    private let policy: ReadCachePolicy
    private var entries: [HTTPReadKey: Entry] = [:]
    private var expiries: [Entry] = []
    private var identities: [RateLimitIdentity: IdentityState] = [:]
    private var oldest: HTTPReadKey?
    private var newest: HTTPReadKey?
    private var revision: UInt64 = 0
    private var bytes = 0

    /// Creates an empty cache without launching tasks or scheduling refreshes.
    /// - Parameters:
    ///   - clock: Monotonic freshness clock, shared with the owning client.
    ///   - policy: Finite entry and retained-payload budgets.
    public init(clock: C, policy: ReadCachePolicy = .init()) {
        self.clock = clock
        self.policy = policy
    }

    /// Captures a generation before a fetch; stale generations cannot repopulate invalidations.
    /// - Returns: Current conservative invalidation generation.
    public func generation() -> UInt64 { revision }

    /// Returns a fresh snapshot and promotes it in LRU order; expiry is inclusive.
    /// - Parameter key: Complete authentication and representation identity.
    /// - Returns: Retained successful bytes, or nil for a missing/expired entry.
    public func value(for key: HTTPReadKey) -> Data? {
        prune()
        guard let entry = entries[key] else {
            DiscordLog.makeLogger("http.cache").trace("REST response cache lookup missed", metadata: ["dk.event": "http.cache.lookup.missed", "dk.entries": .stringConvertible(entries.count)])
            return nil
        }
        if newest != key {
            unlink(entry)
            append(entry)
        }
        DiscordLog.makeLogger("http.cache").trace("REST response cache lookup succeeded", metadata: ["dk.event": "http.cache.lookup.hit", "dk.bytes": .stringConvertible(entry.data.count)])
        return entry.data
    }

    /// Retains a successful response within both budgets, evicting oldest eligible entries.
    /// - Parameters:
    ///   - data: Successful response payload; errors must never be passed here.
    ///   - key: Complete scoped representation key.
    ///   - timeToLive: Positive freshness duration; zero/negative disables insertion.
    ///   - tags: Bounded endpoint invalidation tags.
    ///   - generation: Revision captured before the fetch; stale completions are discarded.
    public func insert(_ data: Data, for key: HTTPReadKey, timeToLive: Duration,
                       tags: Set<String>, generation: UInt64) {
        prune()
        guard key.representation.utf8.count <= 131_072, tags.count <= 128,
              tags.reduce(0, { $0 + $1.utf8.count }) <= 65_536,
              generation == revision, timeToLive > .zero,
              policy.maximumEntries > 0, policy.maximumEntriesPerIdentity > 0,
              data.count <= min(policy.maximumBytes, policy.maximumBytesPerIdentity) else { return }
        remove(key)
        while let state = identities[key.identity],
              state.count >= policy.maximumEntriesPerIdentity || state.bytes > policy.maximumBytesPerIdentity - data.count {
            guard let victim = state.oldest else { return }
            remove(victim)
        }
        while entries.count >= policy.maximumEntries || bytes > policy.maximumBytes - data.count {
            guard let victim = oldest else { return }
            remove(victim)
        }
        let entry = Entry(key: key, data: data, expires: clock.now.advanced(by: timeToLive),
                          tags: tags, expiryIndex: expiries.count)
        entries[key] = entry
        append(entry)
        identities[key.identity, default: IdentityState()].count += 1
        identities[key.identity, default: IdentityState()].bytes += data.count
        bytes += data.count
        expiries.append(entry)
        moveUp(from: entry.expiryIndex)
        DiscordLog.makeLogger("http.cache").trace("REST response cache retained validated bytes", metadata: ["dk.event": "http.cache.inserted", "dk.entries": .stringConvertible(entries.count), "dk.bytes": .stringConvertible(bytes)])
    }

    /// Fences old fetches and removes matching snapshots. Empty tags invalidate all for the identity.
    /// - Parameters:
    ///   - identity: Scope whose visibility or local state changed.
    ///   - tags: Intersecting endpoint tags; empty invalidates every scoped representation.
    public func invalidate(identity: RateLimitIdentity, tags: Set<String> = []) {
        revision &+= 1
        var key = identities[identity]?.oldest
        while let current = key, let entry = entries[current] {
            key = entry.identityNext
            if tags.isEmpty || !entry.tags.isDisjoint(with: tags) { remove(current) }
        }
    }

    /// Drops every retained snapshot and fences all outstanding fetch generations.
    public func removeAll() {
        revision &+= 1
        entries.removeAll()
        expiries.removeAll()
        identities.removeAll()
        oldest = nil
        newest = nil
        bytes = 0
    }

    /// Reports retained entries/payload bytes after removing expired entries.
    /// - Returns: Accounted payload budgets, excluding Swift runtime/index overhead.
    public func snapshot() -> (entries: Int, bytes: Int) {
        prune()
        return (entries.count, bytes)
    }

    /// Reports bounded metadata counts without pruning or exposing scoped keys and payloads.
    /// - Returns: One expiry record per retained entry and one state per nonempty identity.
    func indexSnapshot() -> (expiryEntries: Int, identities: Int) { (expiries.count, identities.count) }

    /// Removes inclusive-expired entries in O(k log n), stopping at the first live expiry.
    /// Capturing time once gives every entry the same observation boundary without timers.
    private func prune() {
        let now = clock.now
        var removed = 0
        while let first = expiries.first, first.expires <= now {
            remove(first.key)
            removed += 1
        }
        if removed > 0 {
            DiscordLog.makeLogger("http.cache").trace("REST response cache expired entries pruned", metadata: ["dk.event": "http.cache.expired", "dk.removed": .stringConvertible(removed)])
        }
    }

    /// Releases one entry and its exact payload accounting; missing keys are harmless.
    /// - Parameter key: Representation to remove.
    private func remove(_ key: HTTPReadKey) {
        if let old = entries[key] {
            unlink(old)
            removeExpiry(at: old.expiryIndex)
            entries.removeValue(forKey: key)
            if var state = identities[key.identity] {
                state.count -= 1
                state.bytes -= old.data.count
                if state.count == 0 { identities.removeValue(forKey: key.identity) }
                else { identities[key.identity] = state }
            }
            bytes -= old.data.count
            DiscordLog.makeLogger("http.cache").trace("REST response cache entry released", metadata: ["dk.event": "http.cache.removed", "dk.entries": .stringConvertible(entries.count), "dk.bytes": .stringConvertible(bytes)])
        }
    }

    /// Detaches one entry from both LRU lists without changing membership or payload accounting.
    /// - Parameter entry: Retained actor-owned node whose neighboring keys remain in membership.
    private func unlink(_ entry: Entry) {
        if let previous = entry.previous { entries[previous]?.next = entry.next }
        else { oldest = entry.next }
        if let next = entry.next { entries[next]?.previous = entry.previous }
        else { newest = entry.previous }
        if let previous = entry.identityPrevious { entries[previous]?.identityNext = entry.identityNext }
        else { identities[entry.key.identity]?.oldest = entry.identityNext }
        if let next = entry.identityNext { entries[next]?.identityPrevious = entry.identityPrevious }
        else { identities[entry.key.identity]?.newest = entry.identityPrevious }
        entry.previous = nil
        entry.next = nil
        entry.identityPrevious = nil
        entry.identityNext = nil
    }

    /// Appends an unlinked retained node as newest in the aggregate and its identity's LRU list.
    /// - Parameter entry: Node already installed in membership; accounting is owned by the caller.
    private func append(_ entry: Entry) {
        entry.previous = newest
        if let newest { entries[newest]?.next = entry.key }
        else { oldest = entry.key }
        newest = entry.key
        var state = identities[entry.key.identity, default: IdentityState()]
        entry.identityPrevious = state.newest
        if let previous = state.newest { entries[previous]?.identityNext = entry.key }
        else { state.oldest = entry.key }
        state.newest = entry.key
        identities[entry.key.identity] = state
    }

    /// Removes one arbitrary expiry position immediately, retaining no stale replacement records.
    /// - Parameter index: Exact heap position owned by the entry being removed.
    private func removeExpiry(at index: Int) {
        let last = expiries.removeLast()
        guard index < expiries.count else { return }
        expiries[index] = last
        last.expiryIndex = index
        if index > 0, last.expires < expiries[(index - 1) / 2].expires { moveUp(from: index) }
        else { moveDown(from: index) }
    }

    /// Restores minimum-expiry order toward the root after inserting or moving one entry.
    /// - Parameter index: Valid heap index whose children already satisfy heap order.
    private func moveUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard expiries[child].expires < expiries[parent].expires else { return }
            exchange(child, parent)
            child = parent
        }
    }

    /// Restores minimum-expiry order toward the leaves after arbitrary removal.
    /// - Parameter index: Valid heap index whose ancestors already satisfy heap order.
    private func moveDown(from index: Int) {
        var parent = index
        while parent < expiries.count / 2 {
            let left = parent * 2 + 1, right = left + 1
            let child = right < expiries.count && expiries[right].expires < expiries[left].expires ? right : left
            guard expiries[child].expires < expiries[parent].expires else { return }
            exchange(parent, child)
            parent = child
        }
    }

    /// Swaps heap entries and synchronizes their actor-owned positions before further mutation.
    /// - Parameters:
    ///   - left: First valid heap index.
    ///   - right: Second valid heap index.
    private func exchange(_ left: Int, _ right: Int) {
        expiries.swapAt(left, right)
        expiries[left].expiryIndex = left
        expiries[right].expiryIndex = right
    }
}
