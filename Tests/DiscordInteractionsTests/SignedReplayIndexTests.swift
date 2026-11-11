// File: Tests/DiscordInteractionsTests/SignedReplayIndexTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordTestSupport
import DiscordTransport
import Foundation
import Synchronization
import Testing
@testable import DiscordInteractions

/// Exercises expiry-index ordering and bounded replay admission through real Ed25519 authentication.
/// Wall time is explicit and mutable independently of arrival order; no signature verification runs in parallel
/// within the actor and no test requires live Discord, real credentials, sockets or elapsed-time assumptions.
@Suite(.timeLimit(.minutes(1))) struct SignedReplayIndexTests {
    /// Out-of-order signed timestamps retain inclusive expiry and prune only the earliest expired signatures.
    /// Both upward and downward heap restoration paths are exercised before capacity can be recovered.
    /// - Throws: Unexpected signing or authentication errors fail the test.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func unorderedTimestampsAndInclusiveExpiry() async throws {
        let fixtures = SignedReplayFixtures()
        let wall = Mutex<Int64>(1_000)
        let verifier = try SignedIngressTests.verifier(cap: 5, now: { wall.withLock { $0 } })
        for timestamp: Int64 in [1_030, 700, 1_000, 900, 800] {
            #expect(!(try await fixtures.verify(verifier, timestamp: timestamp)).isReplay)
        }
        #expect(await verifier.replayEntryCount() == 5)
        await #expect(throws: SignedIngressFailure.replay) { try await fixtures.verify(verifier, timestamp: 700) }
        await #expect(throws: SignedIngressFailure.replayCapacity) { try await fixtures.verify(verifier, timestamp: 1_000, identity: "new") }

        wall.withLock { $0 = 1_001 }
        #expect(!(try await fixtures.verify(verifier, timestamp: 1_001)).isReplay)
        #expect(await verifier.replayEntryCount() == 5)
        await #expect(throws: SignedIngressFailure.replay) { try await fixtures.verify(verifier, timestamp: 1_000) }
        wall.withLock { $0 = 1_101 }
        _ = try await fixtures.verify(verifier, timestamp: 1_101)
        #expect(await verifier.replayEntryCount() == 5)
        wall.withLock { $0 = 1_301 }
        _ = try await fixtures.verify(verifier, timestamp: 1_301)
        #expect(await verifier.replayEntryCount() == 4)
        wall.withLock { $0 = 1_331 }
        _ = try await fixtures.verify(verifier, timestamp: 1_331)
        #expect(await verifier.replayEntryCount() == 3)
    }

    /// Repeated advisory retries reuse one retained entry and oldest eviction follows expiry rather than arrival.
    /// - Throws: Unexpected signing or authentication errors fail the test.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func advisoryRetriesRetainOneEntryAndEvictEarliestExpiry() async throws {
        let fixtures = SignedReplayFixtures()
        let verifier = try SignedIngressTests.verifier(.allowIdenticalRetries, cap: 3)
        for timestamp: Int64 in [1_030, 700, 1_000] { _ = try await fixtures.verify(verifier, timestamp: timestamp) }
        for _ in 0..<128 {
            #expect(try await fixtures.verify(verifier, timestamp: 1_030).isReplay)
            #expect(await verifier.replayEntryCount() == 3)
        }
        #expect(!(try await fixtures.verify(verifier, timestamp: 1_000, identity: "replacement")).isReplay)
        #expect(try await fixtures.verify(verifier, timestamp: 1_030).isReplay)
        #expect(try await fixtures.verify(verifier, timestamp: 1_000).isReplay)
        #expect(!(try await fixtures.verify(verifier, timestamp: 700)).isReplay)
        #expect(await verifier.replayEntryCount() == 3)
    }

    /// Backward wall movement neither drops live protection nor resurrects already expired signatures.
    /// Stale requests fail before replay maintenance, retaining the existing authenticated-only pruning contract.
    /// - Throws: Unexpected signing or authentication errors fail the test.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func wallClockRegressionAndStaleRequests() async throws {
        let fixtures = SignedReplayFixtures()
        let wall = Mutex<Int64>(1_000)
        let verifier = try SignedIngressTests.verifier(cap: 2, now: { wall.withLock { $0 } })
        _ = try await fixtures.verify(verifier, timestamp: 1_030)
        _ = try await fixtures.verify(verifier, timestamp: 1_000)
        wall.withLock { $0 = 900 }
        await #expect(throws: SignedIngressFailure.replayCapacity) { try await fixtures.verify(verifier, timestamp: 900) }
        #expect(await verifier.replayEntryCount() == 2)
        wall.withLock { $0 = 1_400 }
        await #expect(throws: SignedIngressFailure.staleTimestamp) { try await fixtures.verify(verifier, timestamp: 1_000) }
        #expect(await verifier.replayEntryCount() == 2)
        wall.withLock { $0 = 1_301 }
        _ = try await fixtures.verify(verifier, timestamp: 1_301)
        #expect(await verifier.replayEntryCount() == 2)
        wall.withLock { $0 = 1_000 }
        await #expect(throws: SignedIngressFailure.replay) { try await fixtures.verify(verifier, timestamp: 1_030) }
        await #expect(throws: SignedIngressFailure.replayCapacity) { try await fixtures.verify(verifier, timestamp: 1_000) }
        #expect(await verifier.replayEntryCount() == 2)
    }

    /// Invalid authentication cannot prune expired signatures, free capacity or poison indexed membership.
    /// - Throws: Unexpected signing or authentication errors fail the test.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func authenticationFailuresDoNotMaintainReplayIndex() async throws {
        let fixtures = SignedReplayFixtures()
        let wall = Mutex<Int64>(1_000)
        let verifier = try SignedIngressTests.verifier(cap: 1, now: { wall.withLock { $0 } })
        _ = try await fixtures.verify(verifier, timestamp: 700)
        wall.withLock { $0 = 1_001 }
        await #expect(throws: SignedIngressFailure.malformedHeaders) { try await verifier.verify(headers: [], body: Data()) }
        let body = Data("signed".utf8), headers = try SignedIngressTests.headers(body, timestamp: "1001")
        await #expect(throws: SignedIngressFailure.invalidSignature) {
            try await verifier.verify(headers: headers, body: body + Data([32]))
        }
        #expect(await verifier.replayEntryCount() == 1)
        #expect(!(try await fixtures.verify(verifier, timestamp: 1_001)).isReplay)
        #expect(await verifier.replayEntryCount() == 1)
    }

    /// Expiry arithmetic saturation remains a live maximum timestamp instead of wrapping into premature pruning.
    /// - Throws: Unexpected signing or authentication errors fail the test.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func saturatedExpiryRetainsProtection() async throws {
        let fixtures = SignedReplayFixtures()
        let wall = Mutex<Int64>(Int64.max - 1)
        let verifier = try SignedIngressTests.verifier(cap: 1, now: { wall.withLock { $0 } })
        _ = try await fixtures.verify(verifier, timestamp: Int64.max - 1)
        wall.withLock { $0 = Int64.max }
        await #expect(throws: SignedIngressFailure.replay) { try await fixtures.verify(verifier, timestamp: Int64.max - 1) }
        await #expect(throws: SignedIngressFailure.replayCapacity) { try await fixtures.verify(verifier, timestamp: Int64.max) }
        #expect(await verifier.replayEntryCount() == 1)
    }

    /// Concurrent exact duplicates produce one atomic admission and complete replay rejections for all peers.
    /// - Throws: Unexpected signing, admission or child-task errors fail the test after structured joining.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func concurrentDuplicatesRemainAtomic() async throws {
        let verifier = try SignedIngressTests.verifier(cap: 32)
        let body = Data("concurrent".utf8), headers = try SignedIngressTests.headers(body)
        let admitted = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    do {
                        let result = try await verifier.verifyWithAdmissionTiming(headers: headers, body: body)
                        #expect(!result.isReplay)
                        return true
                    } catch SignedIngressFailure.replay { return false }
                }
            }
            var count = 0
            for try await succeeded in group { if succeeded { count += 1 } }
            return count
        }
        #expect(admitted == 1)
        #expect(await verifier.replayEntryCount() == 1)
    }

    /// Full odd/even windows drain to empty and refill without stale index positions or retained retry metadata.
    /// - Parameter cap: Small boundaries and deeper complete/incomplete heap shapes.
    /// - Throws: Unexpected signing, authentication or capacity errors fail the test.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [1, 2, 3, 4, 15, 64, 127]) func completeDrainAndRefill(cap: Int) async throws {
        let fixtures = SignedReplayFixtures()
        let wall = Mutex<Int64>(1_000)
        let verifier = try SignedIngressTests.verifier(cap: cap, now: { wall.withLock { $0 } })
        for index in 0..<cap {
            let timestamp = Int64(1_000 - ((index * 37) % 301))
            _ = try await fixtures.verify(verifier, timestamp: timestamp, identity: String(index))
        }
        #expect(await verifier.replayEntryCount() == cap)
        wall.withLock { $0 = 1_301 }
        _ = try await fixtures.verify(verifier, timestamp: 1_301)
        #expect(await verifier.replayEntryCount() == 1)
        for index in 1..<cap { _ = try await fixtures.verify(verifier, timestamp: 1_301, identity: String(index)) }
        #expect(await verifier.replayEntryCount() == cap)
        await #expect(throws: SignedIngressFailure.replay) { try await fixtures.verify(verifier, timestamp: 1_301) }
        await #expect(throws: SignedIngressFailure.replayCapacity) { try await fixtures.verify(verifier, timestamp: 1_301, identity: "full") }
    }
}

/// Per-test original signed requests; CryptoKit signing may randomize signatures for identical messages.
/// Reusing headers makes retries exact signature duplicates on every supported crypto implementation.
private actor SignedReplayFixtures {
    private var signedHeaders: [Data: [HTTPHeader]] = [:]

    /// Authenticates a fixture, signing each distinct timestamp/body combination only once.
    /// - Parameters:
    ///   - verifier: Independently owned bounded authentication/replay authority.
    ///   - timestamp: Nonnegative signed Unix seconds selected by the calling fixture.
    ///   - identity: Optional suffix making simultaneous-timestamp bodies distinct; default empty.
    /// - Returns: Authenticated original bytes and replay metadata from the real verifier.
    /// - Throws: Signing or authentication/admission errors for the caller to assert.
    /// The finite fixture cache is owned by one test. Signature generation and cache insertion finish
    /// before the verifier suspension, so repeated calls retain the exact original signature bytes.
    func verify(_ verifier: SignedRequestVerifier, timestamp: Int64, identity: String = "") async throws -> VerifiedDiscordRequest {
        let body = Data("\(timestamp):\(identity)".utf8)
        let headers: [HTTPHeader]
        if let existing = signedHeaders[body] { headers = existing }
        else {
            headers = try SignedIngressTests.headers(body, timestamp: String(timestamp))
            signedHeaders[body] = headers
        }
        return try await verifier.verify(headers: headers, body: body)
    }
}
