// File: Examples/LoggingApp/Sources/LoggingApp/LoggingApp.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation
import DiscordLogging
import DiscordLogHandlers
import DiscordTransport
import DiscordCache
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Standalone offline process demonstrating application-owned SwiftLog bootstrap.
@main struct LoggingApp {
    /// Bootstraps once, exercises semantic/subsystem events and closes the shared file.
    /// - Throws: File setup/close errors or an invalid smoke-test observation.
    ///   No Discord credentials, network connections or devices are used.
    static func main() async throws {
        let options = try ExampleOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        let directory = options.outputDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // A retained capture uses a new directory so an earlier run cannot be overwritten.
        try createOutputDirectory(directory)
        defer { if options.outputDirectory == nil { try? FileManager.default.removeItem(at: directory) } }
        let destination = directory.appendingPathComponent("discordkit.ndjson")
        let sink = try DiscordFileLogSink(url: destination)
        defer { try? sink.close() }
        LoggingSystem.bootstrap({ label, provider in
            var console = StreamLogHandler.standardError(label: label)
            console.logLevel = .info
            console.metadataProvider = provider
            return MultiplexLogHandler([
                DiscordLevelFilterLogHandler(console, minimumLevel: .info),
                DiscordFileLogHandler(label: label, sink: sink, logLevel: .trace, metadataProvider: provider),
            ])
        }, metadataProvider: .init { ["example.context": "offline"] })

        let policy = DiscordLogConfiguration(defaultLevel: .info, overrides: [
            "example.logging": .trace, "transport": .trace, "cache": .trace,
        ])
        let artifacts = try await DiscordLog.$configuration.withValue(policy) {
            try await DiscordLog.$context.withValue(["example.run": "offline"]) {
                try await DiscordLog.withOperation("example.logging", event: "example.logging") {
                    let app = DiscordLog.makeLogger("example.logging")
                    app.info("Offline logging example started")
                    app.notice("Application semantic event", metadata: ["action": "logging-demo"])
                    do {
                        let clock = ContinuousClock()
                        try TransportContext(clock: clock, deadline: clock.now).check()
                    } catch TransportFailure.deadlineExceeded {
                        app.debug("Expected synthetic deadline observed")
                    }
                    return try await timingDemo(logger: app, instruments: options.instruments)
                }
            }
        }
        try sink.close()
        let fileState = sink.snapshot()
        guard fileState.isClosed, fileState.droppedRecords == 0, fileState.failures == 0 else {
            throw ExampleFailure.missingOutput
        }
        try artifacts.aggregate.write(to: directory.appendingPathComponent("aggregate.json"), options: .withoutOverwriting)
        try artifacts.intervals.write(to: directory.appendingPathComponent("intervals.ndjson"), options: .withoutOverwriting)
        try artifacts.timeline.write(to: directory.appendingPathComponent("timeline.json"), options: .withoutOverwriting)
        let records = try readRecords(from: destination)
        guard records.contains(where: { $0["level"] as? String == "notice" }),
              records.contains(where: {
                  ($0["metadata"] as? [String: Any])?["dk.event"] as? String == "transport.deadline.expired"
              }), records.contains(where: {
                  let metadata = $0["metadata"] as? [String: Any]
                  return metadata?["dk.event"] as? String == "example.logging.completed"
                      && metadata?["dk.duration_ns"] is String
              }), records.allSatisfy({
                  let metadata = $0["metadata"] as? [String: Any]
                  return metadata?["example.context"] as? String == "offline"
                      && metadata?["example.run"] as? String == "offline"
                      && metadata?["dk.trace_id"] is String && metadata?["dk.span_id"] is String
              }) else {
            throw ExampleFailure.missingOutput
        }
    }

    /// Atomically admits one new private output directory before opening any writer.
    /// - Parameter directory: New directory whose parent already exists.
    /// - Throws: A sanitized error for existing paths, missing parents or filesystem refusal.
    ///   `mkdir` rejects an existing directory too, preserving prior capture contents.
    static func createOutputDirectory(_ directory: URL) throws {
        let created = directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return mkdir(path, mode_t(S_IRWXU)) == 0
        }
        guard created else { throw ExampleFailure.outputDirectoryUnavailable }
    }

    /// Exercises actual cache owner hooks; no reconstructed or synthetic lifecycle endpoints are emitted.
    /// - Parameters:
    ///   - logger: Application-configured diagnostic destination, including the caller's scope.
    ///   - instruments: Whether to also deliver live Apple signposts in this separate capture run.
    /// - Returns: Bounded artifacts serialized only after cache cleanup and capture closure.
    /// - Throws: Setup, owner, export or integrity failure. The cache and adapters close on failure too.
    static func timingDemo(logger: Logger, instruments: Bool = false) async throws -> TimingArtifacts {
        let aggregate = try DiscordTimingAggregate()
        let capture = try DiscordIntervalCapture(configuration: .init(
            maximumRecords: 64, maximumBytes: 32 * 1_024,
            maximumActiveIntervals: 8, sampleEvery: 1, seed: 7))
        let signposts: DiscordIntervalSignposts?
        #if canImport(os)
        signposts = instruments ? try DiscordIntervalSignposts(
            maximumActiveIntervals: 8, subsystem: "DiscordKit.LoggingApp", category: "Intervals") : nil
        #else
        guard !instruments else { throw ExampleFailure.unsupportedInstruments }
        signposts = nil
        #endif
        defer { capture.close(); signposts?.close() }
        let log = DiscordTimingLogAdapter(logger: logger)
        let intervals = DiscordIntervalTiming(clockDomain: 1, sink: { event in
            aggregate.record(event)
            capture.record(event)
            log.record(event) // Formatting/file output adds synchronous observer cost.
            signposts?.record(event)
        })
        let cache = try EntityCache(clock: ContinuousClock(), intervals: intervals)
        do {
            let scope = CacheScope(identity: "offline-example", intents: 0)
            let key = EntityKey(kind: .user, id: 1)
            try await cache.observeGateway(name: "USER_UPDATE", data: .object([
                "id": .string("1"), "username": .string("offline"),
            ]), scope: scope, shard: 0, generation: 0, sequence: nil)
            guard await cache.value(for: key, scope: scope)?.fields["username"] == .string("offline") else {
                throw ExampleFailure.missingOutput
            }
            await cache.invalidate(scope: scope)
            await cache.close() // Joins owned refresh work before closing observation outputs.
        } catch {
            await cache.close()
            throw error
        }
        let owner = await cache.statistics()
        guard owner.entries == 0, owner.bytes == 0, owner.refreshes == 0, owner.waiters == 0 else {
            throw ExampleFailure.missingOutput
        }
        capture.close()
        signposts?.close()
        let summary = aggregate.snapshot(), retained = capture.snapshot()
        guard summary.acceptedCount == 5, summary.invalidCount == 0, summary.droppedCount == 0,
              retained.isClosed, retained.retainedRecords == 10, retained.activeIntervals == 0,
              retained.droppedRecords == 0, retained.sampledOutRecords == 0,
              retained.incompleteIntervals == 0, retained.unmatchedEndpoints == 0 else {
            throw ExampleFailure.missingOutput
        }
        if let profiler = signposts?.snapshot() {
            guard profiler.isClosed, profiler.begunIntervals == 5, profiler.endedIntervals == 5,
                  profiler.activeIntervals == 0, profiler.droppedRecords == 0,
                  profiler.incompleteIntervals == 0 else { throw ExampleFailure.missingOutput }
        }
        return try TimingArtifacts(aggregate: JSONEncoder().encode(summary), intervals: capture.ndjson(),
                                   timeline: capture.chromeTrace())
    }

    /// Reads the example's bounded NDJSON output after explicit sink closure.
    /// - Parameter url: Temporary destination owned by this example.
    /// - Returns: JSON objects in file order, with no retained file handle.
    /// - Throws: Read/JSON failures or a nonobject line.
    static func readRecords(from url: URL) throws -> [[String: Any]] {
        try Data(contentsOf: url).split(separator: 10).map { line in
            guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                throw ExampleFailure.missingOutput
            }
            return object
        }
    }
}

/// Explicit smoke-test failure without paths, log payloads or underlying error text.
enum ExampleFailure: Error, Equatable {
    case missingOutput, invalidArguments, unsupportedInstruments, outputDirectoryUnavailable
}

/// End-of-run output data; no live writer, producer or active interval is retained.
struct TimingArtifacts {
    let aggregate: Data
    let intervals: Data
    let timeline: Data
}

/// Explicit executable output/profiler choices; ordinary smoke runs clean their temporary artifacts.
struct ExampleOptions {
    let outputDirectory: URL?
    let instruments: Bool

    /// Parses a new output directory and optional separate live-profiler mode.
    /// - Parameter arguments: Executable arguments, excluding its name.
    /// - Throws: `invalidArguments` for unknown, repeated or incomplete options.
    init(arguments: [String]) throws {
        var directory: URL?, profiler = false, index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--output-directory" where directory == nil && index + 1 < arguments.count:
                index += 1
                guard !arguments[index].isEmpty, !arguments[index].hasPrefix("--") else {
                    throw ExampleFailure.invalidArguments
                }
                directory = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--instruments" where !profiler: profiler = true
            default: throw ExampleFailure.invalidArguments
            }
            index += 1
        }
        outputDirectory = directory
        instruments = profiler
    }
}
