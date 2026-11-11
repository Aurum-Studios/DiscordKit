// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/Phase10TimingRunner.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordCache
import DiscordCore
import DiscordGateway
import DiscordModels
import DiscordTransport
import Foundation

/// Scalar receipts grow only with the validated maximum of 256 four-band cycles.
struct Phase10BandReceipt: Codable, Sendable {
    let name: String
    var offered = 0, submitted = 0, completed = 0, successful = 0, rejected = 0, cancelled = 0
    var peakActive = 0, peakPending = 0
    var peakPendingAgeNanoseconds: UInt64 = 0
    var recoveryNanoseconds: UInt64 = 0
    var schedulerMaximumLatenessNanoseconds: UInt64 = 0
    var generatorCensored: UInt64 = 0
    var controlProgress = 0
    var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0.rawValue, UInt64(0)) })
    var elapsedNanoseconds: UInt64 = 0
    var successfulPerSecond = 0.0, completedPerSecond = 0.0, offeredPerSecond = 0.0

    /// Combines whole count populations and maxima; no percentile is averaged or reconstructed.
    mutating func include(_ value: Self) {
        offered += value.offered; submitted += value.submitted; completed += value.completed
        successful += value.successful; rejected += value.rejected; cancelled += value.cancelled
        peakActive = max(peakActive, value.peakActive); peakPending = max(peakPending, value.peakPending)
        peakPendingAgeNanoseconds = max(peakPendingAgeNanoseconds, value.peakPendingAgeNanoseconds)
        recoveryNanoseconds = max(recoveryNanoseconds, value.recoveryNanoseconds)
        schedulerMaximumLatenessNanoseconds = max(schedulerMaximumLatenessNanoseconds, value.schedulerMaximumLatenessNanoseconds)
        generatorCensored += value.generatorCensored; controlProgress += value.controlProgress
        elapsedNanoseconds += value.elapsedNanoseconds
        for (key, count) in value.outcomes { outcomes[key, default: 0] += count }
        updateThroughput()
    }

    /// Derives rates from this exact aggregated band population and its actual measured wall span.
    mutating func updateThroughput() {
        let seconds = Double(max(1, elapsedNanoseconds)) / 1_000_000_000
        successfulPerSecond = Double(successful) / seconds; completedPerSecond = Double(completed) / seconds
        offeredPerSecond = Double(offered) / seconds
    }
}

struct Phase10CycleReceipt: Codable, Sendable {
    let ordinal: Int
    let bands: [Phase10BandReceipt]
    let cacheEntries: Int
    let cacheRefreshes: Int
    let cacheWaiters: Int
    let gatewayBufferedEvents: Int
    let remainingArrivalOwners: Int
}

struct Phase10Resources: Codable, Sendable {
    let maximumRSSBytes: UInt64
    let cpuSeconds: Double
    let capExceeded: Bool
    let capReason: String?
}

struct Phase10TimingMeasurement: Codable, Sendable {
    let counts: BenchmarkCounts
    let metrics: [BenchmarkMetric]
    let clockDomain: String
    let durationNanoseconds: UInt64
    let completedCycles: Int
    let cycles: [Phase10CycleReceipt]
    let bands: [Phase10BandReceipt]
    let controlProgress: Int
    let controlFailure: Bool
    let successfulPerSecond: Double
    let completedPerSecond: Double
    let resources: Phase10Resources
    let cleanup: BenchmarkCleanup
    let restCleanup: RESTTimingCleanup
    let gatewayCleanup: EventHubTimingSnapshot
    let cacheEntriesAfterClose: Int
    let cacheExpirations: UInt64
    let gatewayPublicationDrops: Int
    let cpuContentionChecksum: UInt64
    let cancelled: Bool
}

/// One retained fixed working set joins independent arrivals with real public REST/cache/hub owners.
@available(macOS 15, *)
struct Phase10TimingRunner: Sendable {
    static let bandNames = ["below", "near", "above", "recovery"]
    static let rates = [20, 40, 160, 20]

    /// The nominal knee is the injected 25ms single-partition provider control, not a platform capacity claim.
    func run(_ configuration: Phase10TimingConfiguration) async throws -> Phase10TimingMeasurement {
        try configuration.validate()
        let statistics = try RunStatistics(workloads: [.arrivalScheduledResponse, .arrivalSubmittedResponse, .arrivalLateness])
        let fixture = try await Phase10Fixture(seed: configuration.seed, statistics: configuration.observerMode == "aggregate" ? statistics : nil)
        let resources = Phase10ResourceMonitor(configuration: configuration)
        let started = DispatchTime.now().uptimeNanoseconds
        let monitor = Task {
            while !Task.isCancelled {
                do {
                    try await fixture.control()
                    resources.sample()
                    try await Task.sleep(for: .milliseconds(100))
                } catch { return !Task.isCancelled }
            }
            return false
        }
        var totals = Self.bandNames.map { Phase10BandReceipt(name: $0) }
        var cycles: [Phase10CycleReceipt] = []
        cycles.reserveCapacity(Int(configuration.durationSeconds / configuration.cycleSeconds))
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        var offered: UInt64 = 0, admitted: UInt64 = 0, completed: UInt64 = 0
        var interrupted = false
        var failure: (any Error)?
        do {
            for cycle in 0..<Int(configuration.durationSeconds / configuration.cycleSeconds) {
                if DispatchTime.now().uptimeNanoseconds - started >= configuration.durationSeconds * 1_000_000_000 { break }
                if Task.isCancelled || resources.exceeded { interrupted = Task.isCancelled; break }
                var bands: [Phase10BandReceipt] = []
                for index in Self.bandNames.indices {
                    if Task.isCancelled || resources.exceeded { interrupted = Task.isCancelled; break }
                    let seconds = configuration.cycleSeconds / 4
                    let count = Int(seconds) * Self.rates[index]
                    let bandStarted = DispatchTime.now().uptimeNanoseconds
                    let before = await fixture.controlCount()
                    let value = try await ArrivalTimingRunner().run(profile: .init(arrivals: count,
                        intervalNanoseconds: 1_000_000_000 / UInt64(Self.rates[index]),
                        maximumActive: 8, maximumPending: 8, measureGenerator: true, measureQueueAge: true)) { submission in
                        await fixture.execute(submission, cycle: cycle, band: index)
                    }
                    try value.counts.validate()
                    guard value.remainingActive == 0, value.remainingPending == 0,
                          value.invalidOperationTimestamps == 0, !value.clockRegressed else {
                        throw Phase8TimingError.integrityFailure("Integration arrival ownership or clock failure")
                    }
                    var band = Phase10BandReceipt(name: Self.bandNames[index])
                    band.offered = value.offeredArrivals; band.submitted = value.submittedArrivals
                    band.completed = Int(value.counts.completed); band.successful = Int(value.counts.outcomes[.success, default: 0])
                    band.rejected = Int(value.counts.outcomes[.rejected, default: 0]); band.cancelled = Int(value.counts.outcomes[.cancelled, default: 0])
                    band.peakActive = value.peakActive; band.peakPending = value.peakPending
                    band.peakPendingAgeNanoseconds = value.peakPendingAgeNanoseconds ?? 0
                    band.recoveryNanoseconds = value.recoveryNanoseconds
                    if let generator = value.generator {
                        band.schedulerMaximumLatenessNanoseconds = generator.schedulerLateness.maxInRangeNanoseconds ?? 0
                        band.generatorCensored = generator.schedulerLateness.overflowCount + generator.schedulerLateness.droppedCount
                    }
                    let bandDeadline = bandStarted + seconds * 1_000_000_000
                    let bandNow = DispatchTime.now().uptimeNanoseconds
                    if bandDeadline > bandNow {
                        do { try await Task.sleep(for: .nanoseconds(bandDeadline - bandNow)) }
                        catch { interrupted = true }
                    }
                    band.controlProgress = await fixture.controlCount() - before
                    band.elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - bandStarted
                    band.outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0.rawValue, value.counts.outcomes[$0, default: 0]) })
                    band.updateThroughput()
                    totals[index].include(band); bands.append(band)
                    offered += value.counts.offered; admitted += value.counts.admitted; completed += value.counts.completed
                    for outcome in BenchmarkOutcome.allCases { outcomes[outcome, default: 0] += value.counts.outcomes[outcome, default: 0] }
                    if value.cancelled || interrupted { interrupted = true; break }
                }
                let cache = await fixture.cacheStatistics(), gateway = await fixture.gatewaySnapshot()
                guard cache.entries <= 64, cache.refreshes == 0, cache.waiters == 0, gateway.bufferedEvents <= 64 else {
                    throw Phase8TimingError.integrityFailure("Fixed integration working set exceeded")
                }
                if bands.count == 4 {
                    cycles.append(.init(ordinal: cycle, bands: bands, cacheEntries: cache.entries,
                        cacheRefreshes: cache.refreshes, cacheWaiters: cache.waiters,
                        gatewayBufferedEvents: gateway.bufferedEvents, remainingArrivalOwners: 0))
                }
                if interrupted || resources.exceeded { break }
            }
        } catch {
            if error is CancellationError || Task.isCancelled { interrupted = true } else { failure = error }
        }
        monitor.cancel(); let controlFailure = await monitor.value
        let cleaned = await fixture.close()
        resources.sample()
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        guard cleaned.rest.isEmpty, cleaned.gateway.isEmpty, cleaned.cache.entries == 0,
              cleaned.cache.refreshes == 0, cleaned.cache.waiters == 0 else {
            throw Phase8TimingError.integrityFailure("Integration retained runtime owners")
        }
        if let failure { throw failure }
        let counts = BenchmarkCounts(offered: offered, admitted: admitted, completed: completed, outcomes: outcomes, deadlineMisses: 0)
        try counts.validate()
        return Phase10TimingMeasurement(counts: counts, metrics: statistics.metrics(), clockDomain: statistics.clockDomain,
            durationNanoseconds: elapsed, completedCycles: cycles.count, cycles: cycles, bands: totals,
            controlProgress: await fixture.controlCount(), controlFailure: controlFailure,
            successfulPerSecond: Double(outcomes[.success, default: 0]) * 1_000_000_000 / Double(max(1, elapsed)),
            completedPerSecond: Double(completed) * 1_000_000_000 / Double(max(1, elapsed)), resources: resources.receipt(),
            cleanup: .init(completed: true, remainingOwners: 0), restCleanup: cleaned.rest, gatewayCleanup: cleaned.gateway,
            cacheEntriesAfterClose: cleaned.cache.entries, cacheExpirations: cleaned.cache.expirations,
            gatewayPublicationDrops: await fixture.dropCount(), cpuContentionChecksum: await fixture.checksum(), cancelled: interrupted)
    }
}

/// Aggregate fixture state owns only fixed keys, bounded envelopes and joined consumer tasks.
@available(macOS 15, *)
private actor Phase10Fixture {
    let rest: RESTArrivalFixture
    let cache: EntityCache<CacheLoadClock>
    let freshness = CacheLoadClock()
    let authority: GatewayEventHubAuthority
    let dataHub: GatewayEventHub
    let controlHub: GatewayEventHub
    let slow: GatewayEventSubscription
    let healthy: GatewayEventSubscription
    let controlSubscription: GatewayEventSubscription
    let statistics: RunStatistics?
    let scope = CacheScope(identity: "integration-local", intents: 1 << 15)
    let shard: ShardIdentity
    let seed: UInt64
    var consumer: Task<Void, Never>?
    var progress = 0, drops = 0
    var checksumValue: UInt64 = 0

    /// Constructs finite public owners without external credentials, networking or per-arrival retention.
    init(seed: UInt64, statistics: RunStatistics?) async throws {
        self.seed = seed; self.statistics = statistics
        rest = try RESTArrivalFixture(concurrency: 8, delay: .milliseconds(25), orderedDefault: true)
        cache = try EntityCache(clock: freshness, policy: .bounded(.init(maximumEntries: 64, maximumBytes: 1_048_576,
            maximumEntriesPerIdentity: 64, maximumBytesPerIdentity: 1_048_576,
            maximumTimeToLive: .seconds(1), maximumRefreshes: 8, maximumRefreshesPerIdentity: 8,
            maximumWaiters: 8, maximumWaitersPerRefresh: 8)))
        let config = try GatewayEventHubConfiguration(maximumSubscriptions: 3, maximumBufferedEvents: 64,
            maximumBufferedBytes: 1_048_576, maximumEventsPerSubscription: 32, maximumBytesPerSubscription: 524_288)
        authority = GatewayEventHubAuthority(configuration: config)
        dataHub = GatewayEventHub(configuration: config, authority: authority)
        controlHub = GatewayEventHub(configuration: config, authority: authority)
        slow = try await dataHub.subscribe(policy: .dropOldest)
        healthy = try await dataHub.subscribe(policy: .dropOldest)
        controlSubscription = try await controlHub.subscribe(policy: .dropNewest)
        shard = try ShardIdentity(botID: UserID(rawValue: 1), topologyGeneration: 0, index: 0, count: 1)
        let subscription = healthy
        consumer = Task {
            var iterator = subscription.makeAsyncIterator()
            do { while try await iterator.next() != nil { try await Task.sleep(for: .milliseconds(2)) } } catch {}
        }
    }

    /// CPU work, expiry storms, payload bursts and cooperative request cancellation overlap real owners.
    func execute(_ submission: ArrivalSubmission, cycle: Int, band: Int) async -> ArrivalOperationResult {
        let global = UInt64(submission.ordinal) + UInt64(cycle) * 10_000 + UInt64(band) * 1_000
        let key = EntityKey(kind: .user, id: (global &+ seed) % 64 + 1)
        if global.isMultiple(of: 37) { freshness.advance(by: .seconds(2)) }
        if global.isMultiple(of: 13) {
            var value = global &+ seed
            for _ in 0..<4_096 { value = (value &* 6_364_136_223_846_793_005) &+ 1 }
            checksumValue ^= value
        }
        var outcome: BenchmarkOutcome
        do {
            try Task.checkCancellation()
            if await cache.value(for: key, scope: scope) == nil {
                try await cache.apply(.init(fields: ["name": .string("fixed-\(key.id)")], completeness: .complete), for: key, scope: scope)
            }
            if global.isMultiple(of: 17) {
                let operation = Task { await rest.execute(ordinal: Int(global)) }
                do { try await Task.sleep(for: .milliseconds(1)) } catch { operation.cancel() }
                operation.cancel(); outcome = await operation.value
            } else { outcome = await rest.execute(ordinal: Int(global)) }
            if outcome == .success {
                let payload = JSONValue.string(String(repeating: "x", count: global.isMultiple(of: 11) ? 8_192 : 256))
                let result = await dataHub.publish(try GatewayEvent(shard: shard, name: "INTEGRATION_DATA", sequence: Int64(global), data: payload))
                drops += result.dropped
            }
        } catch { outcome = error is CancellationError || Task.isCancelled ? .cancelled : .failure }
        let terminal = DispatchTime.now().uptimeNanoseconds
        statistics?.record(.nanoseconds(terminal - submission.scheduledNanoseconds), workload: .arrivalScheduledResponse, outcome: outcome)
        statistics?.record(.nanoseconds(terminal - submission.submittedNanoseconds), workload: .arrivalSubmittedResponse, outcome: outcome)
        statistics?.record(.nanoseconds(submission.submittedNanoseconds - submission.scheduledNanoseconds), workload: .arrivalLateness, outcome: outcome)
        return .init(outcome: outcome)
    }

    /// A real publication and pull on a second hub share the busy data hub's authority.
    func control() async throws {
        let result = await controlHub.publish(try GatewayEvent(shard: shard, name: "INTEGRATION_CONTROL", sequence: Int64(progress), data: .object([:])))
        guard result.delivered == 1 else { throw Phase8TimingError.integrityFailure("Control publication refused") }
        var iterator = controlSubscription.makeAsyncIterator()
        guard try await iterator.next() != nil else { throw Phase8TimingError.integrityFailure("Control consumer ended") }
        progress += 1
    }
    /// Reads exact successful control publication/pull pairs.
    func controlCount() -> Int { progress }
    /// Reads actual bounded data publication refusals.
    func dropCount() -> Int { drops }
    /// Retains CPU arithmetic output so optimized builds cannot discard the stress work.
    func checksum() -> UInt64 { checksumValue }
    /// Samples public cache ownership without retaining entries.
    func cacheStatistics() async -> EntityCacheStatistics { await cache.statistics() }
    /// Samples shared hub authority ownership without retaining envelopes.
    func gatewaySnapshot() async -> GatewayEventHubSnapshot { await authority.snapshot() }
    /// Cancels and joins consumers, then samples every independently closed real owner.
    func close() async -> (rest: RESTTimingCleanup, gateway: EventHubTimingSnapshot, cache: EntityCacheStatistics) {
        consumer?.cancel()
        await dataHub.finish(); await controlHub.finish()
        if let consumer { _ = await consumer.result }
        consumer = nil
        let restCleanup = await rest.shutdown()
        await cache.close()
        return (restCleanup, .init(await authority.snapshot()), await cache.statistics())
    }
}

/// Process resource caps latch failure evidence; sampling is separate from operation histograms.
private final class Phase10ResourceMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: Phase10TimingConfiguration
    private let baseline: ProcessSample
    private var peak: UInt64 = 0
    private var cpu: Double = 0
    private var reason: String?
    /// Captures process CPU origin before the first scheduled operation.
    init(configuration: Phase10TimingConfiguration) { self.configuration = configuration; baseline = .capture() }
    /// Reads the latched cap verdict without resampling inside measured calls.
    var exceeded: Bool { lock.withLock { reason != nil } }
    /// Samples bounded native CPU/RSS gauges and latches any configured ceiling hit.
    func sample() {
        let value = ProcessSample.capture()
        lock.withLock {
            peak = max(peak, value.residentBytes ?? value.peakRSSBytes)
            cpu = max(cpu, value.cpuSeconds - baseline.cpuSeconds)
            if peak > configuration.maximumRSSBytes { reason = "rss" }
            if cpu > Double(configuration.maximumCPUSeconds) { reason = "cpu" }
        }
    }
    /// Copies terminal resource evidence after all fixture owners have joined.
    func receipt() -> Phase10Resources {
        lock.withLock { .init(maximumRSSBytes: peak, cpuSeconds: cpu, capExceeded: reason != nil, capReason: reason) }
    }
}
