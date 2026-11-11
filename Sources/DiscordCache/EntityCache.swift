// File: Sources/DiscordCache/EntityCache.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging
import Foundation
import DiscordCore
import DiscordModels

/// An optional bounded entity projection and refresh authority shared by many clients.
///
/// This actor, rather than each client, owns aggregate budgets across identities.
/// Construction performs no I/O or task launch. Expiry is lazy and inclusive. Reads
/// return evidence snapshots, never an assertion of current authorization; unobserved
/// external visibility changes remain possible until TTL/revalidation. Callers must
/// invalidate observed visibility changes and successful local mutations explicitly.
///
/// Event ingestion never awaits user code or persistent I/O. Refresh loaders execute
/// only after explicit admission and must cooperate with cancellation. Equivalent
/// loaders must represent the same scoped entity, rather than different REST views.
/// A conservative global revision prevents any refresh begun before a newer accepted
/// observation/invalidation from publishing stale state, even after eviction.
public actor EntityCache<C: Clock> where C.Duration == Duration {
    private struct ScopedKey: Hashable {
        let entity: EntityKey
        let scope: CacheScope
    }
    private struct Entry {
        let snapshot: EntitySnapshot
        let bytes: Int
        var expiryIndex: Int
        var previous: ScopedKey?
        var next: ScopedKey?
        var identityPrevious: ScopedKey?
        var identityNext: ScopedKey?
    }
    private struct Expiry {
        let key: ScopedKey
        let deadline: C.Instant
    }
    private struct IdentityUsage {
        var count = 0
        var bytes = 0
        var oldest: ScopedKey?
        var newest: ScopedKey?
    }
    private struct Refresh {
        let token: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<EntitySnapshot, any Error>]
    }

    private let clock: C
    private let limits: CacheLimits
    /// Optional synchronous owner observer; nil performs no instrumentation-clock reads.
    private let intervals: DiscordIntervalTiming?
    private var entries: [ScopedKey: Entry] = [:]
    /// One indexed deadline per live entry; replacements never append stale expiry records.
    private var expiry: [Expiry] = []
    private var oldest: ScopedKey?
    private var newest: ScopedKey?
    /// Exact quotas and intrusive LRU endpoints, removed when an identity's final entry leaves.
    private var identities: [String: IdentityUsage] = [:]
    private var refreshes: [ScopedKey: Refresh] = [:]
    private var identityRefreshes: [String: Int] = [:]
    private var bytes = 0
    private var waiters = 0
    private var revision: UInt64 = 0
    private var closed = false
    private var hits: UInt64 = 0
    private var misses: UInt64 = 0
    private var evictions: UInt64 = 0
    private var expirations: UInt64 = 0
    private var coalescedReads: UInt64 = 0
    private var refreshStarts: UInt64 = 0
    private var staleCompletions: UInt64 = 0

    /// Creates an empty, idle shared authority with deterministic freshness time.
    /// - Parameters:
    ///   - clock: Monotonic clock shared with the owning runtime or deterministic test.
    ///   - policy: Explicit retention mode; minimal is the small default working set.
    ///   - intervals: Optional bounded synchronous lifecycle observer. Owner intervals start
    ///     after actor admission; caller wrappers measure preceding actor wait separately.
    ///     Sinks must remain prompt and cannot reenter this owner. Nil reads no timing clock.
    /// - Throws: `EntityCacheFailure.invalidLimits` for negative retention bounds,
    ///   nonpositive refresh/waiter caps or TTL, or TTL exceeding 30 days.
    ///   No tasks or resources are acquired.
    public init(clock: C, policy: CachePolicy = .minimal, intervals: DiscordIntervalTiming? = nil) throws {
        self.clock = clock
        self.intervals = intervals
        let limits: CacheLimits
        switch policy {
        case .noCache:
            limits = CacheLimits(maximumEntries: 0, maximumBytes: 0)
        case .minimal:
            limits = CacheLimits(maximumEntries: 64, maximumBytes: 256 * 1_024,
                                 maximumEntriesPerIdentity: 16, maximumBytesPerIdentity: 64 * 1_024,
                                 maximumTimeToLive: .seconds(30))
        case .bounded(let supplied): limits = supplied
        }
        guard min(limits.maximumEntries, limits.maximumBytes, limits.maximumEntriesPerIdentity,
                  limits.maximumBytesPerIdentity) >= 0,
              min(limits.maximumRefreshes, limits.maximumRefreshesPerIdentity,
                  limits.maximumWaiters, limits.maximumWaitersPerRefresh) > 0,
              limits.maximumTimeToLive > .zero,
              limits.maximumTimeToLive <= .seconds(2_592_000) else { throw EntityCacheFailure.invalidLimits }
        self.limits = limits
    }

    /// Reads a fresh projection, including explicit unavailable/deleted tombstones.
    /// - Parameters:
    ///   - key: Exact resource identity and optional guild context.
    ///   - scope: Exact identity, intents and visibility partition.
    /// - Returns: Immutable source evidence, or nil on disabled retention, expiry,
    ///   eviction, invalid scope or closed ownership. Promotes hits in LRU order.
    public func value(for key: EntityKey, scope: CacheScope) -> EntitySnapshot? {
        return withCacheInterval(.cacheLookup) {
            prune()
            guard !closed, valid(scope) else {
                misses &+= 1
                DiscordLog.makeLogger("cache.storage").trace("Entity cache read is ineligible", metadata: ["dk.event": "cache.read.ineligible", "dk.closed": .stringConvertible(closed)])
                return nil
            }
            let scoped = ScopedKey(entity: key, scope: scope)
            guard let entry = entries[scoped] else {
                misses &+= 1
                DiscordLog.makeLogger("cache.storage").trace("Entity cache miss", metadata: ["dk.event": "cache.read.miss", "dk.entries": .stringConvertible(entries.count)])
                return nil
            }
            promote(scoped)
            hits &+= 1
            DiscordLog.makeLogger("cache.storage").trace("Entity cache hit", metadata: ["dk.event": "cache.read.hit"])
            return entry.snapshot
        }
    }

    /// Applies a complete replacement or a sparse top-level merge atomically.
    /// - Parameters:
    ///   - snapshot: Validated observation. Null clears only declared nullable fields;
    ///     redaction erases old contents. Unavailable/deleted snapshots replace old fields.
    ///   - key: Resource identity with guild context where applicable.
    ///   - scope: Exact noncredential identity and visibility partition.
    ///   - timeToLive: Optional freshness duration, capped at policy TTL; nonpositive
    ///     removes any old value and returns `notRetained`. Nil uses the policy TTL.
    /// - Returns: Stored, ignored duplicate/out-of-order, or not retained under finite
    ///   byte/entry/metadata bounds. Every accepted update fences older refreshes.
    /// - Throws: Closed ownership, invalid scope/order, invalid top-level null, or
    ///   bounded JSON serialization errors. Invalid input does not replace old state.
    @discardableResult
    public func apply(_ snapshot: EntitySnapshot, for key: EntityKey, scope: CacheScope,
                      timeToLive: Duration? = nil) throws -> CacheWriteResult {
        return try withCacheInterval(.cacheMerge) {
            try validateObservation(snapshot, scope: scope)
            DiscordLog.makeLogger("cache.storage").trace("Entity observation validated", metadata: ["dk.event": "cache.write.validated", "dk.fields": .stringConvertible(snapshot.fields.count)])
            prune()
            let scoped = ScopedKey(entity: key, scope: scope)
            if isStale(snapshot.order, comparedTo: entries[scoped]?.snapshot.order) {
                DiscordLog.makeLogger("cache.storage").trace("Stale entity observation ignored", metadata: ["dk.event": "cache.write.stale"])
                return .ignoredStale
            }
            let merged = merge(snapshot, previous: entries[scoped]?.snapshot)
            let ttl = min(timeToLive ?? limits.maximumTimeToLive, limits.maximumTimeToLive)
            let retainedBytes = try accountedBytes(merged, scope: scope)
            DiscordLog.makeLogger("cache.storage").trace("Entity observation merged and accounted", metadata: ["dk.event": "cache.write.accounted"])
            revision &+= 1
            remove(scoped)
            guard ttl > .zero, limits.maximumEntries > 0, limits.maximumEntriesPerIdentity > 0,
                  let retainedBytes,
                  retainedBytes <= min(limits.maximumBytes, limits.maximumBytesPerIdentity) else {
                DiscordLog.makeLogger("cache.storage").trace("Entity observation excluded by retention policy", metadata: ["dk.event": "cache.write.not_retained"])
                return .notRetained
            }
            while (identities[scope.identity]?.count ?? 0) >= limits.maximumEntriesPerIdentity
                || (identities[scope.identity]?.bytes ?? 0) > limits.maximumBytesPerIdentity - retainedBytes {
                guard let oldest = identities[scope.identity]?.oldest else { return .notRetained }
                remove(oldest)
                evictions &+= 1
                DiscordLog.makeLogger("cache.storage").trace("Entity evicted under identity budget", metadata: ["dk.event": "cache.entry.evicted", "dk.budget": "identity", "dk.entries": .stringConvertible(entries.count)])
            }
            while entries.count >= limits.maximumEntries || bytes > limits.maximumBytes - retainedBytes {
                guard let oldest else { return .notRetained }
                remove(oldest)
                evictions &+= 1
                DiscordLog.makeLogger("cache.storage").trace("Entity evicted under aggregate budget", metadata: ["dk.event": "cache.entry.evicted", "dk.budget": "aggregate", "dk.entries": .stringConvertible(entries.count)])
            }
            retain(merged, for: scoped, deadline: clock.now.advanced(by: ttl), bytes: retainedBytes)
            DiscordLog.makeLogger("cache.storage").trace("Entity snapshot retained", metadata: ["dk.event": "cache.write.stored", "dk.entries": .stringConvertible(entries.count), "dk.bytes": .stringConvertible(bytes)])
            return .stored
        }
    }

    /// Reuses sufficiently complete event/REST data or joins one bounded explicit fetch.
    /// - Parameters:
    ///   - key: Exact resource identity; all joined loaders must represent the same view.
    ///   - scope: Exact identity, intents and visibility partition.
    ///   - requiredFields: Keys that must be present and unredacted; default none.
    ///   - requireComplete: Whether a partial snapshot is insufficient, default false.
    ///   - loader: One cancellation-cooperative REST read, invoked once for equivalent
    ///     concurrent misses. Errors, including auth/transient failures, are never cached.
    /// - Returns: A fresh eligible snapshot. A newer observation supersedes an old
    ///   completion and is returned only if it satisfies this caller's requirements.
    /// - Throws: Loader errors/cancellation, closed ownership, invalid scope, bounded
    ///   overload, superseded observations without a replacement, or insufficient data.
    ///   Canceling one waiter leaves other callers intact; the final waiter cancels
    ///   and awaits owned loader cleanup. No new refresh is admitted until cleanup ends.
    public func refresh(key: EntityKey, scope: CacheScope, requiredFields: Set<String> = [],
                        requireComplete: Bool = false,
                        loader: @escaping @Sendable () async throws -> EntitySnapshot) async throws -> EntitySnapshot {
        guard let intervals else {
            return try await refreshObserved(key: key, scope: scope, requiredFields: requiredFields,
                requireComplete: requireComplete, loader: loader)
        }
        let interval = intervals.begin(.entityCache, stage: .cacheRefresh)
        do {
            let value = try await DiscordIntervalScope.$context.withValue(interval.context) {
                try await refreshObserved(key: key, scope: scope, requiredFields: requiredFields,
                    requireComplete: requireComplete, loader: loader)
            }
            interval.end()
            return value
        } catch {
            interval.end(error is CancellationError ? .cancelled : .failed)
            throw error
        }
    }

    /// Executes the unchanged refresh state machine after optional timing context installation.
    /// - Parameters:
    ///   - key: Exact resource identity; joined loaders must represent the same view.
    ///   - scope: Opaque identity, intents and visibility partition.
    ///   - requiredFields: At most 256 keys, each at most 256 UTF-8 bytes, required unredacted.
    ///   - requireComplete: Whether partial evidence must trigger a loader rather than reuse.
    ///   - loader: Cancellation-cooperative fetch, admitted once for concurrent same-key misses.
    /// - Returns: Sufficient fresh evidence, including a newer observation that fenced the loader.
    /// - Throws: Original loader error/cancellation or cache scope/capacity/completeness errors.
    ///   The final cancelled waiter joins loader cleanup before returning; nil instrumentation
    ///   calls this directly without task-local rebinding, clock reads or observation callbacks.
    private func refreshObserved(key: EntityKey, scope: CacheScope, requiredFields: Set<String>,
        requireComplete: Bool, loader: @escaping @Sendable () async throws -> EntitySnapshot) async throws -> EntitySnapshot {
        DiscordLog.makeLogger("cache.refresh").debug("Explicit entity refresh requested", metadata: ["dk.event": "cache.refresh.requested", "dk.required_fields": .stringConvertible(requiredFields.count), "dk.requires_complete": .stringConvertible(requireComplete)])
        try Task.checkCancellation()
        guard !closed else { throw EntityCacheFailure.closed }
        guard valid(scope) else { throw EntityCacheFailure.invalidScope }
        guard requiredFields.count <= 256, requiredFields.allSatisfy({ $0.utf8.count <= 256 }) else {
            throw EntityCacheFailure.capacityExceeded
        }
        if let snapshot = value(for: key, scope: scope),
           satisfies(snapshot, fields: requiredFields, complete: requireComplete) {
            DiscordLog.makeLogger("cache.refresh").trace("Retained entity satisfies refresh requirements", metadata: ["dk.event": "cache.refresh.reused"])
            return snapshot
        }
        let scoped = ScopedKey(entity: key, scope: scope)
        let waiter = UUID()
        let snapshot = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(scoped, waiter: waiter, continuation: continuation, loader: loader)
            }
        } onCancel: {
            Task { await self.cancel(scoped, waiter: waiter) }
        }
        try Task.checkCancellation()
        guard satisfies(snapshot, fields: requiredFields, complete: requireComplete) else {
            DiscordLog.makeLogger("cache.refresh").debug("Refresh result does not satisfy caller requirements", metadata: ["dk.event": "cache.refresh.insufficient"])
            throw EntityCacheFailure.insufficientSnapshot
        }
        DiscordLog.makeLogger("cache.refresh").debug("Entity refresh completed", metadata: ["dk.event": "cache.refresh.completed"])
        return snapshot
    }

    /// Fences outstanding reads and erases one observed visibility partition.
    /// - Parameter scope: Exact identity/intents/visibility generation to invalidate.
    /// Existing refreshes may finish, but their old state is never returned or retained.
    public func invalidate(scope: CacheScope) {
        return withCacheInterval(.cacheInvalidation) {
            DiscordLog.makeLogger("cache.storage").trace("Invalidating entity scope and fencing older refreshes", metadata: ["dk.event": "cache.invalidate.scope"])
            revision &+= 1
            for key in entries.keys.filter({ $0.scope == scope }) { remove(key) }
        }
    }

    /// Erases every visibility/intent partition of an observed changed credential.
    /// - Parameter identity: Opaque credential label, never the credential itself.
    /// A later refresh may explicitly establish new state under the current scope.
    public func invalidateVisibility(identity: String) {
        return withCacheInterval(.cacheInvalidation) {
            DiscordLog.makeLogger("cache.storage").trace("Invalidating observed identity visibility", metadata: ["dk.event": "cache.invalidate.visibility"])
            revision &+= 1
            for key in entries.keys.filter({ $0.scope.identity == identity }) { remove(key) }
        }
    }

    /// Invalidates affected projections after a successful local mutation.
    /// - Parameters:
    ///   - keys: Resources affected by the write; empty invalidates the entire scope.
    ///     Arrays larger than 256 conservatively invalidate the entire scope.
    ///   - scope: Exact mutation visibility partition. Related views must be supplied
    ///     by the typed service; mutation equivalence is never inferred generically.
    public func invalidateLocalWrite(keys: [EntityKey], scope: CacheScope) {
        return withCacheInterval(.cacheInvalidation) {
            DiscordLog.makeLogger("cache.storage").trace("Invalidating projections after local write", metadata: ["dk.event": "cache.invalidate.write", "dk.keys": .stringConvertible(keys.count)])
            revision &+= 1
            guard !keys.isEmpty, keys.count <= 256 else { invalidate(scope: scope); return }
            for key in keys { remove(ScopedKey(entity: key, scope: scope)) }
        }
    }

    /// Invalidates guild projections and children after observed removal or availability loss.
    /// - Parameters:
    ///   - guildID: Guild whose cached children are no longer eligible.
    ///   - scope: Exact visibility partition affected by the observation.
    /// No permanent guild registry is retained; old refreshes are fenced globally.
    public func invalidateGuild(_ guildID: GuildID, scope: CacheScope) {
        return withCacheInterval(.cacheInvalidation) {
            DiscordLog.makeLogger("cache.storage").trace("Invalidating guild and child projections", metadata: ["dk.event": "cache.invalidate.guild"])
            revision &+= 1
            for key in entries.keys.filter({ $0.scope == scope
                && ($0.entity.guildID == guildID || ($0.entity.kind == .guild && $0.entity.id == guildID.rawValue)) }) {
                remove(key)
            }
        }
    }

    /// Cancels, awaits and releases every owned refresh, then drops retained projections.
    /// Repeated/concurrent calls wait for the same cleanup and permanently reject reads.
    /// Loaders must cooperate with cancellation; no timeout can safely abandon their resources.
    public func close() async {
        DiscordLog.makeLogger("cache.lifecycle").debug("Entity cache closing", metadata: ["dk.event": "cache.closing", "dk.refreshes": .stringConvertible(refreshes.count), "dk.entries": .stringConvertible(entries.count)])
        closed = true
        revision &+= 1
        entries.removeAll()
        expiry.removeAll()
        identities.removeAll()
        oldest = nil
        newest = nil
        bytes = 0
        let tasks = refreshes.values.map(\.task)
        for task in tasks { task.cancel() }
        DiscordLog.makeLogger("cache.lifecycle").trace("Entity refresh cancellation requested", metadata: ["dk.event": "cache.cleanup.refreshes_cancelled", "dk.tasks": .stringConvertible(tasks.count)])
        for task in tasks { await task.value }
        DiscordLog.makeLogger("cache.lifecycle").info("Entity cache closed after refresh cleanup", metadata: ["dk.event": "cache.closed", "dk.refreshes": .stringConvertible(refreshes.count), "dk.waiters": .stringConvertible(waiters)])
    }

    /// Reports current aggregate usage and cumulative request-reduction/eviction evidence.
    /// - Returns: Counters after inclusive expiry pruning; bytes exclude Swift heap overhead.
    public func statistics() -> EntityCacheStatistics {
        prune()
        return EntityCacheStatistics(entries: entries.count, bytes: bytes, refreshes: refreshes.count,
                                     waiters: waiters, hits: hits, misses: misses, evictions: evictions,
                                     expirations: expirations, coalescedReads: coalescedReads,
                                     refreshStarts: refreshStarts, staleCompletions: staleCompletions)
    }

    /// Removes channel-owned message observations after a channel/thread removal.
    /// - Parameters:
    ///   - channelID: Deleted parent channel identifier.
    ///   - scope: Exact partition affected by this event.
    func invalidateChannelChildren(_ channelID: UInt64, scope: CacheScope) {
        revision &+= 1
        let expected = JSONValue.string(String(channelID))
        for key in entries.keys.filter({ $0.scope == scope && entries[$0]?.snapshot.fields["channel_id"] == expected }) {
            remove(key)
        }
    }

    /// Fences pre-READY reads and removes old or unassigned observations for one source shard.
    /// - Parameters:
    ///   - shard: Nonnegative shard beginning a fresh session.
    ///   - scope: Exact identity/intents/visibility partition.
    ///   - order: READY sequence/generation, or nil for unordered fixtures. Retained
    ///     same-shard observations newer than this value survive duplicate/old READY.
    /// REST-only observations have no known shard and are conservatively invalidated;
    /// observations explicitly attributed to another shard remain independently usable.
    func invalidateShardObservations(_ shard: Int, scope: CacheScope, before order: CacheObservationOrder?) {
        revision &+= 1
        let obsolete = entries.filter { key, entry in
            guard key.scope == scope else { return false }
            guard let previous = entry.snapshot.order else { return true }
            return previous.shard == shard && !isStale(order, comparedTo: previous)
        }.map(\.key)
        for key in obsolete { remove(key) }
    }

    /// Recovers omitted guild context from a unique retained global message/channel snowflake.
    /// - Parameters:
    ///   - kind: Message or channel family; other families retain their explicit key context.
    ///   - id: Exact 64-bit resource identifier.
    ///   - guildID: Explicit incoming context, or nil for an omitted sparse event field.
    ///   - scope: Exact observing partition; no other credential/intent scope is consulted.
    /// - Returns: Explicit key or a unique retained matching key. Ambiguous/missing
    ///   history stays unknown rather than inventing a guild. Scans only bounded entries.
    func projectionKey(kind: EntityKind, id: UInt64, guildID: GuildID?, scope: CacheScope) -> EntityKey {
        guard guildID == nil, kind == .message || kind == .channel else {
            return EntityKey(kind: kind, id: id, guildID: guildID)
        }
        prune()
        let matches = entries.keys.filter { $0.scope == scope && $0.entity.kind == kind && $0.entity.id == id }
        return matches.count == 1 ? matches[0].entity : EntityKey(kind: kind, id: id)
    }

    /// Measures one synchronous admitted cache owner operation without changing its result.
    /// - Parameters:
    ///   - stage: Fixed operation class; nested reducer/storage calls remain separate intervals.
    ///   - body: Actor-isolated work. It must not suspend or reenter through an observer.
    /// - Returns: The unchanged body result, including misses and ignored observations.
    /// - Throws: The original body error after a failed terminal endpoint. Nil timing reads
    ///   no instrumentation clock; begin/end callbacks are synchronous and may add gross cost.
    func withCacheInterval<Result>(_ stage: DiscordIntervalStage, body: () throws -> Result) rethrows -> Result {
        guard let intervals else { return try body() }
        let interval = intervals.begin(.entityCache, stage: stage)
        do {
            let value = try DiscordIntervalScope.$context.withValue(interval.context, operation: body)
            interval.end()
            return value
        } catch {
            interval.end(error is CancellationError ? .cancelled : .failed)
            throw error
        }
    }

    /// Validates the finite noncredential scope label before retaining key metadata.
    /// - Parameter scope: Candidate partition.
    /// - Returns: Whether the label is nonempty and no longer than 256 UTF-8 bytes.
    private func valid(_ scope: CacheScope) -> Bool {
        !scope.identity.isEmpty && scope.identity.utf8.count <= 256
    }

    /// Validates ownership, visibility and scalar update rules before destructive event invalidation.
    /// - Parameters:
    ///   - snapshot: Candidate projection, including optional ordering and nullable fields.
    ///   - scope: Noncredential identity/intents/visibility partition.
    /// - Throws: Closed ownership, invalid scope/order or invalid top-level null.
    func validateObservation(_ snapshot: EntitySnapshot, scope: CacheScope) throws {
        guard !closed else { throw EntityCacheFailure.closed }
        guard valid(scope) else { throw EntityCacheFailure.invalidScope }
        try validate(snapshot)
    }

    /// Rejects invalid top-level nulls and malformed ordering without touching old state.
    /// - Parameter snapshot: Candidate validated projection.
    /// - Throws: Invalid null or order; field/key byte bounds are handled as nonretention.
    private func validate(_ snapshot: EntitySnapshot) throws {
        if let order = snapshot.order, order.shard < 0 || order.sequence < 0 { throw EntityCacheFailure.invalidOrder }
        for (field, value) in snapshot.fields where value == .null && !snapshot.nullableFields.contains(field) {
            throw EntityCacheFailure.invalidNullField
        }
    }

    /// Compares only ordered observations in a common shard domain.
    /// - Parameters:
    ///   - new: Incoming optional order.
    ///   - old: Retained optional order.
    /// - Returns: True for duplicate or older sequence/generation on the same shard.
    func isStale(_ new: CacheObservationOrder?, comparedTo old: CacheObservationOrder?) -> Bool {
        guard let new, let old, new.shard == old.shard else { return false }
        return new.generation < old.generation || (new.generation == old.generation && new.sequence <= old.sequence)
    }

    /// Applies sparse top-level fields while retaining uncertainty and erasing redaction.
    /// - Parameters:
    ///   - new: Validated newest observation.
    ///   - previous: Existing resource in the same exact partition, if still fresh.
    /// - Returns: Immutable merged projection; complete or unavailable observations replace fields.
    private func merge(_ new: EntitySnapshot, previous: EntitySnapshot?) -> EntitySnapshot {
        let preserve = new.completeness == .partial && new.availability == .available
            && previous?.availability == .available
        var fields = preserve ? previous?.fields ?? [:] : [:]
        fields.merge(new.fields) { _, incoming in incoming }
        var redacted = preserve ? previous?.redactedFields ?? [] : []
        redacted.subtract(new.fields.keys)
        redacted.formUnion(new.redactedFields)
        for field in redacted { fields.removeValue(forKey: field) }
        let completeness: CacheCompleteness = preserve && previous?.completeness == .complete ? .complete : new.completeness
        return EntitySnapshot(fields: fields, completeness: completeness, redactedFields: redacted,
                              nullableFields: new.nullableFields.union(preserve ? previous?.nullableFields ?? [] : []),
                              availability: new.availability, provenance: new.provenance,
                              order: new.order ?? previous?.order)
    }

    /// Accounts bounded serialized values and field/scope metadata without counting heap overhead.
    /// - Parameters:
    ///   - snapshot: Merged projection to retain.
    ///   - scope: Exact noncredential partition.
    /// - Returns: Accounted bytes, or nil when hard field/metadata/JSON resource bounds reject retention.
    /// - Throws: JSON serialization failures other than ordinary configured resource bounds.
    private func accountedBytes(_ snapshot: EntitySnapshot, scope: CacheScope) throws -> Int? {
        let names = Array(snapshot.fields.keys) + Array(snapshot.redactedFields) + Array(snapshot.nullableFields)
        guard snapshot.fields.count <= 256, snapshot.redactedFields.count <= 256,
              snapshot.nullableFields.count <= 256, names.allSatisfy({ $0.utf8.count <= 256 }) else { return nil }
        let maximum = min(limits.maximumBytes, limits.maximumBytesPerIdentity, 16 * 1_024 * 1_024)
        guard maximum > 0 else { return nil }
        do {
            let payload = try JSONValue.object(snapshot.fields).serialized(limits: JSONLimits(maximumBytes: maximum))
            return payload.count + names.reduce(0, { $0 + $1.utf8.count }) + scope.identity.utf8.count + 64
        } catch JSONValueError.maximumBytesExceeded { return nil }
        catch JSONValueError.maximumNodesExceeded { return nil }
        catch JSONValueError.maximumDepthExceeded { return nil }
    }

    /// Determines whether a snapshot can avoid a redundant request for one caller.
    /// - Parameters:
    ///   - snapshot: Source evidence, possibly partial/redacted/unavailable.
    ///   - fields: Keys explicitly required by this caller.
    ///   - complete: Whether reviewed complete-resource evidence is required.
    /// - Returns: True only for available data satisfying every requested requirement.
    private func satisfies(_ snapshot: EntitySnapshot, fields: Set<String>, complete: Bool) -> Bool {
        snapshot.availability == .available && (!complete || snapshot.completeness == .complete)
            && fields.isSubset(of: Set(snapshot.fields.keys)) && fields.isDisjoint(with: snapshot.redactedFields)
    }

    /// Registers one continuation atomically and launches at most one admitted loader.
    /// - Parameters:
    ///   - key: Exact entity/scope identity.
    ///   - waiter: Unique subscriber token.
    ///   - continuation: Exactly-once result owned until finish/cancellation.
    ///   - loader: Cancellation-cooperative fetch invoked for a newly admitted flight only.
    private func register(_ key: ScopedKey, waiter: UUID,
                          continuation: CheckedContinuation<EntitySnapshot, any Error>,
                          loader: @escaping @Sendable () async throws -> EntitySnapshot) {
        guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
        guard !closed else { continuation.resume(throwing: EntityCacheFailure.closed); return }
        guard waiters < limits.maximumWaiters else { continuation.resume(throwing: EntityCacheFailure.capacityExceeded); return }
        if var refresh = refreshes[key] {
            guard !refresh.waiters.isEmpty, refresh.waiters.count < limits.maximumWaitersPerRefresh else {
                continuation.resume(throwing: EntityCacheFailure.capacityExceeded); return
            }
            refresh.waiters[waiter] = continuation
            refreshes[key] = refresh
            waiters += 1
            coalescedReads &+= 1
            DiscordLog.makeLogger("cache.refresh").trace("Entity refresh joined existing loader", metadata: ["dk.event": "cache.refresh.coalesced", "dk.waiters": .stringConvertible(refresh.waiters.count)])
            return
        }
        guard refreshes.count < limits.maximumRefreshes,
              (identityRefreshes[key.scope.identity] ?? 0) < limits.maximumRefreshesPerIdentity else {
            continuation.resume(throwing: EntityCacheFailure.capacityExceeded); return
        }
        let token = UUID()
        let captured = revision
        let task = Task {
            let result: Result<EntitySnapshot, any Error>
            let interval = intervals?.begin(.entityCache, stage: .cacheLoader)
            do {
                DiscordLog.makeLogger("cache.refresh").trace("Invoking admitted entity loader", metadata: ["dk.event": "cache.refresh.loader_started"])
                let snapshot = try await loader()
                DiscordLog.makeLogger("cache.refresh").trace("Entity loader returned a snapshot", metadata: ["dk.event": "cache.refresh.loader_completed"])
                try Task.checkCancellation()
                result = .success(snapshot)
                interval?.end()
            } catch {
                interval?.end(error is CancellationError ? .cancelled : .failed)
                result = .failure(error)
            }
            finish(key, token: token, revision: captured, result: result)
        }
        refreshes[key] = Refresh(token: token, task: task, waiters: [waiter: continuation])
        identityRefreshes[key.scope.identity, default: 0] += 1
        waiters += 1
        refreshStarts &+= 1
        DiscordLog.makeLogger("cache.refresh").trace("Entity refresh admitted", metadata: ["dk.event": "cache.refresh.admitted", "dk.refreshes": .stringConvertible(refreshes.count), "dk.waiters": .stringConvertible(waiters)])
    }

    /// Delivers independent cancellation; the final waiter awaits owned loader cleanup.
    /// - Parameters:
    ///   - key: Exact scoped flight.
    ///   - waiter: Caller token; already-completed cancellation is harmless.
    private func cancel(_ key: ScopedKey, waiter: UUID) async {
        guard var refresh = refreshes[key], let continuation = refresh.waiters.removeValue(forKey: waiter) else { return }
        waiters -= 1
        DiscordLog.makeLogger("cache.refresh").trace("Entity refresh waiter cancelled", metadata: ["dk.event": "cache.refresh.waiter_cancelled", "dk.waiters": .stringConvertible(waiters)])
        refreshes[key] = refresh
        if refresh.waiters.isEmpty {
            DiscordLog.makeLogger("cache.refresh").trace("Final refresh waiter cancelled owned loader", metadata: ["dk.event": "cache.refresh.loader_cancelling"])
            refresh.task.cancel()
            await refresh.task.value
        }
        continuation.resume(throwing: CancellationError())
    }

    /// Fences stale completion, retains eligible fresh success and resumes all callers once.
    /// - Parameters:
    ///   - key: Exact entity/scope flight.
    ///   - token: Unique flight generation, preventing stale task callbacks.
    ///   - captured: Invalidation/observation revision before fetch began.
    ///   - result: Successful source snapshot or original loader failure.
    private func finish(_ key: ScopedKey, token: UUID, revision captured: UInt64,
                        result: Result<EntitySnapshot, any Error>) {
        guard let refresh = refreshes[key], refresh.token == token else { return }
        refreshes.removeValue(forKey: key)
        if identityRefreshes[key.scope.identity] == 1 { identityRefreshes.removeValue(forKey: key.scope.identity) }
        else { identityRefreshes[key.scope.identity, default: 0] -= 1 }
        waiters -= refresh.waiters.count
        let delivered: Result<EntitySnapshot, any Error>
        switch result {
        case .failure(let error):
            if error is CancellationError {
                DiscordLog.makeLogger("cache.refresh").debug("Entity refresh cancelled", metadata: ["dk.event": "cache.refresh.cancelled"])
            } else {
                DiscordLog.makeLogger("cache.refresh").debug("Entity refresh failed", metadata: ["dk.event": "cache.refresh.failed"])
            }
            delivered = .failure(error)
        case .success(let snapshot):
            if captured != revision || closed {
                staleCompletions &+= 1
                DiscordLog.makeLogger("cache.refresh").trace("Older refresh completion fenced by newer observation", metadata: ["dk.event": "cache.refresh.superseded", "dk.closed": .stringConvertible(closed)])
                if let current = value(for: key.entity, scope: key.scope), current.availability == .available {
                    delivered = .success(current)
                } else { delivered = .failure(closed ? EntityCacheFailure.closed : EntityCacheFailure.superseded) }
            } else {
                do {
                    let rest = EntitySnapshot(fields: snapshot.fields, completeness: snapshot.completeness,
                                              redactedFields: snapshot.redactedFields, nullableFields: snapshot.nullableFields,
                                              availability: snapshot.availability, provenance: .rest)
                    try apply(rest, for: key.entity, scope: key.scope)
                    // Independent successful refreshes must not invalidate each
                    // other's captured revision; this synchronous actor turn has
                    // no suspension in which an external observation can intervene.
                    revision = captured
                    delivered = .success(entries[key]?.snapshot ?? merge(rest, previous: nil))
                } catch { delivered = .failure(error) }
            }
        }
        for continuation in refresh.waiters.values { continuation.resume(with: delivered) }
        DiscordLog.makeLogger("cache.refresh").trace("Entity refresh waiters resumed and ownership released", metadata: ["dk.event": "cache.refresh.released", "dk.resumed": .stringConvertible(refresh.waiters.count), "dk.refreshes": .stringConvertible(refreshes.count), "dk.waiters": .stringConvertible(waiters)])
    }

    /// Drops inclusively expired entries and all associated ordering metadata without timers.
    private func prune() {
        let now = clock.now
        while let first = expiry.first, first.deadline <= now {
            remove(first.key)
            expirations &+= 1
            DiscordLog.makeLogger("cache.storage").trace("Entity cache entry expired", metadata: ["dk.event": "cache.entry.expired"])
        }
    }

    /// Removes one projection, its exact quota charges, both LRU links and its indexed deadline.
    /// - Parameter key: Scoped entry; missing values are harmless.
    private func remove(_ key: ScopedKey) {
        guard let entry = entries[key] else { return }
        unlink(key, entry: entry)
        removeExpiry(at: entry.expiryIndex)
        entries.removeValue(forKey: key)
        bytes -= entry.bytes
        identities[key.scope.identity]?.count -= 1
        identities[key.scope.identity]?.bytes -= entry.bytes
        if identities[key.scope.identity]?.count == 0 { identities.removeValue(forKey: key.scope.identity) }
    }

    /// Retains one new projection with exactly one deadline and one link in each LRU order.
    /// - Parameters:
    ///   - snapshot: Merged evidence whose bounded byte charge already passed admission.
    ///   - key: Absent scoped entry, after replacement and quota eviction removed old state.
    ///   - deadline: Inclusive monotonic expiry, independent of access order.
    ///   - retainedBytes: Exact payload and metadata charge, excluding allocator overhead.
    private func retain(_ snapshot: EntitySnapshot, for key: ScopedKey, deadline: C.Instant, bytes retainedBytes: Int) {
        entries[key] = Entry(snapshot: snapshot, bytes: retainedBytes, expiryIndex: expiry.count)
        identities[key.scope.identity, default: IdentityUsage()].count += 1
        identities[key.scope.identity]?.bytes += retainedBytes
        bytes += retainedBytes
        append(key)
        expiry.append(Expiry(key: key, deadline: deadline))
        moveExpiryUp(from: expiry.count - 1)
    }

    /// Promotes one retained projection in both exact LRU orders without scanning entries.
    /// - Parameter key: Existing scoped entry; an already newest global entry is also newest for its identity.
    private func promote(_ key: ScopedKey) {
        guard newest != key, let entry = entries[key] else { return }
        unlink(key, entry: entry)
        append(key)
    }

    /// Detaches a retained projection from both LRU orders without releasing quota or expiry state.
    /// - Parameters:
    ///   - key: Existing projection whose neighbor links are being detached.
    ///   - entry: Current links captured before any neighbor changes.
    private func unlink(_ key: ScopedKey, entry: Entry) {
        if let previous = entry.previous { entries[previous]?.next = entry.next }
        else { oldest = entry.next }
        if let next = entry.next { entries[next]?.previous = entry.previous }
        else { newest = entry.previous }
        if let previous = entry.identityPrevious { entries[previous]?.identityNext = entry.identityNext }
        else { identities[key.scope.identity]?.oldest = entry.identityNext }
        if let next = entry.identityNext { entries[next]?.identityPrevious = entry.identityPrevious }
        else { identities[key.scope.identity]?.newest = entry.identityPrevious }
    }

    /// Appends a detached projection to global and identity LRU tails in constant expected work.
    /// - Parameter key: Retained projection with an existing identity usage record.
    private func append(_ key: ScopedKey) {
        entries[key]?.previous = newest
        entries[key]?.next = nil
        if let newest { entries[newest]?.next = key }
        else { oldest = key }
        newest = key
        let identityNewest = identities[key.scope.identity]?.newest
        entries[key]?.identityPrevious = identityNewest
        entries[key]?.identityNext = nil
        if let identityNewest { entries[identityNewest]?.identityNext = key }
        else { identities[key.scope.identity]?.oldest = key }
        identities[key.scope.identity]?.newest = key
    }

    /// Erases an arbitrary retained deadline and repairs its one-entry-per-projection heap.
    /// - Parameter index: Exact position stored by the entry being removed.
    /// Replacement moves the final node into the hole, then repairs in the necessary direction.
    private func removeExpiry(at index: Int) {
        let last = expiry.count - 1
        if index != last { exchangeExpiry(index, last) }
        expiry.removeLast()
        guard index < expiry.count else { return }
        if index > 0, expiry[index].deadline < expiry[(index - 1) / 2].deadline {
            moveExpiryUp(from: index)
        } else { moveExpiryDown(from: index) }
    }

    /// Restores minimum-deadline ordering after insertion or upward replacement.
    /// - Parameter index: Existing heap node whose descendant subtrees remain ordered.
    private func moveExpiryUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard expiry[child].deadline < expiry[parent].deadline else { return }
            exchangeExpiry(child, parent)
            child = parent
        }
    }

    /// Restores minimum-deadline ordering after downward replacement.
    /// - Parameter index: Existing heap node whose child subtrees remain ordered.
    private func moveExpiryDown(from index: Int) {
        var parent = index
        while parent < expiry.count / 2 {
            let left = parent * 2 + 1, right = left + 1
            let child = right < expiry.count && expiry[right].deadline < expiry[left].deadline ? right : left
            guard expiry[child].deadline < expiry[parent].deadline else { return }
            exchangeExpiry(parent, child)
            parent = child
        }
    }

    /// Exchanges heap records and immediately synchronizes both retained-entry positions.
    /// - Parameters:
    ///   - left: Existing first heap position.
    ///   - right: Existing distinct second heap position.
    private func exchangeExpiry(_ left: Int, _ right: Int) {
        expiry.swapAt(left, right)
        entries[expiry[left].key]?.expiryIndex = left
        entries[expiry[right].key]?.expiryIndex = right
    }

    /// Reports retained index record counts for deterministic bounded-metadata regression checks.
    /// - Returns: Exactly one expiry record per retained projection and one quota record per
    ///   identity with retained entries or active refreshes, without pruning or changing LRU order.
    ///   Link and heap-position metadata live directly in entries, so neither can accumulate stale records.
    func retainedIndexCounts() -> (expiry: Int, identities: Int, refreshIdentities: Int) {
        (expiry.count, identities.count, identityRefreshes.count)
    }
}
