// File: Sources/DiscordTransport/OperationTiming.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCore
import Dispatch

/// One bounded observation with fixed protocol stages and no request, user, route or credential labels.
/// Durations belong to one measured interval; subtracting unrelated samples does not establish a latency.
public struct OperationTimingSample: Sendable, Equatable {
    /// Closed ownership boundaries; exchange samples and subscriber samples describe different work.
    public enum Phase: Sendable, Equatable {
        /// Time retained in the dispatcher's local pending queue, excluding private-hub input residence.
        case gatewayLocalQueue
        /// Time waiting for the optional shared callback authority, including its cancellation cleanup.
        case gatewaySharedAdmission
        /// Original trusted socket receipt through actual dispatcher admission; public replay cannot emit it.
        case gatewayReceiveToAdmission
        /// Original trusted socket receipt through confirmed initial-response sink completion.
        case gatewayReceiveToAcknowledgement
        /// Actual dispatcher admission through confirmed initial-response sink completion.
        case gatewayAdmissionToAcknowledgement
        /// Whole dispatcher run, observed only after children and subscription cleanup have joined.
        /// A cancelled outcome is a joined milestone, not a measurement of cancellation-only overhead.
        case gatewayRunJoined
        /// One initial-response call through confirmed completion or joined failure and admission release.
        case interactionInitialResponse
        /// One original-response edit through confirmed completion or joined failure.
        case interactionOriginalEdit
        /// Confirmed initial acknowledgement through the first successful original-response edit.
        case interactionAcknowledgementToOriginalEdit
        /// One actual HTTP exchange's rate-authority admission wait; shared reads emit once per exchange.
        case httpAdmission
        /// Adapter entry through received headers, excluding subsequent request-body cleanup on success.
        /// Failed adapter entry is observed after its existing request/admission cleanup has joined.
        case httpHeaders
        /// Response-body collection through EOF/error and joined response-body cleanup.
        case httpBody
        /// One coalesced subscriber's wait; shared wire work has independent exchange samples.
        case httpCoalescedSubscriber
        /// One REST call through result/failure and its existing structured joins. A cancelled subscriber
        /// does not imply that a shared exchange still needed by other subscribers has been cancelled.
        case httpExecutionJoined
    }

    /// Finite observable results; uncertainty never implies acknowledgement or permits a replay.
    public enum Outcome: Sendable, Equatable {
        /// The measured boundary returned a confirmed result; HTTP headers alone do not imply API success.
        case succeeded
        /// A definite failure ended this boundary without inventing remote success.
        case failed
        /// Cancellation returned after the measured boundary's existing owned cleanup joined.
        case cancelled
        /// A potentially submitted mutation has no confirmed result, including cancellation after submission.
        case uncertain
    }

    /// Fixed measured ownership boundary, without arbitrary labels.
    public let phase: Phase
    /// Confirmed, failed, cancelled or uncertain result for this boundary only.
    public let outcome: Outcome
    /// Nonnegative elapsed monotonic duration. Clock regressions clamp to zero.
    public let elapsed: Duration

    /// Stores one finite timing observation without retaining any operation input.
    /// - Parameters:
    ///   - phase: Closed ownership boundary being observed.
    ///   - outcome: Result for this boundary; successful headers do not classify the final operation.
    ///   - elapsed: Measured duration, clamped to zero if the injected clock regresses.
    public init(phase: Phase, outcome: Outcome, elapsed: Duration) {
        self.phase = phase; self.outcome = outcome; self.elapsed = max(.zero, elapsed)
    }
}

/// Explicit opt-in synchronous timing observer shared by protocol owners.
///
/// Pass the same value to cooperating owners. Callbacks may run concurrently, must return promptly,
/// and cannot throw. This value starts no tasks and retains no samples or registry. A nil owner option
/// performs no timing-clock reads or observer work. The injected clock must be monotonic and share one
/// origin across owners; the default reads uptime. Observations confer no authorization or receipt trust.
public struct OperationTiming: Sendable {
    /// Synchronous nonthrowing consumer; implementations own any bounded aggregation they choose.
    private let sink: @Sendable (OperationTimingSample) -> Void
    /// Monotonic offset source, consulted only by explicitly enabled owners.
    private let now: @Sendable () -> Duration

    /// Stores an observer and clock without consulting either or starting work.
    /// - Parameters:
    ///   - sink: Prompt thread-safe synchronous consumer of content-free samples.
    ///   - now: Monotonic offset source, default system uptime; called only at enabled boundaries.
    public init(sink: @escaping @Sendable (OperationTimingSample) -> Void,
                now: @escaping @Sendable () -> Duration = {
                    .nanoseconds(Int64(clamping: DispatchTime.now().uptimeNanoseconds))
                }) {
        self.sink = sink; self.now = now
    }

    /// Reads the enabled observer's monotonic offset without creating any task.
    /// - Returns: Current offset in this observer's clock domain.
    package func instant() -> Duration { now() }

    /// Emits a measured interval synchronously after the caller's documented ownership boundary.
    /// - Parameters:
    ///   - phase: Closed stage being observed.
    ///   - since: Earlier offset from this exact observer's clock.
    ///   - outcome: Boundary result, default confirmed return.
    package func record(_ phase: OperationTimingSample.Phase, since: Duration,
                        outcome: OperationTimingSample.Outcome = .succeeded) {
        record(phase, elapsed: now() - since, outcome: outcome)
    }

    /// Emits an externally established duration, such as trusted socket receipt age, without reading time.
    /// - Parameters:
    ///   - phase: Closed measured boundary.
    ///   - elapsed: Duration established by the owning trusted clock.
    ///   - outcome: Boundary result, default confirmed return.
    package func record(_ phase: OperationTimingSample.Phase, elapsed: Duration,
                        outcome: OperationTimingSample.Outcome = .succeeded) {
        sink(OperationTimingSample(phase: phase, outcome: outcome, elapsed: elapsed))
    }

    /// Classifies only closed error types without retaining or formatting an arbitrary error.
    /// - Parameter error: Existing operation error; this method never changes its propagation.
    /// - Returns: Uncertainty for typed mutation ambiguity, cancellation for known cancellation, else failure.
    package static func outcome(for error: any Error) -> OperationTimingSample.Outcome {
        if case .unknownMutationOutcome = error as? DiscordError { return .uncertain }
        if error is CancellationError || (error as? DiscordError) == .cancelled { return .cancelled }
        return .failed
    }
}

/// Invocation-local numeric provenance installed only by enabled package-owned dispatcher admission.
/// No task, registry or interaction identifier is created; disabled dispatch bypasses this scope entirely.
package enum OperationTimingScope {
    /// Admission offset in the configured timing observer's clock, unavailable outside enabled callbacks.
    @TaskLocal package static var gatewayAdmission: Duration?
}
