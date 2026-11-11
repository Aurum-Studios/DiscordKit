// File: Tools/DiscordTimingBenchmarks/Sources/DiscordTimingBenchmarks/Outputs.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging
import DiscordLogHandlers
import DiscordTransport
import Foundation

/// Constant-size callback accounting; a shared lock deliberately supplies the contention workload.
final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: UInt64 = 0

    /// Counts one delivered safe record synchronously, with no queue, string rendering or recursive output.
    /// - Parameter record: Content-free timing log record whose caller already formatted safe metadata.
    func record(_ record: DiscordLogRecord) { lock.withLock { count += 1 } }

    /// Reads the exact callback count only after producers have joined.
    /// - Returns: Number of accepted callbacks since construction, including no warmup from other output owners.
    func snapshot() -> UInt64 { lock.withLock { count } }
}

/// Application-owned output lifetimes; every run and warmup has an independent owner.
final class TimingOutputs: @unchecked Sendable {
    let timing: DiscordIntervalTiming?
    let scalar: OperationTiming?
    let aggregate: DiscordTimingAggregate?
    let capture: DiscordIntervalCapture?
    let file: DiscordFileLogSink?
    let callbacks: CallbackCounter
    let logger: Logger
    let recordInterval: @Sendable (DiscordIntervalEvent) -> Void
    #if canImport(os)
    let signposts: DiscordIntervalSignposts?
    #endif

    /// Opens explicit finite adapters before measurement without modifying process logging bootstrap.
    /// - Parameters:
    ///   - configuration: Fixed mode and sampling seed.
    ///   - directory: Existing private directory exclusively owned by this output lifetime.
    /// - Throws: Adapter validation/opening failures, or explicit unsupported Apple-only mode errors.
    init(configuration: TimingConfiguration, directory: URL) throws {
        let mode = configuration.mode
        let callbacks = CallbackCounter()
        self.callbacks = callbacks
        let collectorCount = configuration.collectorScope == .shared ? 1 : configuration.concurrency
        let activeIntervalLimit = 256 / collectorCount
        let usesAggregate = mode == .aggregate || mode == .combined || mode == .scalarAggregate
        let aggregateConfiguration = configuration.collectorScope == .shared ? DiscordTimingAggregateConfiguration()
            : DiscordTimingAggregateConfiguration(maximumKeys: mode == .scalarAggregate ? 4 : 1)
        let aggregate = usesAggregate ? try DiscordTimingAggregate(configuration: aggregateConfiguration) : nil
        self.aggregate = aggregate
        let capture: DiscordIntervalCapture?
        if mode == .sampled || mode == .combined || mode == .saturation {
            capture = try DiscordIntervalCapture(configuration: .init(
                maximumRecords: mode == .saturation ? 3 : 65_536 / collectorCount,
                maximumBytes: 8 * 1_024 * 1_024 / collectorCount, maximumActiveIntervals: activeIntervalLimit,
                sampleEvery: mode == .saturation ? 1 : 16, seed: configuration.seed))
        } else { capture = nil }
        self.capture = capture
        let file: DiscordFileLogSink?
        if mode == .rotatingFile || mode == .sinkFailure {
            file = try DiscordFileLogSink(url: directory.appendingPathComponent("timing.ndjson"),
                configuration: .init(maximumFileBytes: 16_384, maximumFiles: 3, maximumRecordBytes: 8_192))
            if mode == .sinkFailure { try file?.close() }
        } else { file = nil }
        self.file = file
        let logger: Logger
        switch mode {
        case .console:
            logger = Logger(label: "discordkit.timing.benchmark") { label in
                var handler = StreamLogHandler.standardError(label: label)
                handler.logLevel = .trace
                return handler
            }
        case .rotatingFile, .sinkFailure:
            logger = Logger(label: "discordkit.timing.benchmark") { label in
                DiscordFileLogHandler(label: label, sink: file!, logLevel: .trace)
            }
        case .unifiedLog:
            #if canImport(OSLog)
            logger = Logger(label: "discordkit.timing.benchmark") { label in
                DiscordOSLogHandler(label: label, subsystem: "DiscordKit.Benchmarks", logLevel: .trace)
            }
            #else
            throw TimingBenchmarkError.unsupportedPlatform("Unified log requires Apple OSLog")
            #endif
        default:
            logger = Logger(label: "discordkit.timing.benchmark") { label in
                DiscordCallbackLogHandler(label: label, logLevel: [.callback, .callbackContention, .combined].contains(mode) ? .trace : .info,
                    output: callbacks.record)
            }
        }
        self.logger = logger
        #if canImport(os)
        let signposts = mode == .signposts
            ? try DiscordIntervalSignposts(maximumActiveIntervals: activeIntervalLimit,
                subsystem: "DiscordKit.Benchmarks", category: "Intervals") : nil
        self.signposts = signposts
        #else
        if mode == .signposts { throw TimingBenchmarkError.unsupportedPlatform("Signposts require Apple os") }
        #endif
        let logAdapter = DiscordTimingLogAdapter(logger: logger)
        let logEvents: Set<TimingMode> = [.callback, .callbackContention, .console, .rotatingFile, .sinkFailure, .unifiedLog, .combined]
        let recordInterval: @Sendable (DiscordIntervalEvent) -> Void = { event in
            aggregate?.record(event)
            capture?.record(event)
            if logEvents.contains(mode) { logAdapter.record(event) }
            #if canImport(os)
            signposts?.record(event)
            #endif
        }
        self.recordInterval = recordInterval
        if mode == .disabled || mode == .emptyHarness || mode == .clockRead || mode == .filtered || mode.usesREST {
            timing = nil
        } else if mode == .noop {
            timing = DiscordIntervalTiming(clockDomain: 1, sink: { _ in })
        } else {
            timing = DiscordIntervalTiming(clockDomain: 1, sink: recordInterval)
        }
        switch mode {
        case .scalarNoop: scalar = OperationTiming(sink: { _ in })
        case .scalarAggregate: scalar = OperationTiming(sink: { aggregate?.record($0.observation) })
        default: scalar = nil
        }
    }

    /// Stops already joined producers' adapter admission, flushes files and exports local timelines.
    /// - Parameter exportDirectory: Optional caller-owned destination. Nil still serializes capture for byte accounting.
    /// - Returns: Explicit acceptance, loss, incomplete, rotation and export accounting.
    /// - Throws: File flush, capture export or atomic export errors. No producer task survives this call.
    func close(exportDirectory: URL?) throws -> [String: UInt64] {
        capture?.close()
        #if canImport(os)
        signposts?.close()
        #endif
        try file?.close()
        var values: [String: UInt64] = ["callbackRecords": callbacks.snapshot()]
        if let aggregate {
            let state = aggregate.snapshot()
            values["aggregateAccepted"] = state.acceptedCount
            values["aggregateDropped"] = state.droppedCount
            values["aggregateInvalid"] = state.invalidCount
            values["aggregateIgnoredBegin"] = state.ignoredBeginCount
            values["aggregateStorageUpperBoundBytes"] = UInt64(state.storageUpperBoundBytes)
            if let exportDirectory {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(state).write(to: exportDirectory.appendingPathComponent("aggregate.json"), options: .atomic)
            }
        }
        if let capture {
            let state = capture.snapshot()
            values["captureRetained"] = UInt64(state.retainedRecords)
            values["captureDropped"] = state.droppedRecords
            values["captureSampledOut"] = state.sampledOutRecords
            values["captureIncomplete"] = state.incompleteIntervals
            values["captureUnmatched"] = state.unmatchedEndpoints
            values["captureMissingParent"] = state.missingParentRecords
            values["captureLate"] = state.lateRecords
            values["captureActiveAfterClose"] = UInt64(state.activeIntervals)
            values["captureMaximumRecords"] = UInt64(capture.configuration.maximumRecords)
            values["captureMaximumBytes"] = UInt64(capture.configuration.maximumBytes)
            values["captureMaximumActiveIntervals"] = UInt64(capture.configuration.maximumActiveIntervals)
            let ndjson = try capture.ndjson(), timeline = try capture.chromeTrace()
            values["ndjsonBytes"] = UInt64(ndjson.count)
            values["timelineBytes"] = UInt64(timeline.count)
            if let exportDirectory {
                try ndjson.write(to: exportDirectory.appendingPathComponent("intervals.ndjson"), options: .atomic)
                try timeline.write(to: exportDirectory.appendingPathComponent("timeline.json"), options: .atomic)
            }
        }
        if let file {
            let state = file.snapshot()
            values["fileWritten"] = state.writtenRecords
            values["fileDropped"] = state.droppedRecords
            values["fileRotations"] = state.rotations
            values["fileFailures"] = state.failures
            values["fileClosed"] = state.isClosed ? 1 : 0
        }
        #if canImport(os)
        if let signposts {
            let state = signposts.snapshot()
            values["signpostBegun"] = state.begunIntervals
            values["signpostEnded"] = state.endedIntervals
            values["signpostDropped"] = state.droppedRecords
            values["signpostIncomplete"] = state.incompleteIntervals
            values["signpostUnmatched"] = state.unmatchedEndpoints
            values["signpostActiveAfterClose"] = UInt64(state.activeIntervals)
        }
        #endif
        return values
    }
}
