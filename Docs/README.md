<!-- copyright:begin
File: Docs/README.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Documentation

- [DiscordKit setup](Setup.md), [available products](../README.md#available-products), and the [DocC catalogs](../Sources/DiscordKit/DiscordKit.docc/TableOfContents.md) cover adoption and API usage.
- [DiscordKit CI](CI.md), [service setup](TeamCitySetup.md), and [releases](ReleaseTooling.md) cover the project’s validation and delivery.
- [Engineering conventions](Engineering.md) describe component boundaries, state authority, explicit resource lifetimes, bounded measured work and structured diagnostics.
- [Editable copyright](../COPYRIGHT.md) defines the notice fields, tracked-file synchronization, central coverage and independent licensing.
- [Company identity](Identity.md) defines company-wide namespace allocation, stable keys, UUIDs and language-safe identifiers.
- [Documentation standards](Documentation.md) define Markdown, symbol contracts at every visibility, guides, examples and completion checks across the project.
- [Knowledge Base publication](Publishing-Documentation.md) explains article ownership, review, access and task publication.
- [Repository initialization](Plans/Repository-Initialization.md) records the generated baseline and remaining product decisions.
- [Roadmap](Roadmap.md) separates planned work from completed capabilities.
- [Testing](Testing.md) describes real checks and evidence requirements.
- [TeamCity build chains and parallel testing](Continuous-Integration.md) defines ordered platform/build/test phases with independent jobs, unique work partitions, bounded workers, artifact provenance and required aggregate gates.
- [Language guidance](Languages/README.md) routes selected language and framework conventions.
- [Dependencies and build variants](Dependencies.md) explains project ignore templates, exact pins, source submodules, compatible cache reuse and aggregate disk budgets/owned cleanup for concurrent agents.
- [Verification](Verification.md) records what has actually been established.
- [Changelog draft](Changelog-Draft.md) accumulates user-visible changes before release.
- [Air operating contract](Air-Workflow/contract.md) routes named stages and tracker work.
- [Branches, worktrees and stage handoffs](Air-Workflow/worktree-lifecycle.md) defines one issue lineage, per-stage closure, safe checkout release, retained resources and preservation of the standard checkout.
- [YouTrack project template](YouTrack/README.md) supplies reusable project settings, native-template setup, issue/handoff text and a launch checklist.
- [Automatic YouTrack setup](YouTrack/Automatic-Setup.md) configures a supplied empty project's fields/defaults and optional board, records verified mapping and explains recovery.
- [YouTrack Knowledge Base](YouTrack/Knowledge-Base.md) describes the curated project guide inventory, repeatable connector sync, and issue-linked task articles.
- [Task records](Tasks/README.md) preserve plans, state, acceptance criteria and validation receipts.

Add architecture, setup, configuration, privacy, operations and troubleshooting guides as those concerns are implemented. Link new guides here or through a relevant section index. Keep examples reproducible and explain supported behavior and limits. Follow the documentation standards and selected language profiles for API documentation tools and conventions.
