// File: Sources/DiscordLogging/DiscordTimingObservation.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

/// A content-free scalar value for optional timing outputs, independent of transport adoption.
///
/// This value has no begin timestamp, operation identity or parent. It cannot establish an interval
/// timeline or profiler begin/end pair. The finite phases preserve the legacy owner boundaries;
/// a bridge must not reinterpret their populations or invent correlation.
public struct DiscordTimingObservation: Sendable, Equatable {
    /// Closed legacy boundaries, carried as finite identities rather than application labels.
    public enum Phase: String, Sendable, Codable, CaseIterable {
        /// Time retained in the dispatcher local pending queue, excluding private-hub input residence.
        case gatewayLocalQueue
        /// Shared callback-authority admission wait, including its existing cancellation cleanup.
        case gatewaySharedAdmission
        /// Original trusted socket receipt through actual dispatcher admission; replay is excluded.
        case gatewayReceiveToAdmission
        /// Trusted socket receipt through confirmed initial-response sink completion.
        case gatewayReceiveToAcknowledgement
        /// Actual dispatcher admission through confirmed initial-response sink completion.
        case gatewayAdmissionToAcknowledgement
        /// Whole dispatcher run through joined children and subscription cleanup, including cancellation.
        case gatewayRunJoined
        /// Initial response call through confirmed completion or joined failure and admission release.
        case interactionInitialResponse
        /// Original-response edit through confirmed completion or joined failure.
        case interactionOriginalEdit
        /// Confirmed initial acknowledgement through the first successful original-response edit.
        case interactionAcknowledgementToOriginalEdit
        /// One actual exchange rate-authority admission wait; shared reads emit once per exchange.
        case httpAdmission
        /// Adapter entry through headers; failed sends include their existing request/admission cleanup.
        case httpHeaders
        /// Response collection through EOF/error and joined response-body cleanup.
        case httpBody
        /// One independently cancellable subscriber wait, separate from the shared exchange population.
        case httpCoalescedSubscriber
        /// One REST call through result/failure and existing structured joins; shared wire work may continue.
        case httpExecutionJoined
    }

    /// Result of the measured boundary only; uncertainty never authorizes replay.
    public enum Outcome: String, Sendable, Codable, CaseIterable {
        /// Confirmed return at this boundary; successful headers do not establish final API acceptance.
        case succeeded
        /// Definite failure at this boundary without invented remote success.
        case failed
        /// Cancellation after this boundary existing owned cleanup has joined.
        case cancelled
        /// Potential submission without confirmation; this result never grants permission to replay.
        case uncertain
    }

    /// Finite scalar owner boundary, with no arbitrary metric label.
    public let phase: Phase
    /// Owner-established result for this boundary only.
    public let outcome: Outcome
    /// Checked nonnegative integer nanoseconds; nil explicitly marks an invalid or overflowing duration.
    public let elapsedNanoseconds: Int64?

    /// Converts one elapsed duration without reading clocks, formatting strings or emitting output.
    /// - Parameters:
    ///   - phase: Finite legacy boundary; its source semantics remain unchanged.
    ///   - outcome: Finite result for this boundary.
    ///   - elapsed: Nonnegative duration. Negative values and signed integer nanosecond overflow
    ///     produce nil, never fabricated zero or saturated latency. Subnanoseconds truncate toward zero.
    public init(phase: Phase, outcome: Outcome, elapsed: Duration) {
        self.phase = phase
        self.outcome = outcome
        guard elapsed >= .zero else { elapsedNanoseconds = nil; return }
        let components = elapsed.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let total = seconds.partialValue.addingReportingOverflow(components.attoseconds / 1_000_000_000)
        elapsedNanoseconds = seconds.overflow || total.overflow ? nil : total.partialValue
    }
}
