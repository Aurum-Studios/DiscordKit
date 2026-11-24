<!-- copyright:begin
File: Docs/Tasks/teamcity-pipelines/2026-11-24/PLAN.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Reduce TeamCity build configuration usage

The base is `dc72a96d0ca0e31f164d5e85abd71810c759c66f`. It defines 26
classic configurations, or 28 with GitHub release publishing enabled. Aurum's
TeamCity reports 2026.2.2. Native pipelines use a separate Professional license
allowance. [Pipeline licensing](https://www.jetbrains.com/help/teamcity/create-and-edit-pipelines.html)

1. **AC-1** Move qualification, release compilation, repository checks and
   export work into four named Kotlin pipelines. Bring periodic timing into
   one scheduled and manually selectable build. Generate both the default
   settings and the release-enabled variant and check their entity counts.
2. **AC-2** Preserve platform coverage, WSL admission, fixed SwiftPM checkout
   paths and same-agent placement for native consumers. Require both
   qualifications before builds, every build before native tests, and all
   checks before exports. Compare generated dependencies, job inputs and
   component commands against the current contracts.
3. **AC-3** Keep the classic certification ID, exact-revision receipt and DocC
   validation, GitHub status publishing and approved release chain. Move
   pipeline artifacts using separate files and job-specific paths. Exercise
   the job runner's deadline, failure and receipt behavior offline.
4. **AC-4** Document versioned settings import, license read-back, bound artifact
   transport and rollback. Keep hosted import, live agent qualification and
   GitHub status observations pending a published candidate. Commit validated
   edits and release the isolated checkout with the work preserved on its branch.

This run has one writer on the task branch, with disjoint documentation and timing
edits delegated. The request authorizes local implementation and commits. There is
no supplied YouTrack issue or authorization to publish the candidate.
