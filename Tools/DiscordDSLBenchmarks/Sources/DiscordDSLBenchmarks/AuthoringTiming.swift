// File: Tools/DiscordDSLBenchmarks/Sources/DiscordDSLBenchmarks/AuthoringTiming.swift
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

/// Stage 7 dimensions are separate from the retained v1 paired runtime matrix.
struct AuthoringTimingConfiguration: Codable, Sendable {
    var mode = "direct"
    var profile = "smoke"
    var seed: UInt64 = 1
    var handlers = 10
    var modules = 1
    var invocations = 128
    var definitions = 3
    var warmupInvocations = 16
    var concurrency = 2
    var durationSeconds: UInt64 = 10
    var warmupSeconds: UInt64 = 1
    var output: String?
    var commonReport: String?

    /// Rejects unsupported identities and excessive state before compiling or starting a worker.
    /// - Throws: Invalid configuration for malformed populations, profiles, or finite time/cohort bounds.
    func validate() throws {
        guard ["direct", "dsl"].contains(mode), ["smoke", "standard", "stress", "soak"].contains(profile),
              [10, 100, 1_000].contains(handlers), (1...min(handlers, 100)).contains(modules),
              (1...1_000_000).contains(invocations), (1...100).contains(definitions),
              (0...1_000_000).contains(warmupInvocations), (1...64).contains(concurrency),
              concurrency <= invocations, durationSeconds > 0,
              durationSeconds <= (profile == "soak" ? 3_600 : profile == "smoke" ? 10 : 300),
              warmupSeconds <= 60, warmupInvocations == 0 || warmupSeconds > 0,
              output != "", commonReport != "" else { throw BenchmarkError.invalidConfiguration }
        if let output, let commonReport {
            guard URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath() !=
                URL(fileURLWithPath: commonReport).standardizedFileURL.resolvingSymlinksInPath() else {
                throw BenchmarkError.invalidConfiguration
            }
        }
    }

    /// Parses explicit key/value options, accepting the shared driver's finite environment policy.
    /// - Parameters:
    ///   - arguments: Options following the `authoring` subcommand; duplicates and unknown names fail.
    ///   - environment: Injected common-sidecar/profile settings; CLI values take precedence.
    /// - Returns: Validated dimensions; one invocation always selects one mode and one working set.
    /// - Throws: Invalid configuration without creating files, processes, plans or tasks.
    static func parse(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard arguments.count.isMultiple(of: 2) else { throw BenchmarkError.invalidConfiguration }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard options.updateValue(arguments[index + 1], forKey: arguments[index]) == nil else { throw BenchmarkError.invalidConfiguration }
        }
        let known: Set<String> = ["--mode", "--profile", "--seed", "--handlers", "--modules", "--invocations",
            "--definitions", "--warmup-invocations", "--concurrency", "--duration-seconds", "--warmup-seconds", "--output", "--common-report"]
        guard Set(options.keys).isSubset(of: known) else { throw BenchmarkError.invalidConfiguration }
        var result = Self()
        result.mode = options["--mode"] ?? result.mode
        result.profile = options["--profile"] ?? environment["DK_BENCHMARK_PROFILE"] ?? result.profile
        result.output = options["--output"]
        result.commonReport = options["--common-report"] ?? environment["DK_BENCHMARK_ENVELOPE"]
        for (name, fallback) in [("seed", "DK_BENCHMARK_SEED"), ("duration-seconds", "DK_BENCHMARK_DURATION_SECONDS"),
            ("warmup-seconds", "DK_BENCHMARK_WARMUP_SECONDS")] {
            if let text = options["--" + name] ?? environment[fallback] {
                guard let value = UInt64(text) else { throw BenchmarkError.invalidConfiguration }
                switch name { case "seed": result.seed = value; case "duration-seconds": result.durationSeconds = value; default: result.warmupSeconds = value }
            }
        }
        for name in ["handlers", "modules", "invocations", "definitions", "warmup-invocations", "concurrency"] {
            if let text = options["--" + name] ?? (name == "concurrency" ? environment["DK_BENCHMARK_CONCURRENCY"] : nil) {
                guard let value = Int(text) else { throw BenchmarkError.invalidConfiguration }
                switch name {
                case "handlers": result.handlers = value
                case "modules": result.modules = value
                case "invocations": result.invocations = value
                case "definitions": result.definitions = value
                case "warmup-invocations": result.warmupInvocations = value
                default: result.concurrency = value
                }
            }
        }
        try result.validate()
        return result
    }
}

/// Validated inert lowering with instrumented route wrappers preserving the original module description.
struct AuthoringLowering: Sendable {
    let description: DefinitionDescription
    let definitions: [CommandDefinition]
    let routes: [CommandRoute]
}

/// Optional plan behavior is inert until explicit authoring construction or invocation.
struct AuthoringPlanOptions: Sendable {
    let modules: Int
    let statistics: RunStatistics?
    let intervals: DiscordIntervalTiming?
    /// Optional independent definition-only observation; nil preserves the catalog7 behavior.
    var definitionObservation: (@Sendable (Duration) -> Void)? = nil

    /// Checks module fan-out before any schema capture, retaining bounded source and route populations.
    /// - Parameter handlerCount: Selected finite declaration population; every module has at least one handler.
    /// - Throws: Invalid configuration for zero, excessive or empty module partitions.
    func validate(handlerCount: Int) throws {
        guard (1...min(handlerCount, 100)).contains(modules) else { throw BenchmarkError.invalidConfiguration }
    }

    /// Lowers the same declaration population and installs identical real authorization and middleware.
    /// - Parameters:
    ///   - mode: Direct adopts handwritten routes through ExistingCommandFamily; DSL lowers SlashCommand.
    ///   - contributions: Captured DSL schemas, empty for direct.
    ///   - definitions: Handwritten registrations, empty for DSL.
    ///   - routes: Handwritten prepared routes, empty for DSL.
    /// - Returns: Validated inert registrations/routes partitioned over explicit modules; no handlers run.
    /// - Throws: Original structural/policy validation errors. Definition timers include policy construction,
    ///   but exclude input fixtures, router construction, process probes and report serialization.
    func compile(mode: String, contributions: [SlashCommand<BenchmarkHandler>], definitions: [CommandDefinition],
        routes: [CommandRoute]) throws -> AuthoringLowering {
        let count = mode == "dsl" ? contributions.count : definitions.count
        let groups: [BotDefinitionGroup] = (0..<modules).map { module in
            let lower = module * count / modules, upper = (module + 1) * count / modules
            if mode == "dsl" { return BotDefinitionGroup(Array(contributions[lower..<upper])) }
            return BotDefinitionGroup([ExistingCommandFamily(id: "manual\(module)",
                definitions: Array(definitions[lower..<upper]), routes: Array(routes[lower..<upper]))])
        }
        let catalog = try CommandCompilation.compile(BotDefinitionGroup(groups.enumerated().map { index, group in
            Module(id: "module\(index)") { group }
        }), limits: .init(maxModules: modules, maxDepth: 16, maxDeclarations: max(count, modules),
            maxTextBytes: 8 * 1_024 * 1_024, maxStructuralNodes: count * 8 + modules * 8 + 16))
        let statistics = statistics
        let policies = try CommandPolicies(limits: .init(maximumNodes: 8, maximumDepth: 4),
            requiring: InvocationPolicy<CommandContext> { context in
                try Task.checkCancellation()
                return context.interaction.type.knownValue == .applicationCommand
            }, middleware: InvocationMiddleware<CommandContext, Void> { context, next in
                let start = ContinuousClock.now
                do {
                    try await next(context)
                    statistics?.record(start.duration(to: .now), workload: .dslMiddleware, outcome: .success)
                } catch {
                    statistics?.record(start.duration(to: .now), workload: .dslMiddleware,
                        outcome: error is CancellationError ? .cancelled : .failure)
                    throw error
                }
            })
        let applied = try catalog.applying(policies)
        // Wrapping the already applied route times the complete real policy, including joined continuation cleanup.
        let wrapped = applied.routes.map { route in
            route.wrappingExecution { _, next in
                let start = ContinuousClock.now
                do {
                    try await next()
                    statistics?.record(start.duration(to: .now), workload: .dslPolicy, outcome: .success)
                } catch {
                    statistics?.record(start.duration(to: .now), workload: .dslPolicy,
                        outcome: error is CancellationError ? .cancelled : .failure)
                    throw error
                }
            }
        }
        return AuthoringLowering(description: catalog.description, definitions: applied.definitions, routes: wrapped)
    }
}

/// Actual local ownership, independently copied after every finite worker has joined.
struct AuthoringTimingMeasurement: Codable, Sendable {
    let invocations: Int
    let definitionBuilds: Int
    let schemaBuilds: Int
    let counters: CounterSnapshot
    let cleanup: CleanupSnapshot
    let common: DiscordBenchmarkReport
}

/// Stage 7 runner measures external invocation and real router/responder owner phases without ingress claims.
enum AuthoringTimingCommand {
    /// Converts actual ended owner intervals into complete finite phase populations.
    /// - Parameter statistics: Preallocated collector, with no per-observation serialization or I/O.
    /// - Returns: Prompt concurrent-safe synchronous instrumentation. Nested phases overlap.
    static func intervals(_ statistics: RunStatistics) -> DiscordIntervalTiming {
        DiscordIntervalTiming(clockDomain: UInt64.random(in: 1...UInt64.max), sink: { event in
            guard event.kind == .ended, let result = event.outcome else { return }
            let workload: BenchmarkWorkload
            switch (event.operation, event.stage) {
            case (.commandRouting, .operation): workload = .commandRoute
            case (.commandRouting, .preparation): workload = .commandArguments
            case (.commandRouting, .handler): workload = .commandHandler
            case (.interactionResponse, .initialResponse): workload = .interactionInitialResponse
            default: return
            }
            let outcome: BenchmarkOutcome
            switch result { case .succeeded: outcome = .success; case .failed: outcome = .failure; case .cancelled: outcome = .cancelled; case .uncertain: outcome = .uncertain }
            statistics.record(.nanoseconds(event.validity == .valid ? event.elapsedNanoseconds ?? -1 : -1), workload: workload, outcome: outcome)
        })
    }

    /// Warms separate owners, measures repeated definition/lowering, then measures the final plan's full invocation population.
    /// - Parameter configuration: Validated finite single-mode working set and time ceilings.
    /// - Returns: Whole-population phase histograms, exact response counters and zero remaining owners.
    /// - Throws: Original compilation, cancellation or runtime errors after joined workers, or hard integrity failure.
    ///   Time caps are cooperatively checked between bounded worker rounds; the shared supervisor enforces wall timeout.
    static func measure(_ configuration: AuthoringTimingConfiguration) async throws -> AuthoringTimingMeasurement {
        try configuration.validate()
        var legacy = BenchmarkConfiguration()
        legacy.invocations = configuration.invocations; legacy.handlerCounts = [configuration.handlers]
        legacy.concurrency = configuration.concurrency; legacy.sampleLimit = 1
        let before = ProcessSample.capture(), clock = ContinuousClock()
        let statistics = try RunStatistics(workloads: [.dslDefinition, .dslInvoke, .commandRoute, .commandArguments,
            .commandHandler, .interactionInitialResponse, .dslPolicy, .dslMiddleware])
        let counters = BenchmarkCounters()
        let warmupStart = clock.now
        if configuration.warmupInvocations > 0 {
            let warmupOptions = AuthoringPlanOptions(modules: configuration.modules, statistics: nil, intervals: nil)
            let warmupPlan = try RuntimeBenchmark.makePlan(mode: configuration.mode, handlerCount: configuration.handlers,
                configuration: legacy, counters: counters, authoring: warmupOptions)
            var warmed = 0
            while warmed < configuration.warmupInvocations {
                try Task.checkCancellation()
                guard warmupStart.duration(to: clock.now) < .seconds(configuration.warmupSeconds) else { throw BenchmarkError.invocationCeiling }
                let count = min(256, configuration.warmupInvocations - warmed)
                _ = try await RuntimeBenchmark.runRound(warmupPlan, start: 1, count: count, configuration: legacy, counters: counters)
                warmed += count
            }
            guard await warmupPlan.router.activeHandlerCount == 0,
                  await warmupPlan.admission.snapshot().activeCount == 0 else { throw BenchmarkError.functionalGate }
        }
        let warmup = configuration.warmupInvocations == 0 ? 0 : try BenchmarkTime.nanoseconds(duration: warmupStart.duration(to: clock.now))
        counters.resetAfterWarmup()
        let initialSchemas = BenchmarkArguments.captures.snapshot().schemas
        let options = AuthoringPlanOptions(modules: configuration.modules, statistics: statistics, intervals: intervals(statistics))
        var plan: RuntimePlan?
        for _ in 0..<configuration.definitions {
            try Task.checkCancellation()
            plan = try RuntimeBenchmark.makePlan(mode: configuration.mode, handlerCount: configuration.handlers,
                configuration: legacy, counters: counters, authoring: options)
        }
        guard let measuredPlan = plan else { throw BenchmarkError.functionalGate }
        let schemasBeforeInvocations = BenchmarkArguments.captures.snapshot().schemas
        let start = clock.now
        var completed = 0
        while completed < configuration.invocations {
            try Task.checkCancellation()
            guard start.duration(to: clock.now) < .seconds(configuration.durationSeconds) else { throw BenchmarkError.invocationCeiling }
            let count = min(256, configuration.invocations - completed)
            _ = try await RuntimeBenchmark.runRound(measuredPlan, start: completed, count: count,
                configuration: legacy, counters: counters, statistics: statistics, workload: .dslInvoke)
            completed += count
        }
        let elapsed = try BenchmarkTime.nanoseconds(duration: start.duration(to: clock.now))
        let admission = await measuredPlan.admission.snapshot()
        let handlers = await measuredPlan.router.activeHandlerCount
        let snapshot = counters.snapshot(), after = ProcessSample.capture()
        let schemasAfterInvocations = BenchmarkArguments.captures.snapshot().schemas
        let cleanup = CleanupSnapshot(activeHandlers: handlers, activeAcknowledgements: admission.activeCount,
            acknowledgementBytes: admission.encodedBytes, activeWorkers: snapshot.activeWorkers)
        guard completed == configuration.invocations, snapshot.handlers == completed, snapshot.callbacks == completed,
              snapshot.activeWorkers == 0, handlers == 0, admission.activeCount == 0, admission.encodedBytes == 0,
              schemasAfterInvocations == schemasBeforeInvocations else { throw BenchmarkError.functionalGate }
        let metrics = statistics.metrics()
        guard metrics.count == 8, metrics.allSatisfy({ metric in
            metric.outcome == .success && metric.distribution.droppedCount == 0 && !metric.distribution.counterOverflow
                && metric.distribution.observedCount == UInt64(metric.id == "dsl.definition" ? configuration.definitions : completed)
        }), schemasAfterInvocations - initialSchemas == configuration.definitions * configuration.handlers else {
            throw BenchmarkError.functionalGate
        }
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        outcomes[.success] = UInt64(completed)
        var identity = ReportIdentity(scenario: "authoring." + configuration.mode, profile: configuration.profile,
            seed: configuration.seed, inputSizes: ["handlers": UInt64(configuration.handlers), "modules": UInt64(configuration.modules),
                "invocations": UInt64(completed), "definitionBuilds": UInt64(configuration.definitions),
                "warmupInvocations": UInt64(configuration.warmupInvocations), "durationCapSeconds": configuration.durationSeconds],
            instrumentation: "whole-population-owner-phases", scheduler: "closed-loop-bounded-authoring-cohort",
            concurrency: UInt32(configuration.concurrency), warmupNanoseconds: warmup,
            requestedWarmupNanoseconds: configuration.warmupSeconds * 1_000_000_000, measuredNanoseconds: elapsed, repetitions: 1)
        identity.catalogVersion = 7
        let common = DiscordBenchmarkReport(identity: identity, provenance: .capture(), adapter: "offline-equivalent-command-authoring",
            clockDomain: statistics.clockDomain, status: .completed,
            counts: .init(offered: UInt64(completed), admitted: UInt64(completed), completed: UInt64(completed), outcomes: outcomes, deadlineMisses: 0),
            metrics: metrics, gauges: [
                "processCPU": .init(value: try BenchmarkTime.nanoseconds(seconds: max(0, after.cpuSeconds - before.cpuSeconds)),
                    unit: "nanoseconds", method: "getrusage user+system delta", scope: "setup, definitions, warmup and invocations"),
                "processPeakResidentBytes": .init(value: after.peakRSSBytes, unit: "bytes", method: "getrusage", scope: "single-mode process lifetime; includes warmup"),
                "processResidentBytes": .init(value: after.residentBytes, unit: "bytes", method: "native process probe", scope: "after joined invocation owners",
                    unavailableReason: after.residentBytes == nil ? "Current RSS unavailable on this platform." : nil),
            ], cleanup: .init(completed: true, remainingOwners: 0), throughputPerSecond: Double(completed) * 1e9 / Double(max(1, elapsed)),
            qualificationLimitations: [
                "Local synthetic normalized interactions; no trusted ingress, live Discord, network, platform or controlled-host numerical qualification.",
                "Definition lowering, router setup, fixed input creation and process probes are outside invocation timing. Compiler processes remain separate.",
                "Direct handwritten routes and DSL routes use the same real schema decoder, authorization, middleware, handler, response ownership and exact callback validation.",
                "Middleware, policy, router handler and response owner intervals nest and overlap; do not add or subtract their percentiles.",
                "Use the shared fresh-process counterbalanced driver for memory comparisons; direct invocation alone provides no process-isolation proof.",
                "Process RSS includes all definitions, warmup and setup in this mode; live allocation gauges are not allocation event counts.",
                "Module count is explicit. Optional extension-package installation is outside this suite.",
            ])
        try common.validate()
        return .init(invocations: completed, definitionBuilds: configuration.definitions,
            schemaBuilds: schemasAfterInvocations - initialSchemas, counters: snapshot, cleanup: cleanup, common: common)
    }

    /// Writes native and common artifacts only after successful integrity checks and joined teardown.
    /// - Parameter arguments: Explicit Stage 7 CLI options; legacy report readers never receive this shape.
    /// - Throws: Parse, workload, bounded serialization and atomic output errors.
    static func run(_ arguments: [String]) async throws {
        let configuration = try AuthoringTimingConfiguration.parse(arguments)
        let report = try await measure(configuration)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        guard data.count <= DiscordBenchmarkReport.maximumSerializedBytes else { throw BenchmarkReportError.reportTooLarge }
        if let path = configuration.commonReport { try report.common.validatedData().write(to: URL(fileURLWithPath: path), options: .atomic) }
        if let path = configuration.output { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
        else { try FileHandle.standardOutput.write(contentsOf: data + Data([10])) }
    }
}
