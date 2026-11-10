// File: Sources/DiscordLogHandlers/DiscordTimingLogAdapter.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging
import Logging

/// Explicit SwiftLog timing output with fixed events and a closed, content-free metadata vocabulary.
///
/// No request, raw route, payload, credential, persistent identifier or error description can be
/// supplied to this adapter. It creates no global bootstrap, observer, task or output lifetime. Its
/// application-owned logger still controls its own label, base/provider metadata and synchronous
/// backend; applications must keep that independently configured content safe. Filtered calls return
/// before numeric rendering or metadata construction. Accepted calls can format and perform backend
/// I/O synchronously and therefore must not run in realtime callbacks.
public struct DiscordTimingLogAdapter: Sendable {
    private let logger: Logger
    private let level: Logger.Level

    /// Stores an application-configured logger without emitting output or evaluating metadata providers.
    /// - Parameters:
    ///   - logger: Value-semantic application-owned logger; existing console/file/unified outputs work.
    ///     Its base metadata and provider remain application-owned privacy responsibilities.
    ///   - level: Severity for every timing record; defaults to trace. Threshold filtering stays lazy.
    public init(logger: Logger, level: Logger.Level = .trace) {
        self.logger = logger
        self.level = level
    }

    /// Emits one completed scalar with no invented operation identity, start timestamp or profiler pair.
    /// - Parameter observation: Finite phase/result and checked duration. Invalid duration emits an
    ///   explicit validity marker and omits duration rather than fabricating zero. Output is synchronous.
    public func record(_ observation: DiscordTimingObservation) {
        guard level >= logger.logLevel else { return }
        var metadata: Logger.Metadata = [
            "dk.event": "timing.scalar",
            "dk.timing.operation": .string(observation.phase.rawValue),
            "dk.outcome": .string(observation.outcome.rawValue),
            "dk.timing.validity": .string(observation.elapsedNanoseconds == nil ? "timestampOutOfRange" : "valid"),
        ]
        if let elapsed = observation.elapsedNanoseconds { metadata["dk.duration_ns"] = .string(String(elapsed)) }
        logger.log(level: level, "Timing observation", metadata: metadata)
    }

    /// Emits an actual detailed endpoint with finite names and bounded numeric identity metadata.
    /// - Parameter event: Lifecycle begin/end established by its owner. Invalid endpoints keep their
    ///   explicit validity and omit unavailable numeric values. No application content is inspected.
    public func record(_ event: DiscordIntervalEvent) {
        guard level >= logger.logLevel else { return }
        var metadata: Logger.Metadata = [
            "dk.event": .string(event.kind == .began ? "timing.interval.began" : "timing.interval.ended"),
            "dk.timing.operation": .string(TimingOutputNames.operations[TimingOutputNames.operationIndex(event.operation)]),
            "dk.timing.stage": .string(TimingOutputNames.stages[TimingOutputNames.stageIndex(event.stage)]),
            "dk.timing.validity": .string(TimingOutputNames.validity(event.validity)),
            "dk.timing.clock_domain": .string(String(event.context.clockDomain)),
            "dk.timing.namespace": .string(String(event.context.operationID.namespace)),
            "dk.timing.operation_id": .string(String(event.context.operationID.value)),
        ]
        if let outcome = event.outcome {
            metadata["dk.outcome"] = .string(DiscordTimingObservation.Outcome.allCases[TimingOutputNames.outcomeIndex(outcome)].rawValue)
        }
        if let parent = event.context.parentID {
            metadata["dk.timing.parent_namespace"] = .string(String(parent.namespace))
            metadata["dk.timing.parent_id"] = .string(String(parent.value))
        }
        if let attempt = event.context.attempt { metadata["dk.timing.attempt"] = .string(String(attempt)) }
        if let timestamp = event.timestampNanoseconds { metadata["dk.timing.timestamp_ns"] = .string(String(timestamp)) }
        if let elapsed = event.elapsedNanoseconds { metadata["dk.duration_ns"] = .string(String(elapsed)) }
        logger.log(level: level, "Timing observation", metadata: metadata)
    }
}
