#!/usr/bin/env python3
# File: Docs/Tasks/ci-reliability/phase-9/checks/real-docc/replay.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Replay a real local DocC seal/consume/static-route smoke without Swift builds."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urljoin, urlsplit


ROOT = Path(__file__).resolve().parents[6]
sys.path.insert(0, str(ROOT / "Tools/ci"))

import build_docc
import build_documentation_site as site
import documentation_inputs as inputs
import native_jobs
import native_receipts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".build/phase9-real-docc")
    arguments = parser.parse_args()
    output = arguments.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    tested_files = ["Tools/ci/" + name + ".py" for name in (
        "build_docc", "build_documentation_site", "documentation_inputs", "native_jobs",
        "native_receipts", "artifact_index", "artifact_transfer")]
    tested_hashes = {name: native_jobs.file_digest(ROOT / name) for name in tested_files}
    fixture = output / "fixture"
    fixture.mkdir()
    commands = []
    log = (output / "run.log").open("w")

    def execute(argv, cwd=fixture, stage="prepare"):
        argv = list(map(str, argv))
        commands.append({"stage": stage, "argv": argv})
        log.write("+ " + json.dumps(argv) + "\n")
        log.flush()
        result = subprocess.run(argv, cwd=cwd, check=False, capture_output=True,
                                text=True, timeout=120)
        log.write(result.stdout + result.stderr)
        log.flush()
        result.check_returncode()
        return result.stdout

    try:
        docc = subprocess.check_output(["xcrun", "--find", "docc"], text=True,
                                       timeout=30).strip()
        version = execute(["xcodebuild", "-version"], stage="toolchain").strip()
        components = {"root": "DiscordKit", "macros": "DiscordDSLMacros",
                      "extensions": "DiscordDSLExtensions"}
        for component, module in components.items():
            package = fixture / inputs.PACKAGES[component]
            catalog = package / "Sources" / module / (module + ".docc")
            catalog.mkdir(parents=True)
            (catalog / (module + ".md")).write_text(
                "# ``" + module + "``\n\nSynthetic Phase 9 documentation.\n")
        (fixture / ".gitignore").write_text(".build/\n")
        execute(["git", "init", "--quiet"])
        execute(["git", "add", "."])
        execute(["git", "-c", "user.name=Phase 9 fixture", "-c",
                 "user.email=phase9-fixture@example.invalid", "commit", "--quiet",
                 "-m", "Create synthetic documentation source"])
        source = native_jobs.source_identity(fixture)
        execution = native_receipts.execution_identity(fixture)
        sealed = []
        for component, module in components.items():
            package = fixture / inputs.PACKAGES[component]
            graphs = output / "graphs" / component
            graphs.mkdir(parents=True)
            (graphs / (module + ".symbols.json")).write_text(json.dumps({
                "metadata": {"formatVersion": {"major": 0, "minor": 6, "patch": 0},
                             "generator": "DiscordKit Phase 9 synthetic fixture"},
                "module": {"name": module, "platform": {"architecture": "arm64",
                           "vendor": "apple", "operatingSystem": {"name": "macosx"}}},
                "symbols": [], "relationships": []}))
            converted = output / "converted" / component
            converted.mkdir(parents=True)
            archive = converted / (module + ".doccarchive")
            execute(build_docc.conversion_command(docc, package, archive, module, graphs))
            merged = converted / "DiscordKitLibrary.doccarchive"
            execute(build_docc.merge_command(docc, [archive], merged))
            (converted / "build-report.json").write_text(json.dumps({
                "modules": [module], "archiveCount": 1, "warningsAsErrors": True,
                "analyze": True, "publicSymbolsOnly": True, "failedModules": [],
                "mergeStatus": "succeeded", "mergedArchive": merged.name,
                "limits": "Synthetic local DocC smoke; no native or hosted qualification."}))
            sealed_archive = output / "sealed" / (component + ".tar.gz")
            inputs.seal(fixture, component, converted, sealed_archive,
                        output / "sealed" / (component + ".json"),
                        source=source, execution=execution)
            sealed.append(sealed_archive)
        original_run = site.run
        site.run = lambda argv, repository: execute(argv, repository, "consume")
        try:
            site.build_site(fixture, output / "site", docc, "/Phase9Fixture",
                            sealed_inputs=sealed)
        finally:
            site.run = original_run
        exported = output / "site"
        routes = ["documentation/index.html", *[
            "documentation/" + module.lower() + "/index.html"
            for module in components.values()]]
        for route in routes:
            assert (exported / route).is_file(), route
        redirect = (exported / "index.html").read_text()
        assert 'href="documentation/"' in redirect
        assert urljoin("https://example.invalid/Phase9Fixture/", "documentation/") == \
            "https://example.invalid/Phase9Fixture/documentation/"
        assert (exported / ".nojekyll").is_file()
        assert (exported / site.MARKER).read_text() == site.MARKER_CONTENT
        landing = json.loads((exported / "data/documentation.json").read_text())
        documentation_links = sorted(reference["url"] for reference in
            landing["references"].values() if reference.get("type") == "topic")
        assert documentation_links == sorted("/documentation/" + module.lower()
                                             for module in components.values())
        for reference in documentation_links:
            assert (exported / reference.lstrip("/") / "index.html").is_file()
        asset_links = set()
        for route in routes:
            page = (exported / route).read_text()
            for reference in re.findall(r'(?:src|href)="(/[^\"]+)"', page):
                path = urlsplit(reference).path
                assert path.startswith("/Phase9Fixture/"), reference
                assert (exported / path.removeprefix("/Phase9Fixture/")).is_file(), reference
                asset_links.add(reference)
        assert asset_links
        consumed = [row["argv"] for row in commands if row["stage"] == "consume"]
        assert len(consumed) == 2
        assert consumed[0][1] == "merge"
        assert consumed[1][1:3] == ["process-archive", "transform-for-static-hosting"]
        assert consumed[1][-2:] == ["--hosting-base-path", "/Phase9Fixture"]
        assert not any(Path(argv[0]).name == "swift" for argv in
                       [row["argv"] for row in commands])
        assert tested_hashes == {name: native_jobs.file_digest(ROOT / name) for name in tested_files}
        summary = {"schemaVersion": 1, "status": "passed", "xcodeVersion": version,
            "doccSHA256": native_jobs.file_digest(Path(docc)),
            "qualification": "Local synthetic DocC transport and rendered static routes only",
            "nativeCompilationCount": 0, "symbolGraphEmissionCount": 0,
            "syntheticGraphFixtureCount": 3,
            "strictModuleConversionCount": sum(row["argv"][1:2] == ["convert"] for row in commands),
            "packageMergeCount": sum(row["stage"] == "prepare" and row["argv"][1:2] == ["merge"] for row in commands),
            "consumerCommandCount": len(consumed), "consumerMergeCount": 1,
            "consumerStaticTransformCount": 1, "consumerCompilationCount": 0,
            "consumerGraphEmissionCount": 0, "consumerConversionCount": 0,
            "hostingBasePath": "/Phase9Fixture", "routes": routes,
            "checkedDocumentationLinks": documentation_links,
            "checkedAssetLinks": sorted(asset_links), "rootRedirectChecked": True,
            "sourceIdentityAndSealedHashesChecked": True,
            "testedInputs": tested_hashes,
            "commands": commands}
        (output / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps({key: value for key, value in summary.items() if key != "commands"}, indent=2))
    finally:
        log.close()


if __name__ == "__main__":
    main()
