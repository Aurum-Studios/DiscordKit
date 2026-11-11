// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/ServiceTimingRunner.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordCertifiedDevices
import DiscordCommerce
import DiscordCore
import DiscordGameServices
import DiscordHTTP
import DiscordModels
import DiscordSocial
import DiscordTransport
import Foundation

/// Closed public service compositions; all providers are private injected fixtures.
enum ServiceTimingScenario: String, CaseIterable, Codable, Sendable {
    case socialProfile = "service.socialProfile"
    case socialSnapshot = "service.socialSnapshot"
    case socialRejected = "service.socialRejected"
    case socialCancelled = "service.socialCancelled"
    case gameMembers = "service.gameMembers"
    case gameSnapshot = "service.gameSnapshot"
    case gameFailure = "service.gameFailure"
    case commerceVerify = "service.commerceVerify"
    case commerceRejected = "service.commerceRejected"
    case commerceCancelled = "service.commerceCancelled"
    case devicesPublish = "service.devicesPublish"
    case devicesRejected = "service.devicesRejected"
    case devicesCancelled = "service.devicesCancelled"
}

/// Complete terminal populations and independent post-join service ownership receipts.
struct ServiceTimingReport: Codable, Sendable {
    let scenario: String
    let requests: Int
    let concurrency: Int
    let clockDomain: String
    let counts: BenchmarkCounts
    let metrics: [BenchmarkMetric]
    let durationNanoseconds: UInt64
    let cleanup: BenchmarkCleanup
    let backendExecutions: Int
    let snapshotApplications: Int
    let validatedResults: Int
    let droppedMembers: Int
    let observedBodies: Int
    let notes: [String]
}

/// External public-call wrappers preserve service behavior without duplicating REST/RPC observations.
struct ServiceTimingRunner: Sendable {
    /// Runs finite waves of independently owned service attempts and joins every operation and body.
    /// - Parameters:
    ///   - scenario: Fixed implemented orchestration, snapshot, rejection, failure or cancellation script.
    ///   - requests: Measured attempts in 1...100,000; cancellation stops new waves.
    ///   - concurrency: Independent simultaneous fixtures in 1...64, no greater than requests.
    ///   - delay: Explicit injected provider/body wait in zero through one second.
    /// - Returns: One primary terminal observation per admitted attempt, with exact empty cleanup.
    /// - Throws: Invalid limits, setup failure or an independently detected result/ownership mismatch.
    func run(scenario: ServiceTimingScenario, requests: Int = 8, concurrency: Int = 1,
             delay: Duration = .zero) async throws -> ServiceTimingReport {
        guard (1...100_000).contains(requests), (1...64).contains(concurrency), concurrency <= requests,
              delay >= .zero, delay <= .seconds(1) else { throw LoadFailure.invalidArguments }
        let statistics = try RunStatistics(workloads: [.serviceOperation, .serviceBackend, .serviceValidation, .serviceCleanup])
        let clock = ContinuousClock(), start = clock.now
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        var completed = 0, calls = 0, snapshots = 0, validated = 0, dropped = 0, bodies = 0, owners = 0
        var invalid = false
        for wave in stride(from: 0, to: requests, by: concurrency) {
            if Task.isCancelled { break }
            try await withThrowingTaskGroup(of: ServiceTimingReceipt.self) { group in
                for _ in wave..<min(requests, wave + concurrency) {
                    group.addTask { try await serviceTimingAttempt(scenario, delay: delay, statistics: statistics) }
                }
                for try await receipt in group {
                    completed += 1; outcomes[receipt.outcome, default: 0] += 1
                    calls += receipt.backendExecutions; snapshots += receipt.snapshotApplications
                    validated += receipt.validatedResults; dropped += receipt.droppedMembers
                    bodies += receipt.observedBodies; owners += receipt.remainingOwners
                    if receipt.remainingOwners != 0 || (!Task.isCancelled && !receipt.valid) { invalid = true }
                }
            }
        }
        guard !invalid else { throw ServiceTimingFailure.integrity }
        return ServiceTimingReport(scenario: scenario.rawValue, requests: requests, concurrency: concurrency,
            clockDomain: statistics.clockDomain,
            counts: .init(offered: UInt64(completed), admitted: UInt64(completed), completed: UInt64(completed),
                outcomes: outcomes, deadlineMisses: 0), metrics: statistics.metrics(),
            durationNanoseconds: try BenchmarkTime.nanoseconds(duration: start.duration(to: clock.now)),
            cleanup: .init(completed: true, remainingOwners: UInt64(owners)), backendExecutions: calls,
            snapshotApplications: snapshots, validatedResults: validated, droppedMembers: dropped, observedBodies: bodies,
            notes: [
                "Injected providers and HTTP body fixtures only; no desktop, browser, network, purchase or authorization operation occurs.",
                "service.operation wraps the selected implemented public operation through its returned result/error and existing joins; fixture setup, correctness checks, diagnostic snapshots and explicit close are outside it.",
                "service.backend starts after private executor actor admission and covers the injected provider/executor/body-read service including configured wait and cooperative cancellation; it overlaps the primary and does not measure preceding actor residence or duplicate REST/RPC timing.",
                "service.validation wraps only externally visible local snapshot application or snapshot-based descriptor reduction; internal service policy work remains inside service.operation and is not inferred by subtraction.",
                "service.cleanup wraps awaited public close and fixture release, stopping before exact ownership snapshots. Social providers remain caller owned; every outstanding task is joined before close receipts are read.",
                "Game membership scripts retain a silent dropped member and acknowledged progress on second-chunk failure; no mutation is sent outside the injected executor or replayed.",
                "Cancellation scripts park at an explicit injected provider/body boundary, cancel the owning caller and await all structured cleanup without wall-clock scheduling assumptions.",
                "Counts include every started attempt with its actual terminal outcome. Overall duration includes setup, orchestration, diagnostic validation and cleanup; child percentiles cannot be added or subtracted."
            ])
    }
}

/// Bounded internal correctness and ownership receipts, sampled only after terminal timestamps.
private struct ServiceTimingReceipt: Sendable {
    let outcome: BenchmarkOutcome
    let valid: Bool
    let backendExecutions: Int
    var snapshotApplications = 0
    var validatedResults = 0
    var droppedMembers = 0
    var observedBodies = 0
    let remainingOwners: Int
}

/// Safe local fixture failures never include payloads or identifiers.
private enum ServiceTimingFailure: Error, Equatable { case backend, integrity }

/// Original public Social return values retained for correctness checks after the measured call.
private enum ServiceTimingSocialValue: Sendable { case profile(User), snapshot(SocialApplyOutcome) }

/// Chooses the implemented public product while keeping private fixture ownership independent.
/// - Parameters:
///   - scenario: Finite operation class selected before fixture construction.
///   - delay: Validated injected backend wait.
///   - statistics: Shared bounded full-population collector.
/// - Returns: Independently checked result and actual post-cleanup ownership.
/// - Throws: Fixture setup errors; expected operation failures become terminal outcomes.
private func serviceTimingAttempt(_ scenario: ServiceTimingScenario, delay: Duration,
                                 statistics: RunStatistics) async throws -> ServiceTimingReceipt {
    let backend = ServiceTimingBackend(delay: delay, statistics: statistics)
    switch scenario {
    case .socialProfile, .socialSnapshot, .socialRejected, .socialCancelled:
        return try await serviceTimingSocial(scenario, backend: backend, statistics: statistics)
    case .gameMembers, .gameSnapshot, .gameFailure:
        return try await serviceTimingGame(scenario, backend: backend, statistics: statistics)
    case .commerceVerify, .commerceRejected, .commerceCancelled:
        return try await serviceTimingCommerce(scenario, backend: backend, statistics: statistics)
    case .devicesPublish, .devicesRejected, .devicesCancelled:
        return try await serviceTimingDevices(scenario, backend: backend, statistics: statistics)
    }
}

/// Measures a single returned result/error before any correctness assertion or receipt collection.
/// - Parameters:
///   - workload: Fixed preallocated metric identity.
///   - statistics: Collector called only after the terminal timestamp.
///   - operation: Public operation with its own cooperative ownership behavior.
/// - Returns: Original success/error for assertions outside the timer.
private func serviceTimingMeasure<T: Sendable>(_ workload: BenchmarkWorkload, statistics: RunStatistics,
    operation: @Sendable () async throws -> T) async -> Result<T, any Error> {
    let clock = ContinuousClock(), start = clock.now
    let result: Result<T, any Error>
    do { result = .success(try await operation()) } catch { result = .failure(error) }
    let end = clock.now
    statistics.record(start.duration(to: end), workload: workload, outcome: serviceTimingOutcome(result))
    return result
}

/// Cancels only after the selected injected wait is entered, joining the task on all parent exits.
/// - Parameters:
///   - cancelled: Whether this script deliberately cancels after backend entry.
///   - backend: Private entry/completion gate, also unblocked if the operation fails before entry.
///   - statistics: Bounded primary collector.
///   - operation: Selected public service call; setup and diagnostic assertions are excluded.
/// - Returns: Joined actual terminal value/error.
private func serviceTimingOperation<T: Sendable>(cancelled: Bool = false, backend: ServiceTimingBackend,
    statistics: RunStatistics, operation: @escaping @Sendable () async throws -> T) async -> Result<T, any Error> {
    guard cancelled else { return await serviceTimingMeasure(.serviceOperation, statistics: statistics, operation: operation) }
    let task = Task {
        let result = await serviceTimingMeasure(.serviceOperation, statistics: statistics, operation: operation)
        await backend.finished()
        return result
    }
    return await withTaskCancellationHandler {
        await backend.waitForEntryOrCompletion()
        task.cancel()
        return await task.value
    } onCancel: { task.cancel() }
}

/// Maps only closed actual error classes, keeping policy refusals distinct from dependency failures.
/// - Parameter result: Original public operation result.
/// - Returns: A terminal population without free-form error labels.
private func serviceTimingOutcome<T>(_ result: Result<T, any Error>) -> BenchmarkOutcome {
    switch result {
    case .success: return .success
    case .failure(let error):
        if error is CancellationError { return .cancelled }
        if let progress = error as? BulkLobbyMembersFailure, progress.underlying is CancellationError { return .cancelled }
        if error is EntitlementVerificationError { return .rejected }
        if let error = error as? SocialFailure, error == .accountMismatch { return .rejected }
        if let error = error as? CertifiedDeviceFailure, error == .duplicateDevice { return .rejected }
        return .failure
    }
}

/// Reads actual provider identity, applies an authorized local snapshot, or retains exact rejection/cancellation.
/// - Parameters:
///   - scenario: One of the four Social scripts.
///   - backend: Private provider wait and activity receipts.
///   - statistics: Bounded primary/validation/cleanup collectors.
/// - Returns: Exact user/snapshot/error checks and empty Social admission and relationship receipts.
/// - Throws: Fixture model or public client setup errors.
private func serviceTimingSocial(_ scenario: ServiceTimingScenario, backend: ServiceTimingBackend,
                                statistics: RunStatistics) async throws -> ServiceTimingReceipt {
    let account: UInt64 = scenario == .socialRejected ? 9 : 2
    let user = try User(data: Data("{\"id\":\"\(account)\",\"username\":\"fixture\",\"discriminator\":\"0\",\"global_name\":null,\"avatar\":null}".utf8))
    let provider = ServiceTimingProfile(backend: backend, user: user, cancelled: scenario == .socialCancelled)
    let client = try SocialClient(clock: ContinuousClock(), profile: provider,
        stateLimits: SocialStateLimits(), maximumOperations: 1)
    let scope = SocialScope(applicationID: .init(rawValue: 1), accountID: .init(rawValue: 2), consentGeneration: 1)
    try await client.activate(scope: scope, grantedScopes: ["identify"])
    let snapshot = SocialStateSnapshot(scope: scope, generation: 1, sequence: 1,
        users: [SocialUser(id: .init(rawValue: 3), username: "fixture")],
        relationships: [SocialRelationship(userID: .init(rawValue: 3), kind: .friend)])
    let result: Result<ServiceTimingSocialValue, any Error> = await serviceTimingOperation(cancelled: scenario == .socialCancelled,
        backend: backend, statistics: statistics) {
            if scenario == .socialSnapshot {
                let applied = await serviceTimingMeasure(.serviceValidation, statistics: statistics) {
                    try await client.synchronize(snapshot)
                }
                return .snapshot(try applied.get())
            }
            return .profile(try await client.currentProfile())
        }
    // Result values are deliberately checked after service.operation's terminal timestamp.
    var valid = false, snapshots = 0, validated = 0
    switch result {
    case .success(.snapshot(let applied)):
        if scenario == .socialSnapshot {
            let view = try await client.relationshipView()
            valid = applied == .applied && view.scope == scope && view.users.map(\.id) == [UserID(rawValue: 3)]
                && view.users(in: .friend).count == 1 && view.sequence == 1
            snapshots = valid ? 1 : 0
        }
    case .success(.profile(let value)):
        valid = scenario == .socialProfile && value.id == UserID(rawValue: 2)
        validated = valid ? 1 : 0
    case .failure(let error):
        valid = scenario == .socialRejected ? error as? SocialFailure == .accountMismatch
            : scenario == .socialCancelled && error is CancellationError
    }
    _ = await serviceTimingMeasure(.serviceCleanup, statistics: statistics) { await client.close(); await backend.close() }
    let state = await client.snapshot(), view = try await client.relationshipView(), receipt = await backend.receipt()
    let owners = state.inFlightOperations + (state.authorized ? 1 : 0) + (state.closed ? 0 : 1)
        + view.users.count + view.relationships.count + receipt.owners
    valid = valid && receipt.checked && receipt.executions == (scenario == .socialSnapshot ? 0 : 1)
    return .init(outcome: serviceTimingOutcome(result), valid: valid, backendExecutions: receipt.executions,
        snapshotApplications: snapshots, validatedResults: validated, remainingOwners: owners)
}

/// Preserves chunk order, silent drop accounting and partial progress, or measures snapshot descriptor reduction.
/// - Parameters:
///   - scenario: Membership success/failure or local profile snapshot comparison.
///   - backend: Private executor wait and execution receipts.
///   - statistics: Primary/validation/cleanup collectors.
/// - Returns: Independently matched membership or descriptor results and exact released backend ownership.
/// - Throws: Invalid synthetic model, member request or plan construction.
private func serviceTimingGame(_ scenario: ServiceTimingScenario, backend: ServiceTimingBackend,
                              statistics: RunStatistics) async throws -> ServiceTimingReceipt {
    var valid = false, dropped = 0, snapshots = 0
    let outcome: BenchmarkOutcome
    if scenario == .gameSnapshot {
        let profile = try ApplicationIdentityProfile(data: Data(#"{"username":"fixture","metadata":null,"data":{}}"#.utf8))
        let result = await serviceTimingOperation(backend: backend, statistics: statistics) {
            let reduced = await serviceTimingMeasure(.serviceValidation, statistics: statistics) {
                let equal = try GameServiceOperations.profileIfChanged(applicationID: .init(rawValue: 1),
                    userID: .init(rawValue: 2), providerIssuedUserID: "fixture", current: profile,
                    request: .init(username: .value("fixture")))
                let changed = try GameServiceOperations.profileIfChanged(applicationID: .init(rawValue: 1),
                    userID: .init(rawValue: 2), providerIssuedUserID: "fixture", current: profile,
                    request: .init(username: .value("updated")))
                return (equal, changed)
            }
            return try reduced.get()
        }
        outcome = serviceTimingOutcome(result)
        if case .success(let descriptors) = result, let changed = descriptors.1 {
            valid = descriptors.0 == nil && changed.authentication == .bot && changed.retrySafety == .unsafe
                && changed.successStatuses == [201, 204]
                && changed.body?.storedBodyBytes == Data(#"{"username":"updated"}"#.utf8)
            snapshots = valid ? 1 : 0
        }
    } else {
        let members = try (1...26).map { try BulkLobbyMemberRequest(id: .init(rawValue: UInt64($0))) }
        let first = try (1...24).map { try LobbyMember(data: Data("{\"id\":\"\($0)\",\"flags\":0}".utf8)) }
        let last = try LobbyMember(data: Data(#"{"id":"26","flags":0}"#.utf8))
        let plan = try GameServiceOperations.linkedLobbyMembers(lobbyID: .init(rawValue: 1), members: members)
        let result = await serviceTimingOperation(backend: backend, statistics: statistics) {
            try await plan.execute(context: TransportContext(clock: ContinuousClock())) { endpoint in
                await backend.check(endpoint.authentication == .bot && endpoint.path == ["lobbies", "1", "members", "bulk"])
                return try await backend.call { ordinal in
                    if ordinal == 2 && scenario == .gameFailure { throw ServiceTimingFailure.backend }
                    return ordinal == 1 ? first : [last]
                }
            }
        }
        outcome = serviceTimingOutcome(result)
        switch result {
        case .success(let value):
            valid = scenario == .gameMembers && value.upserted.map(\.id) == (Array(1...24) + [26]).map { UserID(rawValue: UInt64($0)) }
                && value.dropped == [UserID(rawValue: 25)] && value.removed.isEmpty
            dropped = value.dropped.count
        case .failure(let error):
            if let failure = error as? BulkLobbyMembersFailure {
                valid = scenario == .gameFailure && failure.upserted.map(\.id) == (1...24).map { UserID(rawValue: UInt64($0)) }
                    && failure.dropped == [UserID(rawValue: 25)] && failure.attempted == [UserID(rawValue: 26)]
                    && failure.unattempted.isEmpty && failure.removed.isEmpty
                    && failure.underlying as? ServiceTimingFailure == .backend
                dropped = failure.dropped.count
            }
        }
    }
    _ = await serviceTimingMeasure(.serviceCleanup, statistics: statistics) { await backend.close() }
    let receipt = await backend.receipt()
    valid = valid && receipt.checked && receipt.executions == (scenario == .gameSnapshot ? 0 : 2)
    return .init(outcome: outcome, valid: valid, backendExecutions: receipt.executions,
        snapshotApplications: snapshots, validatedResults: valid && outcome == .success ? 1 : 0,
        droppedMembers: dropped, remainingOwners: receipt.owners)
}

/// Executes authoritative-read verification only; no purchase, consume or entitlement grant is performed.
/// - Parameters:
///   - scenario: Verified, mismatched-owner or joined-cancellation script.
///   - backend: Private authoritative-read fixture with explicit wait receipts.
///   - statistics: Primary/backend/cleanup collectors.
/// - Returns: Exact policy/error and descriptor checks with joined zero activity.
/// - Throws: Synthetic timestamp or entitlement model construction failures.
private func serviceTimingCommerce(_ scenario: ServiceTimingScenario, backend: ServiceTimingBackend,
                                  statistics: RunStatistics) async throws -> ServiceTimingReceipt {
    let now = try DiscordTimestamp(rawValue: "2026-10-17T12:00:00Z")
    let owner = scenario == .commerceRejected ? "9" : "4"
    let entitlement = try Entitlement(data: Data("{\"id\":\"1\",\"application_id\":\"2\",\"sku_id\":\"3\",\"user_id\":\"\(owner)\",\"type\":1,\"deleted\":false,\"starts_at\":null,\"ends_at\":null,\"consumed\":false}".utf8))
    let requirement = EntitlementRequirement(applicationID: .init(rawValue: 2), skuID: .init(rawValue: 3),
        owner: .user(.init(rawValue: 4)))
    let result = await serviceTimingOperation(cancelled: scenario == .commerceCancelled, backend: backend, statistics: statistics) {
        try await EntitlementVerification.verify(entitlementID: .init(rawValue: 1), requirement: requirement,
            now: { now }, fetch: { endpoint in
                await backend.check(endpoint.authentication == .botOrBearer && endpoint.readPolicy == nil
                    && endpoint.path == ["applications", "2", "entitlements", "1"])
                return try await backend.call(cancelled: scenario == .commerceCancelled) { _ in entitlement }
            })
    }
    var valid = false, validated = 0
    switch result {
    case .success(let value):
        valid = scenario == .commerceVerify && value.id == .init(rawValue: 1)
            && value.applicationID == .init(rawValue: 2) && value.skuID == .init(rawValue: 3)
            && value.userID == .value(.init(rawValue: 4)) && !value.deleted
        validated = valid ? 1 : 0
    case .failure(let error):
        valid = scenario == .commerceRejected ? error as? EntitlementVerificationError == .mismatchedGrant
            : scenario == .commerceCancelled && error is CancellationError
    }
    _ = await serviceTimingMeasure(.serviceCleanup, statistics: statistics) { await backend.close() }
    let receipt = await backend.receipt()
    return .init(outcome: serviceTimingOutcome(result), valid: valid && receipt.checked && receipt.executions == 1,
        backendExecutions: receipt.executions, validatedResults: validated, remainingOwners: receipt.owners)
}

/// Publishes an injected complete device snapshot and proves body cleanup, including cancellation mid-read.
/// - Parameters:
///   - scenario: Successful publication, pre-I/O duplicate rejection or cancelled response read.
///   - backend: Private body-read wait and cancellation gate.
///   - statistics: Primary/backend/cleanup collectors.
/// - Returns: Independent request envelope, terminal error and exactly-once body-release evidence.
/// - Throws: Synthetic device metadata or publisher configuration errors.
private func serviceTimingDevices(_ scenario: ServiceTimingScenario, backend: ServiceTimingBackend,
                                 statistics: RunStatistics) async throws -> ServiceTimingReceipt {
    let product = try CertifiedDeviceProduct(name: "fixture", url: URL(string: "https://example.invalid/device")!)
    let device = try CertifiedDevice(type: .audioInput, id: "fixture", vendor: product, model: product)
    let devices = scenario == .devicesRejected ? [device, device] : [device]
    let transport = ServiceTimingDeviceTransport(backend: backend, cancelled: scenario == .devicesCancelled)
    let publisher = try CertifiedDeviceHTTPPublisher(clientID: "1", port: 6463, transport: transport,
        maximumDevices: 2, maximumRequestBytes: 4096, maximumResponseBytes: 4096)
    let result: Result<Void, any Error> = await serviceTimingOperation(cancelled: scenario == .devicesCancelled,
        backend: backend, statistics: statistics) {
            try await publisher.publish(devices, nonce: "fixture", context: TransportContext(clock: ContinuousClock()))
        }
    var valid = false
    switch result {
    case .success: valid = scenario == .devicesPublish
    case .failure(let error):
        valid = scenario == .devicesRejected ? error as? CertifiedDeviceFailure == .duplicateDevice
            : scenario == .devicesCancelled && error is CancellationError
    }
    _ = await serviceTimingMeasure(.serviceCleanup, statistics: statistics) { await publisher.close(); await transport.close(); await backend.close() }
    let receipt = await backend.receipt(), wire = await transport.receipt()
    let expected = scenario == .devicesRejected ? 0 : 1
    valid = valid && receipt.checked && wire.valid && wire.executions == expected && wire.created == expected && wire.released == expected
        && receipt.executions == expected
    // A closed-operation probe establishes public admission remains fenced; it performs no I/O.
    do { try await publisher.publish([], nonce: "closed", context: TransportContext(clock: ContinuousClock())); valid = false }
    catch { if !Task.isCancelled { valid = valid && error as? CertifiedDeviceFailure == .closed } }
    return .init(outcome: serviceTimingOutcome(result), valid: valid, backendExecutions: receipt.executions,
        validatedResults: scenario == .devicesPublish && valid ? 1 : 0, observedBodies: wire.created,
        remainingOwners: receipt.owners + wire.owners)
}

/// Narrow provider implementation delegates actual client orchestration to the production Social actor.
private struct ServiceTimingProfile: SocialProfileProvider {
    let backend: ServiceTimingBackend
    let user: User
    let cancelled: Bool
    let profileRequirements = SocialProviderRequirements(scopes: ["identify"])
    /// Applies the caller's cancellation/deadline before and after an injected provider call.
    /// - Parameter context: Production client's actual transport context.
    /// - Returns: Complete preallocated user fixture.
    /// - Throws: Cooperative cancellation/deadline from the production context or private wait.
    func currentProfile(context: TransportContext<ContinuousClock>) async throws -> User {
        try context.check()
        let result = try await backend.call(cancelled: cancelled) { _ in user }
        try context.check()
        return result
    }
}

/// One bounded executor and cancellation continuation per fixture; entry gates use no timing sleeps.
private actor ServiceTimingBackend {
    let delay: Duration
    let statistics: RunStatistics
    private var active = 0, executions = 0, peakActive = 0
    private var closed = false, checked = true, completed = false
    private var entered: CheckedContinuation<Void, Never>?
    private var parked: CheckedContinuation<Void, any Error>?

    /// Stores validated fixture parameters without launching work or observing clocks.
    /// - Parameters:
    ///   - delay: Explicit local service wait, excluded from setup.
    ///   - statistics: Preallocated child collector.
    init(delay: Duration, statistics: RunStatistics) { self.delay = delay; self.statistics = statistics }

    /// Wraps one actual injected executor call, including its finite wait and terminal error.
    /// - Parameters:
    ///   - cancelled: Park until the owning caller cancels instead of using a wall-clock delay.
    ///   - operation: Returns the actual local result for this execution ordinal.
    /// - Returns: Provider/executor fixture result.
    /// - Throws: Cancellation, fixture dependency error, or attempted use after explicit close.
    func call<T: Sendable>(cancelled: Bool = false,
        operation: @Sendable (Int) async throws -> T) async throws -> T {
        guard !closed else { throw ServiceTimingFailure.integrity }
        active += 1; executions += 1; peakActive = max(peakActive, active); let ordinal = executions
        entered?.resume(); entered = nil
        defer { active -= 1 }
        let result = await serviceTimingMeasure(.serviceBackend, statistics: statistics) {
            if cancelled { try await self.hold() }
            else if self.delay > .zero { try await ContinuousClock().sleep(for: self.delay) }
            try Task.checkCancellation()
            return try await operation(ordinal)
        }
        return try result.get()
    }

    /// Parks exactly one cooperative injected wait and releases it on actual task cancellation.
    /// - Throws: Cancellation before or during registration; no timer determines correctness.
    private func hold() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { parked = $0 }
        } onCancel: { Task { await self.cancelWait() } }
    }
    /// Resumes and removes the actual owned provider continuation after cancellation.
    private func cancelWait() { parked?.resume(throwing: CancellationError()); parked = nil }
    /// Waits for a provider entry or an early public-operation terminal result.
    func waitForEntryOrCompletion() async {
        if executions > 0 || completed { return }
        await withCheckedContinuation { entered = $0 }
    }
    /// Releases the entry gate when cancellation prevents a public call reaching its provider.
    func finished() { completed = true; entered?.resume(); entered = nil }
    /// Retains only a numeric descriptor-conformance receipt, never raw descriptors or payloads.
    /// - Parameter value: Independently expected fixed endpoint properties.
    func check(_ value: Bool) { checked = checked && value }
    /// Fences fixture reuse after the owning operation joins; this is caller-owned provider cleanup.
    func close() { closed = true }
    /// Reads actual activity and pending continuation ownership after all public operation joins.
    /// - Returns: Exact execution count, fixed descriptor validation and unjoined resource count.
    func receipt() -> (executions: Int, checked: Bool, owners: Int) {
        (executions, checked && peakActive <= 1,
            active + (parked == nil ? 0 : 1) + (entered == nil ? 0 : 1) + (closed ? 0 : 1))
    }
}

/// In-memory HTTP peer owns one finite response body and stores one request for post-timer checks.
private actor ServiceTimingDeviceTransport: HTTPTransport {
    let backend: ServiceTimingBackend
    let cancelled: Bool
    private var requests: [HTTPRequest] = []
    private var requestBytes = Data()
    private var created = 0, released = 0
    private var emitted = false, closed = false

    /// Stores fixture authorities without opening any desktop or network connection.
    /// - Parameters:
    ///   - backend: Private response-body wait and cancellation gate.
    ///   - cancelled: Deliberately hold the body's first read until cancellation.
    init(backend: ServiceTimingBackend, cancelled: Bool) { self.backend = backend; self.cancelled = cancelled }

    /// Consumes the real public publisher request and transfers an exactly-once tracked response body.
    /// - Parameters:
    ///   - request: Publisher-created POST/body; retained only until this attempt is validated.
    ///   - context: Actual production cancellation/deadline authority.
    /// - Returns: Fixed correlated v1 acknowledgement with injected body-read service.
    /// - Throws: Context, body or local fixture bound failures.
    func execute<C: Clock>(_ request: HTTPRequest, context: TransportContext<C>) async throws -> HTTPResponse where C.Duration == Duration {
        try context.check()
        guard requests.isEmpty, !closed else { throw ServiceTimingFailure.integrity }
        requests.append(request)
        if let body = request.body {
            for try await chunk in body {
                guard requestBytes.count + chunk.count <= 4096 else { throw ServiceTimingFailure.integrity }
                requestBytes.append(chunk)
            }
        }
        created += 1
        let body = try BodyStream(maximumChunkBytes: 4096, next: { try await self.next() }, close: { await self.release() })
        return HTTPResponse(status: 200, body: body)
    }
    /// Emits one response chunk through the actual injected wait, then EOF.
    /// - Returns: Correlated acknowledgement once, or nil on a later read.
    /// - Throws: Cooperative cancellation from the body-owned provider wait.
    private func next() async throws -> Data? {
        guard !emitted else { return nil }
        emitted = true
        return try await backend.call(cancelled: cancelled) { _ in
            Data(#"{"cmd":"SET_CERTIFIED_DEVICES","nonce":"fixture","evt":null,"data":null}"#.utf8)
        }
    }
    /// Records the BodyStream's actual exactly-once cleanup callback.
    private func release() { released += 1 }
    /// Closes retained request bodies after production cleanup and fences further fixture admission.
    func close() async { closed = true; for request in requests { await request.body?.close() } }
    /// Validates the real request after timing and reports resource ownership from actual release counters.
    /// - Returns: Exact transferred-body counts, fixed request conformance and retained owner count.
    func receipt() -> (executions: Int, created: Int, released: Int, valid: Bool, owners: Int) {
        var valid = requests.isEmpty
        if let request = requests.first, case .object(let object) = try? JSONValue.parse(requestBytes),
           case .object(let arguments) = object["args"], case .array(let devices) = arguments["devices"],
           case .object(let device) = devices.first {
            valid = request.method == "POST" && request.url.absoluteString == "http://127.0.0.1:6463/rpc?v=1&client_id=1"
                && request.headers.count == 1 && request.headers[0].value == "application/json"
                && object["cmd"] == .string("SET_CERTIFIED_DEVICES") && object["nonce"] == .string("fixture")
                && devices.count == 1 && device["id"] == .string("fixture") && device["type"] == .string("audioinput")
        }
        return (requests.count, created, released, valid, created - released + (closed ? 0 : 1))
    }
}
