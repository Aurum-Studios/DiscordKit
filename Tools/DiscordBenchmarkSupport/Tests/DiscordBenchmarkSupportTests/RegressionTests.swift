// File: Tools/DiscordBenchmarkSupport/Tests/DiscordBenchmarkSupportTests/RegressionTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation
import Testing
@testable import DiscordBenchmarkSupport

@Suite("Hash-bound independent-run regression policy") struct RegressionTests {
    /// Creates exact full-population synthetic evidence with distinct inert build receipts.
    private func report(_ latency: UInt64 = 100, samples: Int = 10_000, candidate: Bool = false,
        tail: Int = 0, tailLatency: UInt64 = 600) throws -> DiscordBenchmarkReport {
        let hash = String(repeating: "a", count: 64)
        let provenance = BenchmarkProvenance(machineIdentity: "controlled-runner-1", cpuModel: "cpu-1", architecture: "arm64",
            cpuAllocation: "cores=4;affinity=0-3;quota=4", memoryBytes: 8_589_934_592,
            compiler: "Swift 6.4", optimization: "release -O", operatingSystem: "OS-1", sdk: "SDK-1",
            target: "arm64-example", sourceRevision: candidate ? "revision-B" : "revision-A", dirtyFingerprint: hash,
            dependencyHashes: ["root": hash], fixtureHashes: ["input": hash],
            executableHash: candidate ? String(repeating: "b", count: 64) : hash, buildFlags: ["-O"])
        var histogram = BoundedHistogram(configuration: try .init(lowerBoundNanoseconds: 0,
            upperBoundNanoseconds: 1_000, bucketWidthNanoseconds: 1))
        histogram.record(tailLatency, count: UInt64(min(tail, samples)))
        histogram.record(latency, count: UInt64(samples - min(tail, samples)))
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        outcomes[.success] = UInt64(samples)
        return DiscordBenchmarkReport(identity: ReportIdentity(scenario: "transport", profile: "standard", seed: 42,
            fixtureHashes: ["input": hash], inputSizes: ["bytes": 64], scheduler: "fixed-cohort",
            concurrency: 4, warmupNanoseconds: 100, requestedWarmupNanoseconds: 100,
            measuredNanoseconds: 1_000_000, repetitions: 1), provenance: provenance, adapter: "synthetic.fixture",
            clockDomain: "local-clock", status: .completed,
            counts: .init(offered: UInt64(samples), admitted: UInt64(samples), completed: UInt64(samples),
                outcomes: outcomes, deadlineMisses: 0),
            metrics: [.init(id: BenchmarkWorkload.transport.rawValue, clockDomain: "local-clock", distribution: histogram.snapshot())],
            gauges: ["processCPU": .init(value: 1_000, unit: "nanoseconds", method: "fixture", scope: "measured"),
                "processResidentBytes": .init(value: 1_000, unit: "bytes", method: "fixture", scope: "process"),
                "processPeakResidentBytes": .init(value: 1_000, unit: "bytes", method: "fixture", scope: "process-lifetime")],
            cleanup: .init(completed: true, remainingOwners: 0), throughputPerSecond: 1_000)
    }

    /// Creates five fresh paired observations and independent measured baseline no-change noise.
    private func series(latencies: [UInt64] = [100, 100, 100, 100, 100], samples: Int = 10_000,
        tail: Int = 0) throws -> BenchmarkSeries {
        var pairs: [BenchmarkPair] = [], noise: [BenchmarkPair] = []
        for index in 0..<5 {
            var baseline = try report(samples: samples)
            var candidate = try report(latencies[index], samples: samples, candidate: true, tail: tail)
            var unchanged = try report(index.isMultiple(of: 2) ? 101 : 99, samples: samples)
            baseline.identity.seed = UInt64(42 + index); candidate.identity.seed = UInt64(42 + index)
            unchanged.identity.seed = UInt64(42 + index)
            let order: BenchmarkPairOrder = index.isMultiple(of: 2) ? .baselineFirst : .candidateFirst
            pairs.append(.init(id: "measure-\(index)", order: order, baselineProcess: "measure-\(index)-A",
                candidateProcess: "measure-\(index)-B", hostContended: false, baseline: baseline, candidate: candidate))
            noise.append(.init(id: "noise-\(index)", order: order, baselineProcess: "noise-\(index)-A",
                candidateProcess: "noise-\(index)-B", hostContended: false, baseline: baseline, candidate: unchanged))
        }
        return BenchmarkSeries(pairs: pairs, noisePairs: noise)
    }

    /// Binds one reviewed p99 budget to the exact baseline and calibration fixtures.
    private func policy(_ series: BenchmarkSeries, statistic: BenchmarkStatistic = .p99,
        floor: Double = 1, tolerance: Double = 0.1) throws -> BenchmarkPolicy {
        let hashes = try series.hashes()
        return BenchmarkPolicy(mode: .reporting, baselineHashes: hashes.baselineHashes,
            noiseSeriesHash: hashes.noiseSeriesHash, budgets: [BenchmarkBudget(id: "latency",
                metricID: BenchmarkWorkload.transport.rawValue, metricVersion: 1, outcome: .success,
                statistic: statistic, direction: .maximum, relativeTolerance: tolerance, absoluteNoiseFloor: floor)])
    }

    /// Standard SHA-256 vectors include padding at multiple block boundaries.
    @Test func sha256KnownVectors() {
        #expect(BenchmarkEvidenceHash.sha256(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(BenchmarkEvidenceHash.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(BenchmarkEvidenceHash.sha256(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    /// Exact no-change pairs establish an actual floor and retain descriptive independent-run spread.
    @Test func noChangeMeasuresNoiseAndCannotPromoteGate() throws {
        let series = try series(), policy = try policy(series)
        let evaluation = try BenchmarkEvaluation.evaluate(series, policy: policy)
        #expect(evaluation.status == .passed)
        #expect(!evaluation.requiredGatePassed)
        var promoted = policy
        promoted.mode = .required
        #expect(try BenchmarkEvaluation.evaluate(series, policy: promoted).requiredGatePassed)
        #expect(evaluation.budgets[0].measuredAbsoluteNoise == 1)
        #expect(evaluation.budgets[0].deltas.count == 5)
        #expect(evaluation.budgets[0].variability.independentPairs == 5)
        #expect(!evaluation.budgets[0].investigationRequired)
        #expect(try BenchmarkSeries.decode(JSONEncoder().encode(series)).hashes() == series.hashes())
        #expect(try BenchmarkPolicy.decode(JSONEncoder().encode(policy)).baselineHashes == policy.baselineHashes)
    }

    /// Repeated known slowdowns produce five paired deltas and the repository's three-run investigation flag.
    @Test func syntheticSlowdownDetectedWithoutAveragingPercentiles() throws {
        let series = try series(latencies: [130, 140, 150, 100, 100])
        let evaluation = try BenchmarkEvaluation.evaluate(series, policy: policy(series))
        #expect(evaluation.status == .regression)
        let budget = evaluation.budgets[0]
        #expect(budget.investigationRequired)
        #expect(budget.deltas.map(\.candidateLower) == [130, 140, 150, 100, 100])
        #expect(budget.variability.minimumAdverseDelta == 0)
        #expect(budget.variability.maximumAdverseDelta == 50)
    }

    /// Two-percent tail stalls move p99 while the median remains healthy.
    @Test func syntheticTailStallDetectedSeparatelyFromMedian() throws {
        let series = try series(tail: 200)
        let tail = try BenchmarkEvaluation.evaluate(series, policy: policy(series))
        let median = try BenchmarkEvaluation.evaluate(series, policy: policy(series, statistic: .p50))
        #expect(tail.status == .regression)
        #expect(tail.budgets[0].deltas.allSatisfy { $0.candidateLower == 600 && $0.candidateSamples == 10_000 })
        #expect(median.status == .passed)
    }

    /// A reviewed wider budget cannot suppress the existing greater-than-ten-percent investigation rule.
    @Test func investigationRemainsRequiredWithWiderWorkloadBudget() throws {
        let series = try series(latencies: [120, 120, 120, 100, 100])
        let evaluation = try BenchmarkEvaluation.evaluate(series, policy: policy(series, tolerance: 0.3))
        #expect(evaluation.status == .passed)
        #expect(evaluation.budgets[0].investigationRequired)
        var required = try policy(series, tolerance: 0.3)
        required.mode = .required
        #expect(try !BenchmarkEvaluation.evaluate(series, policy: required).requiredGatePassed)
        #expect(evaluation.reasons.contains { $0.contains("investigation required") })
    }

    /// Baseline content, noise content, and budget identity are independently pinned.
    @Test func hashMismatchAndMetricVersionRefused() throws {
        var series = try series(), policy = try policy(series)
        series.pairs[0].baseline.throughputPerSecond = 999
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .incompatible)
        series = try self.series(); series.noisePairs[0].candidate.throughputPerSecond = 999
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .incompatible)
        series = try self.series(); policy.budgets[0].metricVersion = 2
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .incompatible)
    }

    /// Hardware, compiler, precision, seed and fixture mismatches remain explicit incompatibilities.
    @Test func incompatibleEvidenceIsRefused() throws {
        var series = try series()
        let policy = try policy(series)
        series.pairs[0].candidate.provenance.cpuModel = "other-hardware"
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .incompatible)
        series = try self.series(); series.pairs[0].candidate.provenance.compiler = "other-compiler"
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .incompatible)
        series = try self.series(); series.pairs[0].candidate.identity.seed = 99
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .incompatible)
        series = try self.series()
        let hash = String(repeating: "c", count: 64)
        series.pairs[0].candidate.identity.fixtureHashes = ["input": hash]
        series.pairs[0].candidate.provenance.fixtureHashes = ["input": hash]
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .incompatible)
    }

    /// Sparse p99 and absent calibration are neither pass nor regression.
    @Test func missingIndependentRunsAndSparseTails() throws {
        var series = try series(samples: 9_999)
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy(series)).status == .insufficientSamples)
        series = try self.series(); series.pairs.removeLast(); series.noisePairs.removeLast()
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy(series)).status == .insufficientSamples)
        series = try self.series(); series.noisePairs = []
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy(series)).status == .insufficientSamples)
    }

    /// A caller cannot invent a lower floor than the independent no-change evidence establishes.
    @Test func underreportedNoiseIsRejected() throws {
        let series = try series()
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy(series, floor: 0)).status == .incompatible)
    }

    /// Host contention, process reuse and interrupted harnesses have distinct non-performance statuses.
    @Test func hostAndHarnessFailureClassifications() throws {
        var series = try series()
        var policy = try policy(series)
        series.pairs[0].hostContended = true
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .hostFailure)
        series = try self.series(); series.pairs[0].candidateProcess = series.pairs[0].baselineProcess
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .harnessFailure)
        series = try self.series(); series.pairs[0].candidate.status = .interrupted
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .harnessFailure)
        series = try self.series(); series.pairs[0].baseline.cleanup.completed = false
        policy = try self.policy(series)
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .harnessFailure)
    }

    /// Error, deadline, aggregate-loss and resource closure are hard bounds even below a latency floor.
    @Test func correctnessAndCleanupRemainHard() throws {
        var series = try series()
        let policy = try policy(series, floor: 10_000)
        series.pairs[0].candidate.counts!.deadlineMisses = 1
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .regression)
        series = try self.series(); series.pairs[0].candidate.cleanup.remainingOwners = 1
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .regression)
        series = try self.series()
        series.pairs[0].candidate.counts!.outcomes[.success]! -= 1
        series.pairs[0].candidate.counts!.outcomes[.failure] = 1
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .regression)
        series = try self.series()
        var histogram = BoundedHistogram(configuration: series.pairs[0].candidate.metrics[0].distribution.configuration)
        histogram.record(100); histogram.recordLoss()
        series.pairs[0].candidate.metrics[0].distribution = histogram.snapshot()
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .regression)
    }

    /// Any censored mass refuses qualification, even when the selected median is in range.
    @Test func censoredPopulationRefused() throws {
        var series = try series()
        var histogram = BoundedHistogram(configuration: series.pairs[0].candidate.metrics[0].distribution.configuration)
        histogram.record(100, count: 10_000); histogram.record(1_001)
        series.pairs[0].candidate.metrics[0].distribution = histogram.snapshot()
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy(series, statistic: .p50)).status == .insufficientSamples)
        #expect(!series.pairs[0].baseline.comparison(with: series.pairs[0].candidate).isCompatible)
    }

    /// Reviewed scope disclaimers are accepted by exact text without erasing or globally ignoring warnings.
    @Test func scopeNotesNeedExplicitReview() throws {
        var series = try series()
        for index in series.pairs.indices {
            series.pairs[index].baseline.qualificationLimitations = ["Local fixture; no live Discord qualification."]
            series.pairs[index].candidate.qualificationLimitations = ["Local fixture; no live Discord qualification."]
            series.noisePairs[index].baseline.qualificationLimitations = ["Local fixture; no live Discord qualification."]
            series.noisePairs[index].candidate.qualificationLimitations = ["Local fixture; no live Discord qualification."]
        }
        var policy = try policy(series)
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .incompatible)
        policy.acceptedQualificationLimitations = ["Local fixture; no live Discord qualification."]
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .passed)
        #expect(!series.pairs[0].baseline.comparison(with: series.pairs[0].candidate).isCompatible)
        series.pairs[0].candidate.qualificationLimitations.append("Unknown accounting limitation.")
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .incompatible)
    }

    /// Throughput minima and resource maxima have explicit units/directions and absolute hard limits.
    @Test func throughputAndResourceBounds() throws {
        var series = try series()
        for index in series.pairs.indices { series.pairs[index].candidate.throughputPerSecond = 800 }
        var policy = try policy(series)
        policy.budgets = [.init(id: "throughput", statistic: .throughput, direction: .minimum,
            relativeTolerance: 0.1, absoluteNoiseFloor: 0)]
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .regression)
        series = try self.series(); policy = try self.policy(series)
        series.pairs[0].candidate.gauges["processResidentBytes"]!.value = 1_100
        policy.budgets = [.init(id: "memory", statistic: .gauge, gauge: "processResidentBytes", direction: .maximum,
            relativeTolerance: 1, absoluteNoiseFloor: 10_000, absoluteLimit: 1_050)]
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .regression)
    }

    /// Direct callers cannot bypass release runtime policy; separately versioned compiler debug is explicit.
    @Test func runtimeDebugRefusedButCompilerConfigurationRetained() throws {
        var series = try series()
        for index in series.pairs.indices {
            series.pairs[index].baseline.provenance.optimization = "debug"
            series.pairs[index].candidate.provenance.optimization = "debug"
            series.noisePairs[index].baseline.provenance.optimization = "debug"
            series.noisePairs[index].candidate.provenance.optimization = "debug"
        }
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy(series)).status == .incompatible)
        for index in series.pairs.indices {
            series.pairs[index].baseline.identity.catalogVersion = 7
            series.pairs[index].candidate.identity.catalogVersion = 7
            series.noisePairs[index].baseline.identity.catalogVersion = 7
            series.noisePairs[index].candidate.identity.catalogVersion = 7
            series.pairs[index].baseline.metrics[0].id = BenchmarkWorkload.compilerClean.rawValue
            series.pairs[index].candidate.metrics[0].id = BenchmarkWorkload.compilerClean.rawValue
            series.noisePairs[index].baseline.metrics[0].id = BenchmarkWorkload.compilerClean.rawValue
            series.noisePairs[index].candidate.metrics[0].id = BenchmarkWorkload.compilerClean.rawValue
        }
        var policy = try policy(series)
        policy.budgets[0].metricID = BenchmarkWorkload.compilerClean.rawValue
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .passed)
    }

    /// Throughput or gauge bounds cannot turn an empty workload into a successful qualification.
    @Test func zeroWorkCannotPassAlternateBudgetTypes() throws {
        let series = try series(samples: 0)
        var policy = try policy(series)
        policy.budgets = [.init(id: "throughput", statistic: .throughput, direction: .minimum,
            relativeTolerance: 0.1, absoluteNoiseFloor: 0)]
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .insufficientSamples)
        policy.budgets = [.init(id: "memory", statistic: .gauge, gauge: "processResidentBytes", direction: .maximum,
            relativeTolerance: 0.1, absoluteNoiseFloor: 0)]
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .insufficientSamples)
    }

    /// Unbalanced ordering and calibration seed drift cannot qualify a superficially matching cohort.
    @Test func orderAndCalibrationScheduleAreFrozen() throws {
        var series = try series()
        let policy = try policy(series)
        series.pairs[3].order = .baselineFirst
        #expect(try BenchmarkEvaluation.evaluate(series, policy: policy).status == .incompatible)
        series = try self.series()
        series.noisePairs[0].baseline.identity.seed = 999
        series.noisePairs[0].candidate.identity.seed = 999
        #expect(try BenchmarkEvaluation.evaluate(series, policy: self.policy(series)).status == .incompatible)
    }

    /// Missing/invalid required policy fields and incompatible versions cannot silently use permissive defaults.
    @Test func malformedPolicyAndSeriesVersionsRejected() throws {
        var series = try series(), policy = try policy(series)
        policy.schemaVersion = 2
        #expect(throws: BenchmarkEvaluationError.invalidPolicy) { try policy.validate() }
        policy = try self.policy(series); policy.budgets[0].relativeTolerance = .infinity
        #expect(throws: BenchmarkEvaluationError.invalidPolicy) { try policy.validate() }
        policy = try self.policy(series); policy.budgets[0].direction = .minimum
        #expect(throws: BenchmarkEvaluationError.invalidPolicy) { try policy.validate() }
        series.schemaVersion = 2
        #expect(throws: BenchmarkEvaluationError.invalidSeries) { try series.validate() }
        #expect(throws: (any Error).self) { try BenchmarkPolicy.decode(Data("{}".utf8)) }
    }
}
