// File: Tests/DiscordInteractionsTests/InteractionEncodingReuseTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCore
import DiscordHTTP
import DiscordLogging
import DiscordModels
import DiscordTestSupport
import DiscordTransport
import Foundation
import Testing
@testable import DiscordInteractions

/// Proves finite callback serialization reuse through exact admission and real built-in wire paths.
/// The successful-encoding event counts the responder's serialization boundary; byte equality proves
/// that built-in delivery consumes that result rather than materializing a different callback body.
@Suite(.timeLimit(.minutes(1))) struct InteractionEncodingReuseTests {
    /// Builds small and large legal Unicode callbacks without relying on undocumented message limits.
    /// - Parameter large: True includes 2,000 content and 6,000 embed scalars; false is a short escaped string.
    /// - Returns: A fully validated JSON-only message callback, around 32 KiB for the large fixture.
    /// - Throws: Model, JSON or outgoing payload validation errors indicate an invalid fixture.
    static func callback(large: Bool) throws -> InteractionResponse {
        guard large else { return .message(try InteractionMessageCreate(content: .value("hello \"🚀\"\n"))) }
        let first = try MessageEmbed(data: JSONValue.object(["description": .string(String(repeating: "🚀", count: 4_000))]).serialized())
        let second = try MessageEmbed(data: JSONValue.object(["description": .string(String(repeating: "🚀", count: 2_000))]).serialized())
        return .message(try InteractionMessageCreate(content: .value(String(repeating: "🚀", count: 2_000)),
            embeds: .value([first, second])))
    }

    /// Counts only successful production serialization boundaries and checks their exact encoded charge.
    /// - Parameters:
    ///   - logs: Isolated per-test records captured only around the response operation.
    ///   - bytes: Independently serialized baseline callback bytes outside that capture scope.
    /// Expected one is a finite mechanism assertion, not a timing or allocator measurement.
    static func expectOneEncoding(_ logs: LogRecorder, bytes: Data) {
        let encodings = logs.entries.filter { $0.metadata["dk.event"] == "interactions.response.validated" }
        #expect(encodings.count == 1)
        #expect(encodings.first?.metadata["dk.bytes"]?.description == String(bytes.count))
    }

    /// Inline HTTP transmits the same bytes reserved by the responder, with one serialization boundary.
    /// - Parameter large: Independent small and large valid callback fixtures.
    /// - Throws: Unexpected signing, body ownership, response or fixture errors fail the test.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func inlineWireAndExactAdmission(large: Bool) async throws {
        let callback = try Self.callback(large: large)
        let expected = try callback.jsonValue(interactionType: .applicationCommand).serialized()
        let admission = try InteractionAcknowledgementAdmission(maximumConcurrent: 1, maximumBytes: expected.count)
        let logs = LogRecorder(), clock = ManualClock()
        let transport = ScriptedHTTPResponder { response in
            #expect(response.status == 200)
            #expect(response.headers == [HTTPHeader(name: "Content-Type", value: "application/json")])
            #expect(await admission.snapshot().encodedBytes == expected.count)
            #expect(await admission.snapshot().activeCount == 1)
            let transmitted = try await ResponseBody.collect(response.body, maximumBytes: expected.count)
            #expect(transmitted == expected)
        }
        let application = try InteractionHTTPApplication(applicationID: .init(rawValue: 2),
            ingress: DiscordSignedIngress(verifier: SignedIngressTests.verifier(.allowIdenticalRetries)), admission: admission)
        try await DiscordLog.$loggerFactory.withValue({ logs.makeLogger($0) }) {
            try await application.handle(InteractionHTTPApplicationTests.exchange(InteractionHTTPApplicationTests.fixture(), responder: transport),
                context: TransportContext(clock: clock)) { try await $0.responder.respond(callback) }
        }
        Self.expectOneEncoding(logs, bytes: expected)
        #expect(await transport.reservationCount == 1)
        #expect(await transport.completionCount == 1)
        #expect(await admission.snapshot().encodedBytes == 0)
        #expect(clock.pendingSleepCount == 0)
    }

    /// Gateway REST reuses the admission serialization with identical callback routing and wire bytes.
    /// - Parameter large: Independent small and large valid callback fixtures.
    /// - Throws: Unexpected model, descriptor, transport or response lifecycle errors fail the test.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func restWireAndExactAdmission(large: Bool) async throws {
        let callback = try Self.callback(large: large), input = try InteractionLifecycleTests.interaction()
        let expected = try callback.jsonValue(interactionType: .applicationCommand).serialized()
        let admission = try InteractionAcknowledgementAdmission(maximumConcurrent: 1, maximumBytes: expected.count)
        let clock = ManualClock(), logs = LogRecorder()
        let transport = try ScriptedHTTPTransport(steps: [{ request in
            #expect(request.method == "POST")
            #expect(request.url.path == "/api/v10/interactions/18446744073709551615/test-token/callback")
            #expect(request.url.query == nil)
            #expect(!request.headers.contains { $0.name.lowercased() == "authorization" })
            #expect(request.headers.contains(HTTPHeader(name: "Content-Type", value: "application/json")))
            #expect(await admission.snapshot().encodedBytes == expected.count)
            let transmitted = try await ResponseBody.collect(request.body, maximumBytes: expected.count)
            #expect(transmitted == expected)
            return HTTPResponse(status: 204)
        }])
        let coordinator = RateLimitCoordinator(clock: clock)
        let client = RESTClient(credential: .interaction(input.token), identity: RateLimitIdentity(),
            transport: transport, coordinator: coordinator, clock: clock, retryPolicy: .init(maximumAttempts: 1))
        let responder = InteractionResponder(interaction: input, deliveryMode: .gateway, clock: InteractionClock(clock),
            sink: .rest(interaction: input, initialClient: client, continuationClient: client, clock: clock), admission: admission)
        try await DiscordLog.$loggerFactory.withValue({ logs.makeLogger($0) }) { try await responder.respond(callback) }
        Self.expectOneEncoding(logs, bytes: expected)
        #expect(await responder.snapshot() == .acknowledged(.channelMessageWithSource))
        #expect(await transport.executionCount == 1)
        #expect(await admission.snapshot().encodedBytes == 0)
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await coordinator.close()
    }

    /// A byte ceiling one below the complete body rejects delivery and restores the initial slot.
    /// - Parameter large: Both fixtures charge UTF-8 bytes rather than Unicode scalar estimates.
    /// - Throws: Unexpected fixture or admission configuration errors fail the test.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func exactCapacityRejectsBeforeDelivery(large: Bool) async throws {
        let callback = try Self.callback(large: large)
        let expected = try callback.jsonValue(interactionType: .applicationCommand).serialized()
        let admission = try InteractionAcknowledgementAdmission(maximumBytes: expected.count - 1)
        let clock = ManualClock(), logs = LogRecorder()
        let responder = InteractionResponder(interaction: try InteractionLifecycleTests.interaction(), deliveryMode: .http,
            clock: InteractionClock(clock), sink: InteractionResponseSink(encodedInitial: { _, _ in
                Issue.record("Over-capacity callback entered delivery")
            }), admission: admission)
        await DiscordLog.$loggerFactory.withValue({ logs.makeLogger($0) }) {
            await #expect(throws: InteractionLifecycleError.acknowledgementCapacityExceeded) { try await responder.respond(callback) }
        }
        Self.expectOneEncoding(logs, bytes: expected)
        #expect(await responder.snapshot() == .pending)
        #expect(await admission.snapshot().encodedBytes == 0)
        #expect(clock.pendingSleepCount == 0)
    }

    /// Incompatible callback kinds fail typed validation before serialization, admission or encoded delivery.
    /// - Parameter kind: PING and autocomplete retain their exclusive callback categories.
    /// - Throws: Unexpected fixture or admission setup failures fail the test.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [1, 4]) func incompatibleCallbacksDoNotEncode(kind: Int) async throws {
        let clock = ManualClock(), logs = LogRecorder(), admission = try InteractionAcknowledgementAdmission()
        let responder = InteractionResponder(interaction: try InteractionLifecycleTests.interaction(kind: kind), deliveryMode: .http,
            clock: InteractionClock(clock), sink: InteractionResponseSink(encodedInitial: { _, _ in
                Issue.record("Invalid callback entered encoded delivery")
            }), admission: admission)
        await DiscordLog.$loggerFactory.withValue({ logs.makeLogger($0) }) {
            await #expect(throws: DiscordError.validation(.invalidValue)) { try await responder.deferResponse() }
        }
        #expect(logs.entries.filter { $0.metadata["dk.event"] == "interactions.response.validated" }.isEmpty)
        #expect(await responder.snapshot() == .pending)
        #expect(await admission.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
    }

    /// Byte-aware built-in delivery retains definite non-submission versus ambiguous acknowledgement ownership.
    /// - Parameter failure: Positive non-submission evidence or explicitly uncertain delivery.
    /// - Throws: Unexpected fixture, model or admission setup errors fail the test.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [InteractionDeliveryError.notSubmitted, .indeterminate])
    func encodedDeliveryFailure(failure: InteractionDeliveryError) async throws {
        let callback = try Self.callback(large: false)
        let expected = try callback.jsonValue(interactionType: .applicationCommand).serialized()
        let admission = try InteractionAcknowledgementAdmission(), clock = ManualClock()
        let responder = InteractionResponder(interaction: try InteractionLifecycleTests.interaction(), deliveryMode: .http,
            clock: InteractionClock(clock), sink: InteractionResponseSink(encodedInitial: { bytes, timeout in
                #expect(bytes == expected)
                #expect(timeout == .seconds(3))
                throw failure
            }), admission: admission)
        await #expect(throws: failure) { try await responder.respond(callback) }
        #expect(await responder.snapshot() == (failure == .notSubmitted ? .pending : .indeterminate))
        #expect(await admission.snapshot().activeCount == 0)
        #expect(await admission.snapshot().encodedBytes == 0)
        #expect(clock.pendingSleepCount == 0)
    }

    /// A REST sink attached to a different trigger kind retains its original typed compatibility rejection.
    /// The unsupported caller composition must never transmit a command message to a PING callback route.
    /// - Throws: Unexpected setup errors fail the test; exact validation and conservative ownership are asserted.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func mismatchedRESTTriggerRetainsValidation() async throws {
        let clock = ManualClock(), command = try InteractionLifecycleTests.interaction()
        let ping = try InteractionLifecycleTests.interaction(kind: 1)
        let transport = try ScriptedHTTPTransport(steps: [])
        let coordinator = RateLimitCoordinator(clock: clock)
        let client = RESTClient(credential: .interaction(ping.token), identity: RateLimitIdentity(),
            transport: transport, coordinator: coordinator, clock: clock)
        let admission = try InteractionAcknowledgementAdmission()
        let responder = InteractionResponder(interaction: command, deliveryMode: .gateway, clock: InteractionClock(clock),
            sink: .rest(interaction: ping, initialClient: client, continuationClient: client, clock: clock), admission: admission)
        await #expect(throws: DiscordError.validation(.invalidValue)) { try await responder.respond(Self.callback(large: false)) }
        #expect(await transport.executionCount == 0)
        #expect(await responder.snapshot() == .pending)
        #expect(await admission.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await coordinator.close()
    }
}
