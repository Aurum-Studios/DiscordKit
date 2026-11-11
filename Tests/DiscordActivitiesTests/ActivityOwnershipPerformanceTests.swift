// File: Tests/DiscordActivitiesTests/ActivityOwnershipPerformanceTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCore
import Foundation
import Testing
@testable import DiscordActivities

/// Exercises exact subscription accounting as independent groups and shared owners churn.
/// Synthetic acknowledgement barriers establish ownership without browser or wall-clock assumptions.
@Suite("Activity subscription ownership accounting", .timeLimit(.minutes(1)))
struct ActivityOwnershipPerformanceTests {
    /// Mixed local READY, independent upstream groups and duplicate owners consume the same finite token cap.
    /// Repeated release and group removal reclaim exactly one slot per token across successive cohorts.
    @Test func mixedGroupChurnPreservesCapacity() async throws {
        let peer = ActivityPeer()
        let client = try ActivityClient(applicationID: .init(rawValue: 1), host: ActivityClientTests.host(),
                                        transport: peer, clock: ContinuousClock(),
                                        limits: ActivityClientLimits(maximumSubscriptions: 4))
        try await client.start(); _ = await peer.nextSent()
        let event = ActivityEventName(rawValue: "FUTURE_EVENT")
        for _ in 0..<4 {
            let first = Task { try await client.subscribe(event, arguments: ["channel_id": .string("1")]) }
            let firstFrame = await peer.nextSent(); try await peer.reply(firstFrame)
            let firstToken = try await first.value
            let second = Task { try await client.subscribe(event, arguments: ["channel_id": .string("2")]) }
            let secondFrame = await peer.nextSent(); try await peer.reply(secondFrame)
            let secondToken = try await second.value
            let duplicate = try await client.subscribe(event, arguments: ["channel_id": .string("1")])
            let ready = try await client.subscribe(.ready)
            #expect(await client.snapshot().subscriptions == 4)
            await #expect(throws: ActivityFailure.overloaded) { try await client.subscribe(.ready) }
            #expect(await client.snapshot().subscriptions == 4)

            try await client.unsubscribe(firstToken)
            try await client.unsubscribe(firstToken)
            #expect(await client.snapshot().subscriptions == 3)
            let replacement = try await client.subscribe(event, arguments: ["channel_id": .string("2")])
            #expect(await client.snapshot().subscriptions == 4)
            try await client.unsubscribe(secondToken)
            #expect(await client.snapshot().subscriptions == 3)
            let removeFirst = Task { try await client.unsubscribe(duplicate) }
            let removal = await peer.nextSent()
            #expect(await client.snapshot().subscriptions == 2)
            await #expect(throws: ActivityFailure.subscriptionTransition) {
                try await client.subscribe(event, arguments: ["channel_id": .string("1")])
            }
            #expect(await client.snapshot().subscriptions == 2)
            try await peer.reply(removal)
            try await removeFirst.value
            #expect(await client.snapshot().subscriptions == 2)
            try await client.unsubscribe(ready)
            let removeSecond = Task { try await client.unsubscribe(replacement) }
            let secondRemoval = await peer.nextSent(); try await peer.reply(secondRemoval)
            try await removeSecond.value
            #expect(await client.snapshot().subscriptions == 0)
        }
        _ = try await client.subscribe(.ready)
        await client.close()
        #expect(await client.snapshot().subscriptions == 0)
        #expect(await peer.closes == 1)
    }

    /// A rejected new group releases its reserved token and terminal cleanup releases unrelated active groups.
    @Test func failedAdmissionReleasesEveryOwnedToken() async throws {
        let peer = ActivityPeer()
        let client = try ActivityClient(applicationID: .init(rawValue: 1), host: ActivityClientTests.host(),
                                        transport: peer, clock: ContinuousClock())
        try await client.start(); _ = await peer.nextSent()
        _ = try await client.subscribe(.ready)
        _ = try await client.subscribe(.ready)
        let subscription = Task { try await client.subscribe(.init(rawValue: "FUTURE_EVENT")) }
        let admission = await peer.nextSent()
        #expect(await client.snapshot().subscriptions == 3)
        try await peer.reply(admission, value: .object(["code": .number(try JSONNumber(rawValue: "4000"))]), event: "ERROR")
        await #expect(throws: ActivityCommandFailure(code: 4000)) { try await subscription.value }
        await client.close()
        let snapshot = await client.snapshot()
        #expect(snapshot.subscriptions == 0 && snapshot.pending == 0 && snapshot.pendingBytes == 0)
        #expect(await peer.closes == 1)
    }
}
