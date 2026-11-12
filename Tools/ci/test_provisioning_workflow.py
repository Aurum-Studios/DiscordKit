# File: Tools/ci/test_provisioning_workflow.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Execute provisioning shell boundaries and check every caller's resource scope."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ACTION = ROOT / '.github/actions/setup-native/action.yml'


def shell_blocks():
    return ['\n'.join(line[8:] for line in block.splitlines())
            for block in re.findall(r'      run: \|\n((?:        [^\n]*\n|\n)+)', ACTION.read_text())]


class ProvisioningWorkflowTests(unittest.TestCase):
    def execute_profile(self, profile):
        """Run the real bash bodies using a recording Python shim, never sudo/apt."""
        with tempfile.TemporaryDirectory(prefix='provisioning shell $ ') as temporary:
            directory = Path(temporary)
            commands = directory / 'commands.jsonl'
            shim = directory / 'python'
            shim.write_text('#!' + sys.executable + '\nimport json, os, sys\n'
                            'with open(os.environ["RECORDED_COMMANDS"], "a") as out:\n'
                            '    out.write(json.dumps(sys.argv[1:]) + "\\n")\n')
            shim.chmod(0o755)
            (directory / 'python3').symlink_to(shim)
            environment = {**os.environ, 'PATH': str(directory) + os.pathsep + os.environ['PATH'],
                           'RECORDED_COMMANDS': str(commands), 'NATIVE_PROFILE': profile,
                           'RUNNER_TEMP': str(directory), 'GITHUB_OUTPUT': str(directory / 'output'),
                           'GITHUB_ENV': str(directory / 'environment')}
            results = [subprocess.run(['bash', '-e', '-c', block], env=environment,
                                      capture_output=True, text=True, timeout=10)
                       for block in shell_blocks()[:2]]
            rows = [json.loads(line) for line in commands.read_text().splitlines()] if commands.exists() else []
            return results, rows

    def test_prepare_is_one_literal_command_and_apt_shares_its_deadline(self):
        results, rows = self.execute_profile('build')
        self.assertTrue(all(result.returncode == 0 for result in results), [result.stderr for result in results])
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0][:4], ['Tools/ci/native_provisioning.py', 'prepare', '--platform', 'auto'])
        self.assertIn('--root', rows[0])
        self.assertIn('provisioning shell $ ', rows[0][rows[0].index('--root') + 1])
        self.assertIn('--github-env', rows[0])
        self.assertIn('provisioning shell $ ', rows[0][rows[0].index('--github-env') + 1])
        for command in rows[1:]:
            self.assertEqual(command[:2], ['Tools/ci/native_provisioning.py', 'run'])
            self.assertIn('--plan', command)
            self.assertIn('--', command)
            self.assertEqual(command[command.index('--') + 1:command.index('--') + 3], ['sudo', 'apt-get'])

    def test_runtime_keeps_manifest_compiler_dependencies_and_omits_build_headers(self):
        results, runtime = self.execute_profile('runtime')
        _, build = self.execute_profile('build')
        self.assertTrue(all(result.returncode == 0 for result in results))
        runtime, build = runtime[-1], build[-1]
        for dependency in ('libc6-dev', 'libgcc-13-dev', 'libstdc++-13-dev', 'linux-libc-dev', 'libpython3.12t64'):
            self.assertIn(dependency, runtime)
            self.assertIn(dependency, build)
        for dependency in ('clang', 'libcurl4-openssl-dev', 'libxml2-dev', 'libz3-dev', 'pkg-config'):
            self.assertNotIn(dependency, runtime)
            self.assertIn(dependency, build)
        self.assertNotIn('nodejs', build)

    def test_invalid_profile_stops_before_preparation_or_apt(self):
        results, rows = self.execute_profile('invalid')
        self.assertTrue(all(result.returncode != 0 for result in results))
        self.assertEqual(rows, [])

    def test_every_native_caller_has_an_explicit_profile_and_ten_minute_cap(self):
        callers = 0
        for workflow in (ROOT / '.github/workflows').glob('*.yml'):
            text = workflow.read_text()
            for match in re.finditer(r'(?m)^      - uses: \./\.github/actions/setup-native\n((?:        [^\n]*\n)+)', text):
                callers += 1
                self.assertIn('        timeout-minutes: 10\n', match[1], workflow.name)
                self.assertRegex(match[1], r'          profile: (build|runtime)\n')
            self.assertEqual(text.count('uses: ./.github/actions/setup-native'),
                             len(re.findall(r'(?m)^      - uses: \./\.github/actions/setup-native$', text)))
            self.assertNotIn('uses: swift-actions/setup-swift', text)
        self.assertGreater(callers, 10)
        text = (ROOT / '.github/workflows/native-platform.yml').read_text()
        jobs = dict((match[1], match[2]) for match in re.finditer(
            r'(?ms)^  ([a-z][a-z-]*):\n(.*?)(?=^  [a-z][a-z-]*:\n|\Z)', text))
        for job in ('canary', 'tests-root', 'tests', 'audit', 'package'):
            self.assertIn('profile: runtime', jobs[job], job)
        for job in ('platform', 'plan', 'build', 'build-core', 'build-remaining', 'fixtures', 'public-api', 'apple-compilation'):
            self.assertIn('profile: build', jobs[job], job)

    def test_cache_has_exact_restore_explicit_trusted_save_and_mandatory_verification(self):
        action = ACTION.read_text()
        self.assertIn('uses: actions/cache/restore@v4', action)
        self.assertIn('uses: actions/cache/save@v4', action)
        self.assertIn("steps.provisioning.outputs.cache-save == 'true'", action)
        self.assertIn('DISCORDKIT_DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}', action)
        self.assertIn('native_provisioning.py provision', action)
        self.assertNotIn('restore-keys:', action)
        self.assertNotIn('continue-on-error', action)
        self.assertNotIn('skip-verify-signature', action)
        self.assertNotIn('actions/setup-node', action)
        self.assertIn('actions/setup-node@v6', (ROOT / '.github/actions/setup-artifact-sdk/action.yml').read_text())

    def test_provisioning_artifacts_are_unique_across_reusable_platform_calls(self):
        """The two platform calls reuse static job IDs and restart matrix indices."""
        template = re.search(r'(?m)^        name: (provisioning-.*)$', ACTION.read_text())[1]
        names = []
        for system, architecture in (('Linux', 'X64'), ('macOS', 'ARM64')):
            for job, index in (('platform', ''), ('plan', ''), ('canary', ''),
                               ('build-core', '0'), ('build-core', '1'), ('tests', '0')):
                values = {'runner.os': system, 'runner.arch': architecture,
                          'github.job': job, 'strategy.job-index': index,
                          'github.run_id': '123', 'github.run_attempt': '1'}
                names.append(re.sub(r'\$\{\{ (.*?) \}\}', lambda match: values[match[1]], template))
        self.assertEqual(len(names), len(set(names)))


if __name__ == '__main__':
    unittest.main()
