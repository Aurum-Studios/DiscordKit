# File: Tools/ci/test_documentation_workflow.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Check immutable documentation outputs, safe packaging and bounded consumer plans."""

import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import build_documentation_site as site
import documentation_workflow as workflow


class DocumentationWorkflowTests(unittest.TestCase):
    def test_only_verified_uploads_can_publish_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipt, output = root / 'transfer.json', root / 'output'
            record = {'operation': 'upload', 'status': 'verified',
                      'artifact': {'id': '14', 'name': 'documentation-inputs-t1', 'digest': 'sha256:' + 'b' * 64}}
            env = {'GITHUB_SHA': 'a' * 40, 'GITHUB_RUN_ID': '42', 'GITHUB_RUN_ATTEMPT': '2'}
            with patch.dict(os.environ, env):
                for changed in ({'status': 'failed'}, {'operation': 'download'},
                                {'artifact': dict(record['artifact'], digest='bad')},
                                {'artifact': dict(record['artifact'], id=True)}):
                    receipt.write_text(json.dumps({**record, **changed}))
                    with self.assertRaises(ValueError):
                        workflow.artifact_output(receipt, output)
                    self.assertFalse(output.exists())
                receipt.write_text(json.dumps(record))
                value = workflow.artifact_output(receipt, output)
                self.assertEqual(value['producerAttempt'], '2')
                self.assertEqual(json.loads(output.read_text().split('=', 1)[1]), value)

    def test_site_archive_preserves_hidden_files_and_rejects_links_or_missing_pages(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, archive = root / 'site', root / 'site.tar.gz'
            (source / 'documentation').mkdir(parents=True)
            (source / 'index.html').write_text(site.ROOT_REDIRECT)
            (source / 'documentation/index.html').write_text('library')
            (source / '.nojekyll').touch()
            (source / site.MARKER).write_text(site.MARKER_CONTENT)
            workflow.export_site(source, archive)
            with tarfile.open(archive) as transport:
                self.assertIn('site/.nojekyll', transport.getnames())
                self.assertIn('site/' + site.MARKER, transport.getnames())
            with self.assertRaises(ValueError):
                workflow.export_site(source, archive)
            archive.unlink()
            (source / 'link').symlink_to('index.html')
            with self.assertRaises(ValueError):
                workflow.export_site(source, archive)
            self.assertFalse(archive.exists())
            (source / 'link').unlink()
            (source / 'documentation/index.html').unlink()
            with self.assertRaises(ValueError):
                workflow.export_site(source, archive)

    def test_same_run_consumer_has_only_bounded_selection_transfer_and_transform(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inputs = {'id': '14', 'digest': 'sha256:' + 'b' * 64, 'producerAttempt': '1',
                      'commit': 'a' * 40, 'runID': '42'}
            with patch.dict(os.environ, {'GITHUB_SHA': 'a' * 40, 'GITHUB_RUN_ID': '42'}), \
                    patch.object(workflow.native_jobs, 'execute_commands') as execute, \
                    patch.object(workflow, 'export_site'):
                workflow.prepare_site(root, root / 'logs', inputs, '/Docs')
                commands = execute.call_args.args[0]
                self.assertEqual([command.timeout for command in commands], [480, 480, 1200])
                transform = commands[-1].arguments
                self.assertEqual(transform.count('--sealed-input'), 3)
                self.assertIn('--input-selection', transform)
                self.assertIn('/Docs', transform)
                self.assertNotIn('swift', [part for command in commands for part in command.arguments])
                for key in ('commit', 'runID'):
                    with self.assertRaises(ValueError):
                        workflow.prepare_site(root, root / 'logs', {**inputs, key: 'wrong'}, '/Docs')


if __name__ == '__main__':
    unittest.main()
