// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/InteractionTimingRunner.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Crypto
import DiscordBenchmarkSupport
import DiscordCommands
import DiscordCore
import DiscordInteractions
import DiscordLogging
import DiscordModels
import DiscordTransport
import Foundation

/// Finite signed-HTTP fixtures. No case supplies trusted listener/socket receipt provenance.
enum InteractionTimingScenario: String, Codable, CaseIterable, Sendable {
    case immediate, manualDefer, automaticDefer, duplicate, invalidSignature, malformed
    case uncertain, cancelled, admissionRefusal, callbackError, handlerFailureAfterAcknowledgement, deadlineRace
    case durableAdmission, durableDuplicate, durableFailure

    /// Selects webhook event admission, which has a separate consumer transaction authority.
    var isDurable: Bool { self == .durableAdmission || self == .durableDuplicate || self == .durableFailure }
}

/// Exact active ownership after all request tasks and body closes have joined.
struct InteractionTimingCleanup: Codable, Sendable {
    let ingress: Int
    let handlers: Int
    let acknowledgements: Int
    let bodies: Int
    let responseSlots: Int
    /// Sums independently owned active work after the cohort has joined.
    var remainingOwners: Int { ingress + handlers + acknowledgements + bodies + responseSlots }
    /// True only when every declared owner count is zero.
    var isEmpty: Bool { remainingOwners == 0 }
}

/// Complete bounded observations from injected HTTP requests carrying actual Ed25519 signatures.
struct InteractionTimingReport: Codable, Sendable {
    let scenario: InteractionTimingScenario
    let requests: Int
    let concurrency: Int
    let counts: BenchmarkCounts
    let metrics: [BenchmarkMetric]
    let clockDomain: String
    let durationNanoseconds: UInt64
    let cleanup: InteractionTimingCleanup
    let durableTransactions: Int
    let setupDurableTransactions: Int
    let notes: [String]
}

/// Exercises authentication, decode, command routing and inline responses without external services.
struct InteractionTimingRunner: Sendable {
    /// Runs finite signed-request cohorts, recording every outcome before final diagnostics.
    /// - Parameters:
    ///   - scenario: Explicit authenticated, rejected, cancelled or uncertain fixture behavior.
    ///   - requests: Number of measured requests in 1...100,000.
    ///   - concurrency: Maximum cohort size in 1...256, bounded by requests.
    ///   - delay: Explicit provider wait in zero through one second.
    /// - Returns: Whole-population metrics, exact admission receipts and joined resource cleanup.
    /// - Throws: Invalid limits, signing or fixture construction failure; request errors become outcomes.
    func run(scenario: InteractionTimingScenario, requests: Int = 32, concurrency: Int = 4,
        delay: Duration = .milliseconds(2)) async throws -> InteractionTimingReport {
        guard (1...100_000).contains(requests), (1...256).contains(concurrency), concurrency <= requests,
              delay >= .zero, delay <= .seconds(1) else { throw LoadFailure.invalidArguments }
        if scenario.isDurable { return try await runDurable(scenario: scenario, requests: requests, concurrency: concurrency, delay: delay) }
        let statistics = try RunStatistics(workloads: [.ingressApplicationResponse, .ingressBodyRead,
            .ingressSignature, .ingressAdmission, .ingressDecode, .commandRoute, .commandAdmission,
            .commandArguments, .commandHandler, .interactionHandler, .interactionWorkflow,
            .interactionProviderWait, .interactionInitialResponse, .interactionOriginalEdit, .commandPolicy])
        let clock = ContinuousClock(), origin = clock.now
        let collection = InteractionTimingCollectionGate()
        let intervals = DiscordIntervalTiming(clockDomain: UInt64.random(in: 1...UInt64.max), sink: { event in
            guard collection.enabled, event.kind == .ended, let workload = interactionWorkload(event) else { return }
            let outcome = interactionIntervalOutcome(event.outcome)
            statistics.record(event.validity == .valid ? (event.elapsedNanoseconds.map(Duration.nanoseconds) ?? .seconds(-1)) : .seconds(-1),
                workload: workload, outcome: outcome)
        }, now: { origin.duration(to: clock.now) })
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 19, count: 32))
        let verifier = try SignedRequestVerifier(publicKey: interactionHex(key.publicKey.rawRepresentation),
            maximumReplayEntries: max(1, requests), now: { 1_000 }, intervals: intervals)
        let ingress = try DiscordSignedIngress(verifier: verifier, maximumConcurrentRequests: concurrency, intervals: intervals)
        let acknowledgement = try InteractionAcknowledgementAdmission(maximumConcurrent: concurrency,
            maximumBytes: scenario == .admissionRefusal ? 1 : 1_048_576)
        let route = CommandRoute(key: try .command(name: "timing")) { context in
            if scenario == .manualDefer { try await context.responder.deferResponse() }
            let start = clock.now
            do {
                if delay > .zero { try await clock.sleep(for: delay) }
                let terminal = clock.now
                statistics.record(start.duration(to: terminal), workload: .interactionProviderWait, outcome: .success)
            } catch {
                let terminal = clock.now
                statistics.record(start.duration(to: terminal), workload: .interactionProviderWait,
                    outcome: interactionFailureOutcome(error))
                throw error
            }
            if scenario == .automaticDefer {
                // Wait for the actual automatic acknowledgement; this fixture always measures an
                // automatic defer followed by its first edit even when timer scheduling is delayed.
                while true {
                    try Task.checkCancellation()
                    let state = await context.responder.snapshot()
                    if case .acknowledged = state { break }
                    guard state == .pending || state == .acknowledging else {
                        throw InteractionLifecycleError.deadlineExceeded
                    }
                    try await clock.sleep(for: .microseconds(50))
                }
            }
            if scenario == .manualDefer || scenario == .automaticDefer {
                // An automatic defer can race the handler at tiny configured delays. Await its actual
                // state before choosing edit versus an initial reply; no initial response is replayed.
                var state = await context.responder.snapshot()
                while state == .acknowledging { await Task.yield(); state = await context.responder.snapshot() }
                if case .acknowledged = state {
                    _ = try await context.responder.editOriginal(.init(content: .value("fixture-final"), deferredResponse: true))
                } else { try await context.responder.reply(.init(content: .value("fixture-final"))) }
            } else { try await context.responder.reply(.init(content: .value("fixture-final"))) }
            if scenario == .handlerFailureAfterAcknowledgement { throw DiscordError.validation(.invalidValue) }
        }.wrappingExecution { _, execute in
            let start = clock.now
            do {
                try await execute()
                let end = clock.now
                statistics.record(start.duration(to: end), workload: .commandPolicy, outcome: .success)
            } catch {
                let end = clock.now
                statistics.record(start.duration(to: end), workload: .commandPolicy, outcome: interactionFailureOutcome(error))
                throw error
            }
        }
        let router = try CommandRouter(routes: [route], maximumConcurrentHandlers: concurrency, intervals: intervals)
        let autoDefer = scenario == .automaticDefer
            ? try InteractionAutoDeferPolicy(delay: max(.nanoseconds(1), delay / 2), mode: .message(ephemeral: true)) : nil
        let app = InteractionHTTPApplication(applicationID: .init(rawValue: 2), ingress: ingress,
            admission: acknowledgement, autoDefer: autoDefer, intervals: intervals)
        // Duplicate setup authenticates the exact fixture once, outside measured request timing.
        // Its instrumentation is excluded by the collection gate until setup has completed.
        let duplicateBody = interactionFixture(ordinal: 0)
        let duplicateHeaders = try interactionHeaders(key: key, body: duplicateBody)
        if scenario == .duplicate {
            _ = try await verifier.verify(headers: duplicateHeaders, body: duplicateBody)
        }
        collection.enable()
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        var completed = 0, admitted = 0, bodyOwners = 0, slotOwners = 0
        var first: ContinuousClock.Instant?, last: ContinuousClock.Instant?
        for wave in stride(from: 0, to: requests, by: concurrency) {
            if Task.isCancelled { break }
            // Signing, request allocation and fixture construction precede measured caller entry.
            let fixtures = try (wave..<min(requests, wave + concurrency)).map { ordinal in
                let signed = scenario == .duplicate ? duplicateBody
                    : scenario == .malformed ? Data("malformed-\(ordinal)".utf8) : interactionFixture(ordinal: ordinal)
                let headers = scenario == .duplicate ? duplicateHeaders : try interactionHeaders(key: key, body: signed)
                let bytes = scenario == .invalidSignature ? signed + Data([32]) : signed
                let source = InteractionTimingBody(bytes)
                let stream = try BodyStream(maximumChunkBytes: 4096, next: { await source.next() }, close: { await source.close() })
                let response = InteractionTimingResponse(failure: scenario == .uncertain ? .indeterminate : scenario == .callbackError ? .notSubmitted : nil)
                return (HTTPExchange(request: HTTPRequest(method: "POST", url: URL(string: "https://fixture.invalid/interactions")!, headers: headers, body: stream),
                    responder: response), source, response, InteractionTimingRequestReceipt())
            }
            await withTaskGroup(of: InteractionTimingResult.self) { group in
                for (exchange, source, response, receipt) in fixtures {
                    group.addTask {
                        if scenario == .cancelled { withUnsafeCurrentTask { $0?.cancel() } }
                        let start = clock.now
                        let result: BenchmarkOutcome
                        let terminal: ContinuousClock.Instant
                        do {
                            try await app.handle(exchange, context: TransportContext(clock: clock,
                                deadline: scenario == .deadlineRace ? clock.now : nil), continuations: { _ in
                                InteractionResponseSink(initial: { _, _ in }, editOriginal: { _, _ in
                                    try Message(data: Data(#"{"id":"4","channel_id":"5","author":{"id":"6","username":"fixture","discriminator":"0","avatar":null},"content":"fixture-final","timestamp":"2026-01-01T00:00:00Z","edited_timestamp":null,"tts":false,"mention_everyone":false,"mentions":[],"mention_roles":[],"attachments":[],"embeds":[],"pinned":false,"type":0}"#.utf8))
                                })
                            }) { context in receipt.admit(); _ = try await router.route(context) }
                            terminal = clock.now
                            let status = await response.status
                            result = status == 200 ? .success : status == 401 || status == 503 ? .rejected : .failure
                        } catch { terminal = clock.now; result = interactionFailureOutcome(error) }
                        statistics.record(start.duration(to: terminal), workload: .interactionWorkflow, outcome: result)
                        await response.close()
                        return InteractionTimingResult(outcome: result, submitted: start, terminal: terminal,
                            admitted: receipt.admitted, bodyOwners: await source.remainingOwners, slotOwners: await response.remainingOwners)
                    }
                }
                for await result in group {
                    completed += 1; admitted += result.admitted ? 1 : 0; outcomes[result.outcome, default: 0] += 1
                    first = first.map { min($0, result.submitted) } ?? result.submitted
                    last = last.map { max($0, result.terminal) } ?? result.terminal
                    bodyOwners += result.bodyOwners; slotOwners += result.slotOwners
                }
            }
        }
        let cleanup = InteractionTimingCleanup(ingress: await ingress.activeRequestCount(), handlers: await router.activeHandlerCount,
            acknowledgements: await acknowledgement.snapshot().activeCount, bodies: bodyOwners, responseSlots: slotOwners)
        return InteractionTimingReport(scenario: scenario, requests: requests, concurrency: concurrency,
            counts: .init(offered: UInt64(completed), admitted: UInt64(admitted), completed: UInt64(completed),
                outcomes: outcomes, deadlineMisses: outcomes[.timedOut, default: 0]), metrics: statistics.metrics(), clockDomain: statistics.clockDomain,
            durationNanoseconds: try BenchmarkTime.nanoseconds(duration: first.flatMap { a in last.map { a.duration(to: $0) } } ?? .zero),
            cleanup: cleanup, durableTransactions: 0, setupDurableTransactions: 0, notes: [
                "Injected HTTP requests carry real Ed25519 signatures; no sockets, Discord credentials or trusted receipt claims.",
                "Application response starts after workflow begin callback at handle entry; workflow starts at external caller entry and stops at joined handle result/error, before response-status diagnostics.",
                "Workflow histograms use logical caller outcomes; owner intervals retain their documented local outcomes, so successful handling of a rejected HTTP request does not become a successful workflow.",
                "Provider wait and policy are explicit fixture wrappers; policy includes the enclosed handler. Nested intervals overlap.",
                "deadlineRace supplies an already-expired caller deadline before signed body admission; in-flight response/deadline races have separate virtual-clock runtime tests.",
                "Admitted counts actual normalized application-handler invocations; authentication/decode refusal never increments admission.",
                "Signing and allocation precede measured caller entry. Every completion is retained in bounded outcome histograms.",
                "Duplicate fixture primes one bounded replay entry outside measured request intervals and histograms.",
                "Automatic-defer handlers await the actual automatic acknowledgement before their first edit; timer/handler scheduling remains measured."
            ])
    }
}

private struct InteractionTimingResult: Sendable {
    let outcome: BenchmarkOutcome
    let submitted: ContinuousClock.Instant
    let terminal: ContinuousClock.Instant
    let admitted: Bool
    let bodyOwners: Int
    let slotOwners: Int
}

/// Maps only finite runtime owner boundaries to declared development metric identities.
private func interactionWorkload(_ event: DiscordIntervalEvent) -> BenchmarkWorkload? {
    switch (event.operation, event.stage) {
    case (.signedIngress, .body): .ingressBodyRead
    case (.signedIngress, .signatureVerification): .ingressSignature
    case (.signedIngress, .replayAdmission): .ingressAdmission
    case (.interactionHTTP, .firstResponse): .ingressApplicationResponse
    case (.interactionHTTP, .decode): .ingressDecode
    case (.interactionHTTP, .handler): .interactionHandler
    case (.commandRouting, .operation): .commandRoute
    case (.commandRouting, .admission): .commandAdmission
    case (.commandRouting, .preparation): .commandArguments
    case (.commandRouting, .handler): .commandHandler
    case (.interactionResponse, .initialResponse): .interactionInitialResponse
    case (.interactionResponse, .originalEdit): .interactionOriginalEdit
    default: nil
    }
}

/// Retains the runtime boundary outcome without claiming remote delivery or request acceptance.
private func interactionIntervalOutcome(_ value: DiscordIntervalOutcome?) -> BenchmarkOutcome {
    switch value {
    case .succeeded: .success
    case .cancelled: .cancelled
    case .uncertain: .uncertain
    default: .failure
    }
}

/// Classifies typed caller failures, retaining refusal, timeout, cancellation and mutation uncertainty.
private func interactionFailureOutcome(_ error: any Error) -> BenchmarkOutcome {
    if (error as? InteractionDeliveryError) == .indeterminate { return .uncertain }
    if (error as? TransportFailure) == .deadlineExceeded || (error as? InteractionLifecycleError) == .deadlineExceeded { return .timedOut }
    if (error as? InteractionLifecycleError) == .acknowledgementCapacityExceeded { return .rejected }
    if error is CancellationError || (error as? DiscordError) == .cancelled { return .cancelled }
    if case .unknownMutationOutcome = error as? DiscordError { return .uncertain }
    return .failure
}

/// Encodes the finite test key/signature bytes using Discord hexadecimal header representation.
private func interactionHex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
/// Signs the exact timestamp prefix and body outside measured caller entry.
private func interactionHeaders(key: Curve25519.Signing.PrivateKey, body: Data) throws -> [HTTPHeader] {
    [.init(name: "X-Signature-Timestamp", value: "1000"),
     .init(name: "X-Signature-Ed25519", value: interactionHex(try key.signature(for: Data("1000".utf8) + body)))]
}
/// Builds one finite command envelope with a run-local ordinal and no real credentials.
private func interactionFixture(ordinal: Int) -> Data {
    Data("""
    {"id":"\(ordinal + 1)","application_id":"2","type":2,"token":"fixture","version":1,
    "data":{"id":"3","name":"timing","type":1},"app_permissions":"0","entitlements":[],
    "authorizing_integration_owners":{},"attachment_size_limit":1000}
    """.utf8)
}

/// A bounded single request body with explicit close evidence.
private actor InteractionTimingBody {
    private var bytes: Data?
    private var closed = false
    /// Transfers finite fixture bytes into the single-use request body.
    init(_ bytes: Data) { self.bytes = bytes }
    /// Transfers the sole chunk once, then yields EOF.
    func next() -> Data? { defer { bytes = nil }; return bytes }
    /// Discards unread bytes and records completion of request-body ownership.
    func close() { bytes = nil; closed = true }
    /// Reports zero after explicit closure, otherwise one still-owned fixture resource.
    var remainingOwners: Int { closed ? 0 : 1 }
}

/// One local response slot; an uncertain send never permits a second reservation.
private actor InteractionTimingResponse: HTTPResponder {
    private let failure: InteractionDeliveryError?
    private var reserved = false
    private var closed = false
    private(set) var status: Int?
    /// Selects explicit no-submit/uncertain adapter evidence, or normal local confirmation.
    init(failure: InteractionDeliveryError?) { self.failure = failure }
    /// Reserves once, consumes or closes the owned response body and reports fixture evidence.
    func respond<C: Clock>(_ response: HTTPResponse, context: TransportContext<C>) async throws where C.Duration == Duration {
        guard !reserved && !closed else { await response.body?.close(); throw InteractionLifecycleError.alreadyAcknowledged }
        reserved = true
        do {
            try context.check()
            if let body = response.body { for try await _ in body {} }
            await response.body?.close()
            if let failure { throw failure }
            status = response.status
        } catch { await response.body?.close(); throw error }
    }
    /// Abandons the response slot without reopening an existing reservation.
    func close() { closed = true }
    /// Reports zero after explicit closure, otherwise one still-owned fixture resource.
    var remainingOwners: Int { closed ? 0 : 1 }
}

/// Disables collection while untimed fixture setup primes the same bounded authentication owner.
private final class InteractionTimingCollectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var collecting = false
    /// Reads whether setup has completed without retaining interval history.
    var enabled: Bool { lock.withLock { collecting } }
    /// Enables measured observations after all untimed fixture priming has joined.
    func enable() { lock.withLock { collecting = true } }
}

/// Per-cohort boolean receipt; all storage is discarded after the corresponding task joins.
private final class InteractionTimingRequestReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    /// Reads the actual normalized-handler entrance receipt after caller timing stops.
    var admitted: Bool { lock.withLock { entered } }
    /// Records handler admission once without retaining interaction identity.
    func admit() { lock.withLock { entered = true } }
}

private extension InteractionTimingRunner {
    /// Measures real signed event processing while wrapping only the actual consumer transaction.
    /// Local committed hints are bounded at one; awaited processor return joins its pending reservation.
    func runDurable(scenario: InteractionTimingScenario, requests: Int, concurrency: Int,
        delay: Duration) async throws -> InteractionTimingReport {
        let statistics = try RunStatistics(workloads: [.interactionWorkflow, .ingressBodyRead, .ingressSignature, .ingressAdmission])
        let collection = InteractionTimingCollectionGate()
        let clock = ContinuousClock(), origin = clock.now
        let intervals = DiscordIntervalTiming(clockDomain: UInt64.random(in: 1...UInt64.max), sink: { event in
            guard collection.enabled, event.kind == .ended else { return }
            // Verifier replay-window work is independent from the consumer transaction. These
            // profiles reserve ingress.admission exclusively for the directly wrapped durable hook.
            let workload: BenchmarkWorkload
            if event.operation == .signedIngress && event.stage == .body { workload = .ingressBodyRead }
            else if event.operation == .signedIngress && event.stage == .signatureVerification { workload = .ingressSignature }
            else { return }
            statistics.record(.nanoseconds(event.validity == .valid ? event.elapsedNanoseconds ?? -1 : -1),
                workload: workload, outcome: interactionIntervalOutcome(event.outcome))
        }, now: { origin.duration(to: clock.now) })
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 23, count: 32))
        let verifier = try SignedRequestVerifier(publicKey: interactionHex(key.publicKey.rawRepresentation),
            maximumReplayEntries: max(1, requests), replayPolicy: .allowIdenticalRetries, now: { 1000 }, intervals: intervals)
        let ingress = try DiscordSignedIngress(verifier: verifier, maximumConcurrentRequests: concurrency, intervals: intervals)
        let ledger = InteractionTimingDurableLedger()
        let processor = try WebhookEventProcessor(applicationID: .init(rawValue: 2),
            maximumConcurrentAdmissions: concurrency, maximumRememberedDeliveries: 1) { _, _, digest in
            let measured = collection.enabled
            InteractionTimingDurableScope.receipt?.admit()
            let start = clock.now
            await ledger.begin()
            do {
                if delay > .zero { try await clock.sleep(for: delay) }
                if scenario == .durableFailure { throw DiscordError.validation(.invalidValue) }
                await ledger.commit(digest)
                await ledger.finish()
                let terminal = clock.now
                if measured { statistics.record(start.duration(to: terminal), workload: .ingressAdmission, outcome: .success) }
                return .accepted
            } catch {
                await ledger.finish()
                let terminal = clock.now
                if measured { statistics.record(start.duration(to: terminal), workload: .ingressAdmission, outcome: interactionFailureOutcome(error)) }
                throw error
            }
        }
        let duplicateBody = interactionWebhookFixture(ordinal: 0)
        let duplicateHeaders = try interactionHeaders(key: key, body: duplicateBody)
        if scenario == .durableDuplicate {
            let source = InteractionTimingBody(duplicateBody)
            let stream = try BodyStream(maximumChunkBytes: 4096, next: { await source.next() }, close: { await source.close() })
            let request = HTTPRequest(method: "POST", url: URL(string: "https://fixture.invalid/events")!, headers: duplicateHeaders, body: stream)
            let response = try await ingress.process(request: request, context: TransportContext(clock: clock)) { await processor.process($0) }
            guard response.status == 204, await source.remainingOwners == 0 else { throw LoadFailure.invalidArguments }
            await response.body?.close()
        }
        let setupCalls = await ledger.snapshot().transactions
        collection.enable()
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        var completed = 0, admitted = 0, bodyOwners = 0, slotOwners = 0
        var first: ContinuousClock.Instant?, last: ContinuousClock.Instant?
        for wave in stride(from: 0, to: requests, by: concurrency) {
            if Task.isCancelled { break }
            let fixtures = try (wave..<min(requests, wave + concurrency)).map { ordinal in
                let bytes = scenario == .durableDuplicate ? duplicateBody : interactionWebhookFixture(ordinal: ordinal)
                let headers = scenario == .durableDuplicate ? duplicateHeaders : try interactionHeaders(key: key, body: bytes)
                let body = InteractionTimingBody(bytes)
                let stream = try BodyStream(maximumChunkBytes: 4096, next: { await body.next() }, close: { await body.close() })
                return (HTTPRequest(method: "POST", url: URL(string: "https://fixture.invalid/events")!, headers: headers, body: stream),
                    body, InteractionTimingResponse(failure: nil), InteractionTimingRequestReceipt())
            }
            await withTaskGroup(of: InteractionTimingResult.self) { group in
                for (request, body, responseOwner, receipt) in fixtures {
                    group.addTask {
                        let start = clock.now
                        let outcome: BenchmarkOutcome
                        let terminal: ContinuousClock.Instant
                        do {
                            let response = try await ingress.process(request: request, context: TransportContext(clock: clock)) { verified in
                                await InteractionTimingDurableScope.$receipt.withValue(receipt) { await processor.process(verified) }
                            }
                            try await responseOwner.respond(response, context: TransportContext(clock: clock))
                            terminal = clock.now
                            if response.status == 204 { outcome = .success }
                            else if scenario == .durableFailure && receipt.admitted { outcome = .failure }
                            else { outcome = response.status == 503 ? .rejected : .failure }
                        } catch { terminal = clock.now; outcome = interactionFailureOutcome(error) }
                        statistics.record(start.duration(to: terminal), workload: .interactionWorkflow, outcome: outcome)
                        await responseOwner.close()
                        return InteractionTimingResult(outcome: outcome, submitted: start, terminal: terminal,
                            admitted: receipt.admitted, bodyOwners: await body.remainingOwners, slotOwners: await responseOwner.remainingOwners)
                    }
                }
                for await result in group {
                    completed += 1; admitted += result.admitted ? 1 : 0; outcomes[result.outcome, default: 0] += 1
                    first = first.map { min($0, result.submitted) } ?? result.submitted
                    last = last.map { max($0, result.terminal) } ?? result.terminal
                    bodyOwners += result.bodyOwners; slotOwners += result.slotOwners
                }
            }
        }
        let store = await ledger.snapshot()
        let cleanup = InteractionTimingCleanup(ingress: await ingress.activeRequestCount(), handlers: store.active,
            acknowledgements: 0, bodies: bodyOwners, responseSlots: slotOwners)
        return InteractionTimingReport(scenario: scenario, requests: requests, concurrency: concurrency,
            counts: .init(offered: UInt64(completed), admitted: UInt64(admitted), completed: UInt64(completed), outcomes: outcomes,
                deadlineMisses: outcomes[.timedOut, default: 0]), metrics: statistics.metrics(), clockDomain: statistics.clockDomain,
            durationNanoseconds: try BenchmarkTime.nanoseconds(duration: first.flatMap { a in last.map { a.duration(to: $0) } } ?? .zero),
            cleanup: cleanup, durableTransactions: store.transactions - setupCalls, setupDurableTransactions: setupCalls,
            notes: ["Real signed HTTP event bytes use allow-identical-retry verification and public WebhookEventProcessor.process.",
                "ingress.admission wraps only the actual injected consumer transaction; verifier replay-window observations are excluded from this identity.",
                "The bounded in-memory fixture simulates a consumer transaction; this run establishes no disk or fleet durability claim.",
                "Duplicate setup commits one event before collection; measured duplicate shortcuts invoke zero consumer transactions.",
                "Processor JSON parsing has no public phase hook; no isolated decode or interaction initial-response metric is invented.",
                "Workflow starts at fixture application caller entry and stops after response sink completion/error before final cleanup diagnostics.",
                "Admitted counts actual consumer transaction entry. Storage failure remains failure despite the processor's retryable503 protocol response.",
                "Processor calls and durable hooks are joined. One retained completed-delivery hint and the fixture's last committed digest are inert bounded state, not active owners."])
    }
}

/// Carries the current bounded receipt into the public processor's actual consumer callback.
private enum InteractionTimingDurableScope {
    @TaskLocal static var receipt: InteractionTimingRequestReceipt?
}

/// Bounded simulated transaction owner; it retains one committed digest and numeric counters.
private actor InteractionTimingDurableLedger {
    private var active = 0
    private var transactions = 0
    private var committedDigest: String?
    /// Records actual consumer-hook entry before its simulated store wait.
    func begin() { active += 1; transactions += 1 }
    /// Simulates completion of an atomic consumer transaction with bounded retained state.
    func commit(_ digest: String) { committedDigest = digest }
    /// Releases the entered transaction after success, failure or cooperative cancellation.
    func finish() { active -= 1 }
    /// Reads exact active and whole-run transaction counts only after joined processor calls.
    func snapshot() -> (active: Int, transactions: Int) { (active, transactions) }
}

/// Encodes a future webhook-event fixture with a unique exact-byte delivery key per ordinal.
private func interactionWebhookFixture(ordinal: Int) -> Data {
    Data("{\"version\":1,\"application_id\":\"2\",\"type\":1,\"event\":{\"type\":\"FIXTURE_\(ordinal)\",\"timestamp\":\"2026-10-17T12:00:00Z\",\"data\":{}}}".utf8)
}
