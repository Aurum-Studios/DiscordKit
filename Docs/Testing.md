<!-- copyright:begin
File: Docs/Testing.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Testing and validation

The generated repository has no product suite or CI certification yet. Configure actual commands in `.air/project.json` under `validation.commands` after inspecting the chosen stack. An empty list means validation is unconfigured. The file is repository guidance, not an Air execution API; only invoke reviewed commands through available tools.

Keep ordinary tests offline and deterministic. Inject clocks, transports and scripted peers. Give persistence tests isolated in-memory or temporary disk stores according to the behavior being tested. Avoid real credentials, production data, timing-dependent sleeps and incidental network calls.

Cover applicable normal, alternate, invalid, boundary, empty and repeated-call behavior. Concurrent operations need deterministic cancellation, ordering, error and cleanup checks; protocol adapters need codecs, unknown variants, authentication failures, limits, retries and pagination where relevant. Test private behavior through observable callers without widening visibility. Prefer assertions about results and effects over implementation mirrors or arbitrary test counts.

Review every affected authored method and meaningful branch, including
constructors, accessors, helpers and lifecycle callbacks, for automated coverage
through observable behavior. Add or update tests with behavior changes; for a bug
fix, demonstrate the regression before the fix and its passing result afterward
when practical. Use parameterized cases for related inputs and boundaries rather
than repeating test bodies. Coverage reports help find gaps but do not establish
assertion quality. Record behavior that cannot reasonably be automated, the reason,
alternative validation and remaining gap. Proportion checks to the change;
documentation-only edits need content checks rather than artificial unit tests.

Read [selected language guidance](Languages/README.md) for toolchain, test and
documentation conventions relevant to each affected component. Choose actual
commands after inspecting the project; selecting guidance does not configure a
runner, install dependencies or establish a passing check.

Bound compiler and test parallelism to the actual environment's usable CPU and
memory. Account for CPU affinity, container/cgroup quotas where applicable,
available memory and measured per-worker demand; the host's logical CPU count
alone is insufficient. Account for nested fan-out across build jobs, test workers
and concurrent CI tasks instead of giving each layer the whole machine. Configure
the real tools' supported limits, reduce or serialize work when capacity is
unknown or shared, and record the chosen limits and observations. Keep mutable
output and fixtures isolated for work that can safely overlap. Share compatible
dependency caches only with supported locking; avoid a full cache per worker.
Apply [cache budgets and cleanup](Dependencies.md#cache-budgets-and-cleanup):
include all agents' peak disk growth, preserve the filesystem reserve and release
owned temporary output after each phase, failure or cancellation. Reuse stable
compatible build roots rather than accumulating retry directories.

For product CI, follow [the TeamCity build chain guide](Continuous-Integration.md).
Complete platform qualification first, independent build sections second and
independent test jobs third, with every required build passing before tests
start. Keep sibling builds/tests independent and reuse compatible compiled test
products at execution. Assign complete work without duplicates, distribute
verified compatible build products,
and reconcile every required receipt through an aggregate that fails incomplete
validation. Use its admission, candidate/reuse and hosted measurement rules when
changing test scheduling; parallel execution must preserve the behavior above.

For documentation changes, follow [the documentation standards](Documentation.md)
for source contracts, Markdown structure, file links and fragments, examples and
rendered navigation. When API/reference content changes, build affected catalogs,
resolve diagnostics and inspect rendered articles, tutorials and symbol/member
navigation using the selected stack's tools. Check source documentation at every
access level; exported-symbol coverage cannot establish private/helper/test
coverage. File-existence checks do not validate fragments or external links.
Exercise affected runnable examples and record unavailable checks honestly.
Avoid unrelated compilation for simple prose edits.

Before a phase or candidate handoff:

1. Establish the correct checkout, base and candidate revision and relevant baseline failures.
2. Run meaningful affected checks with isolated output/resources; serialize competing heavy builds or browser use.
3. Run `git diff --check` and inspect the complete scoped diff.
4. Record command, environment/toolchain, tested revision, result and acceptance-criterion coverage in task evidence and summarize material outcomes in [Verification.md](Verification.md).

Use the outcomes passed, failed, skipped, blocked and unconfigured accurately. Record baseline failures separately. A checked documentation-only descendant may reference earlier code evidence after examining the intervening diff; changes to behavior, dependencies, configuration or build inputs invalidate affected evidence.

Local builds, local tests, hosted CI, native platform execution, delivered artifact verification and real external-service acceptance are separate facts. An instruction to test does not authorize production writes, outbound messages, charges, deployment or service startup. Follow the task's explicit live-action scope when such checks are authorized.
