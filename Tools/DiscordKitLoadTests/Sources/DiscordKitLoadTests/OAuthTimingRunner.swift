// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/OAuthTimingRunner.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordCore
import DiscordOAuth
import Foundation

/// Finite credential-free scripts through the public token ownership coordinator.
enum OAuthTimingScenario: String, CaseIterable, Codable, Sendable {
    case lookup = "oauth.lookup"
    case storage = "oauth.storage"
    case refresh = "oauth.refresh"
    case singleFlight = "oauth.singleFlight"
    case conflict = "oauth.conflict"
    case revoke = "oauth.revoke"
    case joinedCancellation = "oauth.joinedCancellation"

    /// Whether every bounded cohort deliberately contends for one local grant.
    var sharesFlight: Bool { self == .singleFlight || self == .conflict || self == .joinedCancellation }
}

/// Whole public workflow outcomes and independently read storage, backend and ownership receipts.
struct OAuthTimingReport: Codable, Sendable {
    let scenario: String
    let requests: Int
    let concurrency: Int
    let clockDomain: String
    let counts: BenchmarkCounts
    let metrics: [BenchmarkMetric]
    let durationNanoseconds: UInt64
    let cleanup: BenchmarkCleanup
    let refreshCalls: Int
    let storageLoads: Int
    let storageCAS: Int
    let storageConflicts: Int
    let conflicts: Int
    let revokeCalls: Int
    let cancelledReaders: Int
    let coalescedReaders: Int
    /// Largest shared-cohort waiter count read at the admission barrier; independent fixtures are not sampled.
    let maximumWaiters: Int
    let remainingFlights: Int
    let remainingWaiters: Int
    let remainingMutations: Int
    let remainingBackendCalls: Int
    let remainingStorageRecords: Int
    let notes: [String]
}

/// Bounded coordinator workloads with synthetic values, injected delays and joined cleanup.
struct OAuthTimingRunner: Sendable {
    private let onSharedAdmission: (@Sendable () async -> Void)?

    /// Optionally observes the real shared-reader barrier for deterministic cancellation tests.
    /// - Parameter onSharedAdmission: Test-owned barrier callback; nil adds no callback to ordinary runs.
    init(onSharedAdmission: (@Sendable () async -> Void)? = nil) { self.onSharedAdmission = onSharedAdmission }

    /// Runs exact caller populations using private storage and no authorization or wire operations.
    /// - Parameters:
    ///   - scenario: Selected public lookup, mutation, generation conflict or cancellation workflow.
    ///   - requests: Measured caller attempts, in 1...100,000, including a partial final cohort.
    ///   - concurrency: Maximum active callers in 1...256 and no greater than requests.
    ///   - delay: Explicit storage and backend delay in zero through one second; each has a separate metric.
    /// - Returns: Whole caller distributions, once-per-I/O child samples and exact empty cleanup.
    /// - Throws: Invalid dimensions, precancellation, allocation errors or a violated fixture invariant.
    ///   External cancellation stops new cohorts, cancels readers and returns exact joined partial evidence.
    ///   Public caller timestamps precede diagnostics. Nested metrics overlap and cannot be added.
    func run(scenario: OAuthTimingScenario, requests: Int = 16, concurrency: Int = 4,
             delay: Duration = .zero) async throws -> OAuthTimingReport {
        guard (1...100_000).contains(requests), (1...256).contains(concurrency), concurrency <= requests,
              delay >= .zero, delay <= .seconds(1) else { throw LoadFailure.invalidArguments }
        try Task.checkCancellation()
        let statistics = try RunStatistics(workloads: [.oauthLookup, .oauthInstall, .oauthRevoke, .oauthStorageLoad, .oauthStorageCAS,
            .oauthRefreshIO, .oauthRefreshJoined, .oauthRevokeIO, .oauthClose])
        let clock = ContinuousClock(), origin = clock.now
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        var completed = 0, refreshes = 0, loads = 0, exchanges = 0, storageConflicts = 0
        var conflicts = 0, revocations = 0, cancellations = 0, coalesced = 0, maximumWaiters = 0
        var remainingFlights = 0, remainingWaiters = 0, remainingMutations = 0
        var remainingBackends = 0, remainingRecords = 0
        for start in stride(from: 0, to: requests, by: concurrency) {
            if Task.isCancelled { break }
            let width = min(concurrency, requests - start)
            let fixtures = try (0..<(scenario.sharesFlight ? 1 : width)).map { _ in
                try OAuthTimingFixture(scenario: scenario, delay: delay, statistics: statistics)
            }
            var tasks: [Task<OAuthTimingResult, Never>] = []
            let submitted = clock.now
            for ordinal in 0..<width {
                let fixture = fixtures[scenario.sharesFlight ? 0 : ordinal]
                tasks.append(Task { await fixture.execute(scenario: scenario) })
            }
            let currentTasks = tasks
            var counted = 0
            do {
                if scenario.sharesFlight {
                    let fixture = fixtures[0]
                    try await fixture.waitForReaders(width)
                    maximumWaiters = max(maximumWaiters, await fixture.coordinator.snapshot().waiters)
                    guard await fixture.backend.snapshot().refreshes == 1 else { throw LoadFailure.unexpectedResponse }
                    await onSharedAdmission?()
                    try Task.checkCancellation()
                    if scenario == .conflict { try await fixture.storage.replaceExternally() }
                    if scenario == .joinedCancellation {
                        for task in tasks { task.cancel() }
                    } else { await fixture.backend.release() }
                }
                var results: [OAuthTimingResult] = []
                for task in tasks {
                    let result = await withTaskCancellationHandler {
                        await task.value
                    } onCancel: {
                        for task in currentTasks { task.cancel() }
                    }
                    counted += 1
                    completed += 1; outcomes[result.outcome, default: 0] += 1
                    conflicts += result.conflict ? 1 : 0
                    cancellations += result.outcome == .cancelled ? 1 : 0
                    results.append(result)
                }
                try Task.checkCancellation()
                guard results.allSatisfy({ $0.valid }) else { throw LoadFailure.unexpectedResponse }
                if scenario == .joinedCancellation {
                    let state = await fixtures[0].coordinator.snapshot()
                    let backend = await fixtures[0].backend.snapshot()
                    guard state.flights == 1, state.waiters == 0, backend.active == 1 else { throw LoadFailure.unexpectedResponse }
                }
                if scenario != .refresh { for fixture in fixtures { await fixture.close() } }
                if scenario.sharesFlight {
                    statistics.record(submitted.duration(to: clock.now), workload: .oauthRefreshJoined,
                        outcome: scenario == .joinedCancellation ? .cancelled : scenario == .conflict ? .failure : .success)
                    coalesced += width - 1
                }
                for fixture in fixtures {
                    let state = await fixture.coordinator.snapshot()
                    let backend = await fixture.backend.snapshot()
                    let storage = await fixture.storage.snapshot()
                    refreshes += backend.refreshes; revocations += backend.revocations
                    loads += storage.loads; exchanges += storage.exchanges; storageConflicts += storage.conflicts
                    remainingFlights += state.flights; remainingWaiters += state.waiters; remainingMutations += state.mutations
                    remainingBackends += backend.active + backend.waiters; remainingRecords += storage.records
                    guard state.flights == 0, state.waiters == 0, state.mutations == 0,
                          backend.active == 0, backend.waiters == 0, storage.records == 0 else { throw LoadFailure.unexpectedResponse }
                }
            } catch {
                for task in tasks { task.cancel() }
                // Let independently cancelled callers consume their own cancellation before close
                // supplies a lifecycle error; caller-owned mutations also join before storage clears.
                for (index, task) in tasks.enumerated() {
                    let result = await task.value
                    if index >= counted {
                        completed += 1; outcomes[result.outcome, default: 0] += 1
                        conflicts += result.conflict ? 1 : 0
                        cancellations += result.outcome == .cancelled ? 1 : 0
                    }
                }
                for fixture in fixtures { await fixture.close() }
                guard error is CancellationError, Task.isCancelled else { throw error }
                if scenario.sharesFlight, await fixtures[0].backend.snapshot().refreshes > 0 {
                    statistics.record(submitted.duration(to: clock.now), workload: .oauthRefreshJoined, outcome: .cancelled)
                }
                for fixture in fixtures {
                    let state = await fixture.coordinator.snapshot()
                    let backend = await fixture.backend.snapshot()
                    let storage = await fixture.storage.snapshot()
                    refreshes += backend.refreshes; revocations += backend.revocations
                    loads += storage.loads; exchanges += storage.exchanges; storageConflicts += storage.conflicts
                    remainingFlights += state.flights; remainingWaiters += state.waiters; remainingMutations += state.mutations
                    remainingBackends += backend.active + backend.waiters; remainingRecords += storage.records
                }
                break
            }
        }
        let expectedFlights = (requests + concurrency - 1) / concurrency
        if !Task.isCancelled {
            guard completed == requests,
                  refreshes == (scenario.sharesFlight ? expectedFlights : scenario == .refresh ? requests : 0),
                  revocations == (scenario == .revoke ? requests : 0),
                  conflicts == (scenario == .conflict ? requests : 0),
                  cancellations == (scenario == .joinedCancellation ? requests : 0),
                  storageConflicts == (scenario == .conflict ? expectedFlights : 0) else { throw LoadFailure.unexpectedResponse }
        }
        let remaining = remainingFlights + remainingWaiters + remainingMutations + remainingBackends + remainingRecords
        guard remaining == 0 else { throw LoadFailure.unexpectedResponse }
        return OAuthTimingReport(scenario: scenario.rawValue, requests: requests, concurrency: concurrency,
            clockDomain: statistics.clockDomain,
            counts: .init(offered: UInt64(completed), admitted: UInt64(completed), completed: UInt64(completed),
                outcomes: outcomes, deadlineMisses: 0), metrics: statistics.metrics(),
            durationNanoseconds: try BenchmarkTime.nanoseconds(duration: origin.duration(to: clock.now)),
            cleanup: .init(completed: remaining == 0, remainingOwners: UInt64(remaining)),
            refreshCalls: refreshes, storageLoads: loads, storageCAS: exchanges, storageConflicts: storageConflicts,
            conflicts: conflicts, revokeCalls: revocations, cancelledReaders: cancellations, coalescedReaders: coalesced,
            maximumWaiters: maximumWaiters, remainingFlights: remainingFlights, remainingWaiters: remainingWaiters,
            remainingMutations: remainingMutations, remainingBackendCalls: remainingBackends, remainingStorageRecords: remainingRecords,
            notes: [
                "Synthetic local tokens only; injected storage and backend never perform network, browser authorization or persistent I/O.",
                "oauth.lookup wraps accessToken; oauth.install wraps install; oauth.revoke wraps revokeToken. Each public workflow includes caller admission and shared waits, and timestamps stop before result assertions and diagnostics.",
                "oauth.storage.load and oauth.storage.cas wrap actual injected protocol calls, including configured delay and atomic in-memory work. Fixture seeding, external winning replacement and cleanup are excluded.",
                "oauth.refresh.io and oauth.revoke.io wrap actual injected closures, once per exchange rather than once per reader; they include configured delay.",
                "oauth.refresh.joined is an external caller wrapper, not an owner-admission hook. Independent refreshes span caller entry through coordinator close; shared cohorts span before task submission through all reader joins and coordinator close, including barrier and diagnostic overhead.",
                "Joined cancellation releases every subscriber before close cancels and joins the still-owned refresh; barrier cancellation and backend active counters independently prove cleanup.",
                "Each cohort retains at most concurrency readers and one storage record per independent fixture; fixture storage is explicitly cleared after coordinator close.",
                "Single-flight is local to one coordinator. Generation fences prove preservation of the injected winning record, not distributed locking.",
                "Nested populations overlap and their percentiles must not be added or subtracted. Run duration includes setup, diagnostics and teardown; numerical results are informational local evidence."
            ])
    }
}

/// A terminal caller receipt captured before inspecting private fixture state.
private struct OAuthTimingResult: Sendable {
    let outcome: BenchmarkOutcome
    let valid: Bool
    let conflict: Bool
}

/// One bounded grant and its explicitly owned fixture authorities.
private struct OAuthTimingFixture: Sendable {
    let coordinator: OAuthTokenCoordinator
    let storage: OAuthTimingStorage
    let backend: OAuthTimingBackend
    let identity: OAuthTokenIdentity
    let statistics: RunStatistics

    /// Creates one preseeded grant without charging fixture setup to protocol-call populations.
    init(scenario: OAuthTimingScenario, delay: Duration, statistics: RunStatistics) throws {
        let identity = OAuthTokenIdentity(applicationID: .init(rawValue: 1))
        let record = try OAuthStoredToken(response: oauthTimingResponse("synthetic-original",
            lifetime: scenario == .lookup || scenario == .storage || scenario == .revoke ? 3_600 : 1),
            issuedAt: Date(timeIntervalSince1970: 0))
        let storage = OAuthTimingStorage(identity: identity, record: record, delay: delay, statistics: statistics)
        let backend = OAuthTimingBackend(held: scenario.sharesFlight, delay: delay, statistics: statistics)
        self.identity = identity; self.storage = storage; self.backend = backend; self.statistics = statistics
        coordinator = OAuthTokenCoordinator(storage: storage, now: { Date(timeIntervalSince1970: 0) },
            maximumIdentities: 1, maximumWaiters: 256, maximumWaitersPerIdentity: 256,
            refresh: { _, _ in try await backend.refresh() }, revoke: { _, _ in
                guard await storage.inspect() == nil else { throw LoadFailure.unexpectedResponse }
                try await backend.revoke()
            })
    }

    /// Invokes the selected production operation and checks values after its terminal timestamp.
    func execute(scenario: OAuthTimingScenario) async -> OAuthTimingResult {
        let clock = ContinuousClock(), start = clock.now
        let outcome: BenchmarkOutcome
        var token: BearerToken?, conflict = false, expectedError = false
        do {
            switch scenario {
            case .storage: try await coordinator.install(oauthTimingResponse("synthetic-replacement"), for: identity)
            case .revoke: try await coordinator.revokeToken(for: identity)
            default: token = try await coordinator.accessToken(for: identity)
            }
            outcome = .success
        } catch is CancellationError {
            outcome = .cancelled; expectedError = scenario == .joinedCancellation
        } catch OAuthTokenFailure.conflict {
            outcome = .failure; conflict = true; expectedError = scenario == .conflict
        } catch { outcome = .failure }
        let terminal = clock.now
        statistics.record(start.duration(to: terminal),
            workload: scenario == .storage ? .oauthInstall : scenario == .revoke ? .oauthRevoke : .oauthLookup, outcome: outcome)
        let record = await storage.inspect()
        let valid: Bool
        switch scenario {
        case .lookup:
            valid = outcome == .success && token?.withUnsafeValue({ $0 }) == "synthetic-original"
        case .storage:
            valid = outcome == .success && record?.accessToken.withUnsafeValue({ $0 }) == "synthetic-replacement"
        case .refresh, .singleFlight:
            valid = outcome == .success && token?.withUnsafeValue({ $0 }) == "synthetic-rotated"
                && record?.accessToken.withUnsafeValue({ $0 }) == "synthetic-rotated"
                && record?.refreshToken?.withUnsafeValue({ $0 }) == "synthetic-refresh"
        case .conflict:
            valid = expectedError && record?.accessToken.withUnsafeValue({ $0 }) == "synthetic-winner"
        case .revoke: valid = outcome == .success && record == nil
        case .joinedCancellation: valid = expectedError
        }
        if scenario == .refresh {
            await close()
            if await backend.snapshot().refreshes > 0 {
                statistics.record(start.duration(to: clock.now), workload: .oauthRefreshJoined, outcome: outcome)
            }
        }
        return OAuthTimingResult(outcome: outcome, valid: valid, conflict: conflict)
    }

    /// Waits for every reader's real coordinator admission and the held refresh closure entry.
    func waitForReaders(_ count: Int) async throws {
        await backend.waitForRefreshEntry()
        while await coordinator.snapshot().waiters != count { try Task.checkCancellation(); await Task.yield() }
        try Task.checkCancellation()
    }

    /// Joins actual coordinator work before releasing caller-owned in-memory storage.
    func close() async {
        await closeCoordinator()
        await storage.close()
    }

    /// Joins owned refreshes while preserving storage until caller-owned mutations have also joined.
    func closeCoordinator() async {
        let clock = ContinuousClock(), start = clock.now
        await coordinator.close()
        let terminal = clock.now
        statistics.record(start.duration(to: terminal), workload: .oauthClose, outcome: .success)
    }
}

/// Finite authoritative storage implementing generation CAS for the fixture's one root grant.
private actor OAuthTimingStorage: OAuthTokenStorage {
    let identity: OAuthTokenIdentity
    let delay: Duration
    let statistics: RunStatistics
    var record: OAuthStoredToken?
    var loads = 0, exchanges = 0, conflicts = 0

    /// Seeds a single local record before any measured protocol operation.
    init(identity: OAuthTokenIdentity, record: OAuthStoredToken, delay: Duration, statistics: RunStatistics) {
        self.identity = identity; self.record = record; self.delay = delay; self.statistics = statistics
    }

    /// Loads the current record after an explicitly measured injected storage wait.
    func load(for identity: OAuthTokenIdentity) async throws -> OAuthStoredToken? {
        let clock = ContinuousClock(), start = clock.now
        loads += 1
        do {
            if delay > .zero { try await clock.sleep(for: delay) }
            let value = identity == self.identity ? record : nil
            let terminal = clock.now
            statistics.record(start.duration(to: terminal), workload: .oauthStorageLoad, outcome: .success)
            return value
        } catch {
            let terminal = clock.now
            statistics.record(start.duration(to: terminal), workload: .oauthStorageLoad,
                outcome: error is CancellationError ? .cancelled : .failure)
            throw error
        }
    }

    /// Atomically checks and changes the generation after its configurable injected wait.
    func compareExchange(for identity: OAuthTokenIdentity, expectedGeneration: UUID?,
                         replacement: OAuthStoredToken?, now: Date) async throws -> Bool {
        let clock = ContinuousClock(), start = clock.now
        exchanges += 1
        do {
            if delay > .zero { try await clock.sleep(for: delay) }
            let accepted = identity == self.identity && record?.generation == expectedGeneration
            if accepted { record = replacement } else { conflicts += 1 }
            let terminal = clock.now
            statistics.record(start.duration(to: terminal), workload: .oauthStorageCAS, outcome: accepted ? .success : .failure)
            return accepted
        } catch {
            let terminal = clock.now
            statistics.record(start.duration(to: terminal), workload: .oauthStorageCAS,
                outcome: error is CancellationError ? .cancelled : .failure)
            throw error
        }
    }

    /// Applies a competing owner's authoritative generation while the stale refresh is held.
    func replaceExternally() throws {
        guard record != nil else { throw LoadFailure.unexpectedResponse }
        record = try OAuthStoredToken(response: oauthTimingResponse("synthetic-winner"), issuedAt: Date(timeIntervalSince1970: 0))
    }

    /// Reads correctness evidence without adding diagnostic calls to measured load populations.
    func inspect() -> OAuthStoredToken? { record }

    /// Returns exact protocol-call and retained-record receipts without measuring diagnostics.
    func snapshot() -> (loads: Int, exchanges: Int, conflicts: Int, records: Int) {
        (loads, exchanges, conflicts, record == nil ? 0 : 1)
    }

    /// Releases the caller-owned record after all coordinator operations have joined.
    func close() { record = nil }
}

/// Injected network policy with barrier-held refreshes and independently counted active calls.
private actor OAuthTimingBackend {
    let held: Bool
    let delay: Duration
    let statistics: RunStatistics
    let gate = OAuthTimingGate()
    let entered = OAuthTimingGate()
    var refreshes = 0, revocations = 0, active = 0

    /// Creates idle backend policy without starting a task or opening a connection.
    init(held: Bool, delay: Duration, statistics: RunStatistics) {
        self.held = held; self.delay = delay; self.statistics = statistics
    }

    /// Performs one cancellable injected refresh exchange, never replaying it for joined readers.
    func refresh() async throws -> OAuthTokenResponse {
        let clock = ContinuousClock(), start = clock.now
        refreshes += 1; active += 1
        defer { active -= 1 }
        await entered.open()
        do {
            if held { try await gate.wait() }
            if delay > .zero { try await clock.sleep(for: delay) }
            let response = try oauthTimingResponse("synthetic-rotated")
            let terminal = clock.now
            statistics.record(start.duration(to: terminal), workload: .oauthRefreshIO, outcome: .success)
            return response
        } catch {
            let terminal = clock.now
            statistics.record(start.duration(to: terminal), workload: .oauthRefreshIO,
                outcome: error is CancellationError ? .cancelled : .failure)
            throw error
        }
    }

    /// Performs one explicit injected revocation after local durable removal has been checked.
    func revoke() async throws {
        let clock = ContinuousClock(), start = clock.now
        revocations += 1; active += 1
        defer { active -= 1 }
        do {
            if delay > .zero { try await clock.sleep(for: delay) }
            let terminal = clock.now
            statistics.record(start.duration(to: terminal), workload: .oauthRevokeIO, outcome: .success)
        } catch {
            let terminal = clock.now
            statistics.record(start.duration(to: terminal), workload: .oauthRevokeIO,
                outcome: error is CancellationError ? .cancelled : .failure)
            throw error
        }
    }

    /// Waits on the exact refresh-entry barrier without a wall-clock scheduling assumption.
    func waitForRefreshEntry() async { try? await entered.wait() }

    /// Allows a held exchange to finish after admission and competing-write checks.
    func release() async { await gate.open() }

    /// Reports cumulative exchanges and exact active backend/barrier ownership.
    func snapshot() async -> (refreshes: Int, revocations: Int, active: Int, waiters: Int) {
        (refreshes, revocations, active, await gate.count())
    }
}

/// An explicit cancellation-cooperative barrier with bounded callers owned by the current cohort.
private actor OAuthTimingGate {
    var opened = false
    var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    /// Suspends until release or this particular task's cancellation, resuming exactly once.
    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if opened { continuation.resume() }
                else { waiters[id] = continuation }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    /// Releases all current and future callers without creating a background task.
    func open() {
        opened = true
        let current = waiters.values
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }

    /// Removes exactly one canceled task's retained continuation.
    func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }

    /// Exposes retained barrier continuations as independent cleanup evidence.
    func count() -> Int { waiters.count }
}

/// Creates a bounded synthetic response that is never serialized into the timing report.
private func oauthTimingResponse(_ access: String, lifetime: Int = 3_600) throws -> OAuthTokenResponse {
    try OAuthTokenResponse(accessToken: BearerToken(access), refreshToken: OAuthRefreshToken("synthetic-refresh"),
        expiresIn: lifetime, scopes: ["identify"])
}
