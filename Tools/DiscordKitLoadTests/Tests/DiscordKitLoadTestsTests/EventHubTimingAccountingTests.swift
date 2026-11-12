// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/EventHubTimingAccountingTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging
import Foundation
import Testing
@testable import DiscordKitLoadTests

/// Copy partitions come from residence and consumer evidence, including contradictions.
@Suite("Event hub timing accounting", .timeLimit(.minutes(1)))
struct EventHubTimingAccountingTests {
    /// Later publications cannot change the population of an already retained copy.
    @Test func setupAndMeasuredRemainSeparate() throws {
        let accounting = EventHubTimingAccounting()
        let timing = observer(accounting)
        accounting.setPopulation(.setup)
        let setup = timing.begin(.gatewayPublication, stage: .hubResidence)
        accounting.setPopulation(.measured)
        let measured = timing.begin(.gatewayPublication, stage: .hubResidence)
        setup.end(.failed)
        measured.end(.cancelled)
        accounting.record(.consumed, population: .measured)
        let result = try accounting.snapshot()
        #expect(result.setup.discarded == 1 && result.setup.total == 1)
        #expect(result.measured.consumed == 1 && result.measured.cancelledRetained == 1)
        #expect(result.measured.total == 2)
    }

    /// A successful residence endpoint is still cancelled if the public iterator never returns it.
    @Test func cancellationAfterRemovalKeepsItsOriginalPopulation() throws {
        let accounting = EventHubTimingAccounting()
        let timing = observer(accounting)
        accounting.setPopulation(.setup)
        let interval = timing.begin(.gatewayPublication, stage: .hubResidence)
        accounting.setPopulation(.measured)
        accounting.beginPull()
        interval.end()
        #expect(try accounting.finishPull(accepted: false, cancelled: true) == .setup)
        let result = try accounting.snapshot()
        #expect(result.setup.cancelledHandoff == 1 && result.setup.total == 1)
        #expect(result.setup.consumed == 0 && result.setup.discarded == 0)
        #expect(result.measured.total == 0)
    }

    /// Pre-dequeue cancellation cannot manufacture a handoff or consume the retained copy.
    @Test func cancellationBeforeRemovalLeavesResidenceAuthoritative() throws {
        let accounting = EventHubTimingAccounting()
        let interval = observer(accounting).begin(.gatewayPublication, stage: .hubResidence)
        accounting.beginPull()
        #expect(try accounting.finishPull(accepted: false, cancelled: true) == nil)
        interval.end(.cancelled)
        let result = try accounting.snapshot()
        #expect(result.measured.cancelledRetained == 1 && result.measured.cancelledHandoff == 0)
        #expect(result.measured.total == 1)
    }

    /// Acceptance classifies a removal once; a later cancellation does not rewrite it.
    @Test func acceptedRemovalAndDirectHandoffHaveDistinctEvidence() throws {
        let accounting = EventHubTimingAccounting()
        let interval = observer(accounting).begin(.gatewayPublication, stage: .hubResidence)
        accounting.beginPull()
        interval.end()
        #expect(try accounting.finishPull(accepted: true, cancelled: false) == .measured)
        accounting.record(.cancelledHandoff, population: .measured)
        let result = try accounting.snapshot()
        #expect(result.measured.consumed == 1 && result.measured.cancelledHandoff == 1)
        #expect(result.measured.total == 2)
    }

    /// Duplicate retained endpoints cannot inflate a successful copy partition.
    @Test(arguments: [true, false]) func duplicateResidenceEndpointFails(begin: Bool) {
        let events = EventHubTimingAccountingEvents()
        let timing = DiscordIntervalTiming(clockDomain: 1, sink: { events.append($0) }, now: { .zero })
        let interval = timing.begin(.gatewayPublication, stage: .hubResidence)
        interval.end(.cancelled)
        let captured = events.snapshot()
        let accounting = EventHubTimingAccounting()
        accounting.observe(captured[0])
        if begin { accounting.observe(captured[0]) }
        else {
            accounting.observe(captured[1])
            accounting.observe(captured[1])
        }
        #expect(throws: EventHubTimingError.self) { try accounting.snapshot() }
    }

    /// Removed envelopes need one active pull and cannot be assigned twice to that owner.
    @Test(arguments: [false, true]) func unownedOrMultipleRemovalFails(activePull: Bool) {
        let accounting = EventHubTimingAccounting()
        let timing = observer(accounting)
        let first = timing.begin(.gatewayPublication, stage: .hubResidence)
        let second = timing.begin(.gatewayPublication, stage: .hubResidence)
        if activePull { accounting.beginPull() }
        first.end()
        second.end()
        #expect(throws: EventHubTimingError.self) { try accounting.snapshot() }
    }

    /// Contradictory consumer claims fail instead of creating arithmetic cancellation residuals.
    @Test(arguments: [false, true]) func acceptanceWithoutRemovalOrDuringCancellationFails(cancelled: Bool) {
        let accounting = EventHubTimingAccounting()
        accounting.beginPull()
        #expect(throws: EventHubTimingError.self) {
            try accounting.finishPull(accepted: true, cancelled: cancelled)
        }
        #expect(throws: EventHubTimingError.self) { try accounting.snapshot() }
    }

    /// A snapshot cannot claim joined accounting while a retained envelope or pull remains live.
    @Test(arguments: [false, true]) func outstandingOwnerFailsSnapshot(pull: Bool) {
        let accounting = EventHubTimingAccounting()
        let interval = observer(accounting).begin(.gatewayPublication, stage: .hubResidence)
        if pull {
            interval.end(.cancelled)
            accounting.beginPull()
        }
        #expect(throws: EventHubTimingError.self) { try accounting.snapshot() }
        if !pull { interval.end(.cancelled) }
    }

    /// Production scopes outside residence cannot create copy classifications.
    @Test func unrelatedIntervalsAreIgnored() throws {
        let accounting = EventHubTimingAccounting()
        observer(accounting).begin(.gatewayPublication, stage: .operation).end()
        let result = try accounting.snapshot()
        #expect(result.setup.total == 0 && result.measured.total == 0)
    }

    /// Uses a fixed clock because these tests verify ownership rather than latency.
    private func observer(_ accounting: EventHubTimingAccounting) -> DiscordIntervalTiming {
        DiscordIntervalTiming(clockDomain: 1, sink: { accounting.observe($0) }, now: { .zero })
    }
}

/// Captures only the two fixed endpoints needed to inject duplicate observer delivery.
private final class EventHubTimingAccountingEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiscordIntervalEvent] = []

    /// Retains one of this test's finite interval endpoints.
    func append(_ event: DiscordIntervalEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    /// Returns the complete fixed event pair after the interval ends.
    func snapshot() -> [DiscordIntervalEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}
