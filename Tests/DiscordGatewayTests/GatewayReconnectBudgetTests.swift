// File: Tests/DiscordGatewayTests/GatewayReconnectBudgetTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCore
import DiscordTransport
import DiscordTestSupport
import Foundation
import Synchronization
import Testing
@testable import DiscordGateway

/// Exercises reconnect episodes through real shard supervision and finite offline adapters.
@Suite("Gateway reconnect budget episodes", .timeLimit(.minutes(1)))
struct GatewayReconnectBudgetTests {
    /// Preserves omitted-argument compatibility and rejects health thresholds that cannot certify uptime.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func configurationCompatibilityAndValidation() throws {
        let defaults = try GatewayShardConfiguration()
        #expect(defaults.maximumReconnectAttempts == 5)
        #expect(defaults.reconnectBudgetPolicy == .totalRun)
        let policy = GatewayReconnectBudgetPolicy.afterHealthySession(
            minimumDuration: .seconds(2), minimumScheduledHeartbeatACKs: 2)
        #expect(try GatewayShardConfiguration(reconnectBudgetPolicy: policy).reconnectBudgetPolicy == policy)
        #expect(try GatewayShardConfiguration(maximumReconnectAttempts: 0,
            reconnectBudgetPolicy: policy).maximumReconnectAttempts == 0)
        for duration in [Duration.zero, .nanoseconds(-1)] {
            #expect(throws: GatewayFailure.invalidConfiguration) {
                try GatewayShardConfiguration(reconnectBudgetPolicy: .afterHealthySession(
                    minimumDuration: duration, minimumScheduledHeartbeatACKs: 1))
            }
        }
        for acknowledgements in [0, -1] {
            #expect(throws: GatewayFailure.invalidConfiguration) {
                try GatewayShardConfiguration(reconnectBudgetPolicy: .afterHealthySession(
                    minimumDuration: .seconds(1), minimumScheduledHeartbeatACKs: acknowledgements))
            }
        }
    }

    /// READY/RESUMED never replenish the default total-run limit, including custom positive and zero bounds.
    /// - Parameter budget: Replacements permitted; five intentionally uses the initializer's omitted default.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [0, 1, 3, 5])
    func totalRunRemainsFinite(_ budget: Int) async throws {
        let sockets = (0...budget).map { _ in BudgetSocket() }
        let fixture = try BudgetFixture(sockets: sockets, retries: budget == 5 ? nil : budget, jitter: 0)
        try await fixture.withRun { run in
            for index in sockets.indices {
                try await fixture.ready(index)
                await sockets[index].enqueue(.text(#"{"op":7,"d":null}"#))
            }
            try await fixture.expectFailure(.retryLimitExceeded, run: run)
            #expect(await fixture.transport.connectionCount == budget + 1)
            #expect(await fixture.startup.remainingStarts() == 99)
            #expect(await sockets[0].count(opcode: 2) == 1)
            for socket in sockets.dropFirst() { #expect(await socket.count(opcode: 6) == 1) }
        }
    }

    /// Seven independently healthy resumed sessions exceed the old lifetime limit without spending Identify quota.
    /// Each replacement must use the base delay again, proving that recovery resets backoff as well as count.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func healthySessionsPermitMoreThanFiveRecoveries() async throws {
        let sockets = (0..<8).map { _ in BudgetSocket() }
        let fixture = try BudgetFixture(sockets: sockets, policy: .afterHealthySession(
            minimumDuration: .seconds(2), minimumScheduledHeartbeatACKs: 2))
        try await fixture.withRun { _ in
            for index in 0..<7 {
                try await fixture.ready(index)
                try await fixture.scheduledACK(index)
                try await fixture.scheduledACK(index)
                await sockets[index].enqueue(.text(#"{"op":7,"d":null}"#))
                try await fixture.advanceRetry(after: index)
            }
            try await fixture.ready(7)
            #expect(await fixture.transport.connectionCount == 8)
            #expect(await fixture.shard.snapshot().socketGeneration == 8)
            #expect(await fixture.startup.remainingStarts() == 99)
            #expect(await fixture.transport.urls.dropFirst().allSatisfy { $0.host == "resume.discord.gg" })
            for socket in sockets.dropFirst() { #expect(await socket.count(opcode: 6) == 1) }
        }
    }

    /// Rapid READY/RESUMED transitions cannot convert an unhealthy reconnect storm into unlimited attempts.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func briefReadyStormExhaustsEpisode() async throws {
        let sockets = [BudgetSocket(), BudgetSocket()]
        let fixture = try BudgetFixture(sockets: sockets, retries: 1, policy: .afterHealthySession(
            minimumDuration: .seconds(2), minimumScheduledHeartbeatACKs: 2))
        try await fixture.withRun { run in
            try await fixture.ready(0)
            await sockets[0].enqueue(.text(#"{"op":7,"d":null}"#))
            try await fixture.advanceRetry(after: 0)
            try await fixture.ready(1)
            await sockets[1].enqueue(.text(#"{"op":7,"d":null}"#))
            try await fixture.expectFailure(.retryLimitExceeded, run: run)
            #expect(await fixture.transport.connectionCount == 2)
        }
    }

    /// Partial ACK counts in two different generations cannot combine into one healthy-session certificate.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func healthObservationsStayWithinOneGeneration() async throws {
        let sockets = [BudgetSocket(), BudgetSocket()]
        let fixture = try BudgetFixture(sockets: sockets, retries: 1, policy: .afterHealthySession(
            minimumDuration: .seconds(1), minimumScheduledHeartbeatACKs: 2))
        try await fixture.withRun { run in
            try await fixture.ready(0)
            try await fixture.scheduledACK(0)
            await sockets[0].enqueue(.text(#"{"op":7,"d":null}"#))
            try await fixture.advanceRetry(after: 0)
            try await fixture.ready(1)
            try await fixture.scheduledACK(1)
            await sockets[1].enqueue(.text(#"{"op":7,"d":null}"#))
            try await fixture.expectFailure(.retryLimitExceeded, run: run)
            #expect(await fixture.transport.connectionCount == 2)
        }
    }

    /// A prior healthy certificate is consumed by its own recovery and cannot mask the next brief failed generation.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func previousHealthCannotCertifyFollowingStorm() async throws {
        let sockets = [BudgetSocket(), BudgetSocket()]
        let fixture = try BudgetFixture(sockets: sockets, retries: 1, policy: .afterHealthySession(
            minimumDuration: .seconds(2), minimumScheduledHeartbeatACKs: 2))
        try await fixture.withRun { run in
            try await fixture.ready(0)
            try await fixture.scheduledACK(0)
            try await fixture.scheduledACK(0)
            await sockets[0].enqueue(.text(#"{"op":7,"d":null}"#))
            try await fixture.advanceRetry(after: 0)
            try await fixture.ready(1)
            await sockets[1].enqueue(.text(#"{"op":7,"d":null}"#))
            try await fixture.expectFailure(.retryLimitExceeded, run: run)
            #expect(await fixture.transport.connectionCount == 2)
        }
    }

    /// Uses a nanosecond boundary after RESUMED, with one valid ACK, to separate elapsed time from READY alone.
    /// - Parameter exact: True tests the inclusive duration boundary; false stops one nanosecond before it.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true])
    func healthDurationBoundary(_ exact: Bool) async throws {
        let sockets = [BudgetSocket(), BudgetSocket(), BudgetSocket()]
        let fixture = try BudgetFixture(sockets: sockets, retries: 1, policy: .afterHealthySession(
            minimumDuration: .seconds(2), minimumScheduledHeartbeatACKs: 1))
        try await fixture.withRun { run in
            try await fixture.spendFirstRetry()
            try await fixture.scheduledACK(1)
            try fixture.clock.advance(by: exact ? .seconds(1) : .seconds(1) - .nanoseconds(1))
            await sockets[1].enqueue(.text(#"{"op":7,"d":null}"#))
            if exact {
                try await fixture.advanceRetry(after: 1)
                try await fixture.ready(2)
                #expect(await fixture.transport.connectionCount == 3)
            } else {
                try await fixture.expectFailure(.retryLimitExceeded, run: run)
                #expect(await fixture.transport.connectionCount == 2)
            }
        }
    }

    /// A certified healthy session cannot manufacture a replacement when the configured budget is zero.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func zeroRemainsZeroAfterHealth() async throws {
        let socket = BudgetSocket()
        let fixture = try BudgetFixture(sockets: [socket], retries: 0, policy: .afterHealthySession(
            minimumDuration: .seconds(2), minimumScheduledHeartbeatACKs: 2))
        try await fixture.withRun { run in
            try await fixture.ready(0)
            try await fixture.scheduledACK(0)
            try await fixture.scheduledACK(0)
            await socket.enqueue(.text(#"{"op":7,"d":null}"#))
            try await fixture.expectFailure(.retryLimitExceeded, run: run)
            #expect(await fixture.transport.connectionCount == 1)
        }
    }

    /// Exercises ACK shapes that cannot prove a confirmed, sole scheduled write after readiness.
    /// - Parameter sample: Independent missing, unsolicited, pre-ready, requested or ambiguous sample.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: BudgetInvalidHealthSample.allCases)
    func invalidACKObservationsCannotReset(_ sample: BudgetInvalidHealthSample) async throws {
        let heldWrite = TestBarrier()
        let interval = sample == .unsolicited || sample == .requestedOnly ? 3_600_000 : 1_000
        let second = BudgetSocket(heartbeatMilliseconds: interval,
            heldHeartbeats: sample == .earlyWrite || sample == .scheduledDuringRequested ? [1: heldWrite] : [:])
        let fixture = try BudgetFixture(sockets: [BudgetSocket(), second], retries: 1,
            policy: .afterHealthySession(minimumDuration: .seconds(1),
                minimumScheduledHeartbeatACKs: sample == .insufficient ? 2 : 1))
        try await fixture.withRun { run in
            try await fixture.spendFirstRetry(readySecond: sample != .preReady)
            switch sample {
            case .insufficient:
                try await fixture.scheduledACK(1)
            case .unsolicited:
                await second.enqueue(.text(#"{"op":11,"d":null}"#))
                await second.enqueue(.text(#"{"op":11,"d":null}"#))
                try await fixture.synchronize(1)
                try fixture.clock.advance(by: .seconds(1))
            case .preReady:
                try await fixture.scheduledACK(1)
                try await fixture.ready(1)
                // Post-ready duration is sufficient, but the only ACK preceded RESUMED.
                try fixture.clock.advance(by: .seconds(1))
            case .requestedOnly:
                for _ in 0..<2 {
                    await second.enqueue(.text(#"{"op":1,"d":null}"#))
                    await second.enqueue(.text(#"{"op":11,"d":null}"#))
                    try await fixture.synchronize(1)
                }
                try fixture.clock.advance(by: .seconds(1))
                #expect(await second.count(opcode: 1) == 2)
            case .earlyWrite:
                try fixture.clock.advance(by: .seconds(1))
                try await fixture.waitUntil { await second.count(opcode: 1) == 1 }
                try await fixture.waitUntil { heldWrite.waitingCount == 1 }
                await second.enqueue(.text(#"{"op":11,"d":null}"#))
                try await fixture.synchronize(1)
                heldWrite.open()
                try await fixture.waitForPeriodicSleep()
            case .requestedDuringScheduled:
                try await fixture.scheduledWrite(1)
                await second.enqueue(.text(#"{"op":1,"d":null}"#))
                await second.enqueue(.text(#"{"op":11,"d":null}"#))
                try await fixture.synchronize(1)
                #expect(await second.count(opcode: 1) == 2)
            case .scheduledDuringRequested:
                await second.enqueue(.text(#"{"op":1,"d":null}"#))
                try await fixture.waitUntil { heldWrite.waitingCount == 1 }
                try fixture.clock.advance(by: .seconds(1))
                try await fixture.waitUntil { await second.count(opcode: 1) == 2 }
                heldWrite.open()
                try await fixture.waitForPeriodicSleep()
                await second.enqueue(.text(#"{"op":11,"d":null}"#))
                try await fixture.synchronize(1)
            }
            await second.enqueue(.text(#"{"op":7,"d":null}"#))
            try await fixture.expectFailure(.retryLimitExceeded, run: run)
            #expect(await fixture.transport.connectionCount == 2)
        }
        #expect(heldWrite.waitingCount == 0)
    }

    /// Overflowing the bounded unacknowledged-observation window disables later health credit for that generation.
    /// Three requested beats precede all ACKs; a later sole confirmed scheduled beat must still earn no certificate.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func ambiguousOverflowCannotLaterEarnHealth() async throws {
        let sockets = [BudgetSocket(), BudgetSocket()]
        let fixture = try BudgetFixture(sockets: sockets, retries: 1, policy: .afterHealthySession(
            minimumDuration: .seconds(1), minimumScheduledHeartbeatACKs: 1))
        try await fixture.withRun { run in
            try await fixture.spendFirstRetry()
            for _ in 0..<3 { await sockets[1].enqueue(.text(#"{"op":1,"d":null}"#)) }
            for _ in 0..<3 { await sockets[1].enqueue(.text(#"{"op":11,"d":null}"#)) }
            try await fixture.synchronize(1)
            #expect(await sockets[1].count(opcode: 1) == 3)
            try await fixture.scheduledACK(1)
            #expect(await sockets[1].count(opcode: 1) == 4)
            await sockets[1].enqueue(.text(#"{"op":7,"d":null}"#))
            try await fixture.expectFailure(.retryLimitExceeded, run: run)
            #expect(await fixture.transport.connectionCount == 2)
        }
    }

    /// Fatal close and terminal protocol/continuity failures retain precedence after a session qualifies as healthy.
    /// - Parameter terminal: Exact terminal cause that must escape without opening a replacement socket.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: BudgetHealthTerminal.allCases)
    func healthySessionCannotRetryTerminalFailures(_ terminal: BudgetHealthTerminal) async throws {
        let socket = BudgetSocket(peerCode: terminal == .fatal ? 4014 : nil)
        let fixture = try BudgetFixture(sockets: [socket], maximumEvents: terminal == .overflow ? 1 : 16,
            policy: .afterHealthySession(minimumDuration: .seconds(2), minimumScheduledHeartbeatACKs: 2))
        try await fixture.withRun { run in
            try await fixture.ready(0)
            try await fixture.scheduledACK(0)
            try await fixture.scheduledACK(0)
            switch terminal {
            case .fatal: await socket.enqueue(.end)
            case .malformed: await socket.enqueue(.text(#"{"op":10,"d":{}}"#))
            case .overflow:
                await socket.enqueue(.text(#"{"op":99,"d":null}"#))
                await socket.enqueue(.text(#"{"op":99,"d":null}"#))
            }
            let expected: GatewayFailure = terminal == .fatal ? .fatalClose(4014)
                : terminal == .malformed ? .invalidPayload : .eventCapacityExceeded
            try await fixture.expectFailure(expected, run: run)
            #expect(await fixture.transport.connectionCount == 1)
        }
    }

    /// Actual revoked ownership and injected coordinator loss remain terminal after a certified healthy session.
    /// - Parameter unavailable: True injects unavailable validation; false removes the real currently issued lease.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true])
    func healthySessionCannotRetryLostAuthority(_ unavailable: Bool) async throws {
        let socket = BudgetSocket()
        let fixture = try BudgetFixture(sockets: [socket], policy: .afterHealthySession(
            minimumDuration: .seconds(2), minimumScheduledHeartbeatACKs: 2))
        try await fixture.withRun { run in
            try await fixture.ready(0)
            try await fixture.scheduledACK(0)
            try await fixture.scheduledACK(0)
            if unavailable {
                await fixture.leases.makeUnavailable()
            } else {
                try await fixture.leases.revokeCurrent()
                #expect(await fixture.leases.retainedLeaseCount() == 0)
            }
            // The next real receive fence encounters the lost authority before handling this reconnect request.
            await socket.enqueue(.text(#"{"op":7,"d":null}"#))
            let expected: ShardOwnershipFailure = unavailable ? .coordinatorUnavailable : .staleLease
            try await fixture.expectFailure(expected, run: run)
            #expect(await fixture.transport.connectionCount == 1)
            #expect(await fixture.startup.remainingStarts() == 99)
        }
    }

    /// Monotonic time spent joining a held predecessor cannot mature an otherwise too-short healthy session.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func cleanupTimeCannotEarnHealth() async throws {
        let closeGate = TestBarrier()
        let second = BudgetSocket(reconnectGate: closeGate)
        let fixture = try BudgetFixture(sockets: [BudgetSocket(), second], retries: 1,
            policy: .afterHealthySession(minimumDuration: .seconds(2), minimumScheduledHeartbeatACKs: 1))
        try await fixture.withRun { run in
            try await fixture.spendFirstRetry()
            try await fixture.scheduledACK(1)
            await second.enqueue(.text(#"{"op":7,"d":null}"#))
            try await fixture.waitUntil { closeGate.waitingCount == 1 }
            #expect(await fixture.transport.connectionCount == 2)
            try fixture.clock.advance(by: .seconds(10))
            closeGate.open()
            try await fixture.expectFailure(.retryLimitExceeded, run: run)
            #expect(await fixture.transport.connectionCount == 2)
        }
        #expect(closeGate.waitingCount == 0)
    }

    /// Cancelling upgrade, retry delay or shared Identify admission joins all owners and releases the lease.
    /// - Parameter boundary: Cooperative suspension to cancel without advancing its virtual deadline.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: BudgetCancellation.allCases)
    func cancellationJoinsEveryBoundary(_ boundary: BudgetCancellation) async throws {
        let connectGate = TestBarrier()
        let limit = try GatewaySessionStartLimit(total: 1, remaining: boundary == .identify ? 0 : 1,
            resetAfter: .seconds(3_600), maxConcurrency: 1)
        let socket = BudgetSocket()
        let fixture = try BudgetFixture(sockets: [socket], startupLimit: limit,
            connectGate: boundary == .connect ? connectGate : nil,
            policy: .afterHealthySession(minimumDuration: .seconds(1), minimumScheduledHeartbeatACKs: 1))
        try await fixture.withRun { run in
            switch boundary {
            case .connect: try await fixture.waitUntil { connectGate.waitingCount == 1 }
            case .backoff:
                try await fixture.ready(0)
                await socket.enqueue(.text(#"{"op":7,"d":null}"#))
                try await fixture.waitForRetry(after: 0)
            case .identify:
                try await fixture.waitUntil { await fixture.shard.snapshot().phase == .identifying }
                // Ownership renewal, the first periodic beat and queued Identify each own a sleeper.
                try await fixture.waitUntil { fixture.clock.pendingSleepCount >= 3 }
                #expect(await socket.count(opcode: 2) == 0)
            }
            run.cancel()
            await #expect(throws: CancellationError.self) { try await run.value }
            #expect(await fixture.transport.connectionCount == 1)
        }
        #expect(connectGate.waitingCount == 0)
        #expect(await socket.closed)
    }

    /// Resetting reconnect allowance grants no new Identify allowance when invalid-session requires fresh authentication.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func healthyRecoveryCannotRefillSharedIdentifyQuota() async throws {
        let limit = try GatewaySessionStartLimit(total: 1, remaining: 1, resetAfter: .zero, maxConcurrency: 1)
        let sockets = [BudgetSocket(), BudgetSocket()]
        let fixture = try BudgetFixture(sockets: sockets, startupLimit: limit,
            policy: .afterHealthySession(minimumDuration: .seconds(2), minimumScheduledHeartbeatACKs: 2))
        try await fixture.withRun { run in
            try await fixture.ready(0)
            try await fixture.scheduledACK(0)
            try await fixture.scheduledACK(0)
            await sockets[0].enqueue(.text(#"{"op":9,"d":false}"#))
            try await fixture.advanceRetry(after: 0)
            try await fixture.expectFailure(.startupRefreshRequired, run: run)
            #expect(await fixture.startup.remainingStarts() == 0)
            #expect(await sockets[1].count(opcode: 2) == 0)
            #expect(await sockets[1].count(opcode: 6) == 0)
            #expect(await fixture.transport.urls.last?.host == "gateway.discord.gg")
        }
    }
}

/// Negative samples exercise distinct reasons that an ACK cannot establish scheduled heartbeat health.
enum BudgetInvalidHealthSample: Sendable, CaseIterable {
    /// A valid single sample falls short of the configured two-observation threshold.
    case insufficient
    /// ACKs arrive with no outstanding heartbeat at all.
    case unsolicited
    /// A scheduled beat and ACK complete before the valid RESUMED event.
    case preReady
    /// Only server-requested beats are acknowledged after readiness.
    case requestedOnly
    /// ACK arrives while the sole scheduled write is still held in the adapter.
    case earlyWrite
    /// Requested traffic overlaps a confirmed scheduled beat before its ACK.
    case requestedDuringScheduled
    /// A scheduled write starts while a requested write is held by the adapter.
    case scheduledDuringRequested
}

/// Terminal failures must remain terminal even after both health thresholds were satisfied.
enum BudgetHealthTerminal: Sendable, CaseIterable {
    /// Discord explicitly closes with the privileged-intent fatal code 4014.
    case fatal
    /// An unexpected second Hello violates the established control protocol.
    case malformed
    /// Raw event capacity is exceeded and continuity cannot be silently recovered.
    case overflow
}

/// Each case selects one deterministic cancellation suspension in the structured shard run.
enum BudgetCancellation: Sendable, CaseIterable {
    /// Transport upgrade has not transferred ownership of its partial socket.
    case connect
    /// The previous socket is joined and the next replacement is sleeping.
    case backoff
    /// A shared startup coordinator denies immediate Identify pending its reset.
    case identify
}

/// Concrete real-runtime specialization; only clock, ownership and transport boundaries are injected.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private typealias BudgetShard = GatewayShard<ManualClock, BudgetLeases>

/// Records run termination so observation loops fail promptly when the supervised owner already ended.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private final class BudgetCompletion: Sendable {
    /// One synchronized terminal bit, containing no error or credential payload.
    private let storage = Mutex(false)

    /// Returns whether the run returned or threw after joining its children.
    var finished: Bool { storage.withLock { $0 } }

    /// Publishes joined completion once; repeated publication is harmless.
    func finish() { storage.withLock { $0 = true } }
}

/// Isolated ownership, startup, clock and finite sockets for one single-use shard run.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private struct BudgetFixture: Sendable {
    /// Real actor under test, without widened recovery-state visibility.
    let shard: BudgetShard
    /// Monotonic virtual time; tests advance only after observing the required suspension.
    let clock: ManualClock
    /// Forwarded real atomic authority, with explicit test-only revocation/outage controls and release assertions.
    let leases: BudgetLeases
    /// Shared Identify authority; Resume and episode reset must not replenish it.
    let startup: InProcessGatewayStartupCoordinator<ManualClock>
    /// Finite adapter recording actual upgrade URLs and connection attempts.
    let transport: BudgetTransport
    /// All scripted peers, including unused alternatives that must not be connected.
    let sockets: [BudgetSocket]
    /// Joined termination receipt used by observable-state polling.
    private let completion = BudgetCompletion()

    /// Builds an offline shard with a long lease so short virtual scenarios cannot accidentally expire ownership.
    /// - Parameters:
    ///   - sockets: Finite per-generation peers; the adapter fails if the script is exhausted.
    ///   - retries: Explicit episode/total limit, or nil to exercise the production default five.
    ///   - jitter: Fixed heartbeat/retry jitter in 0...1; defaults to one for exact delay boundaries.
    ///   - maximumEvents: Positive raw queue bound, default sixteen.
    ///   - startupLimit: Optional independent shared Identify ledger; default 100 starts without automatic reset.
    ///   - connectGate: Optional cancellation-aware hold while the adapter owns a partial upgrade.
    ///   - policy: Recovery policy; omitted means the backwards-compatible total-run mode.
    /// - Throws: Invalid configuration, identity, credential or discovery fixture construction.
    init(sockets: [BudgetSocket], retries: Int? = nil, jitter: Double = 1, maximumEvents: Int = 16,
         startupLimit: GatewaySessionStartLimit? = nil, connectGate: TestBarrier? = nil,
         policy: GatewayReconnectBudgetPolicy = .totalRun) throws {
        let clock = ManualClock()
        let leases = try BudgetLeases(clock: clock)
        let discovery = try makeDiscovery()
        let limit = try startupLimit ?? GatewaySessionStartLimit(total: 100, remaining: 100,
            resetAfter: .zero, maxConcurrency: 2)
        let startup = InProcessGatewayStartupCoordinator(botID: UserID(rawValue: 1), limit: limit, clock: clock)
        let transport = BudgetTransport(sockets: sockets, connectGate: connectGate)
        let configuration: GatewayShardConfiguration
        if let retries {
            configuration = try GatewayShardConfiguration(maximumBufferedEvents: maximumEvents,
                maximumReconnectAttempts: retries, leaseLifetime: .seconds(86_400), reconnectBudgetPolicy: policy)
        } else {
            configuration = try GatewayShardConfiguration(maximumBufferedEvents: maximumEvents,
                leaseLifetime: .seconds(86_400), reconnectBudgetPolicy: policy)
        }
        shard = GatewayShard(identity: try ShardIdentity(botID: UserID(rawValue: 1), topologyGeneration: 0,
            index: 0, count: 2), token: try BotToken("offline-budget-fixture"), intents: 1,
            discovery: discovery, transport: transport, clock: clock, leases: leases,
            startup: startup, configuration: configuration, random: { jitter })
        self.clock = clock; self.leases = leases; self.startup = startup
        self.transport = transport; self.sockets = sockets
    }

    /// Owns a single run and always cancels, releases test holds and joins it before checking cleanup.
    /// - Parameter operation: Scenario receiving the actual run task for terminal-result assertions.
    /// - Throws: Scenario errors after complete cleanup; expected run failures are asserted by the scenario.
    func withRun(_ operation: (Task<Void, any Error>) async throws -> Void) async throws {
        let run = Task {
            defer { completion.finish() }
            try await shard.run()
        }
        do {
            try await operation(run)
        } catch {
            await releaseHolds()
            run.cancel()
            await shard.stop()
            _ = try? await run.value
            throw error
        }
        await releaseHolds()
        run.cancel()
        await shard.stop()
        _ = try? await run.value
        #expect(await leases.retainedLeaseCount() == 0)
        #expect(clock.pendingSleepCount == 0)
        #expect(await shard.snapshot().phase == .stopped)
        let opened = await transport.connectionCount
        for socket in sockets.prefix(opened) {
            #expect(await socket.closed)
            #expect(await socket.receiveWaiters == 0)
            #expect(await socket.heldWaiters == 0)
        }
    }

    /// Releases only fixture-owned test gates so error cleanup cannot leave a deliberate hold suspended.
    private func releaseHolds() async {
        await transport.releaseHold()
        for socket in sockets { await socket.releaseHolds() }
    }

    /// Waits for an actual observable condition, checking cancellation and joined premature termination.
    /// - Parameter predicate: Fast nonblocking actor/state observation; never advances time or performs I/O.
    /// - Throws: Cancellation or a fixed fixture failure if the run ended before the condition appeared.
    func waitUntil(_ predicate: () async -> Bool) async throws {
        while !(await predicate()) {
            guard !completion.finished else { throw TestSupportFailure.scripted("run ended before expected observation") }
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    /// Waits until ownership renewal and the next periodic heartbeat have registered their clock sleeps.
    /// This occurs after the scheduled write's return and post-write ownership fence, unlike adapter entry.
    /// - Throws: Cancellation or premature joined run termination.
    func waitForPeriodicSleep() async throws {
        try await waitUntil { clock.pendingSleepCount >= 2 }
    }

    /// Sends a valid same-generation READY/RESUMED only after the actual corresponding authentication write.
    /// - Parameter index: Zero-based socket script index; later generations resume the original session.
    /// - Throws: Cancellation, premature run termination or failed test requirements.
    func ready(_ index: Int) async throws {
        let socket = sockets[index]
        try await waitUntil { await socket.count(opcode: index == 0 ? 2 : 6) == 1 }
        let frame = index == 0
            ? #"{"op":0,"s":1,"t":"READY","d":{"session_id":"budget-session","resume_gateway_url":"wss://resume.discord.gg/"}}"#
            : "{\"op\":0,\"s\":\(index + 1),\"t\":\"RESUMED\",\"d\":{}}"
        await socket.enqueue(.text(frame))
        try await waitUntil {
            let snapshot = await shard.snapshot()
            return snapshot.phase == .ready && snapshot.socketGeneration == UInt64(index + 1)
        }
        let events = await shard.drainEvents()
        #expect(events.contains { $0.name == (index == 0 ? "READY" : "RESUMED") })
        try await waitForPeriodicSleep()
    }

    /// Places an unknown-opcode marker after preceding input and observes its real raw-queue ingestion.
    /// This proves that earlier ACK controls were processed, rather than merely enqueued by the test.
    /// - Parameter index: Current socket index.
    /// - Throws: Cancellation or premature termination; records a test failure if marker ordering is lost.
    func synchronize(_ index: Int) async throws {
        _ = await shard.drainEvents()
        await sockets[index].enqueue(.text(#"{"op":99,"d":null}"#))
        try await waitUntil { await shard.snapshot().bufferedEvents > 0 }
        #expect(await shard.drainEvents().contains { $0.opcode == 99 })
    }

    /// Advances one fixed periodic interval and waits for adapter completion plus the next registered timer.
    /// - Parameter index: Current one-second-heartbeat peer.
    /// - Throws: Invalid virtual advancement, cancellation or premature run termination.
    func scheduledWrite(_ index: Int) async throws {
        let previous = await sockets[index].count(opcode: 1)
        try await waitForPeriodicSleep()
        try clock.advance(by: .seconds(1))
        try await waitUntil { await sockets[index].count(opcode: 1) == previous + 1 }
        try await waitForPeriodicSleep()
    }

    /// Acknowledges exactly one confirmed scheduled beat, then proves ACK processing through ordered ingestion.
    /// - Parameter index: Current one-second-heartbeat peer, which need not have received readiness yet.
    /// - Throws: Invalid virtual advancement, cancellation or premature termination.
    func scheduledACK(_ index: Int) async throws {
        try await scheduledWrite(index)
        await sockets[index].enqueue(.text(#"{"op":11,"d":null}"#))
        try await synchronize(index)
    }

    /// Waits for joined predecessor cleanup and the actual retry sleep without advancing its deadline.
    /// - Parameter index: Failed socket index; the next transport connection must still be absent.
    /// - Throws: Cancellation or premature run termination.
    func waitForRetry(after index: Int) async throws {
        try await waitUntil {
            let phase = await shard.snapshot().phase
            return phase == .reconnecting && clock.pendingSleepCount >= 2
        }
        #expect(await transport.connectionCount == index + 1)
        #expect(await sockets[index].closed)
    }

    /// Proves a retry remains pending at 999 ms and opens the next generation at exactly the one-second base.
    /// - Parameter index: Failed socket index; health must have reset prior exponential backoff if any.
    /// - Throws: Invalid virtual advancement, cancellation or premature termination.
    func advanceRetry(after index: Int) async throws {
        try await waitForRetry(after: index)
        try clock.advance(by: .milliseconds(999))
        #expect(await transport.connectionCount == index + 1)
        try clock.advance(by: .milliseconds(1))
        try await waitUntil { await transport.connectionCount == index + 2 }
    }

    /// Spends the one permitted unhealthy retry, then prepares the second generation for a decisive certificate check.
    /// - Parameter readySecond: Whether to send RESUMED immediately; false allows pre-ready heartbeat coverage.
    /// - Throws: Invalid virtual advancement, cancellation or premature termination.
    func spendFirstRetry(readySecond: Bool = true) async throws {
        try await ready(0)
        await sockets[0].enqueue(.text(#"{"op":7,"d":null}"#))
        try await advanceRetry(after: 0)
        if readySecond {
            try await ready(1)
        } else {
            try await waitUntil { await sockets[1].count(opcode: 6) == 1 }
            try await waitForPeriodicSleep()
        }
    }

    /// Asserts an exact Gateway failure and detects an erroneous extra retry without advancing another clock deadline.
    /// - Parameters:
    ///   - expected: Exact Gateway failure that must escape after structured cleanup.
    ///   - run: Actual single-use run task created by this fixture.
    /// - Throws: Caller cancellation; unexpected retry scheduling records a failure before joined cleanup.
    func expectFailure(_ expected: GatewayFailure, run: Task<Void, any Error>) async throws {
        try await expectTerminalFailure(expected, run: run)
    }

    /// Asserts an exact authority failure after health without granting reconnect admission or replacing the owner.
    /// - Parameters:
    ///   - expected: Backing stale-lease or injected coordinator failure required at the public boundary.
    ///   - run: Actual single-use run task created by this fixture.
    /// - Throws: Caller cancellation; unexpected retry scheduling records a failure before joined cleanup.
    func expectFailure(_ expected: ShardOwnershipFailure, run: Task<Void, any Error>) async throws {
        try await expectTerminalFailure(expected, run: run)
    }

    /// Asserts the exact terminal result and detects an erroneous extra retry without waiting on an unadvanced clock.
    /// - Parameters:
    ///   - expected: Exact public failure that must escape after structured cleanup.
    ///   - run: Actual single-use run task created by this fixture.
    /// - Throws: Caller cancellation; unexpected retry scheduling records a failure and returns for joined cleanup.
    private func expectTerminalFailure<Failure: Error & Equatable>(
        _ expected: Failure, run: Task<Void, any Error>
    ) async throws {
        while !completion.finished {
            let phase = await shard.snapshot().phase
            if phase == .reconnecting && clock.pendingSleepCount >= 2 {
                Issue.record("Terminal failure unexpectedly scheduled another reconnect")
                return
            }
            try Task.checkCancellation()
            await Task.yield()
        }
        await #expect(throws: expected) { try await run.value }
    }
}

/// Forwards real lease fencing while allowing deterministic authority loss only after the scenario certifies health.
/// No production visibility changes or clock-driven revocation timers are required.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private actor BudgetLeases: ShardLeaseStore {
    /// Lease instants belong to the same explicitly advanced clock as the real shard.
    typealias LeaseClock = ManualClock
    /// Actual bounded ownership records; revocation removes a real issued ticket here.
    private let backing: InProcessShardLeaseStore<ManualClock>
    /// Latest ticket returned to the shard, including any renewed fencing generation.
    private var current: ShardLease<ManualClock>?
    /// When enabled, validation fails closed while cancellation-safe release remains available.
    private var unavailable = false

    /// Creates one real in-process lease authority without issuing a ticket or launching work.
    /// - Parameter clock: Test-owned monotonic clock shared with the shard.
    /// - Throws: Invalid backing capacity; the fixed one-record bound is valid.
    init(clock: ManualClock) throws {
        backing = try InProcessShardLeaseStore(clock: clock, maximumLeases: 1)
    }

    /// Acquires and records the actual authority returned by the real atomic backing store.
    /// - Parameters:
    ///   - shard: Exact fixed-topology ownership key.
    ///   - owner: Fresh nonsecret shard worker identity.
    ///   - lifetime: Positive requested duration in the injected clock domain.
    /// - Returns: Newly issued backing ticket; no authority is invented by this wrapper.
    /// - Throws: Backing cancellation, ownership, capacity, lifetime or generation failures.
    func acquire(_ shard: ShardIdentity, owner: UUID, lifetime: Duration) async throws -> ShardLease<ManualClock> {
        let ticket = try await backing.acquire(shard, owner: owner, lifetime: lifetime)
        current = ticket
        return ticket
    }

    /// Preserves real owner/generation/expiry validation unless the scenario explicitly injects an outage.
    /// - Parameter lease: Current ticket offered by the real shard at an actual ownership fence.
    /// - Throws: Cancellation, injected coordinator unavailability or the backing store's stale-lease failure.
    func validate(_ lease: ShardLease<ManualClock>) async throws {
        try Task.checkCancellation()
        if unavailable { throw ShardOwnershipFailure.coordinatorUnavailable }
        try await backing.validate(lease)
    }

    /// Renews through real atomic fencing and records the replacement so later revocation targets the current owner.
    /// - Parameters:
    ///   - lease: Current unexpired ticket; a stale predecessor never gains renewed authority.
    ///   - lifetime: Positive replacement lifetime from the backing clock's current instant.
    /// - Returns: Backing store's newly fenced replacement.
    /// - Throws: Cancellation, injected outage or backing stale/lifetime/generation failures.
    func renew(_ lease: ShardLease<ManualClock>, lifetime: Duration) async throws -> ShardLease<ManualClock> {
        try await validate(lease)
        let ticket = try await backing.renew(lease, lifetime: lifetime)
        current = ticket
        return ticket
    }

    /// Forwards cancellation-safe release even during an injected validation outage, without affecting newer owners.
    /// - Parameter lease: Ticket retained by the shard; releasing a revoked/stale ticket is a harmless no-op.
    func release(_ lease: ShardLease<ManualClock>) async {
        await backing.release(lease)
        if current?.generation == lease.generation { current = nil }
    }

    /// Removes the actual current ticket without replacing the shard or changing its private runtime state.
    /// The next real ownership fence therefore receives the backing store's `staleLease` failure.
    /// - Throws: Fixed support failure if no ticket has been acquired; no revocation is fabricated in that case.
    func revokeCurrent() async throws {
        guard let current else { throw TestSupportFailure.scripted("revocation requires an issued ticket") }
        await backing.release(current)
    }

    /// Makes subsequent validation/renewal fail closed; acquisition history and cleanup release remain unchanged.
    func makeUnavailable() { unavailable = true }

    /// Reports actual retained records rather than wrapper receipts, including real revocation and cleanup effects.
    /// - Returns: Zero or one backing ownership records.
    func retainedLeaseCount() async -> Int { await backing.retainedLeaseCount() }
}

/// Finite upgrade adapter; a cancelled partial connection remains adapter-owned and is closed before throwing.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private actor BudgetTransport: WebSocketTransport {
    /// Distinct scripted peers available to sequential socket generations.
    private let sockets: [BudgetSocket]
    /// Optional cooperative suspension before ownership transfers to the shard.
    private let connectGate: TestBarrier?
    /// Actual consumed upgrade URLs, excluding credential-bearing headers and payloads.
    private(set) var urls: [URL] = []

    /// Returns the number of attempted finite upgrades, including a held partial upgrade.
    var connectionCount: Int { urls.count }

    /// Stores test-owned peers without opening a socket or spawning a task.
    /// - Parameters:
    ///   - sockets: Finite script; exhaustion throws `TransportFailure.scriptExhausted`.
    ///   - connectGate: Optional cancellation-aware adapter admission hold.
    init(sockets: [BudgetSocket], connectGate: TestBarrier?) {
        self.sockets = sockets; self.connectGate = connectGate
    }

    /// Records one upgrade and transfers the next socket only after cancellation/deadline checks succeed.
    /// - Parameters:
    ///   - request: Trusted Gateway v10 upgrade request; only its URL is retained.
    ///   - context: Injected clock, deadline and cancellation boundary.
    /// - Returns: Next scripted session-aware connection.
    /// - Throws: Context failure, cancellation or finite script exhaustion; partial sockets are closed first.
    func connectWebSocket<C: Clock>(_ request: HTTPRequest, context: TransportContext<C>) async throws
        -> any WebSocketConnection where C.Duration == Duration {
        try context.check()
        guard urls.count < sockets.count else { throw TransportFailure.scriptExhausted }
        let socket = sockets[urls.count]
        urls.append(request.url)
        do {
            try await connectGate?.wait()
            try context.check()
            return socket
        } catch {
            await socket.close()
            throw error
        }
    }

    /// Opens only this fixture's admission gate so assertion-error cleanup cannot retain an intentional hold.
    func releaseHold() { connectGate?.open() }
}

/// Cancellation-aware finite peer with ordered input and serialized output; no real network or timers are owned.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private actor BudgetSocket: WebSocketSessionConnection {
    /// One bounded scripted inbound message or explicit EOF.
    enum Input: Sendable {
        /// Complete Gateway JSON frame, decoded only by the real shard.
        case text(String)
        /// Ordered peer EOF; numeric disposition is configured separately.
        case end
    }

    /// Input not yet consumed by the sole receive owner, bounded to sixty-four entries.
    private var inputs: [Input]
    /// One-shot signal replaced on each enqueue; cancellation removes waiters synchronously.
    private var inputSignal = TestBarrier()
    /// Selected heartbeat write ordinals held before adapter confirmation.
    private let heldHeartbeats: [Int: TestBarrier]
    /// Optional joined-cleanup hold used to test failure-time freezing.
    private let reconnectGate: TestBarrier?
    /// Numeric peer code only; no remote reason or credential payload is retained.
    private let peerCode: Int?
    /// Gate chaining concurrent adapter calls into one ordered write-completion lane.
    private var lastWriteCompletion: TestBarrier?
    /// Entered frame opcodes; body and authentication credentials are deliberately discarded.
    private var opcodes: [Int] = []
    /// Idempotent resource ownership receipt; closing wakes the sole receive owner.
    private(set) var closed = false

    /// Reports currently suspended receive work for joined-cleanup assertions.
    var receiveWaiters: Int { inputSignal.waitingCount }
    /// Reports outstanding test-owned write/cleanup gate waiters, excluding already released gates.
    var heldWaiters: Int {
        heldHeartbeats.values.reduce(0) { $0 + $1.waitingCount } + (reconnectGate?.waitingCount ?? 0)
    }

    /// Starts with one valid Hello and otherwise waits only for explicitly enqueued finite input.
    /// - Parameters:
    ///   - heartbeatMilliseconds: Valid Hello interval; defaults to one second.
    ///   - peerCode: Optional fixed numeric close classification, normally nil.
    ///   - heldHeartbeats: One-based heartbeat ordinals to suspend before adapter confirmation.
    ///   - reconnectGate: Optional cooperative hold before reconnect cleanup completes.
    init(heartbeatMilliseconds: Int = 1_000, peerCode: Int? = nil,
         heldHeartbeats: [Int: TestBarrier] = [:], reconnectGate: TestBarrier? = nil) {
        inputs = [.text("{\"op\":10,\"d\":{\"heartbeat_interval\":\(heartbeatMilliseconds)}}")]
        self.peerCode = peerCode; self.heldHeartbeats = heldHeartbeats; self.reconnectGate = reconnectGate
    }

    /// Adds one ordered input and wakes pending receive without advancing time.
    /// - Parameter input: Synthetic JSON frame or EOF; ignored after explicit close.
    /// - Precondition: The finite script contains fewer than sixty-four queued entries.
    func enqueue(_ input: Input) {
        guard !closed else { return }
        precondition(inputs.count < 64)
        inputs.append(input)
        inputSignal.open()
        inputSignal = TestBarrier()
    }

    /// Counts observable adapter entries for one opcode without retaining frame data.
    /// - Parameter opcode: Numeric Gateway opcode, usually Identify, Resume or Heartbeat.
    /// - Returns: Number of actual writes entering this adapter, including deliberately held writes.
    func count(opcode: Int) -> Int { opcodes.filter { $0 == opcode }.count }

    /// Serializes writes while allowing tests to distinguish entry, a held write and adapter completion.
    /// - Parameters:
    ///   - message: Complete outbound frame; its body is decoded transiently and then discarded.
    ///   - context: Injected cancellation/deadline checks before and after cooperative holds.
    /// - Throws: Closed socket, malformed output, cancellation or expired context.
    func send<C: Clock>(_ message: WebSocketMessage, context: TransportContext<C>) async throws
        where C.Duration == Duration {
        try context.check()
        guard !closed else { throw TransportFailure.closed }
        let opcode = try GatewayEnvelope(message, maximumBytes: 4_096).opcode
        opcodes.append(opcode)
        let ordinal = opcodes.filter { $0 == 1 }.count
        let predecessor = lastWriteCompletion
        let completed = TestBarrier()
        lastWriteCompletion = completed
        defer { completed.open() }
        try await predecessor?.wait()
        if opcode == 1 { try await heldHeartbeats[ordinal]?.wait() }
        try context.check()
        guard !closed else { throw TransportFailure.closed }
    }

    /// Pulls ordered scripted input, suspending on a cancellable gate only while the bounded queue is empty.
    /// - Parameter context: Clock/deadline/cancellation boundary for this read.
    /// - Returns: Next complete message, or nil after EOF/explicit close.
    /// - Throws: Cancellation, deadline or support gate capacity failure; no receive task survives return.
    func receive<C: Clock>(context: TransportContext<C>) async throws -> WebSocketMessage?
        where C.Duration == Duration {
        try context.check()
        while inputs.isEmpty && !closed {
            let signal = inputSignal
            try await context.run { try await signal.wait() }
        }
        guard !closed else { return nil }
        switch inputs.removeFirst() {
        case .text(let frame): return .text(frame)
        case .end: return nil
        }
    }

    /// Closes idempotently and wakes pending input; the shard joins cancelled output owners separately.
    func close() {
        closed = true
        inputs.removeAll()
        inputSignal.open()
    }

    /// Waits at the optional test cleanup boundary, then aborts without a normal session-invalidating close code.
    /// Cancellation releases the test gate wait before the adapter completes its required close.
    func closeForReconnect() async {
        try? await reconnectGate?.wait()
        close()
    }

    /// Returns the injected numeric disposition immediately, without waiting for any later remote event.
    /// - Returns: Configured peer code or nil for a resumable abrupt disconnect.
    func peerCloseCode() -> Int? { peerCode }

    /// Releases only this peer's deliberate write/cleanup holds before fixture-owned cancellation and join.
    func releaseHolds() {
        for gate in heldHeartbeats.values { gate.open() }
        reconnectGate?.open()
    }
}
