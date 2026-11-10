// File: Tests/DiscordBotDSLTests/MC29GatewayTimingTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordClient
import DiscordCommandDSL
import DiscordCommands
import DiscordCore
import DiscordHTTP
import DiscordInteractions
import DiscordLogging
import DiscordModels
import DiscordTestSupport
import DiscordTransport
import Foundation
import Testing
@testable import DiscordBotDSL
@testable import DiscordGateway

/// Fixed-shape synchronous recorder for isolated trusted-adapter timing tests.
private final class MC29GatewayObservations: @unchecked Sendable {
    /// Protects finite samples from concurrent dispatcher callbacks.
    private let lock = NSLock()
    /// Content-free observations retained only for one test.
    private var samples: [OperationTimingSample] = []
    /// Appends a sample without tasks or arbitrary diagnostic formatting.
    /// - Parameter sample: Closed phase, outcome and monotonic duration.
    func record(_ sample: OperationTimingSample) { lock.withLock { samples.append(sample) } }
    /// Copies the finite sample collection under one lock.
    /// - Returns: Observations emitted so far.
    func snapshot() -> [OperationTimingSample] { lock.withLock { samples } }
}

/// Finite detailed endpoints for proving receipt age never becomes a historical begin timestamp.
private final class MC29GatewayIntervalObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiscordIntervalEvent] = []

    /// Stores one content-free endpoint under the finite test workload.
    func record(_ event: DiscordIntervalEvent) { lock.withLock { events.append(event) } }
    /// Copies endpoint observations atomically.
    func snapshot() -> [DiscordIntervalEvent] { lock.withLock { events } }
}

/// Inert offline composition with actual command routing, response ownership and HTTP sinks.
/// Package-only timestamp construction isolates the provenance branch; it is not live socket qualification.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private struct MC29GatewayFixture {
    /// Shared deterministic clock for all production owners.
    let clock = ManualClock()
    /// Separate independently admitted initial-response transport.
    let initial: ScriptedHTTPTransport
    /// Separate ordinary continuation transport.
    let continuation: ScriptedHTTPTransport
    /// Task-free production service adapter using synthetic exact-token credentials.
    let services: BotServiceAdapter<ManualClock>
    /// Idle client needed only for the private receiver's supported preparation boundary.
    let client: DiscordClient<ManualClock, InProcessShardLeaseStore<ManualClock>>
    /// Shared finite initial-response authority.
    let admission: InteractionAcknowledgementAdmission
    /// Separately owned rate authorities, explicitly closed by test cleanup.
    let coordinators: [RateLimitCoordinator<ManualClock>]

    /// Composes real injected owners without starting the client, socket, HTTP or router.
    /// - Parameter uncertain: Whether the initial sink lacks a confirmed result after entry.
    /// - Throws: Invalid finite production configuration or offline fixture encoding.
    init(uncertain: Bool = false) throws {
        let clock = self.clock
        initial = try ScriptedHTTPTransport(steps: [{ _ in
            try clock.advance(by: .milliseconds(20))
            if uncertain { throw TestSupportFailure.scripted("private-uncertain-delivery") }
            return HTTPResponse(status: 204)
        }])
        continuation = try ScriptedHTTPTransport(steps: [{ _ in
            try clock.advance(by: .milliseconds(30))
            return HTTPResponse(status: 200, body: try RequestBody(bytes: Data(Self.messageJSON.utf8),
                contentType: "application/json").makeStream())
        }])
        let botHTTP = try ScriptedHTTPTransport(steps: [])
        let botCoordinator = RateLimitCoordinator(clock: clock)
        let initialCoordinator = RateLimitCoordinator(clock: clock)
        let continuationCoordinator = RateLimitCoordinator(clock: clock)
        coordinators = [botCoordinator, initialCoordinator, continuationCoordinator]
        let bot = RESTClient(credential: .bot(try BotToken("synthetic-timing-bot")), identity: RateLimitIdentity(),
            transport: botHTTP, coordinator: botCoordinator, clock: clock)
        let token = try InteractionToken("synthetic-timing-token"), identity = RateLimitIdentity()
        let initialClient = RESTClient(credential: .interaction(token), identity: identity,
            transport: initial, coordinator: initialCoordinator, clock: clock, retryPolicy: .init(maximumAttempts: 1))
        let continuationClient = RESTClient(credential: .interaction(token), identity: identity,
            transport: continuation, coordinator: continuationCoordinator, clock: clock, retryPolicy: .init(maximumAttempts: 1))
        services = BotServiceAdapter(services: ServiceContext(rest: bot), clock: clock,
            initialClient: { _ in initialClient }, continuationServices: { _ in ServiceContext(rest: continuationClient) })
        admission = try InteractionAcknowledgementAdmission()
        client = DiscordClient(token: try BotToken("synthetic-timing-bot"),
            configuration: try ClientConfiguration(intents: []), services: ServiceContext(rest: bot),
            transport: ScriptedWebSocketTransport(connection: try ScriptedWebSocketConnection(incoming: [])),
            clock: clock, leases: try InProcessShardLeaseStore(clock: clock, maximumLeases: 1),
            authority: try ClientAuthority(botID: .init(rawValue: 42), clock: clock, budget: ClientResourceBudget()),
            events: GatewayEventHub(configuration: try .init()))
    }

    /// Compiles one ordinary explicit route without invoking its callback.
    /// - Parameter handler: Existing route callback using the normalized unique responder.
    /// - Returns: Validated immutable command catalog.
    /// - Throws: Command definition or router validation failure.
    func commands(_ handler: @escaping @Sendable (InteractionContext) async throws -> Void) throws -> CompiledCommands {
        try CommandCompilation.compile(ExistingCommandFamily(id: "timing", definitions: [
            CommandDefinition.slash(name: "timing", description: "Synthetic timing command")
        ], routes: [CommandRoute(key: .command(name: "timing"), handler: handler)]))
    }

    /// Supplies internal socket-equivalent receipt age only to the private receiver's unit fixture.
    /// - Returns: A dispatch already aged 500 ms, retaining its age as the shared clock advances.
    /// - Throws: Invalid bounded envelope or shard configuration.
    func trustedEvent() throws -> GatewayEvent {
        let envelope = try GatewayEnvelope(.text("{\"op\":0,\"s\":1,\"t\":\"INTERACTION_CREATE\",\"d\":\(Self.interactionJSON)}"),
            maximumBytes: 1_048_576)
        let clock = self.clock, receivedAt = clock.now.advanced(by: .milliseconds(-500))
        return GatewayEvent(shard: try .init(botID: .init(rawValue: 42), topologyGeneration: 0, index: 0, count: 1),
            envelope: envelope, receiptAge: { receivedAt.duration(to: clock.now) })
    }

    /// Closes only this fixture's idle or completed rate owners; no shared production authority is affected.
    func close() async { for coordinator in coordinators { await coordinator.close() } }

    /// Complete bounded interaction with synthetic credentials and no real member/guild data.
    static let interactionJSON = #"{"id":"1","application_id":"9","type":2,"token":"synthetic-timing-token","version":1,"data":{"id":"3","name":"timing","type":1},"app_permissions":"0","entitlements":[],"authorizing_integration_owners":{},"attachment_size_limit":1048576}"#
    /// Complete message accepted by the real continuation decoder.
    static let messageJSON = #"{"id":"7","channel_id":"4","author":{"id":"5","username":"user","discriminator":"0","avatar":null},"content":"response","timestamp":"2026-10-18T12:00:00Z","edited_timestamp":null,"tts":false,"mention_everyone":false,"mentions":[],"mention_roles":[],"attachments":[],"embeds":[],"pinned":false,"type":20}"#
}

/// Trusted admission and acknowledgement timings retain protocol receipt and single-send ownership.
@Suite("MC-29 Gateway timing", .timeLimit(.minutes(1)))
struct MC29GatewayTimingTests {
    /// Existing trusted receipt age includes ingress residence while admission-to-ack excludes that queue age.
    /// - Throws: Unexpected fixture construction, routing or response failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func trustedReceiptAdmissionAndConfirmedAcknowledgement() async throws {
        let fixture = try MC29GatewayFixture(), observations = MC29GatewayObservations(), completed = TestBarrier()
        let clock = fixture.clock, origin = fixture.clock.now
        let timing = OperationTiming(sink: observations.record, now: { origin.duration(to: clock.now) })
        let detailed = MC29GatewayIntervalObservations()
        let intervals = DiscordIntervalTiming(clockDomain: 81, sink: detailed.record,
            now: { origin.duration(to: clock.now) })
        let commands = try fixture.commands { context in
            try await context.responder.deferResponse()
            try clock.advance(by: .milliseconds(100))
            _ = try await context.responder.editOriginal(InteractionMessageEdit(content: .value("private-final"), deferredResponse: true))
            completed.open()
        }
        let adapter = try GatewayInteractionAdapter(applicationID: .init(rawValue: 9), commands: commands,
            services: fixture.services, clock: fixture.clock, admission: fixture.admission,
            serializesPerShard: false, timing: timing, intervals: intervals)
        try await adapter.prepare(client: fixture.client)
        let task = Task { try await adapter.run() }
        try await adapter.receive(fixture.trustedEvent())
        try await completed.wait()
        let samples = observations.snapshot()
        #expect(samples.first { $0.phase == .gatewayReceiveToAdmission }?.elapsed == .milliseconds(500))
        #expect(samples.first { $0.phase == .gatewayAdmissionToAcknowledgement }?.elapsed == .milliseconds(20))
        #expect(samples.first { $0.phase == .gatewayReceiveToAcknowledgement }?.elapsed == .milliseconds(520))
        #expect(samples.first { $0.phase == .interactionAcknowledgementToOriginalEdit }?.elapsed == .milliseconds(130))
        #expect(samples.filter { $0.phase == .gatewayReceiveToAcknowledgement }.allSatisfy { $0.outcome == .succeeded })
        #expect(await fixture.initial.executionCount == 1)
        #expect(await fixture.continuation.executionCount == 1)
        let began = detailed.snapshot().filter { $0.kind == .began }
        #expect(began.count == 6)
        #expect(began.allSatisfy { ($0.timestampNanoseconds ?? -1) >= 0 })
        #expect(began.first { $0.stage == .initialResponse }?.timestampNanoseconds == 0)
        // The existing 500 ms trusted age is scalar evidence; no detailed begin predates this run.
        #expect(detailed.snapshot().first { $0.kind == .ended && $0.stage == .initialResponse }?
            .elapsedNanoseconds == 20_000_000)
        let handler = began.first { $0.stage == .handler }
        #expect(began.first { $0.stage == .initialResponse }?.context.parentID == handler?.context.operationID)
        await adapter.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await fixture.admission.snapshot().activeCount == 0)
        #expect(await adapter.snapshot().activeHandlers == 0)
        #expect(clock.pendingSleepCount == 0)
        await fixture.close()
    }

    /// Public replay constructors cannot forge trusted socket observations or reach the response factory.
    /// - Throws: Unexpected model, command or bounded configuration failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func publicReplayCannotEmitTrustedReceivePhases() async throws {
        let fixture = try MC29GatewayFixture(), observations = MC29GatewayObservations()
        let clock = fixture.clock, origin = fixture.clock.now
        let timing = OperationTiming(sink: observations.record, now: { origin.duration(to: clock.now) })
        let detailed = MC29GatewayIntervalObservations()
        let intervals = DiscordIntervalTiming(clockDomain: 82, sink: detailed.record,
            now: { origin.duration(to: clock.now) })
        let commands = try fixture.commands { _ in Issue.record("Untrusted replay must not invoke a command") }
        let adapter = try GatewayInteractionAdapter(applicationID: .init(rawValue: 9), commands: commands,
            services: fixture.services, clock: fixture.clock, admission: fixture.admission, timing: timing, intervals: intervals)
        try await adapter.prepare(client: fixture.client)
        let event = try GatewayEvent(shard: .init(botID: .init(rawValue: 42), topologyGeneration: 0, index: 0, count: 1),
            name: "INTERACTION_CREATE", sequence: 1, data: JSONValue.parse(Data(MC29GatewayFixture.interactionJSON.utf8)))
        await #expect(throws: GatewayInteractionFailure.untrustedEvent) { try await adapter.receive(event) }
        #expect(observations.snapshot().isEmpty)
        #expect(detailed.snapshot().isEmpty)
        #expect(await fixture.initial.executionCount == 0)
        #expect(await adapter.snapshot().bufferedEvents == 0)
        await adapter.cancel(); await fixture.close()
    }

    /// Unknown initial submission retains its uncertainty and emits no acknowledgement-success measurements.
    /// - Throws: Unexpected fixture or callback synchronization failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func uncertainCallbackDoesNotReportAcknowledgement() async throws {
        let fixture = try MC29GatewayFixture(uncertain: true), observations = MC29GatewayObservations()
        let failed = TestBarrier(), clock = fixture.clock, origin = fixture.clock.now
        let timing = OperationTiming(sink: observations.record, now: { origin.duration(to: clock.now) })
        let commands = try fixture.commands { context in try await context.responder.deferResponse() }
        let authority = try GatewayHandlerAuthority(maximumActiveHandlers: 1)
        let adapter = try GatewayInteractionAdapter(applicationID: .init(rawValue: 9), commands: commands,
            services: fixture.services, clock: fixture.clock, admission: fixture.admission, authority: authority,
            failurePolicy: .continueInvocations, failureObserver: { _ in failed.open() }, timing: timing)
        try await adapter.prepare(client: fixture.client)
        let task = Task { try await adapter.run() }
        try await adapter.receive(fixture.trustedEvent())
        try await failed.wait()
        while await authority.snapshot().activeHandlers != 0 { try Task.checkCancellation(); await Task.yield() }
        let samples = observations.snapshot()
        #expect(samples.contains { $0.phase == .interactionInitialResponse && $0.outcome == .uncertain })
        #expect(!samples.contains { $0.phase == .gatewayReceiveToAcknowledgement || $0.phase == .gatewayAdmissionToAcknowledgement })
        #expect(await fixture.initial.executionCount == 1)
        #expect(await fixture.continuation.executionCount == 0)
        await adapter.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await fixture.admission.snapshot().activeCount == 0)
        await fixture.close()
    }
}
