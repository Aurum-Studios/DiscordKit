// File: Sources/DiscordInteractions/SignedRequestVerifier.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Crypto
import DiscordLogging
import DiscordTransport
import Foundation

/// Authentication/admission failures contain no body, signature, key or token values.
public enum SignedIngressFailure: Error, Sendable, Equatable {
    case invalidConfiguration, malformedHeaders, invalidSignature, staleTimestamp
    case replay, replayCapacity, bodyTooLarge
}

/// Exact-byte retry behavior; semantic event deduplication belongs to the durable consumer.
public enum SignedReplayPolicy: Sendable {
    /// Authenticate every retry and expose duplicates without blocking their acknowledgement.
    case allowIdenticalRetries
    /// Refuse a previously authenticated signature until its signed timestamp is too old.
    case rejectIdentical
}

/// Bytes authenticated by Ed25519 before any JSON decoding. Formatting conceals submitted data.
public struct VerifiedDiscordRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let rawBody: Data
    public let timestamp: Int64
    public let isReplay: Bool

    /// Stores authenticated bytes; only this module can manufacture an authentication result.
    /// - Parameters:
    ///   - rawBody: Exact original request bytes, within the verifier's body bound.
    ///   - timestamp: Signed, validated nonnegative Unix timestamp in seconds.
    ///   - isReplay: Whether the bounded local replay window already contains this signature.
    init(rawBody: Data, timestamp: Int64, isReplay: Bool) {
        self.rawBody = rawBody; self.timestamp = timestamp; self.isReplay = isReplay
    }

    /// Returns a constant safe marker without revealing signed request data.
    public var description: String { "VerifiedDiscordRequest(redacted)" }
    /// Uses the safe marker in debug output.
    public var debugDescription: String { description }
    /// Prevents reflective expansion of the retained request bytes.
    public var customMirror: Mirror { Mirror(self, children: ["redacted": true]) }
}

/// Verifies Discord's timestamp + original-body signature with maintained Ed25519 primitives.
///
/// Timestamp/replay policy is local application policy, not an upstream retry guarantee.
/// Share one verifier per application key in a process. Fleet replay protection requires
/// an external authority; this bounded process-local window does not provide exactly-once delivery.
public actor SignedRequestVerifier {
    private let key: Curve25519.Signing.PublicKey
    private let maximumBodyBytes: Int
    private let maximumAge: Int64
    private let futureSkew: Int64
    private let maximumReplayEntries: Int
    private let replayPolicy: SignedReplayPolicy
    private let now: @Sendable () -> Int64
    private let intervals: DiscordIntervalTiming?
    /// One indexed expiry entry per retained signature; retries never append stale duplicate metadata.
    private var replays = SignedReplayWindow()

    /// Validates policy and the application's public key without starting work.
    /// - Parameters:
    ///   - publicKey: Exactly 64 hexadecimal characters from the Developer Portal, case insensitive.
    ///   - maximumBodyBytes: Positive complete-body byte bound, default 1 MiB.
    ///   - maximumAgeSeconds: Accepted timestamp age, inclusive, in `0...86400`, default 300.
    ///   - maximumFutureSkewSeconds: Accepted positive clock skew in `0...86400`, default 30.
    ///   - maximumReplayEntries: Positive retained signature bound, default 4096; full windows fail closed.
    ///   - replayPolicy: Reject exact retries by default; webhook-event endpoints should allow retries
    ///     and use their durable admission authority to decide duplicate processing.
    ///   - intervals: Optional signature and bounded replay-owner intervals; nil reads no instrumentation clock.
    ///   - now: Wall-clock Unix seconds; inject a deterministic clock in tests. Negative values fail closed.
    /// - Throws: `SignedIngressFailure.invalidConfiguration` for invalid policy or public-key encoding.
    public init(publicKey: String, maximumBodyBytes: Int = 1_048_576,
                maximumAgeSeconds: Int64 = 300, maximumFutureSkewSeconds: Int64 = 30,
                maximumReplayEntries: Int = 4_096, replayPolicy: SignedReplayPolicy = .rejectIdentical,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
                intervals: DiscordIntervalTiming? = nil) throws {
        guard maximumBodyBytes > 0, (0...86_400).contains(maximumAgeSeconds),
              (0...86_400).contains(maximumFutureSkewSeconds), maximumReplayEntries > 0,
              let bytes = Self.hex(publicKey, count: 32),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes)
        else { throw SignedIngressFailure.invalidConfiguration }
        self.key = key; self.maximumBodyBytes = maximumBodyBytes; self.intervals = intervals
        maximumAge = maximumAgeSeconds; futureSkew = maximumFutureSkewSeconds
        self.maximumReplayEntries = maximumReplayEntries; self.replayPolicy = replayPolicy; self.now = now
    }

    /// Authenticates original bytes before allowing model decoding or application dispatch.
    ///
    /// Signature headers must each occur exactly once. Signature verification precedes replay
    /// insertion; invalid requests cannot poison the window. Expired entries are pruned on
    /// each valid signature. Allow-retry mode evicts the oldest timestamp at capacity, so
    /// `isReplay` is advisory; reject mode refuses new work instead of evicting protection.
    /// An indexed minimum expiry avoids scanning retained live signatures; insertion/eviction is
    /// O(log n), and retries retain one entry. Signature verification and replay admission remain
    /// one synchronous actor operation; caller residence is measured only by `verifyWithAdmissionTiming`.
    /// - Parameters:
    ///   - headers: Original ordered fields, including X-Signature-Ed25519 and X-Signature-Timestamp.
    ///   - body: Complete, unmodified bytes; whitespace and JSON key order are significant.
    /// - Returns: Authenticated bytes and advisory replay metadata.
    /// - Throws: Sanitized malformed header, invalid signature, stale timestamp, oversized body,
    ///   replay or capacity errors. This synchronous actor operation never suspends midway.
    public func verify(headers: [HTTPHeader], body: Data) throws -> VerifiedDiscordRequest {
        try verifyAdmitted(headers: headers, body: body, admission: nil)
    }

    /// Authenticates the same exact bytes while also observing caller-to-verifier actor admission.
    /// - Parameters:
    ///   - headers: Original ordered signature fields, with the same validation as `verify`.
    ///   - body: Complete original bytes, with the same body bound as `verify`.
    /// - Returns: The authenticated request after atomic signature and replay checks.
    /// - Throws: The same sanitized authentication/replay errors as `verify`. Admission success
    ///   means actor entry only; authentication can still fail. Nil timing reads no observation
    ///   clock or identity. The existing synchronous isolated `verify` API remains available.
    public nonisolated func verifyWithAdmissionTiming(headers: [HTTPHeader], body: Data) async throws -> VerifiedDiscordRequest {
        let admission = intervals?.begin(.signedIngress, stage: .admission)
        return try await verifyAdmitted(headers: headers, body: body, admission: admission)
    }

    /// Ends caller-to-actor admission before authenticating bytes and mutating the replay window.
    /// - Parameters:
    ///   - headers: Original untrusted ordered fields, validated without suspension.
    ///   - body: Original bounded request body.
    ///   - admission: Optional caller-started token from this observer, ended exactly once at entry.
    /// - Returns: The same authenticated request as the unobserved actor operation.
    /// - Throws: Existing sanitized authentication or replay errors; admission itself is not acceptance.
    private func verifyAdmitted(headers: [HTTPHeader], body: Data,
                                admission: DiscordInterval?) throws -> VerifiedDiscordRequest {
        admission?.end()
        let signatureInterval = intervals?.begin(.signedIngress, stage: .signatureVerification)
        defer { signatureInterval?.end(.failed) }
        guard body.count <= maximumBodyBytes else { throw SignedIngressFailure.bodyTooLarge }
        let signatures = headers.filter { $0.name.lowercased() == "x-signature-ed25519" }
        let timestamps = headers.filter { $0.name.lowercased() == "x-signature-timestamp" }
        guard signatures.count == 1, timestamps.count == 1,
              let signature = Self.hex(signatures[0].value, count: 64),
              !timestamps[0].value.isEmpty, timestamps[0].value.utf8.count <= 19,
              timestamps[0].value.utf8.allSatisfy({ (48...57).contains($0) }),
              let timestamp = Int64(timestamps[0].value)
        else { throw SignedIngressFailure.malformedHeaders }
        let current = now()
        guard current >= 0,
              timestamp <= current ? current - timestamp <= maximumAge : timestamp - current <= futureSkew
        else { throw SignedIngressFailure.staleTimestamp }
        var message = Data(timestamps[0].value.utf8)
        message.append(body)
        guard key.isValidSignature(signature, for: message) else { throw SignedIngressFailure.invalidSignature }
        signatureInterval?.end()
        let replayInterval = intervals?.begin(.signedIngress, stage: .replayAdmission)
        defer { replayInterval?.end(.failed) }
        replays.removeExpired(before: current)
        let replay = replays.contains(signature)
        if replay, case .rejectIdentical = replayPolicy { throw SignedIngressFailure.replay }
        if !replay, replays.count >= maximumReplayEntries {
            if case .rejectIdentical = replayPolicy { throw SignedIngressFailure.replayCapacity }
            replays.removeOldest()
        }
        let (expiry, overflow) = timestamp.addingReportingOverflow(maximumAge)
        replays.insert(signature, expiry: overflow ? Int64.max : expiry)
        replayInterval?.end()
        return VerifiedDiscordRequest(rawBody: body, timestamp: timestamp, isReplay: replay)
    }

    /// Exposes only bounded replay entry count for diagnostics and tests.
    /// - Returns: The retained count, including entries pruned by the next verification.
    public func replayEntryCount() -> Int { replays.count }

    /// Decodes exact-length ASCII hexadecimal without accepting separators or whitespace.
    /// - Parameters:
    ///   - value: Original textual key or signature.
    ///   - count: Required decoded byte count.
    /// - Returns: Decoded bytes, or nil for any length/character mismatch. Length is checked before
    ///   allocating a byte array, so even oversized direct API input cannot create an unbounded copy.
    private static func hex(_ value: String, count: Int) -> Data? {
        guard value.utf8.count == count * 2 else { return nil }
        let bytes = Array(value.utf8)
        var output = Data(); output.reserveCapacity(count)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            output.append(high * 16 + low)
        }
        return output
    }

    /// Converts one ASCII hexadecimal character to its four-bit value.
    /// - Parameter byte: One UTF-8 byte, without normalization.
    /// - Returns: A value in 0...15, or nil for every other byte.
    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}

/// Actor-owned replay membership and minimum expiry with bounded one-entry-per-signature metadata.
/// Root inspection avoids scanning live entries on every authenticated request; insertion and oldest
/// removal cost O(log n), and expiring k entries costs O(k log n). No operation suspends or owns tasks.
private struct SignedReplayWindow {
    private struct Entry {
        let signature: Data
        var expiry: Int64
    }
    private var entries: [Entry] = []
    private var positions: [Data: Int] = [:]

    /// Returns the exact retained signature count, equal to both index and heap sizes.
    var count: Int { entries.count }

    /// Looks up membership without scanning expiry metadata or copying the retained window.
    /// - Parameter signature: Authenticated fixed-length signature bytes.
    /// - Returns: Whether this signature currently has one retained entry.
    func contains(_ signature: Data) -> Bool { positions[signature] != nil }

    /// Removes signatures only after their inclusive signed timestamp acceptance boundary has passed.
    /// - Parameter current: Validated nonnegative wall seconds; backward clock movement never resurrects entries.
    /// Each removed entry releases its signature and position immediately; a live root ends pruning.
    mutating func removeExpired(before current: Int64) {
        while let first = entries.first, first.expiry < current { removeOldest() }
    }

    /// Inserts or updates one authenticated signature while retaining exactly one heap/index entry.
    /// - Parameters:
    ///   - signature: Fixed-length authenticated key; a retry updates its existing position in place.
    ///   - expiry: Inclusive final accepted wall second, saturated by the verifier on arithmetic overflow.
    /// The owner enforces capacity before insertion. Updating supports either expiry direction without
    /// relying on request timestamp arrival order, even if the wall clock moves backwards.
    mutating func insert(_ signature: Data, expiry: Int64) {
        if let index = positions[signature] {
            let previous = entries[index].expiry
            entries[index].expiry = expiry
            if expiry < previous { moveUp(from: index) }
            else if expiry > previous { moveDown(from: index) }
            return
        }
        positions[signature] = entries.count
        entries.append(Entry(signature: signature, expiry: expiry))
        moveUp(from: entries.count - 1)
    }

    /// Removes the minimum expiry, or does nothing for an empty window.
    /// Equal-expiry entries have no promised eviction order, matching advisory retry policy semantics.
    /// Reject policy uses this operation only for expired entries and never evicts live protection.
    mutating func removeOldest() {
        guard let oldest = entries.first else { return }
        positions.removeValue(forKey: oldest.signature)
        let last = entries.removeLast()
        guard !entries.isEmpty else { return }
        entries[0] = last
        positions[last.signature] = 0
        moveDown(from: 0)
    }

    /// Restores heap order towards the root after insertion or a reduced expiry.
    /// - Parameter index: Existing entry whose ancestors already satisfy heap order.
    /// Every swap updates both position mappings before another iteration; metadata stays bounded.
    private mutating func moveUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard entries[child].expiry < entries[parent].expiry else { return }
            exchange(child, parent)
            child = parent
        }
    }

    /// Restores heap order towards the leaves after oldest removal or an increased expiry.
    /// - Parameter index: Existing entry whose child subtrees already satisfy heap order.
    /// Child arithmetic occurs only for a real parent and therefore cannot overflow an array index.
    private mutating func moveDown(from index: Int) {
        var parent = index
        while parent < entries.count / 2 {
            let left = parent * 2 + 1, right = left + 1
            let child = right < entries.count && entries[right].expiry < entries[left].expiry ? right : left
            guard entries[child].expiry < entries[parent].expiry else { return }
            exchange(parent, child)
            parent = child
        }
    }

    /// Exchanges two heap elements and synchronizes their exact membership positions.
    /// - Parameters:
    ///   - left: Existing first position.
    ///   - right: Existing distinct second position.
    /// The actor is the sole owner, so no caller can observe an intermediate index update.
    private mutating func exchange(_ left: Int, _ right: Int) {
        entries.swapAt(left, right)
        positions[entries[left].signature] = left
        positions[entries[right].signature] = right
    }
}
