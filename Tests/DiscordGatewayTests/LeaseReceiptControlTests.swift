// File: Tests/DiscordGatewayTests/LeaseReceiptControlTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCore
import DiscordLogging
import DiscordTestSupport
import DiscordTransport
import Foundation
import Synchronization
import Testing
@testable import DiscordGateway

/// A single externally held validation distinguishes receipt/authority time from decoding.
@Suite("Gateway receipt lease controls", .timeLimit(.minutes(1)))
struct LeaseReceiptControlTests {
    /// A received frame cannot decode or advance sequence until its real authority fence completes.
    /// - Parameters:
    ///   - delay: Deterministic authority residence, including a zero-delay control.
    ///   - fails: True returns a coordinator outage after the same held callback.
    /// - Throws: Unexpected fixture, barrier, interval or shutdown failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [Duration.zero, .milliseconds(17)], [false, true])
    func frameFenceSeparatesAuthorityFromDecode(delay: Duration, fails: Bool) async throws {
        let clock = ManualClock(), origin = clock.now
        let endpoints = Mutex<[DiscordIntervalEvent]>([])
        let observer = DiscordIntervalTiming(clockDomain: 6_303,
            sink: { event in endpoints.withLock { $0.append(event) } },
            now: { origin.duration(to: clock.now) })
        let backing = try InProcessShardLeaseStore(clock: clock, maximumLeases: 1)
        let leases = ReceiptControlLeases(backing: backing)
        let identified = TestBarrier(), allowFrame = TestBarrier(), idle = TestBarrier()
        let socket = GatewayTestSocket(steps: [
            { .text(#"{"op":10,"d":{"heartbeat_interval":10000}}"#) },
            { try await identified.wait(); return .text(#"{"op":0,"s":1,"t":"READY","d":{"session_id":"session","resume_gateway_url":"wss://resume.discord.gg/"}}"#) },
            { try await allowFrame.wait(); return .text(#"{"op":0,"s":2,"t":"FUTURE_CONTROL","d":null}"#) },
            { try await idle.wait(); return nil }
        ], onSend: { if $0.opcode == 2 { identified.open() } })
        let transport = GatewayTestTransport(sockets: [socket])
        let discovery = try makeDiscovery()
        let startup = InProcessGatewayStartupCoordinator(botID: .init(rawValue: 1),
            limit: discovery.sessionStartLimit, clock: clock)
        let shard = GatewayShard(identity: try .init(botID: .init(rawValue: 1), topologyGeneration: 0, index: 0, count: 2),
            token: try BotToken("synthetic-receipt-control"), intents: 1, discovery: discovery,
            transport: transport, clock: clock, leases: leases, startup: startup,
            configuration: try .init(maximumReconnectAttempts: 0), intervals: observer, random: { 1 })
        let owner = Task { try await shard.run() }
        #expect(try await shard.nextEvents()?.map(\.sequence) == [1])
        let before = endpoints.withLock { $0 }
        let decodesBefore = before.filter { $0.stage == .decode && $0.kind == .began }.count
        await leases.arm(fails: fails)
        allowFrame.open()
        try await leases.entered.wait()
        #expect(await shard.snapshot().sequence == 1)
        #expect(await shard.snapshot().bufferedEvents == 0)
        #expect(endpoints.withLock { $0.filter { $0.stage == .decode && $0.kind == .began }.count } == decodesBefore)
        try clock.advance(by: delay)
        leases.allowValidation.open()
        if fails {
            await #expect(throws: ShardOwnershipFailure.coordinatorUnavailable) { try await owner.value }
        } else {
            #expect(try await shard.nextEvents()?.map(\.sequence) == [2])
            await shard.stop()
            try await owner.value
        }
        let events = endpoints.withLock { $0 }
        let receipt = try #require(events.last { $0.stage == .socketReceipt && $0.kind == .ended })
        #expect(receipt.elapsedNanoseconds == (delay == .zero ? 0 : 17_000_000))
        #expect(receipt.outcome == (fails ? .failed : .succeeded))
        let validation = try #require(events.last { $0.stage == .leaseValidation && $0.kind == .ended })
        #expect(validation.elapsedNanoseconds == receipt.elapsedNanoseconds)
        #expect(validation.outcome == receipt.outcome)
        let decodes = events.filter { $0.stage == .decode && $0.kind == .ended }
        #expect(decodes.count == decodesBefore + (fails ? 0 : 1))
        #expect(decodes.allSatisfy { $0.elapsedNanoseconds == 0 })
        #expect(events.filter { $0.stage == .leaseValidation && $0.kind == .ended }.count == (await leases.validationCount))
        #expect(events.filter { $0.kind == .began }.count == events.filter { $0.kind == .ended }.count)
        #expect(await backing.retainedLeaseCount() == 0)
        #expect(await socket.closed)
        #expect(await shard.snapshot().bufferedEvents == 0)
        #expect(clock.pendingSleepCount == 0)
    }
}

/// Decorates the actual in-process authority with one armed, cancellation-aware callback.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private actor ReceiptControlLeases: ShardLeaseStore {
    typealias LeaseClock = ManualClock
    let backing: InProcessShardLeaseStore<ManualClock>
    nonisolated let entered = TestBarrier()
    nonisolated let allowValidation = TestBarrier()
    private var nextFailure: Bool?
    private(set) var validationCount = 0

    /// Retains the test-owned authority without acquiring any ticket or starting tasks.
    /// - Parameter backing: Real bounded generation/expiry ledger shared with test cleanup assertions.
    init(backing: InProcessShardLeaseStore<ManualClock>) { self.backing = backing }

    /// Holds exactly the next validation, after authenticated READY has already drained.
    /// - Parameter fails: Whether the callback fails closed after release instead of validating.
    func arm(fails: Bool) { nextFailure = fails }

    /// Delegates acquisition unchanged to the actual bounded authority.
    /// - Parameters:
    ///   - shard: Complete shard identity to reserve.
    ///   - owner: Opaque runtime owner identifier.
    ///   - lifetime: Positive monotonic lifetime checked by the real ledger.
    /// - Returns: The real fencing ticket.
    /// - Throws: The real authority's cancellation, capacity or ownership failure.
    func acquire(_ shard: ShardIdentity, owner: UUID, lifetime: Duration) async throws -> ShardLease<ManualClock> {
        try await backing.acquire(shard, owner: owner, lifetime: lifetime)
    }

    /// Counts every actual fence and optionally holds one callback before validation.
    /// - Parameter lease: Current runtime ticket; no successful callback bypasses its ledger check.
    /// - Throws: Cancellation, the selected coordinator outage, or the ledger's stale/expired error.
    func validate(_ lease: ShardLease<ManualClock>) async throws {
        validationCount += 1
        if let fails = nextFailure {
            nextFailure = nil
            entered.open()
            try await allowValidation.wait()
            if fails { throw ShardOwnershipFailure.coordinatorUnavailable }
        }
        try await backing.validate(lease)
    }

    /// Preserves real renewal and generation replacement without injecting extra delay.
    /// - Parameters:
    ///   - lease: Ticket being replaced.
    ///   - lifetime: Requested positive renewal lifetime.
    /// - Returns: Real replacement ticket.
    /// - Throws: The ledger's cancellation or ownership failure.
    func renew(_ lease: ShardLease<ManualClock>, lifetime: Duration) async throws -> ShardLease<ManualClock> {
        try await backing.renew(lease, lifetime: lifetime)
    }

    /// Releases only the real owned ticket, including cancellation and failed-validation cleanup.
    /// - Parameter lease: Last ticket retained by the runtime.
    func release(_ lease: ShardLease<ManualClock>) async throws { await backing.release(lease) }
}
