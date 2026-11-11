// File: Sources/DiscordHTTP/RESTTiming.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCore
import Foundation

/// One content-free observation at a REST pipeline boundary, independent of legacy exchange phases.
public struct RESTTimingSample: Sendable, Equatable {
    /// Closed synchronous or awaited owner boundaries; none imply socket, DNS or TLS attribution.
    public enum Phase: Sendable, Equatable {
        /// Descriptor request builder entry through encoded descriptor or thrown validation error.
        case construction
        /// Caller before local mutation ordering through admitted operation entry or failed acquire.
        case ordering
        /// Caller before an enabled cache lookup through fresh/missing/expired result, including actor wait.
        case cacheLookup
        /// Endpoint decoder entry through decoded value or thrown error, excluding response body I/O.
        case decode
        /// Accepted transport/server retry's explicit backoff sleep through wake or cancellation.
        /// A 429's authority-controlled delay belongs to admission and emits no fabricated retry sleep.
        case retryWait
    }
    /// Finite terminal classification belonging only to this observed boundary.
    public enum Outcome: Sendable, Equatable {
        /// Boundary returned its confirmed value, including an ordinary cache miss.
        case succeeded
        /// Boundary threw a definite failure.
        case failed
        /// Boundary threw known cancellation.
        case cancelled
        /// Existing execution semantics report potentially submitted mutation uncertainty.
        case uncertain
    }
    /// Fixed pipeline boundary without route, identity or payload labels.
    public let phase: Phase
    /// Result of this boundary, independent of the later logical result.
    public let outcome: Outcome
    /// Monotonic duration; regressing clocks invalidate the observation rather than fabricate zero latency.
    public let elapsed: Duration?

    /// Stores a finite observation and rejects a negative raw clock difference.
    /// - Parameters:
    ///   - phase: Existing pipeline boundary that actually ran.
    ///   - outcome: Its confirmed terminal classification.
    ///   - elapsed: Difference of offsets from the same observer clock.
    public init(phase: Phase, outcome: Outcome, elapsed: Duration) {
        self.phase = phase; self.outcome = outcome
        self.elapsed = elapsed >= .zero ? elapsed : nil
    }
}

/// Opt-in synchronous REST attribution, without logging bootstrap, tasks or retained history.
///
/// The sink and monotonic clock must be prompt, concurrent-safe and nonrecursive. Terminal timestamps
/// precede the sink. Nested observation callbacks consume time in enclosing requests. A nil RESTClient
/// option performs no instrumentation clock reads or allocation. These scalar observations are not
/// lifecycle intervals and cannot establish a waterfall by subtracting percentiles.
public struct RESTTiming: Sendable {
    private let sink: @Sendable (RESTTimingSample) -> Void
    private let now: @Sendable () -> Duration

    /// Stores an explicit observer without reading its clock or invoking its sink.
    /// - Parameters:
    ///   - sink: Application-owned bounded synchronous consumer of content-free observations.
    ///   - now: Concurrent-safe monotonic offset source, default system uptime.
    public init(sink: @escaping @Sendable (RESTTimingSample) -> Void,
                now: @escaping @Sendable () -> Duration = {
                    let value = DispatchTime.now().uptimeNanoseconds
                    return .seconds(Int64(value / 1_000_000_000)) + .nanoseconds(Int64(value % 1_000_000_000))
                }) {
        self.sink = sink; self.now = now
    }

    /// Captures one real owner entry; only explicitly enabled clients call this method.
    /// - Parameter phase: Fixed boundary whose terminal endpoint the caller owns.
    /// - Returns: Once-ended internal token, allowing ordering entry and refusal to share one owner.
    func begin(_ phase: RESTTimingSample.Phase) -> RESTTimingToken {
        RESTTimingToken(phase: phase, start: now(), sink: sink, now: now)
    }
}

/// A single bounded timing token; the lock protects only terminal ownership and invokes no user code.
final class RESTTimingToken: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    private let phase: RESTTimingSample.Phase
    private let start: Duration
    private let sink: @Sendable (RESTTimingSample) -> Void
    private let now: @Sendable () -> Duration

    /// Retains immutable observation inputs and one terminal flag without starting background work.
    /// - Parameters:
    ///   - phase: Fixed boundary selected by the owner.
    ///   - start: Already captured entry timestamp.
    ///   - sink: Concurrent-safe observer invoked after endpoint capture.
    ///   - now: Same monotonic source used for the entry timestamp.
    init(phase: RESTTimingSample.Phase, start: Duration,
         sink: @escaping @Sendable (RESTTimingSample) -> Void, now: @escaping @Sendable () -> Duration) {
        self.phase = phase; self.start = start; self.sink = sink; self.now = now
    }

    /// Captures and reports one terminal boundary, suppressing duplicate ordering cleanup calls.
    /// - Parameter error: Existing thrown failure, or nil for a confirmed boundary return.
    func end(error: (any Error)? = nil) {
        let shouldEnd = lock.withLock { if ended { return false }; ended = true; return true }
        guard shouldEnd else { return }
        let finish = now()
        let outcome: RESTTimingSample.Outcome
        if case .unknownMutationOutcome = error as? DiscordError { outcome = .uncertain }
        else if error is CancellationError || (error as? DiscordError) == .cancelled { outcome = .cancelled }
        else { outcome = error == nil ? .succeeded : .failed }
        sink(RESTTimingSample(phase: phase, outcome: outcome, elapsed: finish - start))
    }
}
