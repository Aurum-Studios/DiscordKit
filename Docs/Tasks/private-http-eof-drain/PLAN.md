# Bounded private HTTP EOF drain repair

Approved scope: isolated DiscordKit branch `fix/private-http-eof-drain`, base `08606545afd39b0d3a3785c02490307074c8fbb6`, paired with MiniCarson website/daemon connection repair. No staging, commit, deployment, live calls or original-sibling edits.

## Problem and invariant

SwiftNIO can synchronously drain unread response bytes when a peer closes. HTTPWireHandler currently rejects a backlog exceeding 64 KiB plus one read even when total response bytes are within maximumResponseBytes. Keep the existing aggregate response cap, chunk bound, send-once behavior, normal pull backpressure and joined cleanup.

## Phases

1. Add deterministic loopback regressions using existing HTTP peer fixtures. Withhold body consumption until the peer has written and closed. Cover exact response cap for known-length and EOF framing, one-byte overflow, and abandoning/closing a retained response. Capture a red baseline before production changes.
2. Remove the incompatible secondary queue ceiling while retaining the cumulative guard before retention. Document that remote EOF can require retaining the whole already bounded response. Do not change aggregate limits or substitute larger chunks.
3. Run the forced-close regressions and all DiscordNIOTransportTests with SWIFTNIO_STRICT=1, six compiler jobs, offline resolution. Review documentation/diff, record source hashes and receipts, and hand off unstaged source for independent paired MiniCarson validation.

## Qualification boundary

Local macOS loopback evidence qualifies these transport cases only. Full-package, Linux, rendered DocC and production/live qualification remain separate checks; no such pass is inferred from focused results.

## November 8 consolidation authorization

The user subsequently authorized committing all pending non-MC-3 repairs and preparing local pull requests. The original no-commit handoff above is historical. This separately scoped sibling repair is required by the MiniCarson candidate. Keep its existing branch and original dependency pins, validate the documented root/example/local transport checks, commit the completed patch and records, and retain a local PR description. Local checkout consolidation is authorized; push, remote PR/merge, publication and live operations remain outside this task.
