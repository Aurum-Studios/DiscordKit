// File: Tools/DiscordDSLBenchmarks/Tests/DiscordDSLBenchmarksTests/EnvironmentTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Testing
@testable import DiscordDSLBenchmarks

/// Linux model selection remains testable without claiming a native Linux capture.
struct EnvironmentTests {
    /// DMI wins when present; ARM device-tree fallback strips its terminating NUL.
    @Test func linuxModelSources() {
        #expect(BenchmarkEnvironment.linuxHardwareModel { path in
            path.contains("dmi") ? "Board A\n" : "Board B\0"
        } == "linux-model-v1:Board A")
        #expect(BenchmarkEnvironment.linuxHardwareModel { path in
            path.contains("dmi") ? "To Be Filled By O.E.M." : "Board B\0\n"
        } == "linux-model-v1:Board B")
    }

    /// Missing, placeholder, empty and excessive values never fall back to an architecture key.
    @Test func unavailableModelRefusesInventedIdentity() {
        for value in [nil, "", "\n", "unknown", "Unavailable", String(repeating: "x", count: 16_385)] as [String?] {
            #expect(BenchmarkEnvironment.linuxHardwareModel { _ in value } == "unavailable")
        }
    }
}
