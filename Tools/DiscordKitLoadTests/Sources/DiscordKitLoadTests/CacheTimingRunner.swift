// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/CacheTimingRunner.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordCache
import DiscordCore
import DiscordGateway
import DiscordLogging
import DiscordModels
import Foundation

/// Closed cache fixture classes; expiry/eviction measure the public call that triggers lazy work.
enum CacheTimingScenario: String, Codable, CaseIterable, Sendable {
    case lookup = "cache.lookup"
    case sparseMerge = "cache.sparseMerge"
    case projection = "cache.projection"
    case permission = "cache.permission"
    case expiry = "cache.expiry"
    case eviction = "cache.eviction"
    case invalidation = "cache.invalidation"
    case staleFence = "cache.staleFence"
    case refresh = "cache.refresh"
    case singleFlight = "cache.singleFlight"
    case broadcast = "cache.broadcast"

    /// Selects only the requested owner boundary, excluding nested lookup/merge setup populations.
    var ownerStage: DiscordIntervalStage? {
        switch self {
        case .lookup, .expiry: .cacheLookup
        case .sparseMerge, .eviction: .cacheMerge
        case .projection: .cacheProjection
        case .invalidation: .cacheInvalidation
        case .staleFence, .refresh, .singleFlight: .cacheRefresh
        case .permission, .broadcast: nil
        }
    }
}

/// Exact active resources after awaited cache/hub close; cumulative counters live in the report.
struct CacheTimingCleanup: Codable, Sendable {
    let entries: Int
    let refreshes: Int
    let waiters: Int
    let subscriptions: Int
    let bufferedEvents: Int
    /// Counts remaining declared owners; zero is required before reporting successful cleanup.
    var remainingOwners: Int { entries + refreshes + waiters + subscriptions + bufferedEvents }
    /// Whether every cache entry, flight, caller and broadcast subscription has been released.
    var isEmpty: Bool { remainingOwners == 0 }
}

/// Bounded whole-population latency and explicit ownership evidence from local cache work.
struct CacheTimingReport: Codable, Sendable {
    let scenario: CacheTimingScenario
    let requests: Int
    let concurrency: Int
    let workingSet: Int
    let identities: Int
    let hitPercent: Int
    let fanOut: Int
    let slowSubscriber: Bool
    let counts: BenchmarkCounts
    let metrics: [BenchmarkMetric]
    let clockDomain: String
    let durationNanoseconds: UInt64
    let loaderCalls: UInt64
    let coalescedReads: UInt64
    let staleCompletions: UInt64
    let evictions: UInt64
    let expirations: UInt64
    let healthyDeliveries: Int
    let slowResynchronizations: Int
    let cleanup: CacheTimingCleanup
    let notes: [String]
}

/// Marks actual selected calls; setup and diagnostic actor calls never enter owner populations.
private enum CacheTimingMeasurement {
    @TaskLocal static var enabled = false
}

/// Real cache owners, injected freshness time and bounded cohorts; no credentials or external I/O.
@available(macOS 15, *)
struct CacheTimingRunner: Sendable {
    /// Executes every selected call with finite histogram storage and joined failure cleanup.
    /// - Parameters:
    ///   - scenario: Fixed operation class; permission arithmetic uses only an external wrapper.
    ///   - requests: Exact measured calls in 1...100,000, including a partial last cohort.
    ///   - concurrency: Active caller ceiling in 1...256 and no greater than requests.
    ///   - workingSet: Retained keys per identity in 1...4,096; never scales with requests.
    ///   - identities: Opaque local partitions in 1...32, sharing one aggregate authority.
    ///   - hitPercent: Lookup hit ratio, exactly 0, 50 or 100 percent by ordinal; other cases ignore it.
    ///   - fanOut: Broadcast subscribers in 1...32; other cases ignore it.
    ///   - slowSubscriber: Holds one broadcast subscriber until overflow; publication still succeeds.
    ///   - delay: Injected loader wait in zero through one second; independent of freshness time.
    /// - Returns: Every offered outcome, separate owner/loader populations and empty cleanup.
    /// - Throws: Invalid dimensions, cancellation, setup failure or a violated cache/broadcast invariant.
    ///   Caller timers stop before correctness checks and diagnostic snapshots. Owner callbacks are
    ///   synchronous and overlap caller latency; distributions must not be subtracted to infer queue time.
    func run(scenario: CacheTimingScenario, requests: Int = 32, concurrency: Int = 4,
        workingSet: Int = 16, identities: Int = 1, hitPercent: Int = 100,
        fanOut: Int = 2, slowSubscriber: Bool = false, delay: Duration = .milliseconds(2)) async throws -> CacheTimingReport {
        guard (1...100_000).contains(requests), (1...256).contains(concurrency), concurrency <= requests,
              (1...4_096).contains(workingSet), (1...32).contains(identities), [0, 50, 100].contains(hitPercent),
              (1...32).contains(fanOut), delay >= .zero, delay <= .seconds(1) else { throw LoadFailure.invalidArguments }
        try Task.checkCancellation()
        let statistics = try RunStatistics(workloads: [.cacheCall, .cacheOwner, .cacheLoader, .cacheBroadcast])
        let wall = ContinuousClock(), origin = wall.now
        let intervals = DiscordIntervalTiming(clockDomain: UInt64.random(in: 1...UInt64.max), sink: { event in
            guard CacheTimingMeasurement.enabled, event.kind == .ended else { return }
            let workload: BenchmarkWorkload
            if event.operation == .gatewayPublication, event.stage == .operation { workload = .cacheBroadcast }
            else if event.operation == .entityCache, event.stage == .cacheLoader { workload = .cacheLoader }
            else if event.operation == .entityCache, event.stage == scenario.ownerStage { workload = .cacheOwner }
            else { return }
            statistics.record(event.validity == .valid ? event.elapsedNanoseconds.map(Duration.nanoseconds) ?? .seconds(-1) : .seconds(-1),
                workload: workload, outcome: event.outcome == .succeeded ? .success : event.outcome == .cancelled ? .cancelled : .failure)
        }, now: { origin.duration(to: wall.now) })
        let freshness = CacheLoadClock()
        let maximumEntries = workingSet * identities
        let cache = try EntityCache(clock: freshness, policy: .bounded(.init(
            maximumEntries: maximumEntries, maximumBytes: maximumEntries * 4_096,
            maximumEntriesPerIdentity: workingSet, maximumBytesPerIdentity: workingSet * 4_096,
            maximumTimeToLive: .seconds(1), maximumRefreshes: concurrency,
            maximumRefreshesPerIdentity: concurrency, maximumWaiters: concurrency,
            maximumWaitersPerRefresh: concurrency)), intervals: intervals)
        let scopes = (0..<identities).map { CacheScope(identity: "timing-scope-\($0)", intents: 1 << 15) }
        let complete = EntitySnapshot(fields: ["name": .string("before"), "topic": .string("retained")], completeness: .complete)
        let patch = EntitySnapshot(fields: ["name": .string("after")], provenance: .local)
        let projected: JSONValue = .object(["id": .string("1"), "username": .string("fixture")])
        let guild = PermissionGuildState(id: .init(rawValue: 1), ownerID: .init(rawValue: 9), roles: [.init(rawValue: 1): .init()])
        let member = PermissionMemberState(guildID: .init(rawValue: 1), userID: .init(rawValue: 2), roleIDs: [], timeoutActive: false)
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        var completed = 0, healthy = 0, resyncs = 0, remainingSubscriptions = 0, remainingEvents = 0
        var measuredEvictions: UInt64 = 0, measuredExpirations: UInt64 = 0
        var first: ContinuousClock.Instant?, last: ContinuousClock.Instant?
        var hubs: [GatewayEventHub] = []
        do {
            for wave in stride(from: 0, to: requests, by: concurrency) {
                try Task.checkCancellation()
                let count = min(concurrency, requests - wave)
                let sharedScope = scopes[(wave / concurrency) % identities]
                let sharedKey = EntityKey(kind: .user, id: 1)
                if scenario == .refresh || scenario == .singleFlight || scenario == .staleFence {
                    for scope in scopes { await cache.invalidate(scope: scope) }
                }
                // Lookup retains its unchanged working set across cohorts; mutating cases restore theirs.
                // Preparation populates the entire selected fixed working set, not a request-sized cache.
                if (scenario == .lookup && wave == 0) || scenario == .sparseMerge || scenario == .expiry || scenario == .eviction || scenario == .invalidation {
                    for scope in scopes {
                        for key in 0..<workingSet {
                            try Task.checkCancellation()
                            try await cache.apply(complete, for: .init(kind: .user, id: UInt64(key + 1)), scope: scope)
                        }
                    }
                }
                let before = await cache.statistics()
                if scenario == .expiry { freshness.advance(by: .seconds(1)) }
                let gate = CacheLoadGate()
                var subscriptions: [[GatewayEventSubscription]] = []
                hubs = []
                if scenario == .broadcast {
                    for _ in 0..<count {
                        let hub = GatewayEventHub(configuration: try .init(maximumSubscriptions: fanOut,
                            maximumBufferedEvents: fanOut, maximumBufferedBytes: fanOut * 4_096,
                            maximumEventsPerSubscription: 1, maximumBytesPerSubscription: 4_096), intervals: intervals)
                        var streams: [GatewayEventSubscription] = []
                        for _ in 0..<fanOut { streams.append(try await hub.subscribe()) }
                        hubs.append(hub); subscriptions.append(streams)
                    }
                }
                let events = try (0..<count).map { offset in
                    try GatewayEvent(shard: .init(botID: .init(rawValue: 1), topologyGeneration: 0, index: 0, count: 1),
                        name: "LOCAL_CACHE_TIMING", sequence: Int64(wave + offset), data: .object([:]))
                }
                let cohortHubs = hubs, cohortStreams = subscriptions
                try await withThrowingTaskGroup(of: CacheTimingResult.self) { group in
                    for offset in 0..<count {
                        let ordinal = wave + offset
                        let scope = scenario == .singleFlight || scenario == .staleFence ? sharedScope : scopes[ordinal % identities]
                        let key = scenario == .singleFlight || scenario == .staleFence ? sharedKey : EntityKey(kind: .user,
                            id: UInt64(scenario == .eviction ? workingSet + offset + 1 : scenario == .refresh ? offset + 1 : ordinal % workingSet + 1))
                        group.addTask {
                            let result = await CacheTimingMeasurement.$enabled.withValue(true) {
                                let start = wall.now
                                let outcome: BenchmarkOutcome
                                var terminal: ContinuousClock.Instant
                                var valid = true, delivered = 0, resynchronized = 0
                                do {
                                    switch scenario {
                                    case .lookup:
                                        let hit = hitPercent == 100 || (hitPercent == 50 && ordinal % 2 == 0)
                                        let value = await cache.value(for: hit ? key : .init(kind: .user, id: UInt64(workingSet + 1)), scope: scope)
                                        terminal = wall.now
                                        valid = hit ? value == complete : value == nil
                                    case .sparseMerge:
                                        let value = try await cache.apply(patch, for: key, scope: scope)
                                        terminal = wall.now
                                        valid = value == .stored
                                    case .projection:
                                        let value = try await cache.observeGateway(name: "USER_UPDATE", data: projected, scope: scope,
                                            shard: 0, generation: 0, sequence: nil)
                                        terminal = wall.now
                                        valid = value == .stored
                                    case .permission:
                                        let value = PermissionResolver.resolve(guild: guild, member: member)
                                        terminal = wall.now
                                        if case .resolved = value {} else { valid = false }
                                    case .expiry:
                                        let value = await cache.value(for: key, scope: scope)
                                        terminal = wall.now
                                        valid = value == nil
                                    case .eviction:
                                        let value = try await cache.apply(complete, for: key, scope: scope)
                                        terminal = wall.now
                                        valid = value == .stored
                                    case .invalidation:
                                        await cache.invalidateLocalWrite(keys: [key], scope: scope)
                                        terminal = wall.now
                                    case .refresh, .singleFlight, .staleFence:
                                        let value = try await cache.refresh(key: key, scope: scope, requireComplete: true) {
                                            if scenario == .singleFlight || scenario == .staleFence { return try await gate.load(complete) }
                                            if delay > .zero { try await wall.sleep(for: delay) }
                                            return complete
                                        }
                                        terminal = wall.now
                                        valid = value.fields == ["name": .string(scenario == .staleFence ? "after" : "before"),
                                            "topic": .string("retained")] && value.completeness == .complete
                                            && value.availability == .available && value.redactedFields.isEmpty
                                            && value.provenance == (scenario == .staleFence ? .gateway : .rest)
                                    case .broadcast:
                                        let hub = cohortHubs[offset], streams = cohortStreams[offset]
                                        let publications = slowSubscriber ? 3 : 1
                                        for _ in 0..<publications {
                                            await hub.publish(events[offset])
                                            for (index, stream) in streams.enumerated() where !slowSubscriber || index != 0 {
                                                var iterator = stream.makeAsyncIterator()
                                                guard try await iterator.next()?.sequence == events[offset].sequence else { throw LoadFailure.unexpectedResponse }
                                                delivered += 1
                                            }
                                        }
                                        terminal = wall.now
                                        if slowSubscriber {
                                            var iterator = streams[0].makeAsyncIterator()
                                            do { _ = try await iterator.next(); valid = false }
                                            catch GatewayEventDeliveryFailure.resynchronizationRequired { resynchronized = 1 }
                                        }
                                    }
                                    outcome = valid ? .success : .failure
                                } catch {
                                    terminal = wall.now
                                    outcome = error is CancellationError ? .cancelled : .failure
                                    await gate.recordFailure()
                                }
                                statistics.record(start.duration(to: terminal), workload: .cacheCall, outcome: outcome)
                                return CacheTimingResult(outcome: outcome, submitted: start, terminal: terminal,
                                    healthy: delivered, resynchronizations: resynchronized)
                            }
                            return result
                        }
                    }
                    if scenario == .singleFlight || scenario == .staleFence {
                        do {
                            var progress = await cache.statistics(), loader = await gate.counts()
                            while progress.waiters < count && loader.failures == 0 {
                                try Task.checkCancellation()
                                await Task.yield()
                                progress = await cache.statistics(); loader = await gate.counts()
                            }
                            guard loader.failures == 0, progress.waiters == count else { throw LoadFailure.unexpectedResponse }
                            if scenario == .staleFence {
                                try await cache.apply(.init(fields: ["name": .string("after"), "topic": .string("retained")], completeness: .complete),
                                    for: sharedKey, scope: sharedScope)
                            }
                            if delay > .zero { try await wall.sleep(for: delay) }
                            await gate.release()
                        } catch { await gate.release(); group.cancelAll(); throw error }
                    }
                    for try await result in group {
                        completed += 1; outcomes[result.outcome, default: 0] += 1
                        first = first.map { min($0, result.submitted) } ?? result.submitted
                        last = last.map { max($0, result.terminal) } ?? result.terminal
                        healthy += result.healthy; resyncs += result.resynchronizations
                    }
                }
                for hub in hubs {
                    await hub.finish()
                    let receipt = await hub.snapshot()
                    remainingSubscriptions += receipt.subscriptions
                    remainingEvents += receipt.bufferedEvents
                }
                hubs = []
                let usage = await cache.statistics()
                measuredEvictions += usage.evictions - before.evictions
                measuredExpirations += usage.expirations - before.expirations
                guard usage.entries <= maximumEntries, usage.bytes <= maximumEntries * 4_096,
                      usage.refreshes == 0, usage.waiters == 0 else { throw LoadFailure.unexpectedResponse }
                if scenario == .sparseMerge {
                    // Check the actual merged projection after all contenders have joined.
                    let ordinal = wave, scope = scopes[ordinal % identities]
                    let value = await cache.value(for: .init(kind: .user, id: UInt64(ordinal % workingSet + 1)), scope: scope)
                    guard value?.fields["name"] == .string("after"), value?.fields["topic"] == .string("retained") else { throw LoadFailure.unexpectedResponse }
                }
                if scenario == .projection {
                    for ordinal in wave..<(wave + count) {
                        let value = await cache.value(for: .init(kind: .user, id: 1), scope: scopes[ordinal % identities])
                        guard value?.fields == ["id": .string("1"), "username": .string("fixture")],
                              value?.provenance == .gateway, value?.completeness == .partial,
                              value?.availability == .available, value?.redactedFields.isEmpty == true else {
                            throw LoadFailure.unexpectedResponse
                        }
                    }
                }
                if scenario == .invalidation {
                    for ordinal in wave..<(wave + count) {
                        guard await cache.value(for: .init(kind: .user, id: UInt64(ordinal % workingSet + 1)), scope: scopes[ordinal % identities]) == nil else { throw LoadFailure.unexpectedResponse }
                    }
                }
            }
            guard outcomes[.success, default: 0] == UInt64(completed), completed == requests else {
                throw LoadFailure.unexpectedResponse
            }
            let final = await cache.statistics()
            if scenario == .singleFlight || scenario == .staleFence {
                let flights = UInt64((requests + concurrency - 1) / concurrency)
                guard final.refreshStarts == flights, final.coalescedReads == UInt64(requests) - flights,
                      final.staleCompletions == (scenario == .staleFence ? flights : 0) else { throw LoadFailure.unexpectedResponse }
            }
            if scenario == .refresh {
                guard final.refreshStarts == UInt64(requests), final.coalescedReads == 0 else { throw LoadFailure.unexpectedResponse }
            }
            if scenario == .broadcast {
                guard healthy == requests * (slowSubscriber ? 3 : 1) * (fanOut - (slowSubscriber ? 1 : 0)),
                      resyncs == (slowSubscriber ? requests : 0) else { throw LoadFailure.unexpectedResponse }
            }
            await cache.close()
            let cleaned = await cache.statistics()
            let cleanup = CacheTimingCleanup(entries: cleaned.entries, refreshes: cleaned.refreshes, waiters: cleaned.waiters,
                subscriptions: remainingSubscriptions, bufferedEvents: remainingEvents)
            return CacheTimingReport(scenario: scenario, requests: requests, concurrency: concurrency,
                workingSet: workingSet, identities: identities, hitPercent: hitPercent, fanOut: fanOut, slowSubscriber: slowSubscriber,
                counts: .init(offered: UInt64(completed), admitted: UInt64(completed), completed: UInt64(completed), outcomes: outcomes, deadlineMisses: 0),
                metrics: statistics.metrics(), clockDomain: statistics.clockDomain,
                durationNanoseconds: try BenchmarkTime.nanoseconds(duration: first.flatMap { a in last.map { a.duration(to: $0) } } ?? .zero),
                loaderCalls: final.refreshStarts, coalescedReads: final.coalescedReads, staleCompletions: final.staleCompletions,
                evictions: measuredEvictions, expirations: measuredExpirations, healthyDeliveries: healthy, slowResynchronizations: resyncs,
                cleanup: cleanup, notes: [
                    "Whole selected caller populations stop before correctness checks and diagnostic snapshots; owner entry excludes preceding actor residence.",
                    "No paired queue-residence hook exists; caller and owner distributions overlap and must never be subtracted.",
                    "Expiry uses explicitly advanced freshness time; measured durations use a separate real ContinuousClock.",
                    "Expiry measures lookup including lazy prune; eviction measures apply including bounded LRU selection.",
                    "Working sets are fixed per identity; active task cohorts never exceed concurrency, and each broadcast caller owns at most fanOut subscriptions.",
                    "Refresh loaders count once per admitted flight; singleFlight/staleFence deterministically retain every cohort waiter before loader release.",
                    "Permission arithmetic has an external wrapper and no fabricated actor owner interval. Broadcast calls include publication and healthy delivery; slow overflow verification follows the terminal timestamp.",
                    "Setup, diagnostics and report export are excluded from individual call intervals; between-cohort setup remains included in run throughput duration. Numerical results are informational local evidence."
                ])
        } catch {
            for hub in hubs { await hub.finish() }
            await cache.close()
            throw error
        }
    }
}

/// One completed caller's fixed-size receipt, consumed immediately by its bounded task group.
private struct CacheTimingResult: Sendable {
    let outcome: BenchmarkOutcome
    let submitted: ContinuousClock.Instant
    let terminal: ContinuousClock.Instant
    let healthy: Int
    let resynchronizations: Int
}
