# File: Tools/ci/test_artifact_workflows.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Execute actual composite-action scripts with local fixtures and no remote writes."""

import json
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]


def scripts(action):
    text = (ROOT / '.github/actions' / action / 'action.yml').read_text()
    return ['\n'.join(line[8:] for line in block.splitlines())
            for block in re.findall(r'      run: \|\n((?:        [^\n]*\n|\n)+)', text)]


class ArtifactWorkflowTests(unittest.TestCase):
    def test_failed_job_rerun_resolves_in_consumer_then_downloads_ids(self):
        """Current consumers resolve their own index rather than using old matrix outputs."""
        with tempfile.TemporaryDirectory(prefix='artifact workflow ') as directory:
            selection = Path(directory) / 'selection.json'
            env = {'NATIVE_PLATFORM': 'macos-arm64', 'NATIVE_COMPONENTS': '["root","macros"]',
                   'NATIVE_SELECTION': str(selection), 'NATIVE_DESTINATION': str(Path(directory) / 'compiled')}
            invocations = []
            def run(arguments, **kwargs):
                self.assertTrue(kwargs['check'])
                invocations.append(arguments)
                if 'resolve' in arguments:
                    selection.write_text(json.dumps({'components': {
                        'root': {'artifactID': '123', 'artifactDigest': 'sha256:' + 'a' * 64},
                        'macros': {'artifactID': '456', 'artifactDigest': 'sha256:' + 'b' * 64}}}))
            with patch.dict(os.environ, env), patch('subprocess.run', side_effect=run):
                for script in scripts('consume-native'):
                    exec(compile(script, 'consume-native/action.yml', 'exec'), {})
            self.assertEqual(len(invocations), 3)
            self.assertIn('resolve', invocations[0])
            self.assertIn('["root","macros"]', invocations[0])
            self.assertEqual({arguments[arguments.index('--artifact-id') + 1] for arguments in invocations[1:]},
                             {'123', '456'})
            self.assertFalse(any(command in ('swift', 'compile', 'test', 'build')
                                 for arguments in invocations for command in arguments))

    def test_upload_uses_existing_files_and_retains_producer_metadata(self):
        """A transfer can only resubmit local files, with literal argv and no test callback."""
        with tempfile.TemporaryDirectory(prefix='artifact upload $ ') as directory:
            archive = Path(directory) / 'root.tar.gz'
            archive.write_bytes(b'unchanged compiled bytes')
            env = {'TRANSFER_NAME': 'compiled-source-run-attempt', 'TRANSFER_PATHS': str(archive),
                   'TRANSFER_RECEIPT': str(Path(directory) / 'receipt.json'), 'TRANSFER_RETENTION': '2',
                   'PRODUCER_METADATA': 'compilation.json', 'PRODUCER_RECEIPT_NAME': 'compiled-receipt',
                   'GITHUB_OUTPUT': str(Path(directory) / 'output')}
            with patch.dict(os.environ, env), patch('subprocess.run') as run:
                exec(compile(scripts('upload-evidence')[-1], 'upload-evidence/action.yml', 'exec'), {})
            run.assert_not_called()
            arguments = json.loads(Path(env['GITHUB_OUTPUT']).read_text().split('=', 1)[1])
            self.assertEqual(arguments[0], 'upload')
            self.assertEqual(arguments[arguments.index('--path') + 1], str(archive))
            self.assertEqual(arguments[arguments.index('--producer-metadata') + 1], 'compilation.json')
            self.assertEqual(archive.read_bytes(), b'unchanged compiled bytes')

    def test_upload_launches_a_javascript_action_for_runtime_credentials(self):
        text = (ROOT / '.github/actions/upload-evidence/action.yml').read_text()
        self.assertIn('uses: ./.github/actions/artifact-transfer', text)
        self.assertIn('arguments: ${{ steps.arguments.outputs.arguments }}', text)
        launcher = (ROOT / '.github/actions/artifact-transfer/action.yml').read_text()
        self.assertIn('using: node24', launcher)

    def test_missing_local_evidence_fails_before_transfer(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict(os.environ, {'TRANSFER_PATHS': directory + '/absent/*'}), patch('subprocess.run') as run:
                with self.assertRaisesRegex(SystemExit, 'explicitly regenerate'):
                    exec(compile(scripts('upload-evidence')[-1], 'upload-evidence/action.yml', 'exec'), {})
                run.assert_not_called()

    def test_workflow_has_complete_index_and_fresh_barrier_without_attempt_downloads(self):
        text = (ROOT / '.github/workflows/native-platform.yml').read_text()
        self.assertNotIn('actions/download-artifact', text)
        self.assertNotIn('actions/upload-artifact', text)
        self.assertNotIn('continue-on-error', text)
        self.assertIn('needs: [plan, canary, build-core, build-remaining, tests-root]', text)
        self.assertIn('name: Builds / ${{ matrix.platform }} / ${{ matrix.component }}', text)
        self.assertEqual(text.count('--selection .build/artifact-index.json'), 5)
        self.assertEqual(text.count("'--components-json', os.environ['EXPECTED_BUILDS']"), 3)
        self.assertIn('if: always()\n    needs: [platform, plan, build, canary, build-core, build-remaining, resolve', text)
        self.assertEqual(text.count('uses: ./.github/actions/upload-evidence'), text.count('          receipt:'))


if __name__ == '__main__':
    unittest.main()
