// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/EventHubTimingAccounting.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging
import Foundation

/// Setup backlog and measured publications have separate admitted-copy populations.
enum EventHubTimingPopulation: Equatable, Sendable {
    case setup
    case measured
}

/// A copy ends only at an observed owner boundary.
enum EventHubTimingDisposition: Sendable {
    case consumed
    case discarded
    case cancelledRetained
    case cancelledHandoff
}

/// Exact terminal classifications for one admitted-copy population.
struct EventHubTimingPopulationCounts: Codable, Equatable, Sendable {
    var consumed = 0
    var discarded = 0
    var cancelledRetained = 0
    var cancelledHandoff = 0

    /// Counts each terminal copy once, independently of residence metrics.
    var total: Int { consumed + discarded + cancelledRetained + cancelledHandoff }

    /// Records the disposition established by a joined owner.
    mutating func record(_ disposition: EventHubTimingDisposition) {
        switch disposition {
        case .consumed: consumed += 1
        case .discarded: discarded += 1
        case .cancelledRetained: cancelledRetained += 1
        case .cancelledHandoff: cancelledHandoff += 1
        }
    }
}

/// Bounded copy evidence kept separately from latency histograms and consumer aggregates.
final class EventHubTimingAccounting: @unchecked Sendable {
    private enum Pull {
        case idle
        case pending
        case removed(EventHubTimingPopulation)
    }

    private let lock = NSLock()
    private var publicationPopulation = EventHubTimingPopulation.measured
    private var retained: [DiscordIntervalID: EventHubTimingPopulation] = [:]
    private var pull = Pull.idle
    private var setup = EventHubTimingPopulationCounts()
    private var measured = EventHubTimingPopulationCounts()
    private var failure: EventHubTimingError?

    /// Selects the population before the sequential publisher enters the hub.
    func setPopulation(_ population: EventHubTimingPopulation) {
        lock.lock(); defer { lock.unlock() }
        publicationPopulation = population
    }

    /// Observes actual retained-copy endpoints without awaiting or reentering the hub.
    func observe(_ event: DiscordIntervalEvent) {
        guard event.operation == .gatewayPublication, event.stage == .hubResidence else { return }
        lock.lock(); defer { lock.unlock() }
        guard failure == nil else { return }
        switch event.kind {
        case .began:
            guard retained[event.context.operationID] == nil, retained.count < 262_144 else {
                fail("Duplicate residence begin or accounting capacity exceeded")
                return
            }
            retained[event.context.operationID] = publicationPopulation
        case .ended:
            guard let population = retained.removeValue(forKey: event.context.operationID) else {
                fail("Residence ended without one retained copy")
                return
            }
            switch event.outcome {
            case .failed: recordLocked(.discarded, population: population)
            case .cancelled: recordLocked(.cancelledRetained, population: population)
            case .succeeded:
                guard case .pending = pull else {
                    fail("Residence removal has no unique active pull")
                    return
                }
                pull = .removed(population)
            case .uncertain, nil:
                fail("Residence has no definite terminal disposition")
            }
        }
    }

    /// Assigns the next successful queue removal to the one sequential pull.
    func beginPull() {
        lock.lock(); defer { lock.unlock() }
        guard case .idle = pull else {
            fail("Overlapping accounting pulls")
            return
        }
        pull = .pending
    }

    /// Finishes an iterator call, retaining cancellation after a proven queue removal.
    @discardableResult
    func finishPull(accepted: Bool, cancelled: Bool) throws -> EventHubTimingPopulation? {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        guard !(accepted && cancelled) else {
            fail("One pull cannot be accepted and cancelled")
            throw failure!
        }
        let population: EventHubTimingPopulation?
        switch pull {
        case .idle:
            fail("Pull finished without an active owner")
            throw failure!
        case .pending:
            guard !accepted else {
                fail("Accepted pull has no observed queue removal")
                throw failure!
            }
            population = nil
        case .removed(let removed):
            guard accepted || cancelled else {
                fail("Removed copy has no consumer or cancellation disposition")
                throw failure!
            }
            recordLocked(accepted ? .consumed : .cancelledHandoff, population: removed)
            population = removed
        }
        pull = .idle
        return population
    }

    /// Records direct handoff evidence supplied by the joined waiting consumer owner.
    func record(_ disposition: EventHubTimingDisposition, population: EventHubTimingPopulation) {
        lock.lock(); defer { lock.unlock() }
        recordLocked(disposition, population: population)
    }

    /// Exports classifications only after every retained copy and pull owner has ended.
    func snapshot() throws -> (setup: EventHubTimingPopulationCounts, measured: EventHubTimingPopulationCounts) {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        guard retained.isEmpty else {
            throw EventHubTimingError.integrityFailure("Residence accounting still owns retained copies")
        }
        guard case .idle = pull else {
            throw EventHubTimingError.integrityFailure("Residence accounting still owns a pull")
        }
        return (setup, measured)
    }

    /// Mutates counters while the caller owns the ledger lock.
    private func recordLocked(_ disposition: EventHubTimingDisposition, population: EventHubTimingPopulation) {
        switch population {
        case .setup: setup.record(disposition)
        case .measured: measured.record(disposition)
        }
    }

    /// Preserves the first contradiction for the joined snapshot.
    private func fail(_ message: String) {
        failure = failure ?? .integrityFailure(message)
    }
}
