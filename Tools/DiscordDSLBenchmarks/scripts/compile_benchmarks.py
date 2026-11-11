#!/usr/bin/env python3
# File: Tools/DiscordDSLBenchmarks/scripts/compile_benchmarks.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Measure finite external DSL consumers; no credentials, sockets or handlers run.

The bootstrap is separately reported. Measured clean builds remove only the named
consumer's outputs, retaining dependency and macro-plugin compilation. Incremental
builds change one response literal in the first ten-handler file, restore that file
in finally, and include ordinary SwiftPM planning, type checking, codegen and linking.
"""

import argparse
import datetime
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import uuid


def load_supervisor():
    """Load the repository-owned process supervisor by exact path, including its dataclass module identity."""
    name = "discordkit_compiler_process_supervisor"
    if name not in sys.modules:
        path = Path(__file__).resolve().parents[2] / "DiscordBenchmarkSupport/scripts/run_benchmarks.py"
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


SUPERVISOR = load_supervisor()


COUNTS = (10, 100, 1000)
MODES = ("manual", "macro")
MARKER = ".discord-dsl-compiler-benchmark"


def digest_files(paths, root):
    """Hash relative names and exact bytes in deterministic order, without mtimes."""
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(str(path.relative_to(root)).encode() + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def generated_sources(count, macro, module_count=1):
    """Return concrete ten-handler files partitioned over explicit inert DSL modules.

    Module fan-out is finite, at most the number of files, and never changes the
    selected manual/macro declaration count or shared argument schema.
    """
    if count not in COUNTS:
        raise ValueError("handler count must be 10, 100 or 1000")
    if type(module_count) is not int or not 1 <= module_count <= count // 10:
        raise ValueError("modules must be 1...handlerCount/10")
    imports = "import DiscordCommandDSL\nimport DiscordDSL\n"
    if macro:
        imports += "import DiscordDSLMacros\n"
    arguments = """@CommandArguments struct Arguments: Sendable {
    @Option(description: "Text") let text: String
}
""" if macro else """struct Arguments: CommandArguments {
    let text: String
    static var schema: CommandArgumentSchema<Self> {
        get throws {
            let text = try ArgumentOption<String>(name: "text", description: "Text")
            return try CommandArgumentSchema(options: [text.erased]) { try Self(text: $0.value(for: text)) }
        }
    }
}
"""
    sources = {"Arguments.swift": imports + arguments}
    for group in range(count // 10):
        text = imports
        for index in range(group * 10, group * 10 + 10):
            if macro:
                text += f'@SlashCommand("command{index}", description: "Bounded compiler fixture")\n'
            text += f"struct Handler{index}: SlashCommandHandler {{\n    typealias Arguments = {('Macro' if macro else 'Manual') + str(count)}.Arguments\n"
            if not macro:
                text += f'    var command: SlashCommandMetadata {{ .init(name: "command{index}", description: "Bounded compiler fixture") }}\n'
            text += r"""    func execute(_ context: CommandContext, arguments: Arguments) async throws -> MessageResponse {
        try MessageResponse(visibility: .ephemeral) { Text("fixture \(arguments.text)") }
    }
}
"""
        text += f"func group{group}() throws -> BotDefinitionGroup {{\n    try BotDefinitionGroup([\n"
        text += ",\n".join((f'        Handler{index}().contribution(id: "handler{index}", source: .init(fileID: "compiler-fixture", line: {index + 1}))' if macro else
                              f'        SlashCommand(id: "handler{index}", handler: Handler{index}(), source: .init(fileID: "compiler-fixture", line: {index + 1}))')
                             for index in range(group * 10, group * 10 + 10))
        text += "\n    ])\n}\n"
        sources[f"Handlers{group:03}.swift"] = text
    sources["Main.swift"] = imports + "@main struct Consumer {\n    static func main() throws {\n        let groups = try [\n" + ",\n".join(f"            group{group}()" for group in range(count // 10)) + f"""
        ]
        let modules = (0..<{module_count}).map {{ index in
            Module(id: "module\\(index)") {{
                BotDefinitionGroup(Array(groups[index * groups.count / {module_count}..<(index + 1) * groups.count / {module_count}]))
            }}
        }}
        let compiled = try CommandCompilation.compile(BotDefinitionGroup(modules))
        precondition(compiled.routes.count == {count} && compiled.definitions.count == {count})
        print("qualified {count} inert declarations")
    }}
}}
"""
    return sources


def prepare_workspace(repository, workspace, counts=COUNTS, module_count=1, modes=MODES):
    """Create marked finite generated consumers; reject unrelated nonempty directories.

    Selected counts are unique members of COUNTS. Module fan-out cannot exceed
    the smallest consumer's compilation-file population; old generated sources
    in each owned consumer directory are removed before writing current inputs.
    """
    validate_dimensions(counts, module_count, modes)
    if workspace.exists() and any(workspace.iterdir()) and not (workspace / MARKER).is_file():
        raise ValueError("workspace must be empty or marked by this runner")
    workspace.mkdir(parents=True, exist_ok=True)
    (workspace / MARKER).write_text("generated compiler consumers version 1\n")
    names = [f"{mode.title()}{count}" for count in counts for mode in modes]
    root_literal = json.dumps(str(repository))
    macro_literal = json.dumps(str(repository / "Packages/DiscordDSLMacros"))
    macro_dependency = f',\n        .package(name: "DiscordDSLMacros", path: {macro_literal})' if "macro" in modes else ""
    warmup_dependency = ' + [.product(name: "DiscordDSLMacros", package: "DiscordDSLMacros")]' if "macro" in modes else ""
    manifest = f"""// swift-tools-version: 6.4
import PackageDescription
let names = {json.dumps(names)}
let settings: [SwiftSetting] = [.enableUpcomingFeature("ApproachableConcurrency"), .defaultIsolation(nil)]
let runtime: [Target.Dependency] = [
    .product(name: "DiscordCommandDSL", package: "DiscordKit"),
    .product(name: "DiscordDSL", package: "DiscordKit")]
let package = Package(name: "DSLCompilerCosts", platforms: [.macOS(.v13)],
    products: names.map {{ .executable(name: $0, targets: [$0]) }},
    dependencies: [.package(name: "DiscordKit", path: {root_literal}){macro_dependency}],
    targets: [.target(name: "Warmup", dependencies: runtime{warmup_dependency}, swiftSettings: settings)] +
        names.map {{ name in .executableTarget(name: name, dependencies: runtime +
            (name.hasPrefix("Macro") ? [.product(name: "DiscordDSLMacros", package: "DiscordDSLMacros")] : []), swiftSettings: settings) }})
"""
    (workspace / "Package.swift").write_text(manifest)
    shutil.copyfile(repository / "Tests/Fixtures/DSLCompile/Package.resolved", workspace / "Package.resolved")
    warmup = workspace / "Sources/Warmup"
    warmup.mkdir(parents=True, exist_ok=True)
    (warmup / "Warmup.swift").write_text("import DiscordCommandDSL\n" + ("import DiscordDSLMacros\n" if "macro" in modes else "") + "struct Warmup {}\n")
    # Marked workspaces may be reused with a smaller matrix. Remove only owned
    # generated directories; stale sources must not enter the new fixture hash.
    for count in COUNTS:
        for mode in MODES:
            directory = workspace / "Sources" / f"{mode.title()}{count}"
            if directory.name not in names and directory.is_dir() and not directory.is_symlink():
                shutil.rmtree(directory)
    for count in counts:
        for mode in modes:
            directory = workspace / "Sources" / f"{mode.title()}{count}"
            directory.mkdir(parents=True, exist_ok=True)
            for owned in directory.glob("*.swift"):
                owned.unlink()
            for name, content in generated_sources(count, mode == "macro", module_count).items():
                (directory / name).write_text(content)
    return names


def remove_consumer_outputs(scratch, target):
    """Remove only generated target outputs, retaining dependencies and plugins."""
    if not re.fullmatch(r"(?:Manual|Macro)(?:10|100|1000)", target):
        raise ValueError("unknown consumer target")
    removed = []
    for configuration in scratch.glob("*/debug"):
        # SwiftPM owns planning inputs (notably output-file-map.json and LinkFileList).
        # Removing them while its manifest cache is valid can fail before compilation.
        build_directory = configuration / f"{target}.build"
        for path in build_directory.rglob("*"):
            if path.is_file() and path.suffix in {".o", ".d", ".swiftdeps", ".swiftmodule", ".swiftdoc", ".swiftsourceinfo", ".swiftconstvalues", ".dia", ".autolink", ".priors"}:
                path.unlink()
                removed.append(str(path.relative_to(scratch)))
        for path in [configuration / target,
                     configuration / f"{target}.dSYM", *list((configuration / "Modules").glob(target + ".*"))]:
            if path.exists() and not path.is_symlink():
                if path.is_dir():
                    shutil.rmtree(path)
                else:
                    path.unlink()
                removed.append(str(path.relative_to(scratch)))
    return removed


def run_supervised(command, timeout, cwd, directory, cancellation=None, limits=None):
    """Delegate bounded pipe collection, limits, descendant teardown and owner reap to shared supervision.

    Temporary main-thread SIGINT/SIGTERM handlers request cooperative supervisor
    cancellation and are restored even on collection failure. Explicit cancellation
    works in worker threads as well. The elapsed integer duration includes pipe
    collection, native RSS probes, group teardown and reap, excluding JSON export.
    """
    cancellation = cancellation or SUPERVISOR.Cancellation()
    limits = limits or SUPERVISOR.ProcessLimits(timeout, rss_bytes=8 * 1024 * 1024 * 1024)
    previous = {}
    try:
        if threading.current_thread() is threading.main_thread():
            for value in (signal.SIGINT, signal.SIGTERM):
                previous[value] = signal.signal(value, cancellation.request)
        result = SUPERVISOR.run_process(command, directory, limits, cancellation, cwd=cwd)
    finally:
        for value, handler in previous.items():
            signal.signal(value, handler)
    clean = result["cleanup"]
    if (result["status"] != "completed" or not clean["owner_reaped"] or
            clean["group_has_live_members_after_cleanup"] is True or clean["unexpected_descendants"] or
            any(result["dropped_bytes"].values())):
        raise RuntimeError(f"compiler subprocess {result['status']}; see {directory}")
    return result


def parse_time_resources(output, system):
    """Parse native time RSS and CPU independently; absent CPU remains explicitly unavailable.

    Darwin's user/sys values and Linux's named CPU fields describe the timed
    command and waited descendants. RSS is the largest process observation, not
    the simultaneous aggregate compiler-family working set. Native CPU precision
    is retained; a reported zero is not an unavailable gauge.
    """
    pattern = r"(\d+)\s+maximum resident set size" if system == "Darwin" else r"Maximum resident set size \(kbytes\):\s*(\d+)"
    match = re.search(pattern, output)
    if not match:
        raise RuntimeError("time did not report compiler peak RSS")
    number = r"([0-9]+(?:\.[0-9]+)?)"
    if system == "Darwin":
        cpu = re.search(number + r"\s+real\s+" + number + r"\s+user\s+" + number + r"\s+sys", output)
        user, kernel = (float(cpu.group(2)), float(cpu.group(3))) if cpu else (None, None)
    else:
        user_match = re.search(r"User time \(seconds\):\s*" + number, output)
        system_match = re.search(r"System time \(seconds\):\s*" + number, output)
        user = float(user_match.group(1)) if user_match else None
        kernel = float(system_match.group(1)) if system_match else None
    if any(value is not None and not math.isfinite(value) for value in (user, kernel)):
        raise ValueError("time CPU duration must be finite")
    available = user is not None and kernel is not None
    return {"peakRSSBytes": int(match.group(1)) * (1 if system == "Darwin" else 1024),
            "cpuUserSeconds": user, "cpuSystemSeconds": kernel,
            "cpuSeconds": user + kernel if available else None,
            "cpuUnavailableReason": None if available else "native time output omitted a complete user/system CPU pair",
            "cpuSemantics": "native time user plus system CPU for the timed command and waited descendants; native reporting precision"}


def run_timed(command, timeout, cwd, log_path):
    """Measure gross supervised build lifetime with bounded diagnostics and exact per-command cleanup receipts.

    The shared monotonic interval starts before launch and ends after pipes, probes,
    process group teardown and owner reap; report serialization and RSS parsing are
    excluded. /usr/bin/time still supplies the compiler-family maximum process RSS.
    """
    log_path.parent.mkdir(parents=True, exist_ok=True)
    directory = log_path.parent / (log_path.name + ".process-" + uuid.uuid4().hex)
    wrapper = ["/usr/bin/time", "-l" if platform.system() == "Darwin" else "-v"]
    try:
        result = run_supervised(wrapper + command, timeout, cwd, directory)
    finally:
        # Combined compatibility log and native supervisor logs have finite shared
        # byte budgets; failures retain the same partial diagnostics and receipts.
        with log_path.open("wb") as output:
            for name in ("stdout.log", "stderr.log"):
                source = directory / name
                if source.is_file():
                    with source.open("rb") as stream:
                        shutil.copyfileobj(stream, output, length=65536)
    elapsed_nanoseconds = result["elapsed_ns"]
    if not 0 <= elapsed_nanoseconds <= 2**63 - 1:
        raise ValueError("compiler monotonic duration is out of range")
    with log_path.open("rb") as output:
        output.seek(max(0, log_path.stat().st_size - 65536))
        tail = output.read().decode(errors="replace")
    resources = parse_time_resources(tail, platform.system())
    resources["averageActiveCores"] = resources["cpuSeconds"] / (elapsed_nanoseconds / 1e9) if resources["cpuSeconds"] is not None and elapsed_nanoseconds else None
    resources["averageActiveCoresSemantics"] = "native CPU seconds divided by gross supervised wall seconds; observed utilization, not reserved CPU allocation"
    return {"wallSeconds": elapsed_nanoseconds / 1e9, "wallNanoseconds": elapsed_nanoseconds,
            "wallSemantics": "gross supervised lifetime including collection, RSS probes, group teardown and reap; excludes receipt serialization",
            "processReceipt": str(directory / "process.json"), "command": wrapper + list(command), "workingDirectory": str(cwd),
            "stdoutSHA256": hashlib.sha256((directory / "stdout.log").read_bytes()).hexdigest(),
            **resources}


def capture(command, cwd):
    """Collect finite environment/catalog evidence under the same signal-safe group and diagnostic limits.

    The command's owned temporary artifacts are removed only after shared teardown
    and reap. Returned UTF-8 diagnostics are capped at 16,000 characters after the
    stricter shared byte limit has been enforced; failures never become evidence.
    """
    with tempfile.TemporaryDirectory(prefix="discordkit-compiler-capture-") as temporary:
        directory = Path(temporary) / "process"
        run_supervised(command, 30, cwd, directory,
            limits=SUPERVISOR.ProcessLimits(30, diagnostic_bytes=65536, rss_bytes=8 * 1024 * 1024 * 1024))
        return (directory / "stdout.log").read_text(errors="replace").strip()[:16000]


def run_incremental(source, command, timeout, repository, log_path, timed=run_timed):
    """Make exactly one controlled semantic edit and restore bytes after success or failure."""
    original = source.read_bytes()
    edited = original.replace(b'fixture \\(', b'edited \\(', 1)
    if edited == original:
        raise ValueError("incremental fixture lacks the controlled response literal")
    try:
        source.write_bytes(edited)
        return timed(command, timeout, repository, log_path)
    finally:
        source.write_bytes(original)


def linux_hardware_model(read=None):
    """Read bounded Linux hardware evidence; architecture alone cannot identify a machine model.

    A named controlled host and effective allocation remain separate comparison-driver
    receipts. Missing DMI/device-tree evidence stays unavailable, refusing numerical
    baselines. An injectable reader makes Linux and unavailable cases testable on macOS.
    """
    def bounded_read(path):
        try:
            with Path(path).open("rb") as source:
                payload = source.read(16385)
            return payload.decode("utf-8") if len(payload) <= 16384 else None
        except (OSError, UnicodeError):
            return None

    reader = read or bounded_read
    placeholders = {"unavailable", "unknown", "default string", "system product name", "to be filled by o.e.m."}
    for path in ("/sys/class/dmi/id/product_name", "/sys/firmware/devicetree/base/model"):
        raw = reader(path)
        if raw is None or len(raw.encode("utf-8")) > 16384:
            continue
        value = raw.replace("\u0000", "").strip()
        if value and value.lower() not in placeholders:
            return "linux-model-v1:" + value
    return "unavailable"


def environment(swift, repository):
    """Record current compiler and hardware; compiler evidence must establish Swift 6.4+."""
    compiler = capture([swift, "--version"], repository)
    match = re.search(r"Swift version (\d+)\.(\d+)", compiler)
    if not match or tuple(map(int, match.groups())) < (6, 4):
        raise ValueError("Swift 6.4 or newer is required")
    value = {"compiler": compiler, "operatingSystem": platform.platform(), "architecture": platform.machine(),
             "processorCount": os.cpu_count() or 1}
    if platform.system() == "Darwin":
        value["hardwareModel"] = capture(["/usr/sbin/sysctl", "-n", "hw.model"], repository)
        value["physicalMemoryBytes"] = int(capture(["/usr/sbin/sysctl", "-n", "hw.memsize"], repository))
    else:
        value["hardwareModel"] = linux_hardware_model() if platform.system() == "Linux" else "unavailable"
        value["physicalMemoryBytes"] = os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE")
    return value


def validate_dimensions(counts, module_count, modes=MODES):
    """Reject duplicate/unsupported counts and module fan-out before mutating any workspace."""
    if not counts or len(counts) != len(set(counts)) or any(count not in COUNTS for count in counts):
        raise ValueError("handler counts must be a unique nonempty subset of 10,100,1000")
    if type(module_count) is not int or not 1 <= module_count <= min(counts) // 10:
        raise ValueError("modules exceed the smallest selected consumer file population")
    if not modes or len(modes) != len(set(modes)) or any(mode not in MODES for mode in modes):
        raise ValueError("build paths must be a unique nonempty subset of manual,macro")


def repository_inputs(repository):
    """Bind source names/bytes, manifests and pins without changing the legacy source hash boundary."""
    sources = list((repository / "Sources").rglob("*.swift")) + list((repository / "Packages/DiscordDSLMacros/Sources").rglob("*.swift"))
    named = [repository / path for path in ("Package.swift", "Package.resolved", "Packages/DiscordDSLMacros/Package.swift",
             "Packages/DiscordDSLMacros/Package.resolved", "Tests/Fixtures/DSLCompile/Package.resolved")]
    inputs = sources + [path for path in named if path.is_file()]
    return {"sourceHash": digest_files(sources, repository), "buildInputHash": digest_files(inputs, repository),
            "buildInputFileCount": len(inputs), "buildInputHashIncludes": "root and macro Swift sources plus present root/macro manifests and root/macro/compiler-fixture pins",
            "manifestAndPinHashes": {str(path.relative_to(repository)): hashlib.sha256(path.read_bytes()).hexdigest() for path in named if path.is_file()}}


def run_matrix(repository, workspace, swift, jobs, timeout, samples, cache_path, counts=COUNTS, module_count=1, modes=MODES, include_probes=False):
    """Bootstrap dependencies once, then keep clean/edit subprocess costs separate from runtime.

    Integer monotonic durations and exact fixture/pin/source hashes make Stage 7
    envelope conversion possible without deriving populations from percentiles.
    Optional reduced matrices and module fan-out have distinct configurations.
    """
    validate_dimensions(counts, module_count, modes)
    if jobs not in range(1, 33) or samples not in range(1, 6) or not math.isfinite(timeout) or not 1 <= timeout <= 3600:
        raise ValueError("jobs must be 1...32, samples 1...5 and timeout 1...3600 finite seconds")
    evidence_environment = environment(swift, repository)
    input_identity = repository_inputs(repository)
    revision = capture(["git", "rev-parse", "HEAD"], repository)
    names = prepare_workspace(repository, workspace, counts, module_count, modes)
    scratch = workspace / "build"
    command = [swift, "build", "--disable-sandbox", "--skip-update", "--disable-automatic-resolution",
               "--package-path", str(workspace), "--scratch-path", str(scratch),
               "--cache-path", str(cache_path), "--jobs", str(jobs), "--configuration", "debug", "--build-system", "native",
               "--disable-build-manifest-caching"]
    print("Bootstrapping pinned dependencies" + (" and macro plugin" if "macro" in modes else "") + " (separate from measured consumer builds)", flush=True)
    bootstrap = run_timed(command + ["--target", "Warmup"], timeout, repository, workspace / "logs/bootstrap.log")
    rows = []
    for target in names:
        count = int(re.search(r"\d+", target).group())
        row = {"mode": "macro" if target.startswith("Macro") else "manual", "handlerCount": count, "samples": []}
        first = workspace / "Sources" / target / "Handlers000.swift"
        for sample in range(samples):
            removed = remove_consumer_outputs(scratch, target)
            print(f"Measuring {target} sample {sample + 1}/{samples}: clean consumer", flush=True)
            clean = run_timed(command + ["--product", target], timeout, repository, workspace / f"logs/{target}-{sample}-clean.log")
            probes = {}
            if include_probes:
                probes["noOpBuild"] = run_timed(command + ["--product", target], timeout, repository,
                    workspace / f"logs/{target}-{sample}-noop.log")
                probes["noOpBuild"]["scope"] = "warm no-change SwiftPM invocation including planning/cache validation; not isolated package planning"
                clean_binaries = [path for path in scratch.glob(f"*/debug/{target}") if path.is_file()]
                if len(clean_binaries) != 1:
                    raise RuntimeError(f"missing clean consumer binary for {target}")
                startup = run_timed([str(clean_binaries[0])], timeout, repository, workspace / f"logs/{target}-{sample}-startup.log")
                if startup["stdoutSHA256"] != hashlib.sha256(f"qualified {count} inert declarations\n".encode()).hexdigest():
                    raise RuntimeError(f"cold startup qualification failed for {target}")
                startup["scope"] = "fresh process from clean binary: loader, inert catalog construction, count qualification, output and supervised teardown; no handler invocation; OS file cache not flushed"
                probes["coldStartup"] = startup
            incremental = run_incremental(first, command + ["--product", target], timeout, repository,
                                          workspace / f"logs/{target}-{sample}-incremental.log")
            # Executing validates finite catalog construction only; handlers remain inert.
            binaries = [path for path in scratch.glob(f"*/debug/{target}") if path.is_file()]
            if len(binaries) != 1 or capture([str(binaries[0])], repository) != f"qualified {count} inert declarations":
                raise RuntimeError(f"catalog qualification failed for {target}")
            row["samples"].append({"clean": clean, "incremental": incremental, **probes,
                                   "removedConsumerOutputs": removed, "binaryBytes": binaries[0].stat().st_size,
                                   "binarySHA256": hashlib.sha256(binaries[0].read_bytes()).hexdigest()})
        row["functionalGatesPassed"] = True
        rows.append(row)
    if repository_inputs(repository) != input_identity or capture(["git", "rev-parse", "HEAD"], repository) != revision:
        raise RuntimeError("repository build inputs or revision changed during compiler measurement")
    fixture_files = list((workspace / "Sources").rglob("*.swift"))
    return {"schemaVersion": 1, "reportKind": "dsl-compiler-cost", "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "metricCatalogVersion": 7,
            "configuration": {"handlerCounts": list(counts), "modules": module_count, "extensionPackageInstallations": 0, "modes": list(modes), "jobs": jobs, "samples": samples,
                              "configuration": "debug", "buildSystem": "native", "handlersPerFile": 10, "optionsPerHandler": 1,
                              "timingBoundary": "supervised-process-lifetime-v1",
                              "incrementalEdit": "one response literal in the first ten-handler file", "dependencyColdBuildIncluded": False,
                              **({"additionalProbes": ["no-op-build", "cold-startup"]} if include_probes else {})},
            "environment": evidence_environment, "revision": revision, "repository": str(repository),
            **input_identity, "fixtureHash": digest_files(fixture_files, workspace),
            "resolutionHash": hashlib.sha256((workspace / "Package.resolved").read_bytes()).hexdigest(),
            "bootstrap": bootstrap, "workloads": rows,
            "buildCommand": command,
            "runnerHashes": {"compilerRunner": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                             "processSupervisor": hashlib.sha256(Path(SUPERVISOR.__file__).read_bytes()).hexdigest()},
            "targetInfo": json.loads(capture([swift, "-print-target-info"], repository)),
            "fixtureHashIncludes": "generated Swift sources; manifest separately recorded below",
            "manifestHash": hashlib.sha256((workspace / "Package.swift").read_bytes()).hexdigest(),
            "qualification": {"localOnly": True, "liveDiscordQualified": False, "productionQualified": False,
                              "timingIsolationQualified": False,
                              "processRSSSemantics": "time ru_maxrss is the largest reported process RSS, not simultaneous aggregate compiler-family RSS",
                              "scope": "SwiftPM debug consumer compile/link; warm dependencies; no handler execution or live I/O"}}


def main():
    """Write complete JSON only after the entire matrix succeeds; failed runs exit nonzero."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--workspace", type=Path)
    parser.add_argument("--cache-path", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--timeout", type=float, default=1800)
    parser.add_argument("--samples", type=int, default=1)
    parser.add_argument("--handlers", default="10,100,1000", help="unique comma-separated subset of 10,100,1000")
    parser.add_argument("--modules", type=int, default=1, help="1...smallest handler count/10")
    parser.add_argument("--build-paths", default="manual,macro", help="unique comma-separated subset of manual,macro")
    parser.add_argument("--include-probes", action="store_true", help="record separate no-op SwiftPM and fresh inert-consumer startup probes")
    arguments = parser.parse_args()
    repository = arguments.repository.resolve()
    workspace = (arguments.workspace or repository / ".build/dsl-benchmarks/compiler").resolve()
    try:
        counts = tuple(int(value) for value in arguments.handlers.split(","))
        report = run_matrix(repository, workspace, arguments.swift, arguments.jobs, arguments.timeout, arguments.samples,
                            (arguments.cache_path or repository / ".build/dsl-compile-cache").resolve(), counts, arguments.modules,
                            tuple(arguments.build_paths.split(",")), arguments.include_probes)
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Compiler benchmark failed: {error}\n")


if __name__ == "__main__":
    main()
