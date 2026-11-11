// File: Sources/DiscordGateway/GatewayReconnectBudgetPolicy.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

/// Selects when a shard may replenish its finite reconnect allowance without replacing its owner.
///
/// The default preserves a total-run allowance. Long-running services can opt into bounded
/// unhealthy episodes separated by observed healthy sessions. Neither policy retries terminal
/// protocol, ownership or event-continuity failures, and neither grants Identify admission.
public enum GatewayReconnectBudgetPolicy: Sendable, Equatable {
    /// Counts every replacement against one allowance for the entire single-use shard run.
    case totalRun

    /// Replenishes retries/backoff on the next recoverable failure after a healthy socket session.
    ///
    /// A valid READY/RESUMED must precede both the minimum uninterrupted monotonic duration
    /// and the required scheduled-heartbeat ACK observations in the same socket generation.
    /// Only an unambiguous outstanding scheduled beat confirmed by the adapter can qualify;
    /// requested, pre-ready, unsolicited, overlapping and pre-confirmation ACKs cannot.
    /// Discord ACKs have no nonce, so these observations do not prove protocol-level pairing.
    /// Failure freezes elapsed health before child/socket cleanup. No timer or history is added.
    /// Zero reconnect attempts still deny every replacement, including after a healthy session.
    /// - Parameters:
    ///   - minimumDuration: Strictly positive minimum session uptime after READY/RESUMED.
    ///   - minimumScheduledHeartbeatACKs: Strictly positive observation threshold; the counter saturates here.
    case afterHealthySession(minimumDuration: Duration, minimumScheduledHeartbeatACKs: Int)
}

/// Bounded socket-local health observations, mutated only by the owning shard actor.
///
/// This value owns no task, timer, transport, payload or identity. At most two unacknowledged
/// heartbeat observations are counted; further overlap disables new health credit until the
/// next socket generation. Existing qualified observations remain facts about this session.
struct GatewayRecoveryHealth<Instant: InstantProtocol> where Instant.Duration == Duration {
    /// Whether the sole candidate scheduled beat is absent, writing or adapter-confirmed.
    private enum Candidate: Equatable {
        /// No unambiguous scheduled beat can qualify the next ACK.
        case absent
        /// A post-readiness scheduled write has begun but is not yet confirmed.
        case writing
        /// The sole scheduled write completed and a later ACK may qualify it once.
        case confirmed
    }

    /// Required monotonic ready-session duration, validated by the public configuration.
    private let minimumDuration: Duration
    /// Required ACK count, also the saturating bound for retained qualifying observations.
    private let minimumACKs: Int
    /// First valid READY/RESUMED in this generation; pre-ready beats never receive credit.
    private var readyAt: Instant?
    /// First terminal child boundary, excluding later cancellation/join/disconnected time.
    private var endedAt: Instant?
    /// Saturated qualifying count, independent of ordinary heartbeat liveness handling.
    private var qualifyingACKs = 0
    /// Unacknowledged observations, saturated at two with conservative overflow denial.
    private var pendingHeartbeats = 0
    /// Concurrent writes, bounded by the receive/requested and scheduled child owners.
    private var writingHeartbeats = 0
    /// Candidate for at most one subsequent ACK; overlap always invalidates it.
    private var candidate = Candidate.absent
    /// Once bounded observation capacity is exceeded, no further sample can qualify in this generation.
    private var ambiguousOverflow = false

    /// Creates socket-local state only for an explicitly enabled, already validated policy.
    /// - Parameter policy: Public configuration; total-run creates no health state or clock demand.
    init?(policy: GatewayReconnectBudgetPolicy) {
        guard case .afterHealthySession(let duration, let acknowledgements) = policy else { return nil }
        minimumDuration = duration; minimumACKs = acknowledgements
    }

    /// Starts health uptime at the first valid ready transition without relabeling outstanding pre-ready writes.
    /// - Parameter instant: Owning shard's injected monotonic clock at READY/RESUMED acceptance.
    mutating func ready(at instant: Instant) {
        if readyAt == nil, endedAt == nil { readyAt = instant }
    }

    /// Begins one heartbeat observation before its potentially suspending control write.
    /// - Parameter scheduled: True only for the existing periodic heartbeat child.
    mutating func beginHeartbeat(scheduled: Bool) {
        let eligible = scheduled && readyAt != nil && endedAt == nil && !ambiguousOverflow
            && pendingHeartbeats == 0 && writingHeartbeats == 0
        candidate = eligible ? .writing : .absent
        if pendingHeartbeats < 2 { pendingHeartbeats += 1 } else { ambiguousOverflow = true }
        if writingHeartbeats < 2 { writingHeartbeats += 1 } else { ambiguousOverflow = true }
    }

    /// Arms only the same still-unambiguous scheduled observation after confirmed write and ownership fencing.
    /// - Parameter scheduled: Whether this completion belongs to the periodic child, never a requested write.
    mutating func completeHeartbeat(scheduled: Bool) {
        if writingHeartbeats > 0 { writingHeartbeats -= 1 }
        if scheduled, candidate == .writing, pendingHeartbeats == 1, writingHeartbeats == 0,
           !ambiguousOverflow, endedAt == nil {
            candidate = .confirmed
        }
    }

    /// Consumes at most one outstanding observation; early, overlapping and unsolicited ACKs earn no credit.
    /// Ordinary scheduled heartbeat liveness remains separately owned by the shard's existing pending flag.
    mutating func acknowledgeHeartbeat() {
        if candidate == .confirmed, pendingHeartbeats == 1, writingHeartbeats == 0,
           !ambiguousOverflow, endedAt == nil, qualifyingACKs < minimumACKs {
            qualifyingACKs += 1
        }
        candidate = .absent
        if pendingHeartbeats > 0 { pendingHeartbeats -= 1 }
    }

    /// Freezes health at the earliest observed child ending, before any joined cleanup can extend uptime.
    /// - Parameter instant: Injected monotonic time at the original error/cancellation boundary.
    mutating func end(at instant: Instant) {
        if endedAt == nil { endedAt = instant }
    }

    /// Tests the finite certificate without granting any retry or authority by itself.
    /// - Parameter instant: Immediate catch-boundary fallback when no supervised child entered.
    /// - Returns: True only when both validated health thresholds were met before session termination.
    func permitsReset(at instant: Instant) -> Bool {
        guard let readyAt, qualifyingACKs >= minimumACKs else { return false }
        return readyAt.duration(to: endedAt ?? instant) >= minimumDuration
    }
}
