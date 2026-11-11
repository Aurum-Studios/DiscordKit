// File: Tools/DiscordDSLBenchmarks/Sources/DiscordDSLBenchmarks/Phase7Timing.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordCore
import DiscordDSL
import Foundation

/// Opt-in independent populations; the original authoring command retains its combined catalog7 contract.
struct Phase7TimingConfiguration: Codable, Sendable {
    var dimensions = AuthoringTimingConfiguration()
    var workload = "definition-plan"
    var operations = 100
    var warmupOperations = 3
    var stringShape = "ascii"
    var stringLength = 64

    /// Rejects unsupported workloads and finite populations before constructing fixtures or owners.
    /// - Throws: `BenchmarkError.invalidConfiguration` before schema capture, tasks, or file writes.
    func validate() throws {
        try dimensions.validate()
        guard ["definition-plan", "authoring", "invocation"].contains(workload),
              (1...100_000).contains(operations), (0...1_000).contains(warmupOperations),
              ["ascii", "escaped", "unicode"].contains(stringShape), (1...1_024).contains(stringLength),
              warmupOperations == 0 || dimensions.warmupSeconds > 0,
              workload != "invocation" || dimensions.concurrency <= operations,
              workload == "definition-plan" || (stringShape == "ascii" && stringLength == 64) else {
            throw BenchmarkError.invalidConfiguration
        }
    }

    /// Parses new selection options while reusing established output, profile, and finite authoring dimensions.
    /// Legacy definition/invocation options are rejected because `operations` names the sole measured population.
    /// - Parameters:
    ///   - arguments: Explicit key/value options after the new `phase7` subcommand.
    ///   - environment: Shared supervisor defaults; explicit options take precedence.
    /// - Returns: One validated, finite workload selection without starting work.
    /// - Throws: Invalid, duplicate, unsupported, or inconsistent options.
    static func parse(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard arguments.count.isMultiple(of: 2) else { throw BenchmarkError.invalidConfiguration }
        var result = Self(), common: [String] = [], seen: Set<String> = []
        let forbidden: Set<String> = ["--invocations", "--definitions", "--warmup-invocations"]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index], value = arguments[index + 1]
            guard seen.insert(key).inserted, !forbidden.contains(key) else { throw BenchmarkError.invalidConfiguration }
            switch key {
            case "--workload": result.workload = value
            case "--operations":
                guard let count = Int(value) else { throw BenchmarkError.invalidConfiguration }; result.operations = count
            case "--warmup-operations":
                guard let count = Int(value) else { throw BenchmarkError.invalidConfiguration }; result.warmupOperations = count
            case "--string-shape": result.stringShape = value
            case "--string-length":
                guard let count = Int(value) else { throw BenchmarkError.invalidConfiguration }; result.stringLength = count
            default: common.append(contentsOf: [key, value])
            }
        }
        result.dimensions = try AuthoringTimingConfiguration.parse(common + ["--warmup-invocations", "0"], environment: environment)
        try result.validate()
        return result
    }
}

/// Immutable JSON-heavy catalog with an independent writer-byte oracle, built before timed compilation.
struct DefinitionPlanFixture: Sendable {
    static let kind = "phase7.command-snapshot"
    let definition: BotDefinitionGroup
    let declarations: [RawDefinitionContribution]
    let limits: DefinitionLimits
    let expectedTextBytes: Int
    let serializedPayloadBytes: Int
    let fingerprint: String

    /// Builds fixed raw command-shaped payloads without command routing, schemas, policies, or process probes.
    /// String shape varies independently of declaration and module counts; its exact bytes enter the fingerprint.
    /// - Parameter configuration: Previously validated declaration/module/string dimensions.
    /// - Throws: Invalid dimensions or bounded JSON serialization failure before any compilation occurs.
    init(_ configuration: Phase7TimingConfiguration) throws {
        try configuration.validate()
        let source = DefinitionSourceLocation(fileID: "Phase7FixtureV1", line: 1, column: 1)
        let token: String
        switch configuration.stringShape {
        case "escaped": token = "\"\\/\n\t\u{0000}\u{001f}"
        case "unicode": token = "e\u{0301}水🦄"
        default: token = "x"
        }
        let text = String(repeating: token, count: configuration.stringLength)
        var declarations: [RawDefinitionContribution] = [], payloadHashes: [JSONValue] = [], payloadBytes = 0, textBytes = 0
        for index in 0..<configuration.dimensions.handlers {
            let payload: JSONValue = try .object([
                "name": .string("bench\(index)"), "description": .string(text),
                "type": .number(JSONNumber(rawValue: "1")),
                "options": .array([.object(["name": .string("payload"), "description": .string(text),
                    "type": .number(JSONNumber(rawValue: "3")), "required": .bool(true)])]),
            ])
            let declaration = RawDefinitionContribution(id: "handler\(index)", kind: Self.kind,
                text: text, payload: payload, source: source)
            let bytes = try payload.serialized().count
            payloadBytes += bytes
            textBytes += declaration.id.utf8.count + Self.kind.utf8.count + text.utf8.count + source.fileID.utf8.count + bytes
            declarations.append(declaration)
            // Hash bounded individual declarations so the aggregate fingerprint never needs a giant JSON document.
            payloadHashes.append(.string(BenchmarkEvidenceHash.sha256(try JSONValue.object([
                "id": .string(declaration.id), "kind": .string(declaration.kind), "text": .string(declaration.text),
                "payload": payload, "source": .string(source.fileID),
            ]).serialized())))
        }
        let moduleCount = configuration.dimensions.modules
        var groups: [any BotDefinition] = []
        for module in 0..<moduleCount {
            let id = "module\(module)"
            let lower = module * declarations.count / moduleCount, upper = (module + 1) * declarations.count / moduleCount
            let group = BotDefinitionGroup(Array(declarations[lower..<upper]), source: source)
            groups.append(Module(id: id, source: source) { group })
            textBytes += id.utf8.count + source.fileID.utf8.count
        }
        self.declarations = declarations
        definition = BotDefinitionGroup(groups, source: source)
        limits = .init(maxModules: moduleCount, maxDepth: 8, maxDeclarations: declarations.count,
            maxTextBytes: textBytes, maxStructuralNodes: declarations.count * 4 + moduleCount * 8 + 16)
        expectedTextBytes = textBytes
        serializedPayloadBytes = payloadBytes
        fingerprint = BenchmarkEvidenceHash.sha256(try JSONValue.object([
            "fixtureVersion": .number(JSONNumber(rawValue: "1")),
            "modules": .number(JSONNumber(rawValue: String(moduleCount))),
            "declarationSHA256": .array(payloadHashes),
        ]).serialized())
    }

    /// Checks the exact public immutable result after its target timer has ended.
    /// - Parameter plan: Completed plan compiled from this fixture, with no runtime owner or side effects.
    /// - Throws: A functional gate failure for changed snapshots, source/module paths, or accounting.
    func validate(_ plan: DefinitionPlan) throws {
        guard plan.description.textBytes == expectedTextBytes, plan.description.modules.count == limits.maxModules,
              plan.description.declarations.map(\.declaration) == declarations,
              plan.contributions.count == declarations.count, plan.description.namespaces.isEmpty,
              plan.description.structureCount == 1 + limits.maxModules * 3 + declarations.count else { throw BenchmarkError.functionalGate }
        for module in 0..<limits.maxModules {
            let id = "module\(module)", actual = plan.description.modules[module]
            guard actual.id == id, actual.path == [id], actual.namespacePath.isEmpty,
                  actual.source == declarations[0].source else { throw BenchmarkError.functionalGate }
            let lower = module * declarations.count / limits.maxModules, upper = (module + 1) * declarations.count / limits.maxModules
            guard plan.description.declarations[lower..<upper].allSatisfy({ $0.modulePath == [id] && $0.namespacePath.isEmpty }) else {
                throw BenchmarkError.functionalGate
            }
        }
    }
}

/// One metric's complete bounded population; no raw prefix or invocation-sized history is retained.
final class Phase7Statistics: @unchecked Sendable {
    private let lock = NSLock()
    private var histogram: BoundedHistogram
    private var total: UInt64 = 0
    private var sumOverflow = false
    let clockDomain = UUID().uuidString

    /// Ten-microsecond cells over zero through one second retain explicit longer-operation censoring.
    /// - Throws: Invalid histogram configuration or a rejected finite aggregate storage budget.
    init() throws {
        let configuration = try HistogramConfiguration(lowerBoundNanoseconds: 0,
            upperBoundNanoseconds: 1_000_000_000, bucketWidthNanoseconds: 10_000)
        try AggregateStatisticsBudget.validate(histograms: [configuration], additionalBytes: 1_024)
        histogram = BoundedHistogram(configuration: configuration)
    }

    /// Records every completed target span after its timestamp; CPU probes and serialization remain outside.
    /// - Parameter duration: Actual monotonic span; an invalid conversion records explicit aggregate loss.
    func record(_ duration: Duration) {
        lock.withLock {
            guard let value = try? BenchmarkTime.nanoseconds(duration: duration) else { histogram.recordLoss(); return }
            histogram.record(value)
            let (sum, overflow) = total.addingReportingOverflow(value)
            total = sum; sumOverflow = sumOverflow || overflow
        }
    }

    /// Copies finite aggregates only after synchronous construction or all invocation workers have joined.
    /// - Returns: A whole-population histogram and checked exact sum, including censored durations.
    /// - Throws: A functional gate error if the duration sum overflowed.
    func snapshot() throws -> (HistogramSnapshot, UInt64) {
        try lock.withLock {
            guard !sumOverflow else { throw BenchmarkError.functionalGate }
            return (histogram.snapshot(), total)
        }
    }
}

/// Native details distinguish process lifetime, target time, setup state, and exact fixture identity.
struct Phase7TimingMeasurement: Encodable, Sendable {
    let schemaVersion = 1
    let reportKind = "phase7-independent-v1"
    let configuration: Phase7TimingConfiguration
    let operations: Int
    let targetNanoseconds: UInt64
    let elapsedNanoseconds: UInt64
    let schemaBuilds: Int
    let counters: CounterSnapshot
    let cleanup: CleanupSnapshot
    let beforeSetup: ProcessSample
    let beforeMeasurement: ProcessSample
    let afterMeasurement: ProcessSample
    let afterCleanup: ProcessSample
    let common: DiscordBenchmarkReport
}

/// One selected target per process. Cold startup, build/plugin work, and original combined authoring remain separate.
enum Phase7TimingCommand {
    /// Executes an independent inert catalog, full authoring, or routed invocation population.
    /// Time caps are checked between finite operations/cohorts and enforced externally by the shared supervisor.
    /// - Parameter configuration: Validated single-mode finite workload; only invocation starts worker tasks.
    /// - Returns: Completed native/common reports after joined workers and zero runtime owners.
    /// - Throws: Configuration, cooperative cancellation/time-cap, original workload, or integrity failures.
    static func measure(_ configuration: Phase7TimingConfiguration) async throws -> Phase7TimingMeasurement {
        try configuration.validate()
        try Task.checkCancellation()
        let beforeSetup = ProcessSample.capture(), statistics = try Phase7Statistics(), clock = ContinuousClock()
        let counters = BenchmarkCounters(), dimensions = configuration.dimensions
        var legacy = BenchmarkConfiguration()
        legacy.handlerCounts = [dimensions.handlers]; legacy.concurrency = dimensions.concurrency
        legacy.invocations = max(1, configuration.operations); legacy.sampleLimit = 1
        let initialSchemas = BenchmarkArguments.captures.snapshot().schemas
        let options = AuthoringPlanOptions(modules: dimensions.modules, statistics: nil, intervals: nil)
        let fixture = configuration.workload == "definition-plan" ? try DefinitionPlanFixture(configuration) : nil
        var plan: RuntimePlan?
        if configuration.workload == "invocation" {
            plan = try RuntimeBenchmark.makePlan(mode: dimensions.mode, handlerCount: dimensions.handlers,
                configuration: legacy, counters: counters, authoring: options)
        }
        let warmupStart = clock.now
        for index in 0..<configuration.warmupOperations {
            try Task.checkCancellation()
            guard warmupStart.duration(to: clock.now) < .seconds(dimensions.warmupSeconds) else { throw BenchmarkError.invocationCeiling }
            if let fixture { try definitionOperation(fixture, mode: dimensions.mode) }
            else if let plan { try await RuntimeBenchmark.invoke(plan, index: index) }
            else {
                _ = try RuntimeBenchmark.makePlan(mode: dimensions.mode, handlerCount: dimensions.handlers,
                    configuration: legacy, counters: counters, authoring: options)
            }
        }
        let warmup = configuration.warmupOperations == 0 ? 0 : try BenchmarkTime.nanoseconds(duration: warmupStart.duration(to: clock.now))
        guard warmup <= dimensions.warmupSeconds * 1_000_000_000 else { throw BenchmarkError.invocationCeiling }
        counters.resetAfterWarmup()
        let schemasBeforeMeasurement = BenchmarkArguments.captures.snapshot().schemas
        let beforeMeasurement = ProcessSample.capture(), start = clock.now
        var completed = 0
        while completed < configuration.operations {
            try Task.checkCancellation()
            guard start.duration(to: clock.now) < .seconds(dimensions.durationSeconds) else { throw BenchmarkError.invocationCeiling }
            if let fixture {
                try definitionOperation(fixture, mode: dimensions.mode, statistics: statistics)
                completed += 1
            } else if configuration.workload == "authoring" {
                var measuredOptions = options
                measuredOptions.definitionObservation = { statistics.record($0) }
                plan = try RuntimeBenchmark.makePlan(mode: dimensions.mode, handlerCount: dimensions.handlers,
                    configuration: legacy, counters: counters, authoring: measuredOptions)
                completed += 1
            } else if let plan {
                let count = min(256, configuration.operations - completed)
                _ = try await RuntimeBenchmark.runRound(plan, start: completed, count: count,
                    configuration: legacy, counters: counters, observation: { statistics.record($0) }, captureLegacySamples: false)
                completed += count
            } else { throw BenchmarkError.functionalGate }
        }
        let elapsed = try BenchmarkTime.nanoseconds(duration: start.duration(to: clock.now))
        guard elapsed <= dimensions.durationSeconds * 1_000_000_000 else { throw BenchmarkError.invocationCeiling }
        let afterMeasurement = ProcessSample.capture(), snapshot = counters.snapshot()
        let schemasAfterMeasurement = BenchmarkArguments.captures.snapshot().schemas
        let expectedInvocations = configuration.workload == "invocation" ? completed : 0
        let expectedSchemas = configuration.workload == "authoring" ? completed * dimensions.handlers : 0
        var cleanup = CleanupSnapshot(activeHandlers: 0, activeAcknowledgements: 0, acknowledgementBytes: 0, activeWorkers: snapshot.activeWorkers)
        if let plan {
            let admission = await plan.admission.snapshot()
            cleanup = .init(activeHandlers: await plan.router.activeHandlerCount, activeAcknowledgements: admission.activeCount,
                acknowledgementBytes: admission.encodedBytes, activeWorkers: snapshot.activeWorkers)
        }
        guard snapshot.handlers == expectedInvocations, snapshot.callbacks == expectedInvocations,
              schemasAfterMeasurement - schemasBeforeMeasurement == expectedSchemas,
              cleanup.activeWorkers == 0, cleanup.activeHandlers == 0, cleanup.activeAcknowledgements == 0,
              cleanup.acknowledgementBytes == 0 else { throw BenchmarkError.functionalGate }
        plan = nil
        let afterCleanup = ProcessSample.capture(), (distribution, targetNanoseconds) = try statistics.snapshot()
        guard distribution.observedCount == UInt64(completed), distribution.droppedCount == 0,
              !distribution.counterOverflow else { throw BenchmarkError.functionalGate }
        let metric: BenchmarkWorkload = configuration.workload == "definition-plan"
            ? (dimensions.mode == "dsl" ? .dslDefinitionPlanV1 : .dslDefinitionSerializationControlV1)
            : configuration.workload == "authoring" ? .dslDefinition : .dslInvoke
        let hashes = fixture.map { ["definitionPlanV1": $0.fingerprint] } ?? [:]
        var identity = ReportIdentity(scenario: "phase7.\(configuration.workload).\(dimensions.mode)", profile: dimensions.profile,
            seed: dimensions.seed, fixtureHashes: hashes,
            inputSizes: ["handlers": UInt64(dimensions.handlers), "modules": UInt64(dimensions.modules),
                "operations": UInt64(completed), "warmupOperations": UInt64(configuration.warmupOperations),
                "stringLength": UInt64(configuration.stringLength), "serializedPayloadBytes": UInt64(fixture?.serializedPayloadBytes ?? 0),
                "admittedTextBytes": UInt64(fixture?.expectedTextBytes ?? 0), "durationCapSeconds": dimensions.durationSeconds],
            instrumentation: "whole-population-10us-cells-v1", scheduler: configuration.workload == "invocation" ? "closed-loop-bounded-cohort" : "synchronous-single-owner",
            concurrency: configuration.workload == "invocation" ? UInt32(dimensions.concurrency) : 1,
            warmupNanoseconds: warmup, requestedWarmupNanoseconds: dimensions.warmupSeconds * 1_000_000_000,
            measuredNanoseconds: elapsed, repetitions: 1)
        identity.catalogVersion = 9
        var provenance = BenchmarkProvenance.capture(); provenance.fixtureHashes = hashes
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        outcomes[.success] = UInt64(completed)
        let common = DiscordBenchmarkReport(identity: identity, provenance: provenance, adapter: "phase7-independent-v1",
            clockDomain: statistics.clockDomain, status: .completed,
            counts: .init(offered: UInt64(completed), admitted: UInt64(completed), completed: UInt64(completed), outcomes: outcomes, deadlineMisses: 0),
            metrics: [.init(id: metric.rawValue, clockDomain: statistics.clockDomain, distribution: distribution)],
            gauges: [
                "processCPU": .init(value: try BenchmarkTime.nanoseconds(seconds: max(0, afterMeasurement.cpuSeconds - beforeMeasurement.cpuSeconds)),
                    unit: "nanoseconds", method: "getrusage user+system delta", scope: "measurement loop, including validation and collection"),
                "processPeakResidentBytes": .init(value: afterCleanup.peakRSSBytes, unit: "bytes", method: "getrusage", scope: "single selected process lifetime; setup and warmup included"),
                "processResidentBytes": .init(value: afterCleanup.residentBytes, unit: "bytes", method: "native process probe", scope: "after joined owner cleanup",
                    unavailableReason: afterCleanup.residentBytes == nil ? "Current RSS unavailable on this platform." : nil),
            ], cleanup: .init(completed: true, remainingOwners: 0), throughputPerSecond: Double(completed) * 1e9 / Double(max(1, elapsed)),
            qualificationLimitations: [
                "One selected population per invocation; use independent supervised fresh processes and explicit release receipts for comparisons.",
                "DefinitionPlan target compiles prebuilt raw command-shaped declarations; the direct arm is a distinct JSON writer CPU control without structural admission equivalence.",
                "Authoring uses the existing dsl.definition boundary; invocation excludes schema capture, authoring, lowering, router and fixed input setup.",
                "Whole-population target histograms have ten-microsecond cells and explicit overflow. Exact target sums are separate from gross loop time.",
                "Native before/after live allocator gauges are retained state, not cumulative allocation events. Process peaks include setup and warmup.",
                "Authoritative build receipts must bind both the identical harness and selected library revision/content. In-process source identity remains unavailable.",
                "No clean/incremental build, compiler/plugin/bootstrap, package planning, cold runtime startup, network, Discord, or controlled-host numerical qualification is implied.",
            ])
        try common.validate()
        return .init(configuration: configuration, operations: completed, targetNanoseconds: targetNanoseconds,
            elapsedNanoseconds: elapsed, schemaBuilds: schemasAfterMeasurement - initialSchemas,
            counters: snapshot, cleanup: cleanup, beforeSetup: beforeSetup, beforeMeasurement: beforeMeasurement,
            afterMeasurement: afterMeasurement, afterCleanup: afterCleanup, common: common)
    }

    /// The DSL timer includes public admission/result creation; writer-control timing includes serialized byte production.
    /// Exact output checks follow the timestamp and never enter the target histogram.
    /// - Parameters:
    ///   - fixture: Prebuilt finite declarations and independent writer-byte oracle.
    ///   - mode: Validated DSL target or direct JSON writer control.
    ///   - statistics: Optional complete-population collector; nil is unmeasured warmup.
    /// - Throws: Public structural/JSON validation errors or exact output mismatch; owns no runtime tasks.
    private static func definitionOperation(_ fixture: DefinitionPlanFixture, mode: String, statistics: Phase7Statistics? = nil) throws {
        let start = ContinuousClock.now
        if mode == "dsl" {
            let result = try DefinitionPlan.compile(fixture.definition, supportedKinds: [DefinitionPlanFixture.kind], limits: fixture.limits)
            let elapsed = start.duration(to: .now)
            statistics?.record(elapsed)
            try fixture.validate(result)
        } else {
            let bytes = try fixture.declarations.reduce(0) { try $0 + $1.payload.serialized().count }
            let elapsed = start.duration(to: .now)
            statistics?.record(elapsed)
            guard bytes == fixture.serializedPayloadBytes else { throw BenchmarkError.functionalGate }
        }
    }

    /// Writes completed artifacts after integrity checks; failed/partial processes remain visible to the supervisor.
    /// - Parameter arguments: Explicit `phase7` options; legacy entry points and report shapes remain separate.
    /// - Throws: Parse/workload failures or bounded serialization/atomic write errors; never writes completed partial data.
    static func run(_ arguments: [String]) async throws {
        let configuration = try Phase7TimingConfiguration.parse(arguments)
        let report = try await measure(configuration)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        guard data.count <= DiscordBenchmarkReport.maximumSerializedBytes else { throw BenchmarkReportError.reportTooLarge }
        if let path = configuration.dimensions.commonReport { try report.common.validatedData().write(to: URL(fileURLWithPath: path), options: .atomic) }
        if let path = configuration.dimensions.output { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
        else { try FileHandle.standardOutput.write(contentsOf: data + Data([10])) }
    }
}
