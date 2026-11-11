// File: Tests/DiscordDAVETests/DAVEReplayWindowTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Crypto
import DiscordVoiceCrypto
import Foundation
import Testing
@testable import DiscordDAVE

/// Independent authenticated-wire and historical-set oracles for bounded receive bookkeeping.
@Suite struct DAVEReplayWindowTests {
    private let secret = Data(0..<16)

    /// Builds generation-zero authenticated fixtures using Swift Crypto's full-tag GCM,
    /// independently of the sender actor and truncated-tag implementation under test.
    /// - Parameter nonce: Absolute generation-zero nonce, including deliberately skipped positions.
    /// - Returns: The fixed public payload and its exact DAVE frame with the first eight tag bytes.
    /// - Throws: Crypto or wire encoding errors; no receiver state or entropy is consumed.
    private func fixture(_ nonce: UInt32) throws -> (payload: Data, wire: Data) {
        let payload = Data([0xF8, UInt8(truncatingIfNeeded: nonce), UInt8(truncatingIfNeeded: nonce >> 8)])
        let key = Data([0x58, 0xFC, 0x01, 0x31, 0x08, 0xDB, 0xF9, 0x96, 0xEF, 0x65, 0x1E, 0x3F, 0x01, 0x65, 0x8B, 0xFB])
        let sealed = try AES.GCM.seal(payload, using: SymmetricKey(data: key),
            nonce: AES.GCM.Nonce(data: DAVEFrameCipher.fullNonce(nonce)))
        return (payload, try DAVEFrameEnvelope.encode(interleaved: sealed.ciphertext,
            tag: Data(sealed.tag.prefix(8)), nonce: nonce, clearRanges: []))
    }

    /// Compares strict distance/duplicate policy against an unpruned set of all historical
    /// successes, across complete occupancy, multiple modulo wraps, holes and large jumps.
    /// - Parameter window: Arbitrary supported capacities, including non-powers of two and word edges.
    /// Every failed attempt must leave the mathematical newest position unchanged.
    @Test(arguments: [1, 3, 63, 64, 65, 1_024, 8_191, 8_192])
    func historicalAdmissionOracle(window: Int) async throws {
        let receiver = try DAVEFrameCipher(baseSecret: secret, configuration: .init(replayWindow: window))
        var history: Set<UInt32> = [], newest: UInt32?
        var sequence: [UInt32] = []
        for value in 1...UInt32(window * 3 + 130) {
            if value % 7 != 0 { sequence.append(value) }
            if value > 3, value % 7 == 3 { sequence.append(value - 3) }
            if value % 13 == 0 { sequence.append(value) }
            if value > UInt32(window), value % 67 == 0 { sequence.append(value - UInt32(window)) }
        }
        let jump = UInt32(window * 8 + 1_000)
        sequence += [jump, jump - UInt32(window - 1), jump - UInt32(window), jump, jump + 1]
        for nonce in sequence {
            let sample = try fixture(nonce)
            let eligible = newest.map { nonce > $0 || ($0 - nonce < UInt32(window) && !history.contains(nonce)) } ?? true
            if eligible {
                #expect(try await receiver.open(sample.wire, mediaType: .audio, now: 0) == sample.payload)
                history.insert(nonce); newest = max(newest ?? nonce, nonce)
            } else {
                await #expect(throws: DAVEError.replayedFrame) {
                    try await receiver.open(sample.wire, mediaType: .audio, now: 0)
                }
            }
        }
        await receiver.close(); await receiver.close()
        await #expect(throws: DAVEError.closed) {
            try await receiver.open(fixture(jump + 2).wire, mediaType: .audio, now: 0)
        }
    }

    /// A forged far-future nonce sharing a live slot cannot evict authenticated history
    /// or block an unobserved exact-edge frame; a valid large jump must then retire it.
    @Test(arguments: [1, 3, 64, 65, 1_024, 8_192])
    func failedFutureAuthenticationIsReadOnly(window: Int) async throws {
        let receiver = try DAVEFrameCipher(baseSecret: secret, configuration: .init(replayWindow: window))
        let newest = UInt32(window + 10), first = try fixture(newest)
        #expect(try await receiver.open(first.wire, mediaType: .audio, now: 0) == first.payload)
        let future = try fixture(newest + UInt32(window * 3))
        var corrupt = future.wire; corrupt[0] ^= 1
        await #expect(throws: DAVEError.authenticationFailed) {
            try await receiver.open(corrupt, mediaType: .audio, now: 0)
        }
        await #expect(throws: DAVEError.replayedFrame) {
            try await receiver.open(first.wire, mediaType: .audio, now: 0)
        }
        if window > 1 {
            let edge = try fixture(newest - UInt32(window - 1))
            #expect(try await receiver.open(edge.wire, mediaType: .audio, now: 0) == edge.payload)
        }
        #expect(try await receiver.open(future.wire, mediaType: .audio, now: 0) == future.payload)
        await #expect(throws: DAVEError.replayedFrame) {
            try await receiver.open(first.wire, mediaType: .audio, now: 0)
        }
        await receiver.close()
    }
}
