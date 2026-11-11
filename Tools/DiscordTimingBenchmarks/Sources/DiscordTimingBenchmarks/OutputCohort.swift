// File: Tools/DiscordTimingBenchmarks/Sources/DiscordTimingBenchmarks/OutputCohort.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging
import DiscordTransport
import Foundation

/// Task-local routing selects a development collector without changing numeric interval parents.
enum TimingWorkerScope {
    @TaskLocal static var outputs: TimingOutputs?
}

/// Bounded collector ownership with one shared observer identity source in either topology.
final class TimingOutputCohort: Sendable {
    let owners: [TimingOutputs]
    let timing: DiscordIntervalTiming?
    let scalar: OperationTiming?
    private let directories: [URL]
    private let scope: TimingCollectorScope

    /// Opens one shared collector or one collector per finite worker before measurement.
    /// - Parameters:
    ///   - configuration: Fixed mode, worker bound and explicit collector topology.
    ///   - directory: Existing private parent; per-worker exports use distinct child directories.
    /// - Throws: Output setup errors after closing every previously constructed collector.
    init(configuration: TimingConfiguration, directory: URL) throws {
        scope = configuration.collectorScope
        var owners: [TimingOutputs] = [], directories: [URL] = []
        do {
            for worker in 0..<(scope == .shared ? 1 : configuration.concurrency) {
                let destination = scope == .shared ? directory : directory.appendingPathComponent("worker-\(worker)")
                if scope == .perWorker {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                }
                owners.append(try TimingOutputs(configuration: configuration, directory: destination))
                directories.append(destination)
            }
        } catch {
            for owner in owners { _ = try? owner.close(exportDirectory: nil) }
            throw error
        }
        self.owners = owners
        self.directories = directories
        let first = owners[0]
        if scope == .shared || configuration.mode == .noop || first.timing == nil {
            timing = first.timing
        } else {
            // The source remains shared: this comparison removes collector sharing, not ID allocator sharing.
            timing = DiscordIntervalTiming(clockDomain: 1, sink: { event in
                guard let owner = TimingWorkerScope.outputs else {
                    preconditionFailure("Per-worker observation requires a worker context")
                }
                owner.recordInterval(event)
            })
        }
        if scope == .perWorker && configuration.mode == .scalarAggregate {
            scalar = OperationTiming(sink: { sample in
                guard let owner = TimingWorkerScope.outputs else {
                    preconditionFailure("Per-worker observation requires a worker context")
                }
                owner.aggregate?.record(sample.observation)
            })
        } else { scalar = first.scalar }
    }

    /// Selects the fixed collector for a joined cohort's bounded worker index.
    /// - Parameter worker: Valid worker index in the configured finite cohort.
    /// - Returns: The shared output owner or the exclusively assigned worker owner.
    func owner(for worker: Int) -> TimingOutputs { owners[scope == .shared ? 0 : worker] }

    /// Closes every collector, then sums exact counters without concatenating unbounded event histories.
    /// - Parameter exportDirectory: Non-nil enables exports to each owner's already prepared directory.
    /// - Returns: Conserved counter sums; collectorOwners and storage/capture bounds record resources.
    /// - Throws: The first close/export error after all remaining collectors have also been closed.
    func close(exportDirectory: URL?) throws -> [String: UInt64] {
        var counters: [String: UInt64] = ["collectorOwners": UInt64(owners.count)]
        var failure: (any Error)?
        for (index, owner) in owners.enumerated() {
            do {
                for (key, value) in try owner.close(exportDirectory: exportDirectory == nil ? nil : directories[index]) {
                    counters[key, default: 0] += value
                }
            } catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
        return counters
    }
}
