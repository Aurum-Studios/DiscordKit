#!/usr/bin/env python3
# File: Tools/ci/documentation_workflow.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Prepare a read-only same-run documentation consumer and immutable job outputs."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import time

import build_documentation_site
import linux_ci
import native_jobs


ROOT = Path(__file__).resolve().parents[2]


def artifact_output(receipt, output):
    """Expose a nonmatrix upload's verified identity without artifact-name searches."""
    report = json.loads(Path(receipt).read_text())
    artifact = report.get('artifact', {})
    if (report.get('status') != 'verified' or report.get('operation') != 'upload'
            or not re.fullmatch(r'[1-9][0-9]*', str(artifact.get('id', '')))
            or not re.fullmatch(r'sha256:[0-9a-f]{64}', artifact.get('digest', ''))
            or not re.fullmatch(r'[A-Za-z0-9_.-]+', artifact.get('name', ''))):
        raise ValueError('documentation output requires a verified immutable upload')
    value = {**artifact, 'producerAttempt': os.environ['GITHUB_RUN_ATTEMPT'],
             'commit': os.environ['GITHUB_SHA'], 'runID': os.environ['GITHUB_RUN_ID']}
    with Path(output).open('a') as stream:
        stream.write('artifact=' + json.dumps(value, separators=(',', ':')) + '\n')
    return value


def export_site(site, archive):
    """Package only regular site files; the immutable transport seals their bytes."""
    site, archive = Path(site), Path(archive)
    if site.is_symlink() or not site.is_dir():
        raise ValueError('documentation site must be a regular directory')
    marker = site / build_documentation_site.MARKER
    required = ('index.html', 'documentation/index.html', '.nojekyll', marker.name)
    if (any(not (site / name).is_file() or (site / name).is_symlink() for name in required)
            or marker.read_text() != build_documentation_site.MARKER_CONTENT):
        raise ValueError('documentation site export is incomplete')
    members = sorted(site.rglob('*'))
    if any(path.is_symlink() or not (path.is_file() or path.is_dir()) for path in members):
        raise ValueError('documentation site contains links or special files')
    if archive.exists() or archive.is_symlink():
        raise ValueError('documentation site archive already exists')
    archive.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tarfile.open(archive, 'w:gz') as transport:
            transport.add(site, arcname='site', recursive=False)
            for path in members:
                transport.add(path, arcname='site/' + path.relative_to(site).as_posix(), recursive=False)
    except BaseException:
        archive.unlink(missing_ok=True)
        raise


def prepare_site(repository, output, inputs, hosting_base_path):
    """Authenticate, download, merge and transform without compiling or converting."""
    repository, output = Path(repository).resolve(), Path(output).resolve()
    if (not isinstance(inputs, dict) or not {'id', 'digest', 'producerAttempt', 'commit', 'runID'} <= inputs.keys()
            or inputs['commit'] != os.environ['GITHUB_SHA']
            or inputs['runID'] != os.environ['GITHUB_RUN_ID']):
        raise ValueError('documentation consumer inputs differ from this source/run')
    scripts = repository / 'Tools/ci'
    selection = output / 'selection.json'
    downloads = output / 'inputs'
    commands = [
        linux_ci.Command('select-documentation-inputs', (sys.executable,
            str(scripts / 'documentation_inputs.py'), 'select', '--artifact-id', str(inputs['id']),
            '--expected-digest', inputs['digest'], '--output', str(selection)), 480, 'artifactTransfer'),
        linux_ci.Command('download-documentation-inputs', (sys.executable,
            str(scripts / 'artifact_transfer.py'), 'download', '--artifact-id', str(inputs['id']),
            '--expected-digest', inputs['digest'], '--destination', str(downloads),
            '--receipt', str(output / 'download.json')), 480, 'artifactTransfer'),
        linux_ci.Command('prepare-documentation-site', (sys.executable,
            str(scripts / 'build_documentation_site.py'), '--repository', str(repository),
            '--input-selection', str(selection),
            *[argument for component in ('root', 'macros', 'extensions') for argument in
              ('--sealed-input', str(downloads / (component + '.tar.gz')))],
            '--hosting-base-path', hosting_base_path,
            '--output', str(repository / '.build/documentation-site')), 1200, 'documentation'),
    ]
    report = {'status': 'running', 'commands': [], 'certifying': False, 'inputs': inputs,
              'aggregateSeconds': 2160}
    with native_jobs.execution_report(output, report):
        native_jobs.execute_commands(commands, repository, output, report, deadline=time.monotonic() + 2160)
        export_site(repository / '.build/documentation-site', repository / '.build/documentation-site.tar.gz')
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='operation', required=True)
    artifact = sub.add_parser('artifact-output')
    artifact.add_argument('--receipt', type=Path, required=True)
    artifact.add_argument('--output', type=Path, default=os.environ.get('GITHUB_OUTPUT'))
    site = sub.add_parser('prepare-site')
    site.add_argument('--repository', type=Path, default=ROOT)
    site.add_argument('--output', type=Path, default=Path('.build/documentation-ci/site'))
    site.add_argument('--inputs-json', default=os.environ.get('DOCUMENTATION_INPUTS', ''))
    site.add_argument('--hosting-base-path', default='/DiscordKit')
    args = parser.parse_args(argv)
    try:
        if args.operation == 'artifact-output':
            if args.output is None:
                raise ValueError('GitHub output file is required')
            artifact_output(args.receipt, args.output)
        else:
            prepare_site(args.repository, args.output, json.loads(args.inputs_json), args.hosting_base_path)
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print('documentation workflow failed: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
