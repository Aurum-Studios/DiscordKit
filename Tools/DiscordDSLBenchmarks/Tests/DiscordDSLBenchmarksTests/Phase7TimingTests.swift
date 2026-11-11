// File: Tools/DiscordDSLBenchmarks/Tests/DiscordDSLBenchmarksTests/Phase7TimingTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordCore
import DiscordDSL
import Testing
@testable import DiscordDSLBenchmarks

// Keep these tests in the existing serialized suite because schema counters are process-global.
extension RuntimeBenchmarkTests {
    /// New independent populations reject ambiguous options and excessive state before any work.
    /// - Throws: Unexpected rejection of an explicitly valid finite selection.
    @Test func phase7ConfigurationBounds() throws {
        let parsed = try Phase7TimingConfiguration.parse(["--workload", "invocation", "--operations", "517",
            "--warmup-operations", "0", "--mode", "dsl", "--concurrency", "3"], environment: [:])
        #expect(parsed.workload == "invocation")
        #expect(parsed.operations == 517)
        #expect(parsed.dimensions.mode == "dsl")
        #expect(parsed.dimensions.concurrency == 3)
        for invalid in [["--operations", "0"], ["--operations", "100001"], ["--warmup-operations", "1001"],
            ["--workload", "all"], ["--operations", "2", "--operations", "3"], ["--definitions", "1"],
            ["--invocations", "1"], ["--warmup-invocations", "1"], ["--string-shape", "unknown"],
            ["--string-length", "1025"], ["--workload", "authoring", "--string-shape", "unicode"],
            ["--workload", "invocation", "--operations", "1"], ["--warmup-seconds", "0"]] {
            #expect(throws: BenchmarkError.self) { try Phase7TimingConfiguration.parse(invalid, environment: [:]) }
        }
        #expect(try Phase7TimingConfiguration.parse(["--warmup-operations", "0", "--warmup-seconds", "0"], environment: [:]).warmupOperations == 0)
    }

    /// Real public admission has the exact independent writer-derived byte boundary for every string shape.
    /// - Throws: Original fixture or public plan validation failures; expected one-byte failures are asserted.
    @Test func phase7FixtureByteBoundariesAndFingerprints() throws {
        var hashes: Set<String> = []
        for shape in ["ascii", "escaped", "unicode"] {
            var configuration = Phase7TimingConfiguration()
            configuration.stringShape = shape; configuration.dimensions.modules = 3
            let fixture = try DefinitionPlanFixture(configuration)
            let plan = try DefinitionPlan.compile(fixture.definition, supportedKinds: [DefinitionPlanFixture.kind], limits: fixture.limits)
            try fixture.validate(plan)
            #expect(plan.description.textBytes == fixture.expectedTextBytes)
            #expect(fixture.fingerprint.count == 64)
            #expect(try DefinitionPlanFixture(configuration).fingerprint == fixture.fingerprint)
            hashes.insert(fixture.fingerprint)
            let insufficient = DefinitionLimits(maxModules: fixture.limits.maxModules, maxDepth: fixture.limits.maxDepth,
                maxDeclarations: fixture.limits.maxDeclarations, maxTextBytes: fixture.expectedTextBytes - 1,
                maxStructuralNodes: fixture.limits.maxStructuralNodes)
            #expect(throws: DefinitionDiagnostic.self) {
                try DefinitionPlan.compile(fixture.definition, supportedKinds: [DefinitionPlanFixture.kind], limits: insufficient)
            }
        }
        #expect(hashes.count == 3)
    }

    /// Aggregate fixture hashing stays bounded even when the full catalog exceeds the JSON writer's 1 MiB default.
    /// - Throws: Unexpected bounded fixture construction or public plan validation errors.
    @Test func phase7LargeEscapedFixtureFingerprint() throws {
        var configuration = Phase7TimingConfiguration()
        configuration.dimensions.handlers = 1_000; configuration.dimensions.modules = 100
        configuration.stringShape = "escaped"
        let fixture = try DefinitionPlanFixture(configuration)
        #expect(fixture.serializedPayloadBytes > 1_048_576)
        let plan = try DefinitionPlan.compile(fixture.definition, supportedKinds: [DefinitionPlanFixture.kind], limits: fixture.limits)
        try fixture.validate(plan)
        #expect(fixture.fingerprint.count == 64)
    }

    /// Each selected mode records its whole population and excludes other workloads and all warmup work.
    /// - Throws: Original authoring/invocation failures or hard gate failures after cleanup.
    @Test func phase7IndependentPopulations() async throws {
        for workload in ["definition-plan", "authoring", "invocation"] {
            for mode in ["direct", "dsl"] {
                var configuration = Phase7TimingConfiguration()
                configuration.workload = workload; configuration.dimensions.mode = mode
                configuration.dimensions.modules = 2; configuration.dimensions.concurrency = 3
                configuration.operations = workload == "invocation" ? 517 : 2
                configuration.warmupOperations = 1
                let report = try await Phase7TimingCommand.measure(configuration)
                #expect(report.operations == configuration.operations)
                #expect(report.targetNanoseconds > 0)
                #expect(report.common.identity.catalogVersion == 9)
                #expect(report.common.metrics.count == 1)
                #expect(report.common.metrics[0].distribution.observedCount == UInt64(configuration.operations))
                #expect(report.common.metrics[0].distribution.droppedCount == 0)
                #expect(report.common.metrics[0].distribution.configuration.bucketWidthNanoseconds == 10_000)
                #expect(report.counters.handlers == (workload == "invocation" ? 517 : 0))
                #expect(report.counters.callbacks == report.counters.handlers)
                #expect(report.schemaBuilds == (workload == "invocation" ? 10 : workload == "authoring" ? 30 : 0))
                #expect(report.cleanup.activeWorkers == 0)
                #expect(report.cleanup.activeHandlers == 0)
                #expect(report.cleanup.activeAcknowledgements == 0)
                if workload == "definition-plan" {
                    #expect(report.common.metrics[0].id == (mode == "dsl" ? "dsl.definitionPlanV1" : "dsl.definitionSerializationControlV1"))
                    #expect(report.common.identity.fixtureHashes.count == 1)
                } else {
                    #expect(report.common.metrics[0].id == (workload == "authoring" ? "dsl.definition" : "dsl.invoke"))
                }
                try report.common.validate()
            }
        }
    }

    /// Bounded histograms observe late operations and retain overflow without fabricating a truncated percentile.
    /// - Throws: Unexpected histogram or exact-sum conversion errors.
    @Test func phase7HistogramWholePopulation() throws {
        let statistics = try Phase7Statistics()
        for _ in 0..<11 { statistics.record(.microseconds(1)) }
        statistics.record(.seconds(2))
        let (histogram, total) = try statistics.snapshot()
        #expect(histogram.observedCount == 12)
        #expect(histogram.overflowCount == 1)
        #expect(histogram.droppedCount == 0)
        #expect(total == 2_000_011_000)
        #expect(histogram.quantile(99) == .unavailable(.insufficientTailData))
    }
}
