// File: Tests/DiscordInteractionsTests/RuntimeIntervalIngressTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordHTTP
import DiscordCore
import DiscordLogging
import DiscordModels
import DiscordTestSupport
import DiscordTransport
import Foundation
import Testing
@testable import DiscordInteractions

/// Actual HTTP application boundaries remain distinct from receipt provenance and final handler work.
@Suite(.timeLimit(.minutes(1))) struct RuntimeIntervalIngressTests {
    /// Proves first confirmation remains successful while later handler failure ends the joined workflow.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func firstResponsePrecedesJoinedWorkflow(enabled: Bool) async throws {
        let clock = ManualClock(), origin = clock.now, events = IngressIntervalEvents()
        let observer = DiscordIntervalTiming(clockDomain: 601, sink: events.record, now: {
            events.read(); return origin.duration(to: clock.now)
        })
        let intervals = enabled ? observer : nil
        let verifier = try SignedRequestVerifier(publicKey: SignedIngressTests.hex(SignedIngressTests.key().publicKey.rawRepresentation),
            now: { 1000 }, intervals: intervals)
        let admission = try InteractionAcknowledgementAdmission()
        let ingress = try DiscordSignedIngress(verifier: verifier, intervals: intervals)
        let app = InteractionHTTPApplication(applicationID: .init(rawValue: 2), ingress: ingress,
            admission: admission, intervals: intervals)
        let sent = TestBarrier(), release = TestBarrier()
        let http = ScriptedHTTPResponder { response in
            _ = try await ResponseBody.collect(response.body, maximumBytes: 1000)
            try clock.advance(by: .milliseconds(7)); sent.open()
        }
        let exchange = try InteractionHTTPApplicationTests.exchange(InteractionHTTPApplicationTests.fixture(), responder: http)
        let task = Task {
            try await app.handle(exchange, context: TransportContext(clock: clock)) { context in
                try clock.advance(by: .milliseconds(11))
                try await context.responder.reply(.init(content: .value("fixture")))
                try await release.wait()
                try clock.advance(by: .milliseconds(13))
                throw DiscordError.validation(.invalidValue)
            }
        }
        try await sent.wait()
        // The response callback opens before its owner records the sink-completion boundary.
        while enabled && !events.values.contains(where: { $0.kind == .ended && $0.stage == .firstResponse }) { await Task.yield() }
        #expect(!events.values.contains { $0.kind == .ended && $0.operation == .interactionHTTP && $0.stage == .operation })
        release.open()
        await #expect(throws: DiscordError.validation(.invalidValue)) { try await task.value }
        let ended = events.values.filter { $0.kind == .ended }
        if enabled {
            let response = ended.first { $0.stage == .firstResponse }
            let workflow = ended.first { $0.operation == .interactionHTTP && $0.stage == .operation }
            #expect(response?.outcome == .succeeded && response?.elapsedNanoseconds == 18_000_000)
            #expect(workflow?.outcome == .failed && workflow?.elapsedNanoseconds == 31_000_000)
            #expect(ended.contains { $0.operation == .signedIngress && $0.stage == .body })
            #expect(ended.contains { $0.stage == .signatureVerification })
            #expect(ended.contains { $0.stage == .replayAdmission })
            #expect(ended.contains { $0.stage == .decode })
            #expect(events.values.filter { $0.kind == .began }.count == ended.count)
            #expect(events.values.allSatisfy { $0.context.clockDomain == 601 })
        } else { #expect(events.values.isEmpty && events.reads == 0) }
        #expect(await http.reservationCount == 1)
        #expect(await ingress.activeRequestCount() == 0)
        #expect(await admission.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
    }

    /// Distinguishes positive no-submit evidence from uncertainty while retaining one reserved response.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func sendEvidencePreservesSingleReservation(uncertain: Bool) async throws {
        let events = IngressIntervalEvents()
        let intervals = DiscordIntervalTiming(clockDomain: 607, sink: events.record, now: { .zero })
        let app = try InteractionHTTPApplication(applicationID: .init(rawValue: 2),
            ingress: DiscordSignedIngress(verifier: SignedIngressTests.verifier()),
            admission: InteractionAcknowledgementAdmission(), intervals: intervals)
        let error: InteractionDeliveryError = uncertain ? .indeterminate : .notSubmitted
        let http = ScriptedHTTPResponder { _ in throw error }
        let exchange = try InteractionHTTPApplicationTests.exchange(InteractionHTTPApplicationTests.fixture(), responder: http)
        await #expect(throws: error) {
            try await app.handle(exchange, context: TransportContext(clock: ManualClock())) { context in
                try await context.responder.reply(.init(content: .value("fixture")))
            }
        }
        #expect(await http.reservationCount == 1)
        #expect(await http.completionCount == 0)
        #expect(events.values.filter { $0.kind == .ended && $0.stage == .firstResponse }.map(\.outcome)
            == [uncertain ? .uncertain : .failed])
        #expect(events.values.filter { $0.kind == .began }.count == events.values.filter { $0.kind == .ended }.count)
    }

    /// Proves synchronous observer work consumes the original initial-response deadline.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func observerCannotExtendTheInitialDeadline() async throws {
        let clock = ManualClock(), events = IngressIntervalEvents(), origin = clock.now
        let intervals = DiscordIntervalTiming(clockDomain: 606, sink: { event in
            events.record(event)
            if event.kind == .began && event.operation == .interactionHTTP && event.stage == .operation {
                do { try clock.advance(by: .seconds(3)) }
                catch { Issue.record("Finite virtual-clock advance failed") }
            }
        }, now: { origin.duration(to: clock.now) })
        let app = try InteractionHTTPApplication(applicationID: .init(rawValue: 2),
            ingress: DiscordSignedIngress(verifier: SignedIngressTests.verifier()),
            admission: InteractionAcknowledgementAdmission(), intervals: intervals)
        let http = ScriptedHTTPResponder { #expect($0.status == 500) }
        let exchange = try InteractionHTTPApplicationTests.exchange(InteractionHTTPApplicationTests.fixture(), responder: http)
        await #expect(throws: InteractionLifecycleError.deadlineExceeded) {
            try await app.handle(exchange, context: TransportContext(clock: clock)) { context in
                try await context.responder.reply(.init(content: .value("fixture")))
            }
        }
        #expect(await http.reservationCount == 1)
        #expect(events.values.contains { $0.kind == .ended && $0.stage == .initialResponse && $0.outcome == .failed })
        #expect(clock.pendingSleepCount == 0)
    }

    /// Rejects tampered signed bytes before replay mutation or typed decoding.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func signatureRejectionCannotReachDecodeOrReplay() async throws {
        let events = IngressIntervalEvents()
        let intervals = DiscordIntervalTiming(clockDomain: 602, sink: events.record, now: { .zero })
        let verifier = try SignedRequestVerifier(publicKey: SignedIngressTests.hex(SignedIngressTests.key().publicKey.rawRepresentation),
            now: { 1000 }, intervals: intervals)
        let ingress = try DiscordSignedIngress(verifier: verifier, intervals: intervals)
        let app = InteractionHTTPApplication(applicationID: .init(rawValue: 2), ingress: ingress,
            admission: try InteractionAcknowledgementAdmission(), intervals: intervals)
        let body = InteractionHTTPApplicationTests.fixture()
        let request = try SignedIngressTests.request(body + Data([32]), fields: SignedIngressTests.headers(body))
        let http = ScriptedHTTPResponder { #expect($0.status == 401) }
        try await app.handle(HTTPExchange(request: request, responder: http), context: TransportContext(clock: ManualClock())) { _ in
            Issue.record("Rejected signature reached application handler")
        }
        #expect(events.values.contains { $0.kind == .ended && $0.stage == .signatureVerification && $0.outcome == .failed })
        #expect(!events.values.contains { $0.stage == .decode || $0.stage == .replayAdmission })
        #expect(events.values.filter { $0.kind == .ended && $0.stage == .firstResponse }.map(\.outcome) == [.failed])
        #expect(await verifier.replayEntryCount() == 0)
    }

    /// Attributes exact replay rejection to admission after successful signature verification.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func replayRefusalOccursAfterSuccessfulSignature() async throws {
        let events = IngressIntervalEvents()
        let intervals = DiscordIntervalTiming(clockDomain: 603, sink: events.record, now: { .zero })
        let verifier = try SignedRequestVerifier(publicKey: SignedIngressTests.hex(SignedIngressTests.key().publicKey.rawRepresentation),
            now: { 1000 }, intervals: intervals)
        let body = Data("fixture".utf8), headers = try SignedIngressTests.headers(body)
        _ = try await verifier.verify(headers: headers, body: body)
        await #expect(throws: SignedIngressFailure.replay) { try await verifier.verify(headers: headers, body: body) }
        let ended = events.values.filter { $0.kind == .ended }
        #expect(ended.filter { $0.stage == .signatureVerification }.map(\.outcome) == [.succeeded, .succeeded])
        #expect(ended.filter { $0.stage == .replayAdmission }.map(\.outcome) == [.succeeded, .failed])
    }
}

private final class IngressIntervalEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DiscordIntervalEvent] = []
    private var count = 0
    /// Copies an independent endpoint snapshot under the recorder lock.
    var values: [DiscordIntervalEvent] { lock.withLock { stored } }
    /// Counts only explicit instrumentation-clock reads.
    var reads: Int { lock.withLock { count } }
    /// Records one finite test endpoint synchronously.
    func record(_ event: DiscordIntervalEvent) { lock.withLock { stored.append(event) } }
    /// Increments the instrumentation-clock read counter synchronously.
    func read() { lock.withLock { count += 1 } }
}
