# MC-29-D1 state

Local sibling task associated with MiniCarson MC-29; no configured DiscordKit
tracker issue is fabricated. Explicit Air scope authorization is verified.
Rate slice: Testing. Candidate source `414b2f59`, test availability repair `724b1ce5`.
Timing slice: isolated Implementation, not yet integrated or tested.
Starting revision: f469253d6dcdc654afb6756e915579b942548038.
Branch: implement/MC-29-D1. Root owns records/integration/docs and all validation.
Shared DiscordKit main remains clean at the starting revision.

The original-store baseline with the identical corrected regression test file
executes both named rate regressions: all three positive-headroom alias orders
fail, and exact/after-reset completion cases fail (ten issues total across two
parameterized methods/six cases). This is expected failing runtime evidence, not
a successful unit suite. A preliminary invocation failed compilation because
Swift Testing rejects suite-level availability; per-method attributes now follow
existing repository practice. Its failed compiler evidence is retained.
The operational resource-wrapper cleanup API typo was corrected; the first exact
lease was released manually after verifying child completion, and the rerun
released its own lease normally. The actual baseline run uses the unchanged old
RateLimitStore at f469253d plus test-only commits `44e3d37e` / `336f6e90`.

Independent source review of exact rate candidate `414b2f59` found no material
rate/partition/ownership defect; tests were not executed by that reviewer. The
availability-only test repair changes no arithmetic or test assertions. Run the
repaired full rate/store-contract slice next, then integrate and qualify timing.
