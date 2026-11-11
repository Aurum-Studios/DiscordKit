// File: Tests/DiscordRPCTests/RPCQueuedCorrelationTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCore
import DiscordLogging
import DiscordTransport
import DiscordTestSupport
import Foundation
import Testing
@testable import DiscordRPC

/// Signals exact queue admission synchronously from existing diagnostic events, without timing sleeps.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private struct RPCAdmissionHandler: LogHandler {
    let admissions: [TestBarrier]
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?

    /// Preserves native value-semantic metadata storage for the injected logger.
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        /// Reads the finite metadata entry without altering admission gates.
        get { metadata[key] }
        /// Stores the logger's metadata entry using ordinary value semantics.
        set { metadata[key] = newValue }
    }

    /// Opens the matching finite gate only after pending correlation and queued ownership are installed.
    /// - Parameter event: Existing structured admission event; no peer data or nonce is retained.
    func log(event: LogEvent) {
        guard event.metadata?["dk.event"] == "rpc.request.admitted",
              let value = event.metadata?["dk.pending"]?.description, let count = Int(value),
              admissions.indices.contains(count - 1) else { return }
        admissions[count - 1].open()
    }
}

/// Held sends expose the distinction between pending correlation and still-queued frames.
@Suite("RPC queued correlation ownership", .timeLimit(.minutes(1)))
struct RPCQueuedCorrelationTests {
    /// A reply during a blocked send releases only that sent caller; queued cancellation preserves order.
    /// An old reply cannot resolve the remaining request after the writer resumes, and no cancelled bytes send.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func sentReplyAndQueuedCancellationRemainIndependent() async throws {
        let admissions = (0..<3).map { _ in TestBarrier(maximumWaiters: 1) }
        try await DiscordLog.$loggerFactory.withValue({ label in
            Logger(label: label, factory: { _ in RPCAdmissionHandler(admissions: admissions) })
        }) {
            let peer = RPCPeer()
            let context = TransportContext(clock: ContinuousClock())
            let rpc = try RPCClient(applicationID: .init(rawValue: 1), clock: ContinuousClock(),
                                    connector: RPCPeerConnector([peer]), maximumPendingRequests: 3)
            try await rpc.connect(context: context)
            await peer.holdWrites()
            let first = Task { try await rpc.request(.getGuilds(), context: context) }
            let firstFrame = await peer.nextSent()
            let cancelled = Task { try await rpc.request(.getGuilds(), context: context) }
            try await admissions[1].wait()
            let remaining = Task { try await rpc.request(.getVoiceSettings(), context: context) }
            try await admissions[2].wait()
            #expect(await rpc.resourceCounts().pending == 3)
            try await peer.reply(to: firstFrame, data: .string("first"))
            #expect(try await first.value == .string("first"))
            #expect(await rpc.resourceCounts().pending == 2)
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(await rpc.resourceCounts().pending == 1)
            await peer.releaseWrites()
            let remainingFrame = await peer.nextSent()
            guard case .object(let fields) = try JSONValue.parse(remainingFrame.payload) else {
                Issue.record("Missing final request envelope"); await rpc.close(); return
            }
            #expect(fields["cmd"] == .string("GET_VOICE_SETTINGS"))
            try await peer.reply(to: firstFrame, data: .string("late"))
            try await peer.reply(to: remainingFrame, data: .string("remaining"))
            #expect(try await remaining.value == .string("remaining"))
            let counts = await rpc.resourceCounts()
            #expect(counts.pending == 0 && counts.pendingBytes == 0)
            await rpc.close()
            #expect(await peer.closeCount == 1)
        }
    }
}
