// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/SyntheticCommandTimingRunner.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordCommandDSL
import DiscordCommands
import DiscordCore
import DiscordDSL
import DiscordInteractions
import DiscordLogging
import DiscordModels
import Foundation

/// Equivalent handwritten and lowered routes; neither path claims trusted ingress receipt.
enum SyntheticCommandTimingScenario: String, Codable, CaseIterable, Sendable {
    case directImmediate = "synthetic.directImmediate", dslImmediate = "synthetic.dslImmediate"
    case directDeferred = "synthetic.directDeferred", dslDeferred = "synthetic.dslDeferred"
    case directFailure = "synthetic.directFailure", dslFailure = "synthetic.dslFailure"
    case directCancelled = "synthetic.directCancelled", dslCancelled = "synthetic.dslCancelled"

    /// Selects the lowered authoring path without changing provider or response behavior.
    var isDSL: Bool { rawValue.contains(".dsl") }
    /// Selects one explicit manual defer followed by its first edit.
    var isDeferred: Bool { self == .directDeferred || self == .dslDeferred }
    /// Declares the exact expected fixture terminal category for ordinary, uncancelled runs.
    var expectedOutcome: BenchmarkOutcome {
        switch self {
        case .directFailure, .dslFailure: .failure
        case .directCancelled, .dslCancelled: .cancelled
        default: .success
        }
    }
}

/// Separately inspected authorities after all finite workers have joined.
struct SyntheticCommandTimingCleanup: Codable, Sendable {
    let handlers: Int
    let acknowledgements: Int
    let acknowledgementBytes: Int
    /// Sums independently inspected handler and acknowledgement ownership gauges.
    var remainingOwners: Int { handlers + acknowledgements + acknowledgementBytes }
}

/// Complete synthetic populations with explicit bypass and exact response parity evidence.
struct SyntheticCommandTimingReport: Codable, Sendable {
    let scenario: SyntheticCommandTimingScenario
    let counts: BenchmarkCounts
    let metrics: [BenchmarkMetric]
    let clockDomain: String
    let durationNanoseconds: UInt64
    let callbacks: Int
    let edits: Int
    let cleanup: SyntheticCommandTimingCleanup
    let notes: [String]
}

/// Same real typed schema is captured before measurement on both paths.
private struct SyntheticTimingArguments: CommandArguments {
    let payload: String
    /// Builds the same bounded typed argument schema for the handwritten and lowered routes.
    static var schema: CommandArgumentSchema<Self> {
        /// Captures the finite option definition without executing a handler or response.
        get throws {
            let payload = try ArgumentOption<String>(name: "payload", description: "Offline fixture", maxLength: 64)
            return try .init(options: [payload.erased]) { decoder in
                try Self(payload: decoder.value(for: payload))
            }
        }
    }
}

/// Identical application/provider and response behavior for both invocation paths.
private struct SyntheticTimingHandler: ManualSlashCommandHandler {
    typealias Arguments = SyntheticTimingArguments
    let scenario: SyntheticCommandTimingScenario
    let delay: Duration
    let statistics: RunStatistics
    /// Provides the same fixed command metadata to direct and DSL route construction.
    var command: SlashCommandMetadata { .init(name: "timing", description: "Offline timing fixture") }

    /// Owns the explicit provider wait; errors retain their terminal population without fallback responses.
    /// - Parameters:
    ///   - context: Synthetic caller-owned response context, with no trusted receipt provenance.
    ///   - arguments: Real per-call typed decoding from the immutable fixture.
    /// - Throws: Injected provider failure/cancellation or the unchanged response error.
    func execute(_ context: InteractionContext, arguments: Arguments) async throws {
        guard arguments.payload == "phase-six" else { throw SyntheticTimingFailure.parity }
        if scenario.isDeferred { try await context.responder.deferResponse() }
        let clock = ContinuousClock(), start = ContinuousClock.now
        do {
            if delay > .zero { try await clock.sleep(for: delay) }
            switch scenario.expectedOutcome {
            case .failure: throw SyntheticTimingFailure.provider
            case .cancelled: throw CancellationError()
            default: break
            }
            let terminal = clock.now
            statistics.record(start.duration(to: terminal), workload: .syntheticProviderWait, outcome: .success)
        } catch {
            let terminal = clock.now
            statistics.record(start.duration(to: terminal), workload: .syntheticProviderWait,
                outcome: error is CancellationError ? .cancelled : .failure)
            throw error
        }
        if scenario.isDeferred {
            _ = try await context.responder.editOriginal(.init(content: .value(arguments.payload), deferredResponse: true))
        } else {
            try await context.responder.reply(.init(content: .value(arguments.payload)))
        }
    }
}

private enum SyntheticTimingFailure: Error, Equatable { case parity, provider }

/// Constant-space response checks; never retains payload histories or invocation identities.
private final class SyntheticTimingSink: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks = 0
    private var edits = 0
    let deferred: Bool
    let message: Message

    /// Prepares an independent message oracle outside all measured operations.
    /// - Parameter deferred: Whether exactly one defer and one edit are required.
    /// - Throws: Invalid fixed model fixture.
    init(deferred: Bool) throws {
        self.deferred = deferred
        message = try Message(data: Data(#"{"id":"3","channel_id":"4","author":{"id":"5","username":"fixture","discriminator":"0","avatar":null},"content":"phase-six","timestamp":"2026-01-01T00:00:00Z","edited_timestamp":null,"tts":false,"mention_everyone":false,"mentions":[],"mention_roles":[],"attachments":[],"embeds":[],"pinned":false,"type":0}"#.utf8))
    }

    /// Builds exact response validation closures without starting any I/O or response task.
    /// - Parameter receipt: Per-invocation confirmation owner, independent of final workflow outcome.
    /// - Parameter onInitialResponse: Optional development synchronization hook after local sink confirmation.
    /// - Returns: An offline sink that confirms only the expected response content/type.
    func makeSink(receipt: SyntheticTimingResponseReceipt, onInitialResponse: (@Sendable () -> Void)?) -> InteractionResponseSink {
        InteractionResponseSink(initial: { [self] response, timeout in
            let expected: InteractionResponse = if deferred { .deferredMessage(ephemeral: false) }
                else { .message(try .init(content: .value("phase-six"))) }
            guard timeout > .zero,
                  try response.jsonValue(interactionType: .applicationCommand) == expected.jsonValue(interactionType: .applicationCommand)
            else { throw SyntheticTimingFailure.parity }
            lock.withLock { callbacks += 1 }
            receipt.initialConfirmed()
            onInitialResponse?()
        }, editOriginal: { [self] edit, timeout in
            guard deferred, timeout > .zero, try edit.jsonValue() == .object(["content": .string("phase-six")]), edit.deferredResponse
            else { throw SyntheticTimingFailure.parity }
            lock.withLock { edits += 1 }
            receipt.editConfirmed()
            return message
        })
    }

    /// Copies final counters only after workers have joined.
    /// - Returns: Exactly confirmed initial and continuation operations.
    func snapshot() -> (Int, Int) { lock.withLock { (callbacks, edits) } }
}

/// Synthetic direct/DSL comparisons use equivalent real typed preparation and response owners.
struct SyntheticCommandTimingRunner: Sendable {
    /// Measures every invocation externally before its diagnostic actor snapshots and final validation.
    /// - Parameters:
    ///   - scenario: One explicit synthetic origin and response/failure family.
    ///   - requests: Finite invocation count, at most 100,000.
    ///   - concurrency: Fixed worker cohort, at most 256 and no greater than requests.
    ///   - onInitialResponse: Optional test synchronization callback after a confirmed local initial sink.
    ///   - delay: Injected provider wait in zero through one second.
    /// - Returns: Whole-population outcome metrics and joined authority cleanup.
    /// - Throws: Invalid bounds, authoring/schema errors or failed independent parity checks.
    func run(scenario: SyntheticCommandTimingScenario, requests: Int, concurrency: Int,
             delay: Duration, onInitialResponse: (@Sendable () -> Void)? = nil) async throws -> SyntheticCommandTimingReport {
        guard (1...100_000).contains(requests), (1...256).contains(concurrency), concurrency <= requests,
              delay >= .zero, delay <= .seconds(1) else { throw LoadFailure.invalidArguments }
        let statistics = try RunStatistics(workloads: [.syntheticInvoke, .syntheticProviderWait, .commandRoute,
            .commandArguments, .commandAdmission, .commandHandler, .interactionInitialResponse, .interactionOriginalEdit])
        let intervals = DiscordIntervalTiming(clockDomain: UInt64.random(in: 1...UInt64.max), sink: { event in
            guard event.kind == .ended, let outcome = event.outcome else { return }
            let workload: BenchmarkWorkload
            switch (event.operation, event.stage) {
            case (.commandRouting, .operation): workload = .commandRoute
            case (.commandRouting, .preparation): workload = .commandArguments
            case (.commandRouting, .admission): workload = .commandAdmission
            case (.commandRouting, .handler): workload = .commandHandler
            case (.interactionResponse, .initialResponse): workload = .interactionInitialResponse
            case (.interactionResponse, .originalEdit): workload = .interactionOriginalEdit
            default: return
            }
            let result: BenchmarkOutcome
            switch outcome {
            case .succeeded: result = .success
            case .failed: result = .failure
            case .cancelled: result = .cancelled
            case .uncertain: result = .uncertain
            }
            statistics.record(.nanoseconds(event.validity == .valid ? (event.elapsedNanoseconds ?? -1) : -1),
                workload: workload, outcome: result)
        })
        let handler = SyntheticTimingHandler(scenario: scenario, delay: delay, statistics: statistics)
        let routes: [CommandRoute]
        if scenario.isDSL {
            let declaration = try SlashCommand(id: "timing", handler: handler)
            routes = try CommandCompilation.compile(Module(id: "timing") { declaration }).routes
        } else {
            let schema = try SyntheticTimingArguments.schema
            routes = [CommandRoute(key: try .command(name: "timing"), prepare: { context in
                guard case .value(.command(let command)) = context.interaction.data,
                      case .value(let options) = command.options else { throw SyntheticTimingFailure.parity }
                let arguments = try schema.decode(options: options, resolved: command.resolved, commandName: "timing")
                return { try await handler.execute(context, arguments: arguments) }
            })]
        }
        let router = try CommandRouter(routes: routes, maximumConcurrentHandlers: concurrency, intervals: intervals)
        let admission = try InteractionAcknowledgementAdmission(maximumConcurrent: concurrency, maximumBytes: concurrency * 2_048)
        let sinkOwner = try SyntheticTimingSink(deferred: scenario.isDeferred)
        let interaction = try Interaction(data: Data(#"{"id":"1","application_id":"2","type":2,"token":"synthetic-offline","version":1,"app_permissions":"0","entitlements":[],"authorizing_integration_owners":{},"attachment_size_limit":1024,"data":{"id":"1","type":1,"name":"timing","options":[{"name":"payload","type":3,"value":"phase-six"}]}}"#.utf8))
        let clock = ContinuousClock()
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        var first: ContinuousClock.Instant?, last: ContinuousClock.Instant?
        var confirmedInitials = 0, confirmedEdits = 0, integrityFailures = 0
        for offset in stride(from: 0, to: requests, by: concurrency) {
            if Task.isCancelled { break }
            await withTaskGroup(of: (BenchmarkOutcome, ContinuousClock.Instant, ContinuousClock.Instant, Int, Int, Bool).self) { group in
                for _ in 0..<min(concurrency, requests - offset) {
                    group.addTask {
                        let receipt = SyntheticTimingResponseReceipt()
                        let sink = sinkOwner.makeSink(receipt: receipt, onInitialResponse: onInitialResponse)
                        let responder = InteractionResponder(interaction: interaction, deliveryMode: .http,
                            clock: InteractionClock(clock), sink: sink, admission: admission, intervals: intervals)
                        let context = try! InteractionContext(interaction: interaction, deliveryMode: .http, responder: responder)
                        let start = clock.now
                        let outcome: BenchmarkOutcome
                        var unexpectedError = false
                        do {
                            guard try await router.route(context) else { throw SyntheticTimingFailure.parity }
                            outcome = .success
                        } catch {
                            if error is CancellationError || (error as? DiscordError) == .cancelled { outcome = .cancelled }
                            else if case .unknownMutationOutcome = error as? DiscordError {
                                outcome = .uncertain
                                unexpectedError = !Task.isCancelled
                            } else {
                                outcome = .failure
                                unexpectedError = (error as? SyntheticTimingFailure) != .provider
                            }
                        }
                        let terminal = clock.now
                        statistics.record(start.duration(to: terminal), workload: .syntheticInvoke, outcome: outcome)
                        let responseCounts = receipt.snapshot()
                        let responseParity: Bool
                        if outcome == .success {
                            responseParity = responseCounts.0 == 1 && responseCounts.1 == (scenario.isDeferred ? 1 : 0)
                        } else if outcome == .cancelled || outcome == .uncertain {
                            // A cancelled deferred workflow may already have confirmed its initial
                            // response. That confirmation is retained without inventing workflow success.
                            responseParity = responseCounts.0 <= 1 && responseCounts.1 <= responseCounts.0
                                && (scenario.isDeferred || responseCounts.1 == 0)
                        } else { responseParity = responseCounts.0 == 0 && responseCounts.1 == 0 }
                        return (outcome, start, terminal, responseCounts.0, responseCounts.1,
                            unexpectedError || !responseParity)
                    }
                }
                for await result in group {
                    outcomes[result.0, default: 0] += 1
                    confirmedInitials += result.3; confirmedEdits += result.4
                    integrityFailures += result.5 ? 1 : 0
                    first = first.map { min($0, result.1) } ?? result.1
                    last = last.map { max($0, result.2) } ?? result.2
                }
            }
        }
        let handlers = await router.activeHandlerCount
        let acknowledgement = await admission.snapshot()
        let cleanup = SyntheticCommandTimingCleanup(handlers: handlers, acknowledgements: acknowledgement.activeCount,
            acknowledgementBytes: acknowledgement.encodedBytes)
        let counters = sinkOwner.snapshot()
        let completed = outcomes.values.reduce(0, +)
        guard cleanup.remainingOwners == 0, integrityFailures == 0,
              counters.0 == confirmedInitials, counters.1 == confirmedEdits,
              Task.isCancelled || outcomes[scenario.expectedOutcome] == UInt64(requests)
        else { throw SyntheticTimingFailure.parity }
        let elapsed = try first.flatMap { start in try last.map { try BenchmarkTime.nanoseconds(duration: start.duration(to: $0)) } } ?? 0
        return .init(scenario: scenario,
            counts: .init(offered: completed, admitted: completed, completed: completed, outcomes: outcomes, deadlineMisses: 0),
            metrics: statistics.metrics(), clockDomain: statistics.clockDomain, durationNanoseconds: elapsed,
            callbacks: counters.0, edits: counters.1, cleanup: cleanup,
            notes: ["Synthetic caller entry; bypasses signature verification, socket receipt and Gateway provenance.",
                "Authoring, schema capture, fixture creation and responder construction precede invocation timing.",
                "Fixed cohorts; equivalent typed schema and application behavior; provider wait measured directly."])
    }
}

/// Per-invocation confirmed response evidence, read after external caller timing has stopped.
private final class SyntheticTimingResponseReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var initials = 0
    private var edits = 0
    /// Records an initial callback only after its independent response oracle succeeds.
    func initialConfirmed() { lock.withLock { initials += 1 } }
    /// Records an original edit only after its independent response oracle succeeds.
    func editConfirmed() { lock.withLock { edits += 1 } }
    /// Copies the two finite confirmation counters after the caller operation has joined.
    func snapshot() -> (Int, Int) { lock.withLock { (initials, edits) } }
}
