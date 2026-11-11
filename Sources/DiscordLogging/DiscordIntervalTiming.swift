// File: Sources/DiscordLogging/DiscordIntervalTiming.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Dispatch
import Foundation

/// Finite runtime owners; these identify work, never routes, users, payloads or credentials.
public enum DiscordIntervalOperation: Sendable, Equatable {
    /// One caller's REST execution, including its cache/decode and existing structured joins.
    case rest
    /// One actual wire attempt through its send/body/rate ownership, independently from API acceptance.
    case httpExchange
    /// One independently cancellable subscriber to a shared wire exchange.
    case httpSubscriber
    /// A dispatcher run and its bounded queue/admission/callback children.
    case gatewayDispatch
    /// Actor-owned interaction response, edit or supervised auto-defer handler work.
    case interactionResponse
    /// One Gateway connection owner across session recovery and joined shutdown.
    case gatewaySession
    /// One supported JSON frame from transport receipt through ingestion.
    case gatewayFrame
    /// One bounded hub publication and its independently retained subscriber copies.
    case gatewayPublication
    /// Authentication of one bounded signed request; no socket receipt is implied.
    case signedIngress
    /// HTTP application entry, first confirmed response and joined workflow.
    case interactionHTTP
    /// One exact command route, synchronous preparation and admitted handler.
    case commandRouting
}

/// Actual owner boundaries, independent of the legacy scalar phase enumeration.
/// Owner intervals exclude preceding actor residence unless a caller explicitly starts them there.
public enum DiscordIntervalStage: Sendable, Equatable {
    /// Complete selected owner operation, through the cleanup documented by that owner.
    case operation
    /// Explicit authority acquire, excluding the later permit release.
    case admission
    /// Adapter entry through headers or the existing failed-send cleanup.
    case headers
    /// Response collection through EOF/error and joined body close.
    case body
    /// Independent subscriber wait and its existing cancellation cleanup.
    case subscriber
    /// Bounded dispatcher pending retention; discarded work ends after joined cleanup.
    case localQueue
    /// Admitted callback return, or auto-defer handler plus its joined timer, as documented by the owner.
    case handler
    /// Initial response actor entry through confirmed completion or joined failure and release.
    case initialResponse
    /// Original edit actor entry through result/failure and continuation release.
    case originalEdit
    /// Actual transport receipt through frame processing; excludes earlier network wait.
    case socketReceipt
    /// Parsing or typed decoding of the owner's bounded supported input.
    case decode
    /// Shard-owned retention before its consumer removes a received frame.
    case ingestionQueue
    /// One subscription's retained event through removal or explicit discard.
    case hubResidence
    /// Confirmed heartbeat write through matching ACK, deadline or owner shutdown.
    case heartbeatACK
    /// Recovery trigger through the next locally usable READY or RESUMED session.
    case reconnect
    /// Joined owner teardown after the owner's supervised children finish.
    case shutdown
    /// Exact signed bytes through signature acceptance or rejection.
    case signatureVerification
    /// Replay or durable admission acquire through accepted/refused/error result.
    case replayAdmission
    /// Complete synchronous command input preparation through validation or failure.
    case preparation
    /// HTTP application entry through the first confirmed inline response sink return.
    case firstResponse
}

/// Result of this boundary only; successful headers do not promise successful API execution.
public enum DiscordIntervalOutcome: Sendable, Equatable {
    /// Confirmed completion at this boundary.
    case succeeded
    /// Definite failure without invented remote success.
    case failed
    /// Known cancellation after the boundary's existing cleanup.
    case cancelled
    /// Potentially submitted mutation without a confirmed result; never permission to replay.
    case uncertain
}

/// Whether endpoints can establish an honest duration; invalid measurements never become zero latency.
public enum DiscordIntervalValidity: Sendable, Equatable {
    /// Both offsets and their parent clock relationship are valid.
    case valid
    /// Negative or overflowing offsets cannot establish a signed integer nanosecond endpoint.
    case timestampOutOfRange
    /// Terminal raw offset precedes begin, even if integer truncation would hide the regression.
    case clockRegression
    /// A supplied parent belongs to another monotonic clock domain and has been detached.
    case mixedClockDomain
}

/// Ephemeral numeric identity scoped to one observer namespace, with no persistent service identity.
public struct DiscordIntervalID: Sendable, Equatable, Hashable {
    /// Random observer namespace, generated once when timing is explicitly configured.
    public let namespace: UInt64
    /// Nonwrapping sequence within that namespace.
    public let value: UInt64
}

/// Fixed-size propagation value, explicitly carried across shared-reader and callback boundaries.
/// It confers neither authorization nor trusted receipt provenance. Diagnostic UUIDs remain separate.
public struct DiscordIntervalContext: Sendable, Equatable {
    /// Application-selected identity for one monotonic origin and clock source.
    public let clockDomain: UInt64
    /// Identity of the active interval, distinct even for concurrent children.
    public let operationID: DiscordIntervalID
    /// Direct owning interval, absent for roots or rejected foreign-clock parents.
    public let parentID: DiscordIntervalID?
    /// Exchange attempt number, inherited by children unless explicitly replaced.
    public let attempt: UInt32?
}

/// Task-scoped interval context; structured children inherit it, detached work does not.
/// Owners must explicitly capture and restore context for shared work and unrelated later callbacks.
public enum DiscordIntervalScope {
    /// Current bounded numeric context; nil disables contextual propagation, not an explicitly supplied observer.
    @TaskLocal public static var context: DiscordIntervalContext?
}

/// Content-free lifecycle endpoint, delivered synchronously without retaining an event history.
public struct DiscordIntervalEvent: Sendable, Equatable {
    /// Begin and terminal endpoints originate at real lifecycle hooks, never reconstructed scalar samples.
    public enum Kind: Sendable, Equatable {
        /// Actual lifecycle start, captured before invoking the begin sink.
        case began
        /// Once-only terminal boundary, captured before invoking the ending sink.
        case ended
    }
    /// Whether this is an actual begin or terminal endpoint.
    public let kind: Kind
    /// Finite owner family.
    public let operation: DiscordIntervalOperation
    /// Finite measured boundary within that owner.
    public let stage: DiscordIntervalStage
    /// Fixed-size identity, parent and clock provenance.
    public let context: DiscordIntervalContext
    /// Nonnegative nanoseconds in `context.clockDomain`, or nil for an unrepresentable offset.
    public let timestampNanoseconds: Int64?
    /// Present only on a valid terminal event; subnanosecond endpoints truncate toward zero.
    public let elapsedNanoseconds: Int64?
    /// Present only on terminal events; the operation owner classifies its unchanged result.
    public let outcome: DiscordIntervalOutcome?
    /// Explicit endpoint validity; invalid observations never carry a qualifying duration.
    public let validity: DiscordIntervalValidity
}

/// Opt-in detailed lifecycle hooks, usable without SwiftLog bootstrap or diagnostic logging.
///
/// The application supplies a domain identifying the same monotonic origin to every cooperating owner.
/// Context from another domain is detached and explicitly invalid. A configured value owns one constant-
/// size identity allocator; handles own their individual terminal state. There is no global registry,
/// retained history, background task, formatting, file I/O, or automatic error/cancellation policy.
/// Nil owner options perform no clock reads, ID allocations, or callbacks.
///
/// Sinks must be prompt, nonthrowing, concurrent-safe and nonrecursive. They cannot control/reenter the
/// observed owner. Both clock and sink execute outside internal locks. Begin precedes end for one handle;
/// different handles may interleave. Start callbacks and child callbacks consume real time inside later
/// enclosing endpoints; terminal timestamps exclude their own callback. Do not subtract percentile rows.
public struct DiscordIntervalTiming: Sendable {
    private let source: IntervalIdentitySource
    private let clockDomain: UInt64
    private let sink: @Sendable (DiscordIntervalEvent) -> Void
    private let now: @Sendable () -> Duration

    /// Configures one observer without reading its instrumentation clock or invoking its sink.
    /// - Parameters:
    ///   - clockDomain: Run-local numeric identity for the exact monotonic clock and origin; not a metric label.
    ///   - sink: Application-owned bounded synchronous consumer; it may be called concurrently.
    ///   - now: Prompt concurrent-safe monotonic nonnegative offset from that origin; defaults to system uptime. Regression and
    ///     offsets outside signed 64-bit integer nanoseconds invalidate observations rather than clamp them.
    public init(clockDomain: UInt64, sink: @escaping @Sendable (DiscordIntervalEvent) -> Void,
                now: @escaping @Sendable () -> Duration = {
                    let uptime = DispatchTime.now().uptimeNanoseconds
                    return .seconds(Int64(uptime / 1_000_000_000))
                        + .nanoseconds(Int64(uptime % 1_000_000_000))
                }) {
        self.source = IntervalIdentitySource()
        self.clockDomain = clockDomain
        self.sink = sink
        self.now = now
    }

    /// Starts an actual interval and emits its begin endpoint after capturing the clock.
    /// - Parameters:
    ///   - operation: Finite owning operation family.
    ///   - stage: Real owner boundary; no preceding actor queue time is implied.
    ///   - attempt: Optional attempt identity; nil inherits a same-domain parent's attempt.
    ///   - parent: Explicit owning context, default current structured context. Foreign domains are
    ///     detached and flagged. Pass nil to deliberately start unrelated shared-reader work.
    /// - Returns: An explicitly ended handle. Dropping it does not invent a terminal event or cancel work.
    ///   Identity exhaustion after UInt64.max intervals is a programmer capacity violation, never wraparound.
    public func begin(_ operation: DiscordIntervalOperation, stage: DiscordIntervalStage,
                      attempt: UInt32? = nil,
                      parent: DiscordIntervalContext? = DiscordIntervalScope.context) -> DiscordInterval {
        let foreign = parent.map { $0.clockDomain != clockDomain } ?? false
        let acceptedParent = foreign ? nil : parent
        let context = DiscordIntervalContext(clockDomain: clockDomain, operationID: source.next(),
            parentID: acceptedParent?.operationID, attempt: attempt ?? acceptedParent?.attempt)
        let start = now()
        let stamp = Self.nanoseconds(start)
        let validity: DiscordIntervalValidity = stamp == nil ? .timestampOutOfRange
            : (foreign ? .mixedClockDomain : .valid)
        let interval = DiscordInterval(operation: operation, stage: stage, context: context,
            start: start, startNanoseconds: stamp, validity: validity, sink: sink, now: now)
        sink(DiscordIntervalEvent(kind: .began, operation: operation, stage: stage, context: context,
            timestampNanoseconds: stamp, elapsedNanoseconds: nil, outcome: nil, validity: validity))
        return interval
    }

    /// Converts nonnegative offsets using checked arithmetic, preserving invalidity rather than saturation.
    /// - Parameter offset: Raw clock offset; negative or overflowing values cannot establish endpoints.
    /// - Returns: Truncated integer nanoseconds, or nil for an invalid offset.
    fileprivate static func nanoseconds(_ offset: Duration) -> Int64? {
        guard offset >= .zero else { return nil }
        let parts = offset.components
        let seconds = parts.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !seconds.overflow else { return nil }
        let total = seconds.partialValue.addingReportingOverflow(parts.attoseconds / 1_000_000_000)
        return total.overflow ? nil : total.partialValue
    }
}

/// One actual interval with once-only terminal state and an explicitly propagated context.
/// Thread safety covers only the small terminal flag; clocks and external sinks run outside that lock.
public final class DiscordInterval: @unchecked Sendable {
    /// Immutable numeric scope suitable for explicitly carrying into structured work or callbacks.
    public let context: DiscordIntervalContext
    private let operation: DiscordIntervalOperation
    private let stage: DiscordIntervalStage
    private let start: Duration
    private let startNanoseconds: Int64?
    private let validity: DiscordIntervalValidity
    private let sink: @Sendable (DiscordIntervalEvent) -> Void
    private let now: @Sendable () -> Duration
    private let lock = NSLock()
    private var ended = false

    /// Stores immutable endpoint state; only `ended` is mutable and every access holds `lock`.
    /// - Parameters:
    ///   - operation: Finite family captured by the owner.
    ///   - stage: Boundary captured by the owner.
    ///   - context: Numeric identity and validated parent relationship.
    ///   - start: Raw begin offset, retained to detect subnanosecond regression.
    ///   - startNanoseconds: Checked serialized begin offset, nil if invalid.
    ///   - validity: Initial timestamp/parent validity, retained through termination.
    ///   - sink: Prompt concurrent-safe consumer invoked outside locks.
    ///   - now: Injected clock, read only by the first terminal caller.
    fileprivate init(operation: DiscordIntervalOperation, stage: DiscordIntervalStage,
                     context: DiscordIntervalContext, start: Duration, startNanoseconds: Int64?,
                     validity: DiscordIntervalValidity,
                     sink: @escaping @Sendable (DiscordIntervalEvent) -> Void,
                     now: @escaping @Sendable () -> Duration) {
        self.operation = operation; self.stage = stage; self.context = context
        self.start = start; self.startNanoseconds = startNanoseconds; self.validity = validity
        self.sink = sink; self.now = now
    }

    /// Captures and emits at most one terminal endpoint, without changing the operation's result.
    /// - Parameter outcome: Owner-established result after its documented cleanup. Default is success.
    ///   Concurrent/repeated callers after the first return without reading time or invoking the sink;
    ///   the first caller alone completes delivery. No automatic terminal is emitted on deallocation.
    public func end(_ outcome: DiscordIntervalOutcome = .succeeded) {
        let first = lock.withLock {
            if ended { return false }
            ended = true
            return true
        }
        guard first else { return }
        let stop = now()
        let stamp = DiscordIntervalTiming.nanoseconds(stop)
        let terminalValidity: DiscordIntervalValidity
        if stamp == nil || startNanoseconds == nil { terminalValidity = .timestampOutOfRange }
        else if stop < start { terminalValidity = .clockRegression }
        else { terminalValidity = validity }
        let elapsed: Int64?
        if terminalValidity == .valid, let stamp, let startNanoseconds {
            elapsed = stamp - startNanoseconds
        } else { elapsed = nil }
        sink(DiscordIntervalEvent(kind: .ended, operation: operation, stage: stage, context: context,
            timestampNanoseconds: stamp, elapsedNanoseconds: elapsed, outcome: outcome,
            validity: terminalValidity))
    }
}

/// Constant-space allocator: immutable random namespace plus a lock-protected nonwrapping sequence.
/// The unchecked conformance is limited to `sequence`, whose reads/writes all hold `lock`.
private final class IntervalIdentitySource: @unchecked Sendable {
    private let namespace = UInt64.random(in: UInt64.min...UInt64.max)
    private let lock = NSLock()
    private var sequence: UInt64 = 0

    /// Allocates an ephemeral identity without invoking external code under the allocator lock.
    /// - Returns: A unique sequence in this observer's random namespace; exhaustion traps before wraparound.
    func next() -> DiscordIntervalID {
        lock.withLock {
            precondition(sequence < UInt64.max, "Interval identity capacity exhausted")
            sequence += 1
            return DiscordIntervalID(namespace: namespace, value: sequence)
        }
    }
}
