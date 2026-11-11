// File: Examples/LoggingApp/Tests/LoggingAppTests/LoggingAppTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation
import Testing
import DiscordLogging
import DiscordLogHandlers
@testable import LoggingApp

/// Tests bounded example-output inspection without process-global logging changes.
struct LoggingAppTests {
    /// Admission rejects existing empty/artifact directories before a writer can mutate earlier output.
    @Test func exclusiveOutputDirectory() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("capture")
        try LoggingApp.createOutputDirectory(directory)
        #expect(throws: ExampleFailure.outputDirectoryUnavailable) { try LoggingApp.createOutputDirectory(directory) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let artifact = directory.appendingPathComponent("discordkit.ndjson")
        let original = Data("previous capture\n".utf8)
        try original.write(to: artifact)
        #expect(throws: ExampleFailure.outputDirectoryUnavailable) { try LoggingApp.createOutputDirectory(directory) }
        #expect(try Data(contentsOf: artifact) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["discordkit.ndjson"])
        #expect(throws: ExampleFailure.outputDirectoryUnavailable) { try LoggingApp.createOutputDirectory(artifact) }
        #expect(try Data(contentsOf: artifact) == original)
    }

    /// Real cache projection creates nested merge ancestry and closes with complete, loss-free evidence.
    @Test func actualOwnerTiming() async throws {
        let artifacts = try await LoggingApp.timingDemo(logger: Logger(label: "logging-example-test"))
        let aggregate = try JSONDecoder().decode(DiscordTimingAggregateSnapshot.self, from: artifacts.aggregate)
        #expect(aggregate.acceptedCount == 5)
        #expect(Set(aggregate.rows.compactMap(\.stage)) == ["cacheProjection", "cacheMerge", "cacheLookup", "cacheInvalidation"])
        let records = try artifacts.intervals.split(separator: 10).map {
            try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        let intervals = records.filter { $0["kind"] as? String == "interval" }
        #expect(intervals.count == 5 && intervals.allSatisfy { $0["complete"] as? Bool == true })
        let projection = try #require(intervals.first { $0["stage"] as? String == "cacheProjection" })
        let merge = try #require(intervals.first { $0["stage"] as? String == "cacheMerge" })
        #expect(merge["parentID"] as? UInt64 == projection["operationID"] as? UInt64)
        #expect(merge["parentNamespace"] as? UInt64 == projection["namespace"] as? UInt64)
        let timeline = try #require(JSONSerialization.jsonObject(with: artifacts.timeline) as? [String: Any])
        let events = try #require(timeline["traceEvents"] as? [[String: Any]])
        #expect(events.count == 5 && events.allSatisfy { $0["ph"] as? String == "X" })
    }

    /// Output retention and profiler adoption require explicit, unambiguous arguments.
    @Test func outputOptions() throws {
        #expect(try ExampleOptions(arguments: []).outputDirectory == nil)
        #expect(try ExampleOptions(arguments: ["--instruments"]).instruments)
        let options = try ExampleOptions(arguments: ["--output-directory", "capture", "--instruments"])
        #expect(options.outputDirectory?.lastPathComponent == "capture" && options.instruments)
        for arguments in [["--output-directory"], ["--unknown"], ["--instruments", "--instruments"],
                          ["--output-directory", "--instruments"], ["--output-directory", ""]] {
            #expect(throws: ExampleFailure.invalidArguments) { try ExampleOptions(arguments: arguments) }
        }
    }

    /// Reads exact NDJSON objects and rejects nonobjects and malformed JSON.
    @Test func outputInspection() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"level\":\"info\"}\n{\"level\":\"notice\"}\n".utf8).write(to: url)
        #expect(try LoggingApp.readRecords(from: url).compactMap { $0["level"] as? String } == ["info", "notice"])
        try Data("[]\n".utf8).write(to: url)
        #expect(throws: ExampleFailure.missingOutput) { try LoggingApp.readRecords(from: url) }
        try Data("{\n".utf8).write(to: url)
        #expect(throws: (any Error).self) { try LoggingApp.readRecords(from: url) }
        try Data().write(to: url)
        #expect(try LoggingApp.readRecords(from: url).isEmpty)
    }
}
