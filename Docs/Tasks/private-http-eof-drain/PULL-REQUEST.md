# Fix bounded HTTP responses when peers close

Valid HTTP responses could fail with `responseTooLarge` when a peer closed
while the asynchronous body consumer was suspended. Retain the unread
response within the existing aggregate body ceiling during EOF drain, with
unchanged normal demand reads, emitted chunk limits and joined cleanup.

Add deterministic Content-Length and EOF-framed exact-limit, one-byte overflow
and unread-close regressions, and document the retained-payload bound.

Validation: 58 transport tests, the complete 2,469-test root suite, root and
RESTOnly builds, and two 10,000-request concrete loopback workloads passed
with strict NIO checking. Burst admission produced 9,880 expected capacity
refusals; neither workload had request failures. Existing source/DocC checks passed; fresh paired DocC validation is
recorded by MiniCarson's consolidation task.

This commit is required by MiniCarson's prepared website/daemon repair. Push
this branch before MiniCarson's candidate so its exact sibling pin is
fetchable. Native Linux/hosted CI and live Discord remain separate checks.
