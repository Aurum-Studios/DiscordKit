// File: .github/actions/artifact-transfer/index.mjs
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

// Runner artifact credentials are injected into JavaScript actions, not shell
// steps. Keep them in this process tree instead of exporting to GITHUB_ENV.
import {spawn} from 'node:child_process';
import path from 'node:path';

try {
  const args = JSON.parse(process.env.INPUT_ARGUMENTS ?? 'null');
  if (!Array.isArray(args) || !args.every(value => typeof value === 'string' && !value.includes('\0'))) {
    throw new Error('arguments must be a JSON array of strings');
  }
  const workspace = process.env.GITHUB_WORKSPACE;
  if (!workspace) throw new Error('GitHub workspace is required');
  const child = spawn('python3', [path.join(workspace, 'Tools/ci/artifact_transfer.py'), ...args], {
    cwd: workspace, env: process.env, stdio: 'inherit', shell: false
  });
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => child.kill(signal));
  child.on('error', () => {
    process.stderr.write('Unable to launch bounded artifact transport.\n');
    process.exitCode = 1;
  });
  child.on('exit', (code, signal) => { process.exitCode = signal ? 1 : (code ?? 1); });
} catch (error) {
  process.stderr.write(`Invalid artifact transfer action input: ${error.message}\n`);
  process.exitCode = 1;
}
