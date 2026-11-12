// File: Tools/ci/artifact-sdk/upload.mjs
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

// One transport attempt. The Python parent owns deadlines and all retries.
// Pinning the SDK is deliberate: its public upload API hides five RPC retries.
import {createReadStream} from 'node:fs';
import {readFile, stat, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {BlobClient} from '@azure/storage-blob';
import {HttpClient} from '@actions/http-client';
import {BearerCredentialHandler} from '@actions/http-client/lib/auth';

const sdk = import.meta.resolve('@actions/artifact');
const {getBackendIdsFromToken} = await import(new URL('./internal/shared/util.js', sdk));
const {getResultsServiceUrl, getRuntimeToken} = await import(new URL('./internal/shared/config.js', sdk));
const {getExpiration} = await import(new URL('./internal/upload/retention.js', sdk));
const {StringValue, ArtifactServiceClientJSON} = await import(new URL('./generated/index.js', sdk));

const [inputFile, outputFile] = process.argv.slice(2);
let phase = 'input';
let http;
try {
  const input = JSON.parse(await readFile(inputFile, 'utf8'));
  if (!/^[A-Za-z0-9_.-]+$/.test(input.name) || !/^[a-f0-9]{64}$/.test(input.sha256)
      || !Number.isInteger(input.retentionDays) || input.retentionDays < 1 || input.retentionDays > 90) {
    throw new Error('invalid upload input');
  }
  // Hash the prepared ZIP before any remote mutation; retries reuse these bytes.
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(input.path)) hash.update(chunk);
  if (hash.digest('hex') !== input.sha256) throw new Error('prepared ZIP digest changed');
  const size = (await stat(input.path)).size;
  const backend = getBackendIdsFromToken();
  http = new HttpClient('DiscordKit-ci-artifact-transfer', [new BearerCredentialHandler(getRuntimeToken())], {
    allowRetries: false, maxRetries: 0, allowRedirects: false, keepAlive: false
  });
  const client = new ArtifactServiceClientJSON({
    async request(service, method, contentType, data) {
      const endpoint = new URL(`/twirp/${service}/${method}`, getResultsServiceUrl()).href;
      const response = await http.post(endpoint, JSON.stringify(data), {'Content-Type': contentType});
      const status = response.message.statusCode ?? 0;
      // Preserve the HTTP classification even when an intermediary returns HTML.
      // Malformed JSON on HTTP 200 remains a permanent protocol error.
      if (status < 200 || status >= 300) {
        response.message.resume();
        throw Object.assign(new Error('artifact RPC HTTP failure'), {statusCode: status});
      }
      return JSON.parse(await response.readBody());
    }
  });
  phase = 'create';
  const created = await client.CreateArtifact({
    ...backend, name: input.name, version: 7,
    mimeType: StringValue.create({value: 'application/zip'}),
    expiresAt: getExpiration(input.retentionDays)
  });
  if (!created.ok || !created.signedUploadUrl) throw new Error('invalid CreateArtifact response');
  phase = 'blob';
  // No Azure retries either. Its ordinary default is an independent retry budget.
  const blob = new BlobClient(created.signedUploadUrl, undefined, {retryOptions: {maxTries: 1}}).getBlockBlobClient();
  await blob.uploadFile(input.path, {
    concurrency: 1, blockSize: 8 * 1024 * 1024, maxSingleShotSize: 8 * 1024 * 1024,
    blobHTTPHeaders: {blobContentType: 'application/zip'}
  });
  phase = 'finalize';
  const finalized = await client.FinalizeArtifact({
    ...backend, name: input.name, size: String(size),
    hash: StringValue.create({value: `sha256:${input.sha256}`})
  });
  if (!finalized.ok || !/^[1-9][0-9]*$/.test(String(finalized.artifactId))) {
    throw new Error('invalid FinalizeArtifact response');
  }
  await writeFile(outputFile, JSON.stringify({id: String(finalized.artifactId), digest: `sha256:${input.sha256}`}));
} catch (error) {
  const status = error.statusCode ?? error.status ?? Number(error.message?.match(/\((\d{3})\)/)?.[1]);
  const code = error.code ?? error.message?.match(/\b(ECONNRESET|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN|EPIPE)\b/)?.[1];
  const transient = [408, 429, 500, 502, 503, 504].includes(status)
    || ['ECONNRESET', 'ECONNREFUSED', 'ETIMEDOUT', 'EAI_AGAIN', 'EPIPE'].includes(code);
  // Never retain signed blob URLs, JWTs, headers, or SDK error text in receipts.
  await writeFile(outputFile, JSON.stringify({error: {
    category: transient ? 'transient' : 'permanent', phase,
    status: Number.isFinite(status) ? status : null, code: code ?? null
  }}));
  process.exitCode = 1;
} finally {
  http?.dispose();
}
