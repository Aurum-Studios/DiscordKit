<!--
File: Docs/Tasks/performance-improvements/ORDERING-IDLE-PROBE.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Parked ordering CPU diagnostic

This standalone macOS consumer supplements the versioned held-owner timing case.
It is outside runtime/test targets and retains the exact manifest template and
source used for [Phase 1](PHASE-1.md). Its raw process receipts and source hashes
are indexed in [phase-1-observations.json](phase-1-observations.json).

One predecessor holds a partition with 1 or 64 queued successors. Public snapshots
confirm both boundaries of a one-second hold. CPU is the process's raw
`getrusage(RUSAGE_SELF)` user+system delta after a 100 ms setup settle. The separate
driver sleep and sampling overhead remain inside that interval; setup, release,
handoff and cleanup are outside. Clock counters observe actual coordinator sleep
calls and results, not all runtime tasks, OS wakeups, idle power or allocations.

Each process has a five-second cooperative guard plus a ten-second hard supervisor
cap, one-second termination grace, one-GiB sampled RSS ceiling, finite output and
joined caller/timer cleanup. `64` is a queue population, not permission for 64
concurrent operations in one partition. Default policy and quota authority remain
unchanged; this ordering-only diagnostic performs no quota reservation or network
request. Unknown host contention and the very small candidate CPU deltas limit
numerical interpretation.

## Reproduction

Use a fresh ignored destination and the desired original checkout. The original
Phase 1 capture used `01c743e4` and the candidate runtime with identical consumer
source. Reserve and record host conditions before any numerical qualification;
finish all builds/tests before running the processes sequentially. Preserve every
failed run as well as successful runs. No report from this standalone diagnostic
is a common-schema regression-policy result.

The preparation below extracts the two listings, substitutes an explicit library
checkout, copies its pins and obtains a release-build receipt. Set `original` and
`candidate` to the intended checkout paths; neither checkout is modified. The
release receipt binds tracked library source, compiler, pins and executable. Also
retain hashes of the extracted ignored manifest, pins and main source as capture
fixtures; those consumer inputs are outside Git's source fingerprint.

```python
from pathlib import Path
import re
import shutil
import subprocess

root = Path.cwd()
original = root / ".build/performance-phase1/baseline-source"
candidate = root
output = root / ".build/ordering-idle-recapture"
output.mkdir(parents=True, exist_ok=False)
listing = (root / "Docs/Tasks/performance-improvements/ORDERING-IDLE-PROBE.md").read_text()
manifest, source = re.findall(r"```swift\n(.*?)```", listing, re.S)
for family, checkout in [("original", original), ("candidate", candidate)]:
    package = output / family
    (package / "Sources/OrderingIdleProbe").mkdir(parents=True)
    (package / "Package.swift").write_text(manifest.replace("__DISCORDKIT_ROOT__", str(checkout.resolve())))
    (package / "Sources/OrderingIdleProbe/main.swift").write_text(source)
    shutil.copy2(checkout / "Package.resolved", package / "Package.resolved")
    subprocess.run(["python3", str(root / "Tools/DiscordBenchmarkSupport/scripts/run_benchmarks.py"),
                    "build", "--package", str(package), "--product", "OrderingIdleProbe",
                    "--repository", str(checkout), "--receipt", str(output / (family + "-release.json"))],
                   check=True)
```

Then use `run_benchmarks.run_process` with the receipt-bound executable plus literal
argument `1` or `64`, `ProcessLimits(10, grace_seconds=1)`, `stdout_is_report=True`
and `require_json=True`. Register SIGINT/SIGTERM on one shared `Cancellation` object,
validate the release receipt before and after each run, and retain the supervisor
result, raw stdout/stderr, source hashes and before/after environment. Assert
`status == "completed"`, all successors completed, final owner/count/byte/clock
counters are zero, and the supervisor reaped the process with no surviving owned
group. Never accept an incomplete process as a CPU observation.

At each cohort run five fresh candidate/candidate no-change pairs, then five fresh
original/candidate pairs, alternating arm order. Keep each process's CPU delta,
actual elapsed hold, clock counters and ownership receipts separately. Do not pool
holds as independent process replications, infer power from CPU, or infer all task
counts from injected sleep calls. The exact local orchestration script and its
hash remain in the Phase 1 capture index.

## Consumer manifest

```swift
// swift-tools-version: 6.4
// Ignored public-API diagnostic; substitute the dependency path before building.
import PackageDescription

let package = Package(
    name: "OrderingIdleProbe",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "DiscordKit", path: "__DISCORDKIT_ROOT__")],
    targets: [.executableTarget(name: "OrderingIdleProbe", dependencies: [
        .product(name: "DiscordHTTP", package: "DiscordKit"),
        .product(name: "DiscordLogging", package: "DiscordKit")
    ], swiftSettings: [.defaultIsolation(nil)])]
)
```

## Consumer source

```swift
// Ignored public-API diagnostic for a parked whole-operation ordering queue.
import Darwin
import DiscordHTTP
import DiscordLogging
import Foundation

enum ProbeError: Error { case invalidArguments, barrierTimeout, clockDidNotDrain, nonemptyCleanup, cpuProbeFailed, timeout }

/// A finite release gate owned by the single predecessor operation.
struct ReleaseSignal: Sendable {
    let stream: AsyncStream<Void>
    let continuation: AsyncStream<Void>.Continuation

    /// Creates exactly one buffered signal; no task or timer is allocated here.
    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream; continuation = pair.continuation
    }

    /// Waits for the driver to release the predecessor, honoring task cancellation.
    func wait() async throws {
        var iterator = stream.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
        try Task.checkCancellation()
    }

    /// Releases or finishes the single held owner; repeat calls are harmless.
    func release() { continuation.yield(()); continuation.finish() }
}

/// Actual calls into the injected clock; these are not all scheduler wakeups or runtime tasks.
struct ClockCounters: Codable, Sendable {
    var invocations = 0
    var completed = 0
    var cancelled = 0
    var active = 0
    var peakActive = 0
}

/// A small synchronous counter owner whose snapshot cost remains in the CPU interval.
final class ClockDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var values = ClockCounters()

    /// Counts one real injected-clock sleep invocation before forwarding it.
    func begin() {
        lock.withLock {
            values.invocations += 1; values.active += 1
            values.peakActive = max(values.peakActive, values.active)
        }
    }

    /// Records a joined sleep terminal result and relinquishes its active counter.
    func end(cancelled: Bool) {
        lock.withLock {
            values.active -= 1
            if cancelled { values.cancelled += 1 } else { values.completed += 1 }
        }
    }

    /// Reads a single consistent finite counter snapshot.
    func snapshot() -> ClockCounters { lock.withLock { values } }
}

/// Production monotonic time with observation restricted to actual coordinator sleeps.
struct ProbeClock: Clock {
    typealias Instant = ContinuousClock.Instant
    typealias Duration = Swift.Duration
    let base = ContinuousClock()
    let diagnostics: ClockDiagnostics

    /// Preserves the real monotonic clock's instant without virtual-time behavior.
    var now: Instant { base.now }

    /// Forwards the real clock's minimum resolution.
    var minimumResolution: Duration { base.minimumResolution }

    /// Records each sleep and its result; the separate driver hold is never counted here.
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        diagnostics.begin()
        do {
            try await base.sleep(until: deadline, tolerance: tolerance)
            diagnostics.end(cancelled: false)
        } catch {
            diagnostics.end(cancelled: true)
            throw error
        }
    }
}

/// Raw process CPU and monotonic observations at one edge of the parked interval.
struct ParkSample: Codable, Sendable {
    let uptimeNanoseconds: UInt64
    let userCPUNanoseconds: UInt64
    let systemCPUNanoseconds: UInt64
    let clock: ClockCounters

    /// Captures getrusage(RUSAGE_SELF), uptime and clock counters synchronously.
    static func capture(_ diagnostics: ClockDiagnostics) throws -> Self {
        let uptime = DispatchTime.now().uptimeNanoseconds
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw ProbeError.cpuProbeFailed }
        let user = UInt64(usage.ru_utime.tv_sec) * 1_000_000_000 + UInt64(usage.ru_utime.tv_usec) * 1_000
        let system = UInt64(usage.ru_stime.tv_sec) * 1_000_000_000 + UInt64(usage.ru_stime.tv_usec) * 1_000
        return Self(uptimeNanoseconds: uptime, userCPUNanoseconds: user, systemCPUNanoseconds: system,
            clock: diagnostics.snapshot())
    }
}

/// Credential-free public ownership counters retained before and after the parked interval.
struct Ownership: Codable, Sendable {
    let queued: Int
    let held: Int
    let activeReservations: Int
    let queuedBytes: Int

    /// Copies only aggregate public snapshot fields; no raw ordering scopes are serialized.
    init(_ snapshot: SchedulingSnapshot) {
        queued = snapshot.queuedCount; held = snapshot.orderedOperationsCount
        activeReservations = snapshot.activeCount; queuedBytes = snapshot.queuedBytes
    }
}

/// Finite diagnostic evidence, separate from the versioned runtime benchmark catalog.
struct ProbeReport: Encodable, Sendable {
    let format = "DiscordKit.OrderingIdleProbe"
    let schemaVersion = 1
    let status = "completed"
    let callers: Int
    let schedulingPolicy = "SchedulingPolicy()"
    let fairnessIntervalNanoseconds: UInt64
    let requestedParkNanoseconds: UInt64 = 1_000_000_000
    let setupSettleNanoseconds: UInt64 = 100_000_000
    let before: ParkSample
    let after: ParkSample
    let parkedElapsedNanoseconds: UInt64
    let parkedUserCPUNanoseconds: UInt64
    let parkedSystemCPUNanoseconds: UInt64
    let parkedTotalCPUNanoseconds: UInt64
    let parkedCPUFractionOfOneCore: Double
    let parkedClockSleepInvocations: Int
    let parkedClockSleepCompletions: Int
    let parkedClockSleepCancellations: Int
    let ownershipBefore: Ownership
    let ownershipBeforeRelease: Ownership
    let completedSuccessors: Int
    let finalOwnership: Ownership
    let finalClock: ClockCounters
    let notes: [String]
}

/// Establishes a public ownership barrier with a finite independent wall deadline.
func waitForOwnership(_ coordinator: RateLimitCoordinator<ProbeClock>, queued: Int, held: Int) async throws {
    let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(2))
    while true {
        try Task.checkCancellation()
        let value = await coordinator.snapshot()
        if value.queuedCount == queued && value.orderedOperationsCount == held { return }
        guard clock.now < deadline else { throw ProbeError.barrierTimeout }
        await Task.yield()
    }
}

/// Closes admission and joins all explicitly owned caller tasks on every terminal path.
func cleanup(_ coordinator: RateLimitCoordinator<ProbeClock>, holder: Task<Void, any Error>,
             successors: [Task<Void, any Error>], release: ReleaseSignal, cancel: Bool,
             diagnostics: ClockDiagnostics) async throws -> (Ownership, ClockCounters, Int) {
    if cancel { holder.cancel(); successors.forEach { $0.cancel() } }
    release.release()
    // Caller cancellation is explicit: these unstructured tasks do not inherit later driver cancellation.
    _ = await holder.result
    var completed = 0
    for successor in successors {
        if case .success = await successor.result { completed += 1 }
    }
    await coordinator.close()
    let deadline = ContinuousClock().now.advanced(by: .seconds(2))
    await Task.yield()
    while diagnostics.snapshot().active > 0 {
        guard ContinuousClock().now < deadline else { throw ProbeError.clockDidNotDrain }
        await Task.yield()
    }
    let snapshot = Ownership(await coordinator.snapshot()), clock = diagnostics.snapshot()
    guard snapshot.queued == 0, snapshot.held == 0, snapshot.activeReservations == 0,
        snapshot.queuedBytes == 0, clock.active == 0,
        clock.invocations == clock.completed + clock.cancelled else { throw ProbeError.nonemptyCleanup }
    return (snapshot, clock, completed)
}

/// Measures CPU only while every successor remains parked behind the held predecessor.
func run(callers: Int) async throws -> ProbeReport {
    let diagnostics = ClockDiagnostics()
    let policy = SchedulingPolicy()
    let coordinator = RateLimitCoordinator(clock: ProbeClock(diagnostics: diagnostics), policy: policy)
    let request = RateLimitRequest(identity: RateLimitIdentity(), route: "POST /ordering-idle-probe", majorResource: "local")
    let release = ReleaseSignal()
    let holder = Task {
        try await coordinator.withOrdering(request: request) { try await release.wait() }
    }
    do {
        try await withTaskCancellationHandler {
            try await waitForOwnership(coordinator, queued: 0, held: 1)
        } onCancel: { holder.cancel(); release.release() }
    } catch {
        _ = try await cleanup(coordinator, holder: holder, successors: [], release: release,
            cancel: true, diagnostics: diagnostics)
        throw error
    }
    let successors = (0..<callers).map { _ in
        Task { try await coordinator.withOrdering(request: request) {} }
    }
    return try await withTaskCancellationHandler {
        do {
            try await waitForOwnership(coordinator, queued: callers, held: 1)
            // This setup settle allows delayed clock registration and is excluded from parked CPU.
            try await Task.sleep(for: .milliseconds(100))
            try await waitForOwnership(coordinator, queued: callers, held: 1)
            let ownershipBefore = Ownership(await coordinator.snapshot())
            let before = try ParkSample.capture(diagnostics)
            // Driver sleep uses the native clock, never the instrumented coordinator clock.
            try await Task.sleep(for: .seconds(1))
            let after = try ParkSample.capture(diagnostics)
            let ownershipAfter = Ownership(await coordinator.snapshot())
            guard ownershipBefore.queued == callers, ownershipAfter.queued == callers,
                ownershipBefore.held == 1, ownershipAfter.held == 1 else { throw ProbeError.nonemptyCleanup }
            let (finalOwnership, finalClock, completed) = try await cleanup(coordinator, holder: holder,
                successors: successors, release: release, cancel: false, diagnostics: diagnostics)
            guard completed == callers else { throw ProbeError.nonemptyCleanup }
            let elapsed = after.uptimeNanoseconds - before.uptimeNanoseconds
            let user = after.userCPUNanoseconds - before.userCPUNanoseconds
            let system = after.systemCPUNanoseconds - before.systemCPUNanoseconds
            let fairness = policy.fairnessInterval.components
            let fairnessNanoseconds = UInt64(fairness.seconds) * 1_000_000_000 + UInt64(fairness.attoseconds / 1_000_000_000)
            return ProbeReport(callers: callers, fairnessIntervalNanoseconds: fairnessNanoseconds,
                before: before, after: after,
                parkedElapsedNanoseconds: elapsed, parkedUserCPUNanoseconds: user,
                parkedSystemCPUNanoseconds: system, parkedTotalCPUNanoseconds: user + system,
                parkedCPUFractionOfOneCore: Double(user + system) / Double(max(1, elapsed)),
                parkedClockSleepInvocations: after.clock.invocations - before.clock.invocations,
                parkedClockSleepCompletions: after.clock.completed - before.clock.completed,
                parkedClockSleepCancellations: after.clock.cancelled - before.clock.cancelled,
                ownershipBefore: ownershipBefore, ownershipBeforeRelease: ownershipAfter,
                completedSuccessors: completed, finalOwnership: finalOwnership, finalClock: finalClock, notes: [
                    "Public withOrdering API and actual SchedulingPolicy(); no REST transport, quota reservation, remote authority or credential.",
                    "One held setup operation retains the shared partition throughout the measured one-second driver hold. Exact public snapshots confirm the full queued successor population before and after parking.",
                    "The 100ms setup settle precedes CPU sampling; setup and release/handoff/cleanup occur outside the getrusage delta. Sampling and a separate native driver sleep remain inside the interval.",
                    "CPU is this process's getrusage user+system delta, not whole-host or peer CPU. Clock counters are actual injected sleep invocations and results, not scheduler wakeups or all runtime tasks.",
                    "The five-second structured guard cancels and joins owned operations. The external process supervisor supplies the hard failure/cleanup cap.",
                    "Local diagnostic only; no controlled-host numerical, idle-power, allocation-stack or production tail qualification."
                ])
        } catch {
            _ = try await cleanup(coordinator, holder: holder, successors: successors, release: release,
                cancel: true, diagnostics: diagnostics)
            throw error
        }
    } onCancel: {
        holder.cancel(); successors.forEach { $0.cancel() }; release.release()
    }
}

/// A structured operation/timeout race; cancellation of the guard is a normal joined result.
enum ProbeRace: Sendable { case report(ProbeReport), timeout, timerCancelled }

/// Applies a whole-operation cap while awaiting the cleanup of the losing child.
func bounded(callers: Int) async throws -> ProbeReport {
    try await withThrowingTaskGroup(of: ProbeRace.self) { group in
        group.addTask { .report(try await run(callers: callers)) }
        group.addTask {
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return .timerCancelled }
            return .timeout
        }
        defer { group.cancelAll() }
        while let next = try await group.next() {
            switch next {
            case .report(let report):
                group.cancelAll(); try await group.waitForAll(); return report
            case .timeout: group.cancelAll(); throw ProbeError.timeout
            case .timerCancelled: continue
            }
        }
        throw ProbeError.timeout
    }
}

/// Serializes one finite diagnostic after joined cleanup, with a safe failure category on error.
@main struct Main {
    /// Validates the finite cohort and emits JSON only after the owned operation has joined.
    static func main() async {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 1, let callers = Int(arguments[0]), [1, 64].contains(callers) else {
                throw ProbeError.invalidArguments
            }
            let report = try await bounded(callers: callers)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try FileHandle.standardOutput.write(contentsOf: encoder.encode(report) + Data([10]))
        } catch {
            let failure = ["format": "DiscordKit.OrderingIdleProbe", "status": "failed",
                "error": error is CancellationError ? "cancelled" : String(describing: error)]
            if let data = try? JSONSerialization.data(withJSONObject: failure, options: [.sortedKeys]) {
                try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            }
            exit(1)
        }
    }
}
```
