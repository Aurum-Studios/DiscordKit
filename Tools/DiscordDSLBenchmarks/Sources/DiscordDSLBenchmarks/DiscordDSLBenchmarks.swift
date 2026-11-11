// File: Tools/DiscordDSLBenchmarks/Sources/DiscordDSLBenchmarks/DiscordDSLBenchmarks.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordLogging
import Foundation

/// Complete matrix artifact carries its configuration, local environment and explicit measurement boundaries.
struct BenchmarkReport: Encodable, Sendable {
    let schemaVersion = 1
    let configuration: BenchmarkConfiguration
    let environment: BenchmarkEnvironment
    let workloads: [WorkloadMeasurement]
    let qualification: [String]
}

/// Local offline authoring/handler measurements; the executable has no listener, credentials or remote adapter.
@main struct DiscordDSLBenchmarks {
    /// Dispatches opt-in Stage 7 suites or the retained deterministic legacy paired matrix.
    /// Process-owned SwiftLog diagnostics go to stderr, preserving the JSON destination.
    /// - Throws: Configuration, original workload validation or hard functional gate failure; no partial success artifact is written.
    static func main() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "compiler-report" { try CompilerTimingCommand.run(Array(arguments.dropFirst())); return }
        if arguments.first == "authoring" { try await AuthoringTimingCommand.run(Array(arguments.dropFirst())); return }
        if arguments.first == "phase7" { try await Phase7TimingCommand.run(Array(arguments.dropFirst())); return }
        let parsed = try BenchmarkConfiguration.parse(arguments)
        let environment = BenchmarkEnvironment.capture()
        let modes = parsed.mode.map { [$0] } ?? ["direct", "dsl"]
        let selected = parsed.configuration.handlerCounts.flatMap { count in
            modes.compactMap { BenchmarkWorkload.authoring(mode: $0, handlers: count) }
        }
        let statistics = try RunStatistics.requested(workloads: selected)
        var workloads: [WorkloadMeasurement] = []
        do {
            for count in parsed.configuration.handlerCounts {
                for mode in modes {
                    workloads.append(try await RuntimeBenchmark.run(mode: mode, handlerCount: count, configuration: parsed.configuration,
                        statistics: statistics, warmupInvocations: parsed.warmupInvocations))
                }
            }
        } catch {
            do {
                try statistics?.writePartialSidecar(
                    identity: ReportIdentity(scenario: "dsl-runtime", profile: parsed.mode ?? "legacy-paired-matrix",
                        inputSizes: ["requestedInvocations": UInt64(parsed.configuration.invocations),
                            "warmupInvocations": UInt64(parsed.warmupInvocations)], scheduler: "bounded-workers"),
                    adapter: LegacyReportFormat.dslVersion1.rawValue, cancelled: error is CancellationError)
            } catch {
                try? FileHandle.standardError.write(contentsOf: Data("Partial benchmark envelope unavailable.\n".utf8))
            }
            throw error
        }
        let report = BenchmarkReport(configuration: parsed.configuration, environment: environment, workloads: workloads,
            qualification: [
                "Local synthetic normalized HTTP contexts; no signature verification, network, Discord, Gateway host or fleet-capacity qualification.",
                "Each declared handler has one retained schema and one fixed interaction snapshot; each invocation creates a fresh response owner and typed arguments.",
                "Direct and DSL paths share the real typed decoder, handler, router and response ownership; the direct route is handwritten and the DSL route uses SlashCommand and CommandCompilation.",
                "Plan compilation includes authoring, schema capture, lowering and router admission; it excludes fixed input parsing, sink creation and consumer compiler time measured by the separate build script. Process snapshots include the fixture population.",
                "Latency is a bounded prefix of end-to-end route invocations including fresh responder construction and exact initial callback validation; throughput covers every invocation and joined worker round.",
                "Selected modes: \(modes.joined(separator: ",")); unmeasured same-plan warmup: \(parsed.warmupInvocations) calls per working set. Legacy defaults run direct then DSL. Process-wide peaks include warmup and earlier workloads.",
                "Accounted state reports retained input/author JSON byte counts and configured cardinality caps, not exact heap allocation size. Current RSS and live allocation gauges are best-effort platform observations.",
                "No REST client, registration reconciler, hydration provider, transport or listener is constructed; only the initial offline callback sink is configured. Implicit REST request counts are structurally zero.",
                "Duration-floor runs repeat the fixed population up to a hard 100-million invocation ceiling; existing cache/broadcast soak and handler execution evidence remain separate.",
            ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try statistics?.writeLegacySidecar(data, format: .dslVersion1,
            identity: ReportIdentity(scenario: "dsl-runtime", profile: parsed.mode ?? "legacy-paired-matrix",
                inputSizes: ["invocations": UInt64(parsed.configuration.invocations),
                    "concurrency": UInt64(parsed.configuration.concurrency),
                    "payloadBytes": UInt64(parsed.configuration.payloadBytes),
                    "warmupInvocations": UInt64(parsed.warmupInvocations)],
                instrumentation: "aggregate", scheduler: "bounded-workers"))
        if let output = parsed.output { try data.write(to: URL(fileURLWithPath: output), options: .atomic) }
        else { print(String(decoding: data, as: UTF8.self)) }
    }
}
