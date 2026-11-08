# Isolated 4-core Linux compilation runner

## Scope

Configure a GitHub-hosted Ubuntu 24.04 x64 runner for DiscordKit, following
MiniCarson's separate native compilation group. Preserve the existing macOS,
Apple SDK, documentation, maintenance and release behavior.

Current local base: `1b8ea36db05be06189829c5a6f20a13d1656630b`.
Repository: `Aurum-Studios/DiscordKit`, ID `1421497969`, public.

## Gates

1. Commit this plan before changing runner settings or implementation.
2. Create `DiscordKit-Native` with selected access to DiscordKit only and public
   repository access enabled. Add `linux-x64-4`: Ubuntu 24.04 image, 4 CPUs,
   16 GiB RAM, maximum one runner, no static IP. Record acknowledged API receipts
   under the ignored build directory and re-read membership and configuration.
3. Separate the existing Linux desktop job from the macOS matrix so Linux can
   select both the dedicated group and label. Preserve all Linux stages, pinned
   dependency resolution, signing checks, timeouts and uploaded evidence. Pass
   four compiler jobs explicitly; retain the helper's conservative local default.
4. Document setup and verification boundaries. Validate workflow syntax, compare
   stage coverage with the original workflow, run existing Linux helper tests,
   and independently review the diff. Commit the completed change locally.

## Qualification

Ready status verifies configured scheduling inventory, not successful compilation.
Hosted qualification requires a run of the committed workflow and its Linux host,
command and artifact evidence. This task authorizes the requested runner setup;
workflow push, hosted run dispatch and merge remain separate from local preparation.
