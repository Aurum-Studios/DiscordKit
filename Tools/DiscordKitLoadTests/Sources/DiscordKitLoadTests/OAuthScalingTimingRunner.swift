// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/OAuthScalingTimingRunner.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordCore
import DiscordOAuth
import Foundation

/// Versioned same-owner controls; legacy OAuth scripts retain their original fixture policy.
struct OAuthScalingTimingRunner: Sendable {
    /// Runs one coordinator per finite cohort with independently delayed storage and refresh I/O.
    /// A held backend proves every reader joined before release or selected-reader cancellation.
    /// - Parameters:
    ///   - scenario: Shared-key, unrelated-key or independently cancelled-reader V2 policy.
    ///   - requests: Total callers, including a partial final cohort, in 1...100,000.
    ///   - concurrency: Maximum simultaneous readers in one coordinator, in 1...256.
    ///   - storageDelay: Cancellable delay applied independently to each load and generation CAS.
    ///   - backendDelay: Cancellable refresh delay after the deterministic admission gate opens.
    /// - Returns: Whole caller and child populations, exact caller duration sum and empty cleanup.
    /// - Throws: Invalid limits, precancellation or independently detected ownership/result discrepancies.
    func run(scenario: OAuthTimingScenario, requests: Int, concurrency: Int,
             storageDelay: Duration, backendDelay: Duration) async throws -> OAuthTimingReport {
        guard scenario.isScaling, (1...100_000).contains(requests), (1...256).contains(concurrency),
              concurrency <= requests, storageDelay >= .zero, storageDelay <= .seconds(1),
              backendDelay >= .zero, backendDelay <= .seconds(1) else { throw LoadFailure.invalidArguments }
        try Task.checkCancellation()
        let statistics = try RunStatistics(workloads: [.oauthLookup, .oauthStorageLoad, .oauthStorageCAS,
            .oauthRefreshIO, .oauthRefreshCohortV2, .oauthClose])
        let origin = ContinuousClock.now
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        var completed = 0, refreshes = 0, loads = 0, exchanges = 0, cancellations = 0
        var coalesced = 0, maximumWaiters = 0
        var lookupNanoseconds: UInt64 = 0
        for offset in stride(from: 0, to: requests, by: concurrency) {
            if Task.isCancelled { break }
            let width = min(concurrency, requests - offset)
            let keyCount = scenario == .unrelatedRefreshV2 ? width : 1
            let identities = (1...keyCount).map { OAuthTokenIdentity(applicationID: .init(rawValue: UInt64($0))) }
            let storage = try OAuthScalingStorage(identities: identities, delay: storageDelay, statistics: statistics)
            let backend = OAuthScalingBackend(delay: backendDelay, statistics: statistics)
            let coordinator = OAuthTokenCoordinator(storage: storage, now: { Date(timeIntervalSince1970: 0) },
                maximumIdentities: keyCount, maximumWaiters: 256, maximumWaitersPerIdentity: 256,
                refresh: { _, _ in try await backend.refresh() },
                revoke: { _, _ in throw LoadFailure.unexpectedResponse })
            let submitted = ContinuousClock.now
            let tasks = (0..<width).map { index in
                let identity = identities[scenario == .unrelatedRefreshV2 ? index : 0]
                return Task { await oauthScalingLookup(coordinator, identity: identity, statistics: statistics) }
            }
            var interrupted = false
            var admittedCohort = false
            do {
                await backend.waitForOwners(keyCount)
                while true {
                    try Task.checkCancellation()
                    let state = await coordinator.snapshot()
                    let active = await backend.snapshot()
                    if state.waiters == width && active.active == keyCount {
                        maximumWaiters = max(maximumWaiters, state.waiters)
                        admittedCohort = true
                        break
                    }
                    await Task.yield()
                }
                if scenario == .partialCancellationV2 && width > 1 {
                    // A surviving reader keeps the single shared refresh alive.
                    for task in tasks.prefix(width / 2) { task.cancel() }
                    for task in tasks.prefix(width / 2) {
                        guard await task.value.outcome == .cancelled else { throw LoadFailure.unexpectedResponse }
                    }
                    guard await coordinator.snapshot().waiters == width - width / 2,
                          await backend.snapshot().active == 1 else { throw LoadFailure.unexpectedResponse }
                }
                await backend.release()
            } catch {
                for task in tasks { task.cancel() }
                await coordinator.close()
                guard error is CancellationError, Task.isCancelled else {
                    for task in tasks { _ = await task.value }
                    await storage.close()
                    throw error
                }
                interrupted = true
            }
            let terminal = await withTaskCancellationHandler {
                var values: [OAuthScalingLookupReceipt] = []
                for task in tasks { values.append(await task.value) }
                return values
            } onCancel: { for task in tasks { task.cancel() } }
            let joined = ContinuousClock.now
            statistics.record(submitted.duration(to: joined), workload: .oauthRefreshCohortV2,
                outcome: interrupted || Task.isCancelled ? .cancelled : .success)
            let closeStart = ContinuousClock.now
            await coordinator.close()
            statistics.record(closeStart.duration(to: .now), workload: .oauthClose, outcome: .success)
            let state = await coordinator.snapshot(), provider = await backend.snapshot()
            let authority = await storage.snapshot()
            if !interrupted && !Task.isCancelled {
                let cancelled = scenario == .partialCancellationV2 ? width / 2 : 0
                guard terminal.filter({ $0.outcome == .cancelled }).count == cancelled,
                      terminal.filter({ $0.outcome == .success }).count == width - cancelled,
                      provider.refreshes == keyCount, authority.loads == keyCount,
                      authority.exchanges == keyCount, authority.records == keyCount,
                      authority.allRotated else { await storage.close(); throw LoadFailure.unexpectedResponse }
            }
            await storage.close()
            guard state.flights == 0, state.waiters == 0, state.mutations == 0, provider.active == 0,
                  provider.waiters == 0, await storage.snapshot().records == 0 else { throw LoadFailure.unexpectedResponse }
            for result in terminal {
                outcomes[result.outcome, default: 0] += 1; completed += 1
                if result.outcome == .cancelled { cancellations += 1 }
                let duration = try BenchmarkTime.nanoseconds(duration: result.duration)
                let sum = lookupNanoseconds.addingReportingOverflow(duration)
                guard !sum.overflow else { throw LoadFailure.unexpectedResponse }
                lookupNanoseconds = sum.partialValue
            }
            refreshes += provider.refreshes; loads += authority.loads; exchanges += authority.exchanges
            if admittedCohort { coalesced += width - keyCount }
            if interrupted || Task.isCancelled { break }
        }
        var report = OAuthTimingReport(scenario: scenario.rawValue, requests: requests, concurrency: concurrency,
            clockDomain: statistics.clockDomain,
            counts: .init(offered: UInt64(completed), admitted: UInt64(completed), completed: UInt64(completed),
                outcomes: outcomes, deadlineMisses: 0), metrics: statistics.metrics(),
            durationNanoseconds: try BenchmarkTime.nanoseconds(duration: origin.duration(to: .now)),
            cleanup: .init(completed: true, remainingOwners: 0), refreshCalls: refreshes, storageLoads: loads,
            storageCAS: exchanges, storageConflicts: 0, conflicts: 0, revokeCalls: 0,
            cancelledReaders: cancellations, coalescedReaders: coalesced, maximumWaiters: maximumWaiters,
            remainingFlights: 0, remainingWaiters: 0, remainingMutations: 0, remainingBackendCalls: 0,
            remainingStorageRecords: 0, notes: [
                "Versioned credential-free control: each cohort shares one coordinator, one injected authoritative storage actor and one backend actor; unrelatedRefreshV2 gives every caller a distinct root grant.",
                "storageDelay and backendDelay vary independently. Every root storage load and generation CAS remains authoritative and is independently counted; fixture seeding and inspection are outside measured calls.",
                "Backend exchanges wait at an explicit cohort barrier until all caller waiters and all expected refresh owners exist. oauth.refresh.io includes this deliberate fixture wait; it is not a standalone backend capacity measurement.",
                "The driver awaits backend-owner arrival before polling only the remaining subscriber registrations; these diagnostic snapshots and task scheduling can perturb enclosing caller/backend intervals and do not supply isolated CPU attribution.",
                "oauth.lookup wraps each actual public caller. oauth.refreshCohortV2 wraps submission through all terminal caller joins, once per cohort even for unrelated grants, excluding subsequent close and diagnostic snapshots. This batch population is distinct from legacy oauth.refresh.joined, which is never emitted by V2 cases. Whole and child populations overlap.",
                "partialCancellationV2 cancels floor(cohortWidth/2) admitted readers and joins them before release; surviving readers must receive the single rotated result without replay or cancellation of shared work.",
                "All tasks, backend gate waiters, coordinator owners and storage records are joined or cleared before cleanup is reported. No network, persistent storage, browser or distributed locking is qualified."
            ])
        report.measuredLookupNanoseconds = lookupNanoseconds
        return report
    }
}

/// Original caller outcome and elapsed interval retained only through one finite cohort join.
private struct OAuthScalingLookupReceipt: Sendable {
    let outcome: BenchmarkOutcome
    let duration: Duration
}

/// Measures a genuine public caller before checking its successful synthetic token value.
/// - Parameters:
///   - coordinator: Shared cohort owner that performs all authoritative storage and generation checks.
///   - identity: Private root grant selected before entering the public-call timer.
///   - statistics: Bounded collector called after the terminal timestamp.
/// - Returns: Actual success/cancellation/failure with its exact original caller duration.
private func oauthScalingLookup(_ coordinator: OAuthTokenCoordinator, identity: OAuthTokenIdentity,
                                statistics: RunStatistics) async -> OAuthScalingLookupReceipt {
    let start = ContinuousClock.now
    do {
        let token = try await coordinator.accessToken(for: identity)
        let terminal = ContinuousClock.now
        let outcome: BenchmarkOutcome = token.withUnsafeValue { $0 == "synthetic-rotated" } ? .success : .failure
        statistics.record(start.duration(to: terminal), workload: .oauthLookup, outcome: outcome)
        return .init(outcome: outcome, duration: start.duration(to: terminal))
    } catch {
        let terminal = ContinuousClock.now
        let outcome: BenchmarkOutcome = error is CancellationError ? .cancelled : .failure
        statistics.record(start.duration(to: terminal), workload: .oauthLookup, outcome: outcome)
        return .init(outcome: outcome, duration: start.duration(to: terminal))
    }
}

/// One finite authoritative storage owner with distinct records for unrelated-key controls.
private actor OAuthScalingStorage: OAuthTokenStorage {
    private var records: [OAuthTokenIdentity: OAuthStoredToken]
    private let delay: Duration
    private let statistics: RunStatistics
    private var loads = 0, exchanges = 0

    /// Seeds each root grant outside timing without invoking the measured storage protocol.
    /// - Parameters:
    ///   - identities: Distinct bounded grant keys owned by this cohort.
    ///   - delay: Independent cooperative delay for every measured storage operation.
    ///   - statistics: Preallocated load/CAS distributions.
    /// - Throws: Invalid synthetic token response or stored-token construction.
    init(identities: [OAuthTokenIdentity], delay: Duration, statistics: RunStatistics) throws {
        let record = try OAuthStoredToken(response: oauthScalingResponse("synthetic-original", lifetime: 1),
            issuedAt: Date(timeIntervalSince1970: 0))
        records = Dictionary(uniqueKeysWithValues: identities.map { ($0, record) })
        self.delay = delay; self.statistics = statistics
    }

    /// Reads current authoritative state after the selected cancellable storage delay.
    /// - Parameter identity: Grant key supplied by the production coordinator.
    /// - Returns: Current token record, or nil after removal.
    /// - Throws: Cancellation from the owned storage wait; errors retain their own timing outcome.
    func load(for identity: OAuthTokenIdentity) async throws -> OAuthStoredToken? {
        let start = ContinuousClock.now
        loads += 1
        do {
            if delay > .zero { try await Task.sleep(for: delay) }
            let value = records[identity], end = ContinuousClock.now
            statistics.record(start.duration(to: end), workload: .oauthStorageLoad, outcome: .success)
            return value
        } catch {
            statistics.record(start.duration(to: .now), workload: .oauthStorageLoad,
                outcome: error is CancellationError ? .cancelled : .failure)
            throw error
        }
    }

    /// Applies a replacement only after an atomic generation comparison following storage delay.
    /// - Parameters:
    ///   - identity: Root record to compare and replace.
    ///   - expectedGeneration: Required existing generation; nil requires absence.
    ///   - replacement: Coordinator-validated next root record, or nil for removal.
    ///   - now: Protocol-required wall instant; this root-only fixture has no parent lineage.
    /// - Returns: Whether the authoritative generation comparison accepted the replacement.
    /// - Throws: Cancellation during the independent storage wait.
    func compareExchange(for identity: OAuthTokenIdentity, expectedGeneration: UUID?,
                         replacement: OAuthStoredToken?, now: Date) async throws -> Bool {
        let start = ContinuousClock.now
        exchanges += 1
        do {
            if delay > .zero { try await Task.sleep(for: delay) }
            let accepted = records[identity]?.generation == expectedGeneration
            if accepted { records[identity] = replacement }
            let end = ContinuousClock.now
            statistics.record(start.duration(to: end), workload: .oauthStorageCAS, outcome: accepted ? .success : .failure)
            return accepted
        } catch {
            statistics.record(start.duration(to: .now), workload: .oauthStorageCAS,
                outcome: error is CancellationError ? .cancelled : .failure)
            throw error
        }
    }

    /// Inspects exact protocol counts and rotation after timers stop, without another measured load.
    /// - Returns: Actual call/record counts and whether every retained root has the rotated value.
    func snapshot() -> (loads: Int, exchanges: Int, records: Int, allRotated: Bool) {
        (loads, exchanges, records.count, records.values.allSatisfy { $0.accessToken.withUnsafeValue { $0 == "synthetic-rotated" } })
    }

    /// Releases caller-owned records after every coordinator mutation and refresh has joined.
    func close() { records.removeAll() }
}

/// Held refreshes separate caller ownership from storage and configurable backend delay.
private actor OAuthScalingBackend {
    private let delay: Duration
    private let statistics: RunStatistics
    private var refreshes = 0, active = 0, released = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var expectedOwners = 0
    private var arrival: CheckedContinuation<Void, Never>?

    /// Allocates inert backend gates without starting work.
    /// - Parameters:
    ///   - delay: Independent refresh delay after cohort release.
    ///   - statistics: Bounded once-per-refresh I/O population.
    init(delay: Duration, statistics: RunStatistics) { self.delay = delay; self.statistics = statistics }

    /// Owns one injected exchange through admission gate, optional delay and terminal response.
    /// - Returns: The synthetic rotated token shared by callers of the same grant.
    /// - Throws: Cancellation during the gate or delay, or invalid response construction.
    func refresh() async throws -> OAuthTokenResponse {
        let start = ContinuousClock.now
        refreshes += 1; active += 1
        if active == expectedOwners { arrival?.resume(); arrival = nil }
        defer { active -= 1 }
        do {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else if released { continuation.resume() }
                    else { waiters[id] = continuation }
                }
            } onCancel: { Task { await self.cancel(id) } }
            if delay > .zero { try await Task.sleep(for: delay) }
            let result = try oauthScalingResponse("synthetic-rotated")
            statistics.record(start.duration(to: .now), workload: .oauthRefreshIO, outcome: .success)
            return result
        } catch {
            statistics.record(start.duration(to: .now), workload: .oauthRefreshIO,
                outcome: error is CancellationError ? .cancelled : .failure)
            throw error
        }
    }

    /// Resumes all admitted exchanges exactly once; future owners pass the already-open gate.
    func release() {
        released = true
        let values = waiters.values; waiters.removeAll()
        for waiter in values { waiter.resume() }
    }

    /// Avoids diagnostic polling throughout injected storage waits before refresh ownership exists.
    /// - Parameter count: Exact expected simultaneous exchanges, one shared grant or one per caller.
    func waitForOwners(_ count: Int) async {
        guard active < count else { return }
        expectedOwners = count
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || active >= count { continuation.resume() } else { arrival = continuation }
            }
        } onCancel: { Task { await self.cancelArrival() } }
    }

    /// Releases the single driver arrival continuation when its owning cohort is cancelled.
    private func cancelArrival() { arrival?.resume(); arrival = nil }

    /// Removes one cancelled exchange's gate waiter without affecting surviving owners.
    /// - Parameter id: Private identifier allocated before that exchange's suspension.
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    /// Inspects exact backend and driver-gate ownership outside measured protocol calls.
    /// - Returns: Cumulative exchanges, active exchanges and retained exchange/driver continuations.
    func snapshot() -> (refreshes: Int, active: Int, waiters: Int) { (refreshes, active, waiters.count + (arrival == nil ? 0 : 1)) }
}

/// Synthetic values never enter report fields or external adapters.
/// - Parameters:
///   - access: Fixed fixture credential marker, never used outside this private process.
///   - lifetime: Validated synthetic token lifetime in seconds.
/// - Returns: Root refresh-capable response for production coordinator validation.
/// - Throws: Token-wrapper or response validation errors.
private func oauthScalingResponse(_ access: String, lifetime: Int = 3_600) throws -> OAuthTokenResponse {
    try OAuthTokenResponse(accessToken: BearerToken(access), refreshToken: OAuthRefreshToken("synthetic-refresh"),
        expiresIn: lifetime, scopes: ["identify"])
}
