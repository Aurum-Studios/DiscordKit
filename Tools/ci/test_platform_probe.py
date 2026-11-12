# File: Tools/ci/test_platform_probe.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Exercise admission failure paths without claiming hosted platform qualification."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import platform_probe


class PlatformProbeTests(unittest.TestCase):
    """A probe must really execute and retain diagnostics on every failed boundary."""

    def run_probe(self, run, identity=None, compatibility_error=None):
        """Run with injected compiler commands and return the durable probe result."""
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with patch.object(platform_probe, "native_preflight"), \
                    patch.object(platform_probe, "build_compatibility_facts", return_value={
                        "exact": {"fixture": "native"}, "informational": {}}, side_effect=compatibility_error), \
                    patch.object(platform_probe.subprocess, "run", side_effect=run), \
                    patch.dict(os.environ, identity or {"RUNNER_OS": "Linux", "RUNNER_ARCH": "X64"}):
                try:
                    platform_probe.probe(directory, directory / "evidence", "linux-x64")
                except (ValueError, subprocess.SubprocessError):
                    pass
            return json.loads((directory / "evidence/probe.json").read_text())

    def test_compile_success_requires_the_runtime_roundtrip(self):
        """A compiler exit alone cannot qualify the host's installed Swift runtime."""
        calls = []

        def run(arguments, **options):
            """Record bounded children and report the expected executable output."""
            calls.append(arguments)
            self.assertEqual(options["timeout"], 120)
            self.assertTrue(options["check"])
            return subprocess.CompletedProcess(arguments, 0,
                "DiscordKit native probe passed\n" if len(calls) == 2 else "", "")

        record = self.run_probe(run)
        self.assertEqual(record["status"], "passed")
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][0], "swiftc")

    def test_unexpected_runtime_output_denies_admission(self):
        """A stale or incorrect executable must not admit expensive build jobs."""
        record = self.run_probe(lambda args, **kw: subprocess.CompletedProcess(args, 0, "", ""))
        self.assertEqual(record["status"], "failed")
        self.assertEqual(record["commands"][-1]["status"], "failed")

    def test_compile_failure_is_retained_and_never_executes(self):
        """Compiler/linker failures remain visible and cannot fall through to execution."""
        record = self.run_probe(lambda args, **kw: (_ for _ in ()).throw(
            subprocess.CalledProcessError(1, args, output="compile failed", stderr="linker failure")))
        self.assertEqual(record["status"], "failed")
        self.assertEqual(len(record["commands"]), 1)

    def test_compile_and_runtime_timeouts_deny_admission(self):
        """A deadline at either child leaves a terminal failure and stops later work."""
        for timed_out_command in ("compile", "execute"):
            with self.subTest(command=timed_out_command):
                calls = []

                def run(arguments, **options):
                    """Time out the selected boundary after recording the actual deadline."""
                    calls.append(arguments)
                    command = "compile" if arguments[0] == "swiftc" else "execute"
                    if command == timed_out_command:
                        raise subprocess.TimeoutExpired(arguments, options["timeout"])
                    return subprocess.CompletedProcess(arguments, 0, "", "")

                record = self.run_probe(run)
                self.assertEqual(record["status"], "failed")
                self.assertIn("timed out after 120 seconds", record["error"])
                self.assertEqual(record["commands"][-1]["name"], timed_out_command)
                self.assertEqual(record["commands"][-1]["status"], "failed")
                expected_count = 1 if timed_out_command == "compile" else 2
                self.assertEqual(len(calls), expected_count)
                self.assertEqual(len(record["commands"]), expected_count)
                if timed_out_command == "execute":
                    self.assertEqual(record["commands"][0]["status"], "passed")

    def test_assigned_runner_mismatch_stops_before_compilation(self):
        """Group routing cannot override the observed and assigned platform identities."""
        record = self.run_probe(lambda *args, **kw: self.fail("must not compile"),
                                {"RUNNER_OS": "Windows", "RUNNER_ARCH": "X64"})
        self.assertEqual(record["status"], "failed")
        self.assertEqual(record["commands"], [])

    def test_unavailable_build_compatibility_stops_before_compilation(self):
        """Unknown compatibility facts cannot fall through to the successful probe."""
        record = self.run_probe(lambda *args, **kw: self.fail("must not compile"),
                                compatibility_error=ValueError("required SDK unavailable"))
        self.assertEqual(record["status"], "failed")
        self.assertEqual(record["commands"], [])
        self.assertIn("required SDK unavailable", record["error"])


class BuildCompatibilityFactsTests(unittest.TestCase):
    """Required OS/runtime/compiler/image/SDK identities never use guessed values."""

    def facts(self, target="linux-x64", *, environment=None, overrides=None,
              target_info=None, system_release="fixture-kernel", system_version="fixture-build",
              distribution=None, query=None):
        """Inject native observations while keeping metadata command arguments literal."""
        system, architecture, triple = {
            "linux-x64": ("Linux", "x86_64", "x86_64-unknown-linux-gnu"),
            "macos-arm64": ("Darwin", "arm64", "arm64-apple-macosx26.0"),
            "windows-x64": ("Windows", "AMD64", "x86_64-unknown-windows-msvc"),
        }[target]
        info = target_info if target_info is not None else {
            "compilerVersion": "Swift version 6.4.1 (fixture)",
            "target": {"triple": triple, "unversionedTriple": triple, "moduleTriple": triple},
            "paths": {"runtimeLibraryPaths": ["/toolchain/lib/swift"],
                      "runtimeLibraryImportPaths": ["/toolchain/lib/swift"],
                      "runtimeResourcePath": "/toolchain/lib/swift"}}
        outputs = {
            ("swift", "--version"): "Swift version 6.4.1 (fixture)\nTarget: " + triple,
            ("swift", "-print-target-info"): json.dumps(info),
            ("ldd", "--version"): "ldd (Ubuntu GLIBC 2.39-0ubuntu8.7) 2.39\nCopyright fixture",
            ("sw_vers", "-productVersion"): "26.1",
            ("sw_vers", "-buildVersion"): "25B78",
            ("xcode-select", "-p"): "/Applications/Xcode.app/Contents/Developer",
            ("xcodebuild", "-version"): "Xcode 26.1\nBuild version 17B55",
            ("xcrun", "--sdk", "macosx", "--show-sdk-path"): "/Applications/Xcode.app/SDKs/MacOSX26.1.sdk",
            ("xcrun", "--sdk", "macosx", "--show-sdk-version"): "26.1",
            ("xcrun", "--sdk", "macosx", "--show-sdk-build-version"): "25B78",
        }
        outputs.update(overrides or {})

        def observe(arguments):
            """Map each expected metadata query to a complete, observed response."""
            if arguments[0] == "powershell":
                self.assertIn("ucrtbase.dll", arguments[-1])
                return "10.0.26100.4061"
            return outputs[tuple(arguments)]

        with patch.dict(os.environ, environment or {}, clear=True), \
                patch.object(platform_probe.platform, "system", return_value=system), \
                patch.object(platform_probe.platform, "machine", return_value=architecture), \
                patch.object(platform_probe.platform, "release", return_value=system_release), \
                patch.object(platform_probe.platform, "version", return_value=system_version), \
                patch.object(platform_probe.platform, "freedesktop_os_release", return_value=(
                    distribution if distribution is not None else {"ID": "ubuntu", "VERSION_ID": "24.04"})):
            return platform_probe.build_compatibility_facts(Path.cwd(), target, query=query or observe)

    def test_linux_runtime_and_compiler_target_have_exact_observed_facts(self):
        """Exact compiler/runtime facts are present even on an unmanaged local image."""
        facts = self.facts()
        exact = facts["exact"]
        self.assertEqual(exact["policyVersion"], 1)
        self.assertEqual(exact["osRuntime"], {"distributionID": "ubuntu", "distributionVersion": "24.04",
                                           "libc": "ldd (Ubuntu GLIBC 2.39-0ubuntu8.7) 2.39"})
        self.assertEqual(exact["swiftTarget"], "x86_64-unknown-linux-gnu")
        self.assertEqual(exact["image"], {"kind": "unmanaged"})
        self.assertIsNone(exact["xcode"])

    def test_image_os_and_version_are_exact_but_release_url_and_runner_are_informational(self):
        """Changing image IDs invalidates compatibility; diagnostic labels do not."""
        environment = {"GITHUB_ACTIONS": "true", "ImageOS": "ubuntu24", "ImageVersion": "20261110.1",
                       "ImageRelease": "https://example.invalid/image/first", "RUNNER_NAME": "producer"}
        producer = self.facts(environment=environment)
        consumer = self.facts(environment={**environment, "ImageRelease": "https://example.invalid/image/second",
                                          "RUNNER_NAME": "consumer"})
        self.assertEqual(producer["exact"], consumer["exact"])
        self.assertNotEqual(producer["informational"], consumer["informational"])
        changed = self.facts(environment={**environment, "ImageVersion": "20261111.1"})
        self.assertNotEqual(producer["exact"], changed["exact"])

    def test_missing_partial_or_placeholder_hosted_image_fails_closed(self):
        """Hosted runners cannot borrow the explicit local unmanaged-image policy."""
        for environment in ({"GITHUB_ACTIONS": "true"}, {"ImageOS": "ubuntu24"},
                            {"ImageOS": "ubuntu24", "ImageVersion": "unknown"},
                            {"ImageOS": "", "ImageVersion": "20261110.1"}):
            with self.subTest(environment=environment), self.assertRaisesRegex(ValueError, "Image"):
                self.facts(environment=environment)

    def test_missing_os_and_runtime_identity_fails_closed(self):
        """A matching Swift compiler does not substitute for native runtime facts."""
        for options in ({"system_release": ""}, {"system_version": "unknown"},
                        {"distribution": {"ID": "ubuntu"}},
                        {"distribution": {"ID": "ubuntu", "VERSION_ID": "22.04"}},
                        {"overrides": {("ldd", "--version"): "unknown"}},
                        {"overrides": {("ldd", "--version"): "musl libc version 1.2"}}):
            with self.subTest(options=options), self.assertRaises(ValueError):
                self.facts(**options)

    def test_missing_target_or_runtime_paths_fail_closed(self):
        """Target JSON is validated before it becomes an equality-bearing identity."""
        for info in ({}, {"compilerVersion": "unknown"},
                     {"compilerVersion": "Swift version 6.4.1", "target": {"triple": "unknown"}},
                     {"compilerVersion": "Swift version 6.4.1", "target": {
                         "triple": "x86_64-unknown-linux-gnu", "moduleTriple": "x86_64-unknown-linux-gnu",
                         "unversionedTriple": "x86_64-unknown-linux-gnu"}, "paths": {
                         "runtimeLibraryPaths": [], "runtimeLibraryImportPaths": [], "runtimeResourcePath": ""}}):
            with self.subTest(info=info), self.assertRaises(ValueError):
                self.facts(target_info=info)

    def test_wrong_compiler_or_target_never_yields_compatibility(self):
        """Cross-target output and compiler drift require explicit regeneration."""
        with self.assertRaisesRegex(ValueError, "expected Swift"):
            self.facts(overrides={("swift", "--version"): "Swift version 6.4.0"})
        info = self.facts()["exact"]["swiftTargetInfo"]
        info["target"]["triple"] = "arm64-apple-macosx26.0"
        with self.assertRaisesRegex(ValueError, "Swift target does not match"):
            self.facts(target_info=info)

    def test_macos_requires_complete_xcode_and_sdk_identity(self):
        """Developer-directory, compiler selection and SDK version/build/path are exact."""
        facts = self.facts("macos-arm64")
        exact = facts["exact"]
        self.assertEqual(exact["osRuntime"], {"productVersion": "26.1", "buildVersion": "25B78"})
        self.assertEqual(exact["xcode"]["sdkVersion"], "26.1")
        self.assertEqual(exact["xcode"]["sdkBuildVersion"], "25B78")
        required_commands = (("sw_vers", "-productVersion"), ("sw_vers", "-buildVersion"),
                             ("xcode-select", "-p"), ("xcodebuild", "-version"),
                             ("xcrun", "--sdk", "macosx", "--show-sdk-path"),
                             ("xcrun", "--sdk", "macosx", "--show-sdk-version"),
                             ("xcrun", "--sdk", "macosx", "--show-sdk-build-version"))
        for command in required_commands:
            with self.subTest(command=command), self.assertRaises(ValueError):
                self.facts("macos-arm64", overrides={command: ""})
        changed = self.facts("macos-arm64", overrides={
            ("xcrun", "--sdk", "macosx", "--show-sdk-build-version"): "25B99"})
        self.assertNotEqual(exact, changed["exact"])
        changed = self.facts("macos-arm64", environment={"SDKROOT": "/different/MacOSX26.1.sdk"})
        self.assertNotEqual(exact, changed["exact"])
        with self.assertRaisesRegex(ValueError, "DEVELOPER_DIR"):
            self.facts("macos-arm64", environment={"DEVELOPER_DIR": "unknown"})

    def test_macos_uses_supported_native_os_version_queries(self):
        """The platform tool supports separate version queries rather than a plist switch."""
        commands = []

        def query(arguments):
            """Observe real collector arguments while providing the native OS responses."""
            commands.append(arguments)
            if arguments == ["sw_vers", "-productVersion"]:
                return "26.1"
            if arguments == ["sw_vers", "-buildVersion"]:
                return "25B78"
            if arguments == ["swift", "--version"]:
                return "Swift version 6.4.1 (fixture)"
            if arguments == ["swift", "-print-target-info"]:
                return json.dumps({"compilerVersion": "Swift version 6.4.1", "target": {
                    "triple": "arm64-apple-macosx26.0", "unversionedTriple": "arm64-apple-macosx",
                    "moduleTriple": "arm64-apple-macos"}, "paths": {
                    "runtimeLibraryPaths": ["/swift"], "runtimeLibraryImportPaths": ["/swift"],
                    "runtimeResourcePath": "/swift"}})
            if arguments[0] == "sw_vers":
                self.fail("unsupported sw_vers query")
            return "fixture"

        facts = self.facts("macos-arm64", query=query)
        self.assertEqual(facts["exact"]["osRuntime"], {"productVersion": "26.1", "buildVersion": "25B78"})
        self.assertNotIn(["sw_vers", "-plist"], commands)

    def test_windows_collects_native_ucrt_file_version(self):
        """The Windows runtime is an exact observed file version, including local runs."""
        facts = self.facts("windows-x64")
        self.assertEqual(facts["exact"]["osRuntime"], {"ucrtVersion": "10.0.26100.4061"})

    def test_unbounded_metadata_and_child_timeouts_fail_closed(self):
        """Oversize output and query deadlines cannot produce partial usable identities."""
        with self.assertRaises(ValueError):
            self.facts(overrides={("swift", "--version"): "x" * (128 * 1024 + 1)})
        with self.assertRaises(subprocess.TimeoutExpired):
            self.facts(query=lambda arguments: (_ for _ in ()).throw(subprocess.TimeoutExpired(arguments, 30)))

    def test_standalone_helper_uses_shared_bounded_metadata_supervision(self):
        """Callers without an enclosing report still use process-tree cleanup and deadlines."""
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(platform_probe, "metadata_query", side_effect=RuntimeError("supervised")) as query, \
                patch.object(platform_probe.platform, "system", return_value="Linux"), \
                patch.object(platform_probe.platform, "machine", return_value="x86_64"):
            repository = Path(temporary)
            with self.assertRaisesRegex(RuntimeError, "supervised"):
                platform_probe.build_compatibility_facts(repository, "linux-x64")
            self.assertEqual(query.call_args.args[0], ["swift", "--version"])
            self.assertEqual(query.call_args.args[1], repository)
            self.assertEqual(query.call_args.args[3], "build-fact-1")


class VerifiedProvisioningFactsTests(unittest.TestCase):
    """Cold/hit provenance cannot change compatibility or permit a shadow compiler."""

    def fixture(self, path, hit=False):
        import hashlib
        import native_provisioning as provisioning
        policy = provisioning.load_policy()
        distribution = policy['platforms']['linux-x64']
        triple = 'x86_64-unknown-linux-gnu'
        info = {'compilerVersion': 'Swift version 6.4.1 (fixture)',
                'target': {'triple': triple, 'unversionedTriple': triple, 'moduleTriple': triple},
                'paths': {'runtimeLibraryPaths': ['/toolchain/lib/swift'],
                          'runtimeLibraryImportPaths': ['/toolchain/lib/swift'],
                          'runtimeResourcePath': '/toolchain/lib/swift'}}
        image = {'system': 'Linux', 'architecture': 'x86_64', 'release': 'fixture-kernel',
                 'version': 'fixture-build', 'imageOS': 'ubuntu24', 'imageVersion': '20261112.1',
                 'distribution': {'id': 'ubuntu', 'version': '24.04'}}
        return {'schemaVersion': 1, 'status': 'passed', 'platform': 'linux-x64',
                'policySHA256': hashlib.sha256(provisioning.canonical(policy)).hexdigest(),
                'distribution': {'url': distribution['distributionURL'], 'sha256': distribution['distributionSHA256']},
                'verification': {'method': distribution['signature'], 'signatureVerified': True,
                                 'sha256': distribution['distributionSHA256'],
                                 'signer': distribution['signerFingerprints'][0]},
                'image': image,
                'cache': {'hit': hit, 'key': provisioning.compatibility_key(policy, 'linux-x64', image)},
                'binPath': distribution['installationPath'] + '/usr/bin',
                'swiftVersion': 'Swift version 6.4.1 (fixture)\nTarget: ' + triple, 'targetInfo': info}

    def facts(self, path, record, *, shadow=False):
        path.write_text(json.dumps(record))
        environment = {'DISCORDKIT_PROVISIONING_RECEIPT': str(path), 'ImageOS': 'ubuntu24',
                       'ImageVersion': '20261112.1'}
        def which(name):
            return ('/shadow/bin/' if shadow else record['binPath'] + '/') + name
        with patch.object(platform_probe.shutil, 'which', side_effect=which):
            return BuildCompatibilityFactsTests().facts(environment=environment)

    def test_cold_and_cache_hit_have_identical_exact_phase4_compatibility(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'provisioning.json'
            cold = self.facts(path, self.fixture(path))
            hit = self.facts(path, self.fixture(path, hit=True))
        self.assertEqual(cold['exact'], hit['exact'])
        self.assertFalse(cold['informational']['provisioning']['cacheHit'])
        self.assertTrue(hit['informational']['provisioning']['cacheHit'])

    def macos_facts(self, path, *, ending="", changed=None):
        """Compare a stripped installer receipt against the raw metadata collector."""
        import native_provisioning as provisioning
        policy = provisioning.load_policy()
        distribution = policy['platforms']['macos-arm64']
        environment = {'ImageOS': 'macos26', 'ImageVersion': '20261112.1'}
        baseline = BuildCompatibilityFactsTests().facts('macos-arm64', environment=environment)['exact']
        image = {'system': 'Darwin', 'architecture': 'arm64', 'release': baseline['release'],
                 'version': baseline['version'], 'imageOS': environment['ImageOS'],
                 'imageVersion': environment['ImageVersion'], 'xcode': baseline['xcode']}
        record = self.fixture(path)
        record.update(platform='macos-arm64', image=image,
                      distribution={'url': distribution['distributionURL'], 'sha256': distribution['distributionSHA256']},
                      verification={'method': distribution['signature'], 'signatureVerified': True,
                                    'sha256': distribution['distributionSHA256'], 'signer': distribution['signer']},
                      cache={'hit': False, 'key': provisioning.compatibility_key(policy, 'macos-arm64', image)},
                      binPath=str(Path.home() / 'Library/Developer/Toolchains' /
                                  distribution['toolchainDirectory'] / 'usr/bin'),
                      swiftVersion=baseline['swiftVersion'], targetInfo=baseline['swiftTargetInfo'])
        path.write_text(json.dumps(record))
        environment['DISCORDKIT_PROVISIONING_RECEIPT'] = str(path)
        queries = {('xcode-select', '-p'): 'developerDirectory',
                   ('xcodebuild', '-version'): 'version',
                   ('xcrun', '--sdk', 'macosx', '--show-sdk-path'): 'sdkPath',
                   ('xcrun', '--sdk', 'macosx', '--show-sdk-version'): 'sdkVersion',
                   ('xcrun', '--sdk', 'macosx', '--show-sdk-build-version'): 'sdkBuildVersion'}
        outputs = {query: baseline['xcode'][field] + ending for query, field in queries.items()}
        outputs.update(changed or {})
        with patch.object(platform_probe.shutil, 'which', side_effect=lambda name: record['binPath'] + '/' + name):
            return BuildCompatibilityFactsTests().facts('macos-arm64', environment=environment, overrides=outputs)

    def test_macos_verified_receipt_accepts_raw_stdout_terminators(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'provisioning.json'
            clean = self.macos_facts(path)
            for ending in ('\n', '\r\n'):
                with self.subTest(ending=ending):
                    raw = self.macos_facts(path, ending=ending)
                    self.assertEqual(raw, clean)
            self.assertIn('provisioning', clean['informational'])

    def test_macos_verified_receipt_rejects_changed_sdk_or_xcode(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'provisioning.json'
            changes = {('xcrun', '--sdk', 'macosx', '--show-sdk-path'): '/SDKs/different.sdk\n',
                       ('xcrun', '--sdk', 'macosx', '--show-sdk-version'): '27.0\n',
                       ('xcrun', '--sdk', 'macosx', '--show-sdk-build-version'): 'different-build\n',
                       ('xcode-select', '-p'): '/Applications/DifferentXcode.app/Contents/Developer\n',
                       ('xcodebuild', '-version'): 'Xcode 27.0\nBuild version 18A1\n'}
            for query, value in changes.items():
                with self.subTest(query=query), self.assertRaisesRegex(ValueError, 'another image or SDK'):
                    self.macos_facts(path, ending='\n', changed={query: value})

    def test_failed_unsigned_stale_wrong_image_and_shadowed_receipts_fail(self):
        mutations = (lambda r: r.update(status='failed'),
                     lambda r: r.update(platform='macos-arm64'),
                     lambda r: r['distribution'].update(sha256='0'*64),
                     lambda r: r['verification'].update(signatureVerified=False),
                     lambda r: r['verification'].update(signer='untrusted'),
                     lambda r: r['image'].update(imageVersion='stale'),
                     lambda r: r.update(swiftVersion='Swift version 6.4.0'))
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'provisioning.json'
            for mutate in mutations:
                record = self.fixture(path)
                mutate(record)
                with self.subTest(record=record), self.assertRaises(ValueError):
                    self.facts(path, record)
            with self.assertRaisesRegex(ValueError, 'active compiler'):
                self.facts(path, self.fixture(path), shadow=True)
            for record in ([], {}, {'verification': []}):
                with self.subTest(record=record), self.assertRaises(ValueError):
                    self.facts(path, record)


if __name__ == "__main__":
    unittest.main()
