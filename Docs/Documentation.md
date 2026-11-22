<!-- copyright:begin
File: Docs/Documentation.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Documentation standards

Documentation is part of the implementation of every affected feature, fix and
phase. These rules cover authored Markdown, source comments, symbol reference,
examples, configuration, build tooling and task evidence throughout the repository.
In generated repositories, read selected language guidance in
`Docs/Languages/README.md` for native documentation syntax and tools. Preserve
supported versions, existing project organization and explicit user scope;
this policy does not authorize publication or live actions.

## Purpose, audience and accuracy

- Explain what exists, whom it serves, how to use it and its relevant limits.
  Start each guide with its purpose, audience and prerequisites. Define unfamiliar
  domain terms and use names consistent with code and the product interface.
- Describe observable behavior and the reasons behind consequential decisions.
  Comments that merely repeat a declaration, heading or implementation add no
  contract. Keep useful documentation proportionate to the behavior's complexity.
- Separate implemented behavior, proposals, deprecated behavior and unverified
  claims. State supported versions/platforms when they affect the instructions.
  A plan, example, green local check or generated reference is not delivery proof.
- Keep one authoritative home for each fact. Link to it from other entrypoints
  instead of copying commands, compatibility matrices or long explanations that
  can drift. Keep public contracts and internal implementation notes distinct.
- Update affected documentation in the same phase as behavior, signature,
  configuration, dependency or operational changes. Review callers and examples
  when renaming/removing symbols. Do not defer correctness to a later docs stage.
- Preserve historical plans, decisions and verification receipts with their
  original revision/date. Add a clear current status or superseding link rather
  than rewriting old results as current. Remove obsolete current instructions or
  mark them deprecated with a supported replacement and migration path.

## Documentation structure and navigation

The root README is the product entrypoint: purpose, current maturity, supported
use, minimal setup and links to deeper material. [The documentation index](README.md)
is the map. Every maintained guide must be reachable from that map, an appropriate
section index or its canonical parent; avoid orphan pages and directory dumps.

Provide the following material as the corresponding product concern is
implemented. Combine small related topics when that makes them easier to use;
do not create empty pages for capabilities the project does not have.

| Material | Required content |
| --- | --- |
| Setup and contribution | Supported tools/versions, prerequisites, checkout location, dependency installation, configuration, first successful check and expected result |
| Tutorials | A concrete learning goal, starting state, ordered steps, explanations, complete runnable examples, expected outcomes, cleanup and next steps |
| Task guides | A specific user/developer task, inputs, steps, verification, common failure paths and recovery |
| Reference | Exact API, command, configuration or schema contracts; defaults, limits, units, errors and version constraints |
| Architecture | Components, responsibility boundaries, data/control flow, dependencies, persistence, trust boundaries, concurrency and lifecycle where relevant |
| Design decisions | Context, considered alternatives, chosen behavior, trade-offs, compatibility consequences and status; link a superseding decision when replaced |
| Operations and troubleshooting | Required access/environment, preflight, effects, success/failure signals, diagnosis, recovery/rollback and escalation or stop conditions |
| Compatibility and migration | Affected versions/consumers, breaking or deprecated behavior, data changes, migration order, rollback limits and verification |
| Release and verification | User-visible changes, remaining limitations, exact tested/delivered revision or artifact and separate qualification evidence |

Document meaningful modules, packages and major directories: their purpose,
entrypoints, responsibilities and dependency boundaries. Give authored source,
build and configuration files enough module/file context to explain their role;
use a file-level comment when that role or its constraints are not clear from the
surrounding module reference. Explain non-obvious algorithms, safety checks and
workarounds near the code, including why they are needed and when they can change.

Library documentation must offer curated module/package landing pages, organized
type and member groups, conceptual articles, practical tutorials and useful
cross-links between reference and task guidance. A generated symbol list alone
does not provide that structure. Use the selected ecosystem's documentation tools;
Swift libraries use curated DocC catalogs, including a tutorial overview.

## Markdown and other authored documentation

- Give each Markdown page one descriptive top-level title. Use a logical heading
  hierarchy without skipped levels; choose stable, specific headings that make a
  useful outline. Keep file names and terminology consistent with nearby docs.
- Use short, direct prose. Prefer ordered lists for dependent steps, bullets for
  parallel facts and tables for comparisons/contracts. Separate headings, lists,
  tables and fenced blocks with blank lines. Keep tables readable in source and
  preview; avoid oversized tables when separate sections explain the topic better.
- Use descriptive link text and repository-relative links for versioned local
  material. Check path casing, URL encoding and fragments; link to the supporting
  section or primary upstream source. Avoid machine paths, IDE-only links and
  private tracker identities in reusable or public guidance. Identify the relevant
  external version or verification date when compatibility depends on it.
- Mark fenced code with the appropriate language. Distinguish shell commands
  from expected output; do not include prompt characters that break copying.
  State the working directory, prerequisites, placeholders and environment for
  commands. Keep commands and sample paths consistent with the actual project.
- Provide alt text for informative images and a text explanation for diagrams.
  Do not rely on color alone. Describe the relationships or behavior a diagram
  establishes, use legible labels and keep editable diagram sources when practical.
- Keep authored Markdown, catalogs, diagram sources and intended example assets
  in version control. Exclude reproducible generated sites, caches and build
  artifacts unless the repository explicitly maintains a reviewed distribution.
- Follow the same standards in plans, task records, skills and prompt guidance.
  Replace template instructions with real observations before claiming a record
  is complete. Ensure renamed/moved pages retain valid inbound links/navigation.

## Symbol documentation at every visibility

Document every authored callable, including public, protected, package/internal,
private, file-local and nested declarations; exported-only checks are insufficient.
This includes free functions, methods, constructors/initializers, destructors/
deinitializers, operators, subscripts, accessors, local functions, helpers,
overrides, protocol/interface implementations and tests. Explain closure,
callback, delegate and event-handler contracts beside their declaration or use
when they have no separate documentation surface. Do not widen access to expose
a symbol to a documentation tool or test.

Document modules/namespaces/packages, types, interfaces/protocols, generic
parameters and constraints, aliases, enum cases, stored/computed properties,
fields, constants, events and relevant macros. Explain their domain meaning,
responsibility and invariants. A simple member can use a concise description;
state applicable contracts rather than adding empty tags for every item below.

| Contract | What the documentation must explain when relevant |
| --- | --- |
| Purpose | What the declaration represents or does, the result it promises and the intended use |
| Inputs | Parameter meaning, valid ranges, units, encoding, null/empty handling, defaults and preconditions |
| Results | Returned/yielded value, ordering, absence/sentinel meaning, mutability and success guarantees |
| Failures | Exceptions/errors, failure results, partial success, retry behavior, invalid input and post-failure state |
| State and effects | Mutation, persistence, I/O, notifications, external writes, atomicity and repeated-call/idempotency behavior |
| Ownership | Who owns, borrows, retains, releases, closes or disposes resources; valid lifetimes and aliasing constraints |
| Concurrency | Thread/actor/context requirements, synchronization, reentrancy and callback execution context/order |
| Cancellation and lifecycle | Startup/shutdown, suspension, cancellation propagation, timeout behavior, cleanup and completion guarantees |
| Compatibility | Availability, platform/version constraints, serialization or ABI promises, deprecation and migration |

Use the language's native documentation comments and established generator tags
or symbol links. Put the contract with its declaration; use inline implementation
comments to explain reasoning and links to longer design material. Keep parameter
names, error identifiers, links, availability and examples synchronized with code.
Prefer behavioral guarantees over incidental implementation steps.

Overrides and implementations must have a documented contract at the declaration.
Use supported inheritance/cross-reference conventions for identical guarantees
and explain local changes, additional side effects or stricter requirements.
Document accessor-specific behavior at the member when the language or generator
cannot attach it to individual accessors. Describe named test/fixture helpers and
test cases with the scenario, important setup and expected observable outcome.

Keep generated and vendored code under its established ownership policy. Document
the generator/templates and authored adapters, regeneration command and relevant
limitations instead of hand-editing output. Audit authored source directly for
private/local/test coverage even when generated reference documentation is clean.

## Configuration, tooling, tests and examples

- Reference each supported configuration key, environment variable, CLI option,
  serialized/schema field and feature flag: purpose, type, default/requiredness,
  accepted values, units/limits, precedence, validation and reload/restart behavior
  where applicable. Explain compatibility and migrations for persistent formats.
- Document script/build entrypoints with invocation, working directory, supported
  toolchain, inputs/outputs, exit/failure behavior and side effects. Identify
  required access, destructive effects and recovery before operational commands.
  Distinguish preview/dry-run from writes and local actions from external effects.
- Test documentation must explain behavior being established and why important
  fixtures exist. Record fixture provenance, generation/update procedure and
  relevant constraints. Keep test guides aligned with the actual commands,
  filtering, resources and supported environments.
- Make examples complete enough to reproduce from their declared starting state.
  Include imports/setup, dependencies, representative inputs, expected outputs,
  error paths and cleanup as appropriate. Label pseudocode, abbreviated snippets
  and illustrative output so they are not mistaken for runnable verification.
- Keep snippets, sample projects, tutorials and command help aligned with current
  signatures, configuration and supported targets. Reuse checked example sources
  where practical. Exercise meaningful behavior; syntax-only checks do not prove
  an end-to-end tutorial succeeds.
- Use synthetic values and clear placeholders. Keep credentials, tokens, personal
  data, private endpoints and production records out of examples/screenshots/logs.
  Explain how required secrets are supplied without printing them. Checking an
  example does not authorize charges, outbound messages, deployment or live writes.

## Documentation completion and validation

Plan affected documentation and its checks alongside acceptance criteria. Review
the actual diff and current implementation; older plans and comments are evidence
to reconcile, not proof of current behavior. Use this completion sequence for each
affected phase and any configured documentation checkpoint:

1. Inventory affected entrypoints, symbols, consumers, Markdown, examples,
   configuration, architecture, operations and release notes. Update applicable
   material and explain consequential compatibility or migration changes.
2. Review authored source for contract quality and all-visibility coverage.
   Documentation presence/counts and exported symbol graphs do not establish
   completeness. Use suitable existing audits plus direct review of forms they
   cannot detect; identify generated/vendor exclusions explicitly.
3. Check local file targets, fragments/anchors, case, renamed symbols, reference
   links, fences and navigation. Check relevant external references as needed;
   a local file-existence checker does not verify anchors or external availability.
4. Build affected documentation using the project's supported tools, resolve new
   diagnostics and record baseline warnings separately. Inspect rendered landing
   pages, topic groups, articles, tutorials, examples, tables, images and symbol/
   member navigation as applicable. A successful build alone is not render review.
5. Validate affected runnable snippets, commands and sample projects with focused,
   isolated checks. Record any unavailable environment or required authorization
   rather than executing an unapproved live action or claiming an example passed.
6. Update [verification](Verification.md), [the changelog draft](Changelog-Draft.md),
   roadmap and task evidence where affected. Record command/procedure, date,
   toolchain/environment, exact revision/artifact, scope, outcome and limitations.
   Keep local, hosted, native-platform, delivered and live acceptance facts separate.
7. Inspect the complete scoped diff and run `git diff --check`. Reconcile material
   omissions and broken links before handoff; report blocked, skipped and
   unconfigured checks explicitly. Preserve unrelated drafts and historical evidence.

Configure actual documentation checks with the other project commands in
`.air/project.json` under `validation.commands`; initialization leaves them empty.
Select checks proportionate to the changed content. Simple prose changes need
relevant content/link review; documentation or example changes involving APIs,
configuration or build inputs need their affected checks and evidence. Follow
[the testing guide](Testing.md) when reusing earlier code evidence for a checked
documentation-only descendant. Record local validation and article publication
with separate receipts.

## Knowledge Base publication and native reference

Maintain the project's internal guides in the authorized YouTrack library.
[The publication guide](Publishing-Documentation.md) covers initial import,
article ownership, access, and the issue links for approved task records. Give
readers an overview and stable navigation as the project grows. Preview material
from Git and verify the destination and audience before publishing it.

For native API reference, document the actual generator, build command and
intended audience. Follow the selected language guidance for production coverage,
overviews, examples, navigation and diagnostics. Configure its checks with the
other product commands. Record hosted generation, artifacts, and any separately
authorized delivery against the exact source revision.
