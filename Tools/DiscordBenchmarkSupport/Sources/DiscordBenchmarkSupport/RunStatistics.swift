// File: Tools/DiscordBenchmarkSupport/Sources/DiscordBenchmarkSupport/RunStatistics.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation

/// Finite development workloads with unchanged legacy timer boundaries and new whole-population identities.
public enum BenchmarkWorkload: String, CaseIterable, Sendable {
    case transport = "legacy.transport.wholePopulation"
    case httpPolicy = "legacy.httpPolicy.wholePopulation"
    case direct10 = "legacy.dsl.direct10.wholePopulation"
    case direct100 = "legacy.dsl.direct100.wholePopulation"
    case direct1000 = "legacy.dsl.direct1000.wholePopulation"
    case dsl10 = "legacy.dsl.dsl10.wholePopulation"
    case dsl100 = "legacy.dsl.dsl100.wholePopulation"
    case dsl1000 = "legacy.dsl.dsl1000.wholePopulation"
    case voice = "legacy.voice.duplexTick.wholePopulation"
    /// One complete instrumentation fixture call, including synchronous observer work.
    case instrumentation = "instrumentation.operation.gross"
    /// External synchronous batch including minimal checksum consumption, never a call percentile.
    case pureBatch = "pure.batch"
    /// Joined adapter request; response completion and awaited close precede diagnostics.
    case transportRequest = "transport.request"
    case transportConstruct = "transport.construct"
    case transportHeaders = "transport.headers"
    case transportBody = "transport.body"
    case transportBodyClose = "transport.bodyClose"
    /// Caller-visible REST operation and honestly observed child boundaries.
    case restRequest = "rest.request"
    case restConstruct = "rest.construct"
    case restOrderWait = "rest.orderWait"
    case restCacheLookup = "rest.cacheLookup"
    case restDecode = "rest.decode"
    case restRetryWait = "rest.retryWait"
    case restAdmission = "rest.admission"
    case restHeaders = "rest.headers"
    case restBody = "rest.body"
    case restSubscriber = "rest.subscriber"
    case restExecution = "rest.executionJoined"
    /// Scheduled and submitted whole workflows retain separate populations.
    case arrivalScheduledResponse = "arrival.scheduledResponse"
    case arrivalSubmittedResponse = "arrival.submittedResponse"
    case arrivalLateness = "arrival.lateness"
    case arrivalAdmissionWait = "arrival.admissionWait"
    case arrivalService = "arrival.service"

    /// Gateway, signed application and explicitly synthetic owner boundaries, introduced in catalog six.
    case gatewaySession = "gateway.sessionJoined"
    case gatewaySocketReceipt = "gateway.socketReceipt"
    case gatewayDecode = "gateway.decode"
    case gatewayIngestionQueue = "gateway.ingestionQueue"
    case gatewayPublication = "gateway.publication"
    case gatewayHubResidence = "gateway.hubResidence"
    case gatewayDispatch = "gateway.dispatchJoined"
    case gatewayLocalQueue = "gateway.localQueue"
    case gatewayAdmission = "gateway.admission"
    case gatewayHandler = "gateway.handler"
    case gatewayHeartbeatACK = "gateway.heartbeatAck"
    case gatewayReconnect = "gateway.reconnect"
    case gatewayShutdown = "gateway.shutdown"
    case ingressApplicationResponse = "ingress.applicationResponse"
    case ingressBodyRead = "ingress.bodyRead"
    case ingressSignature = "ingress.signature"
    case ingressAdmission = "ingress.admission"
    case ingressDecode = "ingress.decode"
    case commandRoute = "command.route"
    case commandArguments = "command.arguments"
    case commandAdmission = "command.admission"
    case commandPolicy = "command.policy"
    case commandHandler = "command.handler"
    case interactionHandler = "interaction.handler"
    case interactionWorkflow = "interaction.workflow"
    case interactionProviderWait = "interaction.providerWait"
    case interactionInitialResponse = "interaction.initialResponse"
    case interactionOriginalEdit = "interaction.originalEdit"
    case syntheticInvoke = "synthetic.invoke"
    case syntheticProviderWait = "synthetic.providerWait"

    case gatewayReceiveToAdmission = "gateway.receiveToAdmission"
    case gatewayReceiveToAcknowledgement = "gateway.receiveToAcknowledgement"
    case gatewayAdmissionToAcknowledgement = "gateway.admissionToAcknowledgement"
    case gatewayInitialResponse = "gateway.initialResponse"
    case gatewayOriginalEdit = "gateway.originalEdit"
    case gatewayAcknowledgementToOriginalEdit = "gateway.acknowledgementToOriginalEdit"

    /// Earliest catalog revision defining this identity; old readers retain old semantics.
    public var minimumCatalogVersion: UInt32 {
        /// Returns the frozen catalog introduction version without inspecting observations.
        get {
            switch self {
            case .gatewayReceiveToAdmission, .gatewayReceiveToAcknowledgement, .gatewayAdmissionToAcknowledgement, .gatewayInitialResponse, .gatewayOriginalEdit, .gatewayAcknowledgementToOriginalEdit, .commandPolicy, .gatewaySession, .gatewaySocketReceipt, .gatewayDecode, .gatewayIngestionQueue, .gatewayPublication, .gatewayHubResidence, .gatewayDispatch, .gatewayLocalQueue, .gatewayAdmission, .gatewayHandler, .gatewayHeartbeatACK, .gatewayReconnect, .gatewayShutdown, .ingressApplicationResponse, .ingressBodyRead, .ingressSignature, .ingressAdmission, .ingressDecode, .commandRoute, .commandArguments, .commandAdmission, .commandHandler, .interactionHandler, .interactionWorkflow, .interactionProviderWait, .interactionInitialResponse, .interactionOriginalEdit, .syntheticInvoke, .syntheticProviderWait: 6
            case .instrumentation: 3
            case .pureBatch: 4
            case .transport, .httpPolicy, .direct10, .direct100, .direct1000,
                 .dsl10, .dsl100, .dsl1000, .voice: 2
            default: 5
            }
        }
    }

    /// Selects a declared DSL population without accepting arbitrary metric labels.
    /// - Parameters:
    ///   - mode: Exact direct or dsl workload selection.
    ///   - handlers: Exactly 10, 100 or 1,000 retained handlers.
    /// - Returns: A finite metric identity, or nil for unsupported input.
    public static func authoring(mode: String, handlers: Int) -> Self? {
        Self(rawValue: "legacy.dsl.\(mode)\(handlers).wholePopulation")
    }
}

/// Shared opt-in numeric collection for development tools; no runtime product imports this package.
///
/// Initialization allocates every finite population before work. Each 100-microsecond
/// bucket covers durations in 0...1 second; longer observations remain censored.
/// Selected workload subsets must fit the shared 16 MiB ceiling; a full catalog allocation can be rejected.
/// A lock protects concurrent DSL workers. It never calls application code or does
/// I/O, and completed timestamps are captured before entering it. Collection cost
/// can still perturb scheduling and enclosing throughput measurements.
public final class RunStatistics: @unchecked Sendable {
    private let lock = NSLock()
    private var populations: [BenchmarkWorkload: [BenchmarkOutcome: BoundedHistogram]]
    public let clockDomain = UUID().uuidString

    /// Preallocates bounded storage for selected, unique workload identities.
    /// - Parameter workloads: Finite workload set; duplicates are harmless.
    /// - Throws: Invalid histogram configuration or aggregate budget rejection.
    public init(workloads: [BenchmarkWorkload]) throws {
        let configuration = try HistogramConfiguration(lowerBoundNanoseconds: 0,
            upperBoundNanoseconds: 1_000_000_000, bucketWidthNanoseconds: 100_000)
        let count = Set(workloads).count * BenchmarkOutcome.allCases.count
        _ = try AggregateStatisticsBudget.validate(histograms: Array(repeating: configuration, count: count),
            additionalBytes: 16_384)
        var result: [BenchmarkWorkload: [BenchmarkOutcome: BoundedHistogram]] = [:]
        for workload in Set(workloads) {
            var outcomes: [BenchmarkOutcome: BoundedHistogram] = [:]
            for outcome in BenchmarkOutcome.allCases {
                outcomes[outcome] = BoundedHistogram(configuration: configuration)
            }
            result[workload] = outcomes
        }
        populations = result
    }

    /// Creates collection only when a common-envelope sidecar was explicitly requested.
    /// - Parameters:
    ///   - workloads: Fixed identities allocated outside measured work.
    ///   - environment: Process environment, injectable for deterministic disabled tests.
    /// - Returns: Nil without DK_BENCHMARK_ENVELOPE, otherwise a bounded collector.
    /// - Throws: Configuration failure or an empty requested destination.
    public static func requested(workloads: [BenchmarkWorkload],
        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> RunStatistics? {
        guard let destination = environment["DK_BENCHMARK_ENVELOPE"] else { return nil }
        guard !destination.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        return try Self(workloads: workloads)
    }

    /// Records a completed operation in its outcome population without retaining raw observations.
    /// - Parameters:
    ///   - duration: Elapsed ContinuousClock duration, captured before this call.
    ///   - workload: An identity selected during initialization.
    ///   - outcome: Terminal category; unknown failures remain failure.
    /// Invalid conversion increments loss. Unregistered identities are a programmer
    /// error and are rejected before any dictionary allocation or label insertion.
    public func record(_ duration: Duration, workload: BenchmarkWorkload, outcome: BenchmarkOutcome) {
        lock.lock()
        defer { lock.unlock() }
        precondition(populations[workload] != nil, "Unregistered benchmark workload")
        if let value = try? BenchmarkTime.nanoseconds(duration: duration) {
            populations[workload]![outcome]!.record(value)
        } else {
            populations[workload]![outcome]!.recordLoss()
        }
    }

    /// Copies deterministic snapshots after joined work, excluding empty populations.
    /// - Returns: Sorted full-population metrics with explicit censor and loss counts.
    public func metrics() -> [BenchmarkMetric] {
        lock.lock()
        defer { lock.unlock() }
        return populations.keys.sorted { $0.rawValue < $1.rawValue }.flatMap { workload in
            populations[workload]!.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { outcome in
                let snapshot = populations[workload]![outcome]!.snapshot()
                guard snapshot.observedCount > 0 || snapshot.droppedCount > 0 || snapshot.counterOverflow else { return nil }
                return BenchmarkMetric(id: workload.rawValue, outcome: outcome,
                    clockDomain: clockDomain, distribution: snapshot)
            }
        }
    }

    /// Writes an opt-in common envelope after native serialization and awaited cleanup.
    /// - Parameters:
    ///   - data: Unmodified legacy report bytes, preserved inside the adapter.
    ///   - format: Explicit native source format/version.
    ///   - identity: Scenario/profile dimensions; unavailable evidence remains unavailable.
    ///   - environment: Sidecar destination and optional recorded seed.
    /// - Throws: Schema, bounded serialization or atomic file-write failure.
    /// This method performs no writes when no sidecar was requested. It does not
    /// promote a legacy import into numerical qualification.
    public func writeLegacySidecar(_ data: Data, format: LegacyReportFormat, identity: ReportIdentity,
        environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let destination = environment["DK_BENCHMARK_ENVELOPE"], !destination.isEmpty else { return }
        let report = try DiscordBenchmarkReport.adaptingLegacy(data, format: format,
            identity: identity, metrics: metrics())
        try report.validatedData().write(to: URL(fileURLWithPath: destination), options: .atomic)
    }

    /// Retains accumulated observations after a failed or cancelled owner has joined its work.
    /// - Parameters:
    ///   - identity: Known requested dimensions; incomplete counts are never invented.
    ///   - adapter: Finite native adapter/format identity.
    ///   - cancelled: True only for an observed cancellation error.
    ///   - environment: Explicit sidecar destination; absent disables filesystem work.
    /// - Throws: Bounded schema serialization or atomic write errors. Callers preserve
    ///   their original operation error if partial evidence cannot be written.
    /// Cleanup gauges and whole-run throughput remain explicitly unavailable. A
    /// failure before a timer began has no fabricated zero-duration observation.
    public func writePartialSidecar(identity: ReportIdentity, adapter: String, cancelled: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let destination = environment["DK_BENCHMARK_ENVELOPE"], !destination.isEmpty else { return }
        let report = DiscordBenchmarkReport(identity: identity, provenance: .capture(), adapter: adapter,
            clockDomain: clockDomain, status: cancelled ? .interrupted : .failed, metrics: metrics(),
            gauges: ["processCPU": .init(value: nil, unit: "nanoseconds", method: "unavailable",
                    scope: "process", unavailableReason: "Partial run: gauge not captured."),
                "processResidentBytes": .init(value: nil, unit: "bytes", method: "unavailable",
                    scope: "process", unavailableReason: "Partial run: gauge not captured."),
                "processPeakResidentBytes": .init(value: nil, unit: "bytes", method: "unavailable",
                    scope: "process-lifetime", unavailableReason: "Partial run: gauge not captured.")],
            cleanup: .init(reason: "Owner failure path completed; final resource gauges unavailable."),
            qualificationLimitations: ["Partial run: complete outcome, resource and throughput accounting unavailable."])
        try report.validatedData().write(to: URL(fileURLWithPath: destination), options: .atomic)
    }
}
