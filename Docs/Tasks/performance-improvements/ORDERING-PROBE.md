<!--
File: Docs/Tasks/performance-improvements/ORDERING-PROBE.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Ordering handoff reproduction

This retained exploratory consumer reproduces finding F01 using public APIs. It
is documentation, outside the runtime/test target graph. The original build ran
against clean `065e2b65`; [evidence](EVIDENCE.md) and [observations](observations.json)
record that capture. A later recapture has its own revision/host/results.

One operation holds an ordering partition; its successor invokes the injected
clock's real sleep. The driver confirms one queued and one held operation, then
releases the first. Markers distinguish release signal, first operation exit,
first ordering return and successor entry. The confirmed-return delta can be
negative in a changed implementation when the successor runs before the first
caller resumes; preserve its sign. A sleep callback marks invocation, not proof
that the task has already suspended. The observer/marker lock and atomic snapshot
perturb scheduling; this is a causal local probe, not a production latency benchmark.

The ten-millisecond arm uses the actual default `SchedulingPolicy()`. The other
changes only the polling interval. There is no REST transport, quota reservation,
remote authority or decoder in this probe. Each trial cancels and joins after two
seconds; the process supervisor adds a hard timeout. Close logging occurs outside
the measured handoff. No controlled-host, p99, rate-store or live claim follows.

## Recapture

From the repository root, the following script extracts the two Swift listings,
prepares a new ignored consumer with the repository pins, builds release with four
jobs, and runs ten alternating pairs serially. It preserves native stdout, stderr,
commands and process status. Every output directory must be new. The process-group
supervisor reaps its leader and sends KILL to the owned group on failure/interrupt;
it is a small exploratory procedure, not the common regression-policy machinery.
Reserve/record host conditions separately for any numerical qualification. Do not
run other builds or performance captures concurrently.

```python
import json
import os
from pathlib import Path
import re
import signal
import subprocess

root = Path.cwd()
output = root / ".build/performance-recapture/ordering-probe"
output.mkdir(parents=True, exist_ok=False)
listing = (root / "Docs/Tasks/performance-improvements/ORDERING-PROBE.md").read_text()
manifest, source = re.findall(r"```swift\n(.*?)```", listing, re.S)
(output / "Package.swift").write_text(manifest)
(output / "Package.resolved").write_bytes((root / "Package.resolved").read_bytes())
(output / "Sources/OrderingProbe").mkdir(parents=True)
(output / "Sources/OrderingProbe/main.swift").write_text(source)

def group_state(pid):
    try:
        os.killpg(pid, 0)
    except ProcessLookupError:
        return "absent"
    except PermissionError:
        return "unknownPermission"
    return "present"

def interrupt(_signum, _frame):
    raise KeyboardInterrupt()

signal.signal(signal.SIGTERM, interrupt)

def run(command, stem, seconds):
    (output / (stem + "-command.json")).write_text(json.dumps(command, indent=2))
    with (output / (stem + ".stdout.log")).open("wb") as stdout, \
         (output / (stem + ".stderr.log")).open("wb") as stderr:
        child = subprocess.Popen(command, cwd=root, stdout=stdout, stderr=stderr,
                                 start_new_session=True)
        status = {"status": "running", "pid": child.pid, "killSent": False}
        try:
            code = child.wait(timeout=seconds)
            if code:
                raise RuntimeError(f"{stem} exited {code}")
            if group_state(child.pid) != "absent":
                raise RuntimeError(f"{stem} left a process group after leader exit")
            status["status"] = "completed"
        except BaseException as error:
            status["status"] = ("timedOut" if isinstance(error, subprocess.TimeoutExpired)
                                else "interrupted" if isinstance(error, KeyboardInterrupt)
                                else "failed")
            try:
                os.killpg(child.pid, signal.SIGKILL)
                status["killSent"] = True
            except ProcessLookupError:
                pass
            child.wait(timeout=5)
            raise
        finally:
            status["exitCode"] = child.poll()
            status["processGroupAfterReaping"] = group_state(child.pid)
            (output / (stem + "-status.json")).write_text(json.dumps(status, indent=2))

run(["swift", "build", "--package-path", str(output), "-c", "release",
     "--force-resolved-versions", "--jobs", "4"], "build", 180)
executable = output / ".build/release/OrderingProbe"
for pair in range(10):
    policies = [10000, 100] if pair % 2 == 0 else [100, 10000]
    for position, policy in enumerate(policies):
        stem = f"pair-{pair:02d}-arm-{position}-fairness-{policy}"
        run([str(executable), str(policy), "8"], stem, 10)
        result = json.loads((output / (stem + ".stdout.log")).read_text())
        assert len(result["trials"]) == 8
        assert all(t["queuedAfter"] == t["orderedAfter"] == 0 for t in result["trials"])
```

Report each process median and its spread, retain all signed trial offsets and
check owned process groups are absent. Do not pool trials as independent process
replications, invent p99, or treat a lower polling value as an implemented fix.
For Stage 1, move the minimal proven workload into the existing versioned timing
suite, add deterministic boundary/ownership tests, and compare an actual candidate
against unchanged code plus independent no-change pairs.

## Consumer manifest

```swift
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OrderingProbe",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "DiscordKit", path: "../../..")],
    targets: [.executableTarget(name: "OrderingProbe", dependencies: [
        .product(name: "DiscordHTTP", package: "DiscordKit")
    ], swiftSettings: [.defaultIsolation(nil)])]
)
```

## Consumer source

```swift
import DiscordHTTP
import Foundation

struct Signal: Sendable {
    let stream: AsyncStream<Void>
    let continuation: AsyncStream<Void>.Continuation
    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
    }
    func wait() async throws {
        var iterator = stream.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
        try Task.checkCancellation()
    }
}

final class Markers: @unchecked Sendable {
    private let lock = NSLock()
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant
    private var values: [String: Int64] = [:]
    init() { origin = clock.now }
    func mark(_ key: String) {
        let duration = origin.duration(to: clock.now).components
        let offset = duration.seconds * 1_000_000_000 + duration.attoseconds / 1_000_000_000
        lock.withLock { values[key] = offset }
    }
    func snapshot() -> [String: Int64] { lock.withLock { values } }
}

struct ProbeClock: Clock {
    typealias Instant = ContinuousClock.Instant
    typealias Duration = Swift.Duration
    let base = ContinuousClock()
    let sleeper: Signal
    let markers: Markers
    var now: Instant { base.now }
    var minimumResolution: Duration { base.minimumResolution }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        markers.mark("secondSleepInvoked")
        sleeper.continuation.yield(())
        try await base.sleep(until: deadline, tolerance: tolerance)
    }
}

enum ProbeFailure: Error { case timeout, unexpectedOwners, missingMarker }

struct Trial: Codable, Sendable {
    let offsetsNanoseconds: [String: Int64]
    let releaseSignalToSecondEntryNanoseconds: Int64
    let firstOperationExitToSecondEntryNanoseconds: Int64
    let firstOrderingReturnToSecondEntryNanoseconds: Int64
    let queuedAfter: Int
    let orderedAfter: Int
}

func runOwnedTrial(fairnessMicroseconds: Int) async throws -> Trial {
    let entered = Signal(), release = Signal(), sleeper = Signal()
    let markers = Markers()
    let clock = ProbeClock(sleeper: sleeper, markers: markers)
    let coordinator: RateLimitCoordinator<ProbeClock>
    if fairnessMicroseconds == 10_000 {
        // Use the actual default policy, rather than restating its fairness value.
        coordinator = RateLimitCoordinator(clock: clock, policy: SchedulingPolicy())
    } else {
        coordinator = RateLimitCoordinator(clock: clock,
            policy: SchedulingPolicy(fairnessInterval: .microseconds(fairnessMicroseconds)))
    }
    let request = RateLimitRequest(identity: RateLimitIdentity(), route: "POST /ordering-probe", majorResource: "local")
    let first = Task {
        defer { entered.continuation.finish() }
        try await coordinator.withOrdering(request: request) {
            markers.mark("firstOperationEntered")
            entered.continuation.yield(())
            try await release.wait()
            markers.mark("firstOperationExiting")
        }
        markers.mark("firstOrderingReturned")
    }
    let second = Task {
        defer { sleeper.continuation.finish() }
        try await entered.wait()
        markers.mark("secondOrderingCalled")
        try await coordinator.withOrdering(request: request) {
            markers.mark("secondOperationEntered")
        }
        markers.mark("secondOrderingReturned")
    }
    return try await withTaskCancellationHandler {
        do {
            try await sleeper.wait()
            let before = await coordinator.snapshot()
            guard before.queuedCount == 1, before.orderedOperationsCount == 1 else {
                throw ProbeFailure.unexpectedOwners
            }
            markers.mark("releaseSignal")
            release.continuation.yield(())
            release.continuation.finish()
            try await first.value
            try await second.value
            await coordinator.close()
            let after = await coordinator.snapshot()
            guard after.queuedCount == 0, after.orderedOperationsCount == 0 else {
                throw ProbeFailure.unexpectedOwners
            }
            let values = markers.snapshot()
            guard let admitted = values["secondOperationEntered"], let released = values["releaseSignal"],
                  let exit = values["firstOperationExiting"], let returned = values["firstOrderingReturned"] else {
                throw ProbeFailure.missingMarker
            }
            return Trial(offsetsNanoseconds: values,
                releaseSignalToSecondEntryNanoseconds: admitted - released,
                firstOperationExitToSecondEntryNanoseconds: admitted - exit,
                firstOrderingReturnToSecondEntryNanoseconds: admitted - returned,
                queuedAfter: after.queuedCount, orderedAfter: after.orderedOperationsCount)
        } catch {
            first.cancel(); second.cancel()
            release.continuation.finish(); entered.continuation.finish(); sleeper.continuation.finish()
            await coordinator.close()
            _ = await first.result; _ = await second.result
            throw error
        }
    } onCancel: {
        first.cancel(); second.cancel()
        release.continuation.finish(); entered.continuation.finish(); sleeper.continuation.finish()
    }
}

func boundedTrial(fairnessMicroseconds: Int) async throws -> Trial {
    try await withThrowingTaskGroup(of: Trial.self) { group in
        group.addTask { try await runOwnedTrial(fairnessMicroseconds: fairnessMicroseconds) }
        group.addTask { try await Task.sleep(for: .seconds(2)); throw ProbeFailure.timeout }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw ProbeFailure.timeout }
        return result
    }
}

struct Report: Codable {
    let schemaVersion = 1
    let scope = "Exploratory public withOrdering API; local ContinuousClock; no REST, network or rate-store reservation."
    let fairnessMicroseconds: Int
    let defaultPolicy: Bool
    let processIdentifier: Int32
    let notes = [
        "The release signal follows an observed call to the waiter's Clock.sleep and an atomic coordinator snapshot showing one waiter and one held ordering operation.",
        "Clock.sleep invocation is observed before forwarding to ContinuousClock.sleep; scheduling may delay actual suspension.",
        "firstOrderingReturned confirms ordering ownership already released; the signed delta can be negative if the successor executes before its predecessor caller resumes.",
        "Each trial has a two-second structured timeout and joins both operations; no percentile or controlled-host qualification is claimed."
    ]
    let trials: [Trial]
}

@main struct Main {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2, let fairness = Int(arguments[0]), [100, 10_000].contains(fairness),
              let count = Int(arguments[1]), (1...32).contains(count) else {
            throw ProbeFailure.missingMarker
        }
        var trials: [Trial] = []
        for _ in 0..<count { trials.append(try await boundedTrial(fairnessMicroseconds: fairness)) }
        let report = Report(fairnessMicroseconds: fairness, defaultPolicy: fairness == 10_000,
            processIdentifier: ProcessInfo.processInfo.processIdentifier, trials: trials)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report)); FileHandle.standardOutput.write(Data([10]))
    }
}
```
