# Bounded artifact SDK adapter

Install with `npm ci --ignore-scripts --prefix Tools/ci/artifact-sdk` using Node 24.
The lockfile pins the official Actions artifact SDK and Azure Blob client. Do not
call this worker directly from a workflow shell: the runner injects its runtime
artifact credentials into JavaScript actions. The local `artifact-transfer`
JavaScript action passes those credentials only to its supervised descendants.

The public SDK upload call hides five RPC attempts and Azure retries. This adapter
uses the pinned SDK's generated Create/Finalize protocol over the official
Actions HTTP client with `allowRetries: false`, then Azure with `maxTries: 1`.
HTTP status is classified before parsing: an HTML 502/503 response remains
transient, while malformed JSON on HTTP 200 fails permanently. RPC redirects are
disabled so credentials cannot escape to a redirected host.
`artifact_transfer.py` supervises the entire child process group and owns the three
120-second attempts within a shared 420-second aggregate deadline. Changing the
SDK version requires checking these internal module paths and the protocol again;
an import failure fails closed. It uploads a prepared ZIP byte for byte, so retries
have a stable digest and preserve the outer ZIP digest used by the REST API.

The SDK dependency tree currently retains unused archiver/glob dependencies with
moderate npm advisories. This adapter imports neither archiver nor glob and does
not use the SDK's ZIP/filesystem traversal implementation; Python prepares its
explicit file inventory. A future SDK update should remove those inherited
advisories without replacing this bounded retry policy.

Primary implementation references:

- [Official SDK upload protocol](https://github.com/actions/toolkit/blob/main/packages/artifact/src/internal/upload/upload-artifact.ts)
- [Official RPC transport](https://github.com/actions/toolkit/blob/main/packages/artifact/src/internal/shared/artifact-twirp-client.ts)
- [Official Actions HTTP client](https://github.com/actions/toolkit/tree/main/packages/http-client)
- [Official Blob upload implementation](https://github.com/actions/toolkit/blob/main/packages/artifact/src/internal/upload/blob-upload.ts)
- [Runner JavaScript action environment](https://github.com/actions/runner/blob/main/src/Runner.Worker/Handlers/NodeScriptActionHandler.cs)
- [GitHub artifact REST API and digest](https://docs.github.com/en/rest/actions/artifacts)

No local helper test authenticates a hosted upload. Phase 11 owns that proof.
