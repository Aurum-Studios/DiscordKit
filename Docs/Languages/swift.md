<!-- copyright:begin
File: Docs/Languages/swift.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Swift guidance

Apply this profile to Swift targets. Preserve the repository's supported platforms,
toolchain, frameworks and dependency choices; selection does not configure checks.

## Company identity

- Apply the `aurum-studios.com` / `com.aurum-studios` allocation in generated
  `Docs/Identity.md`; consult `identity.identifiers` before configuring targets.
  Keep the immutable namespace key separate from display names and Air slugs.
- Use the recorded Swift module spelling, for example
  `Com_AurumStudios_Projects_P_orbit_editor`, and the exact Apple bundle prefix
  `com.aurum-studios.projects.orbit-editor`. Modules and bundle IDs have different
  syntax; retain key boundaries rather than deleting hyphens. Allocate each
  product, target/module, test module, app extension, resource and documentation
  bundle under its owner, with collision-checked flat module aliases for components.
- Shared libraries retain independent `com.aurum-studios.libraries.<key>`
  allocations across consumers and repositories. Verify SwiftPM product, package
  and registry identities separately; changing an exported module name affects
  ABI. Objective-C runtime names and exported C symbols need their own prefixes.
- Validate final IDs, platform-required prefixes, case rules and suffix lengths;
  reserve actual aliases before publication. Preserve third-party module names
  and deployed/signing identities until an explicit migration. Generation does
  not verify publisher rights or provision identifiers.
  [Apple bundle IDs](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier),
  [Swift module identity](https://github.com/swiftlang/swift/blob/main/docs/Modules.md).

## Preferred tools and dependencies

Use applicable preferences for suitable new choices. Preserve explicit instructions
and established project choices; surface material conflicts. Entries do not install
tools or dependencies, clone repositories or authorize migrations.

### Toolchain and package management

- Use [Swift Package Manager](https://www.swift.org/documentation/package-manager/)
  for new Swift libraries, executables and shared modules, and for dependencies in
  Apple applications. Retain Xcode projects/schemes where application packaging,
  signing or platform resources require them; SwiftPM does not replace those tasks.
- Start new projects with Swift **6.4**, `// swift-tools-version: 6.4` and Swift 6
  language mode (`swiftLanguageModes: [.v6]` when set explicitly in Package.swift).
  The tools version is a minimum manifest/toolchain requirement, not a compiler
  patch pin. Record the exact compiler/Xcode version used locally and in CI.
- Keep this baseline current with the latest stable Swift and compatible stable
  Xcode. Check the [official releases](https://www.swift.org/download/) and
  [Xcode compatibility table](https://developer.apple.com/xcode/system-requirements)
  during setup and upgrades. As verified on 2026-11-08, Swift 6.4.2 is the stable
  patch supplied by Xcode 27.2; see its
  [release announcement](https://forums.swift.org/t/announcing-swift-6-4-2/90337).
  Review and update the preset, manifest, compiler pins, CI, SwiftLint and DocC
  together after build/test/documentation checks. Betas and snapshots require an
  explicit project decision; preserve older established support until a reviewed
  upgrade. Avoid floating `latest` in reproducible CI.
- Prefer stable semantic-version requirements for package dependencies, limited
  to products actually used by a target. Review changes to Package.resolved;
  commit application/executable resolution and follow the repository's explicit
  library lockfile policy. Do not replace existing pins as a side effect of setup.

### SwiftLint

- Install and configure [SwiftLint](https://github.com/realm/SwiftLint) for every
  new Swift project, including libraries. On macOS, `brew install swiftlint` is
  the preferred simple installation; use the upstream portable binary or documented
  [SwiftLintPlugins](https://github.com/SimplyDanny/SwiftLintPlugins) integration
  when the project needs another supported route. Pin a tested release in CI and
  document local installation/version selection. It is a development tool, not a
  library runtime dependency. Configure the actual lint command during setup.
- Start from the [commented swiftlint.yml](swift/swiftlint.yml). Copy it from
  this profile's `swift` directory to the Swift component root as `swiftlint.yml`,
  customize it, and always pass `--config swiftlint.yml`. Alternatively adopt
  the conventional `.swiftlint.yml` name deliberately and update all invocations.
  Keep test and example sources in scope; exclude generated/vendor output only.
- Run `swiftlint version`, then
  `swiftlint rules --config swiftlint.yml --enabled --verbose` to inspect the
  resolved options, and
  `swiftlint lint --config swiftlint.yml --strict --force-exclude` for linting.
  Keep normal per-file/progress output enabled. `lint` has no `--verbose` flag;
  verbose configuration output belongs to `rules`. The supplied configuration
  retains default rules, enables explicit opt-in rules and fails on warnings.
- Validate the configuration against the pinned release before upgrading.
  Prefer explicit, reviewed rule lists to enabling every new rule automatically.
  Review corrections before applying them; do not silently baseline violations.
  Compiler-backed analyzer rules require a clean compiler log and a separate
  `swiftlint analyze` command; ordinary lint does not run them.

### Preferred Swift packages

Prefer Apple-maintained or official Swift project packages for applicable new
dependencies. Package names below identify upstream repositories; import/product
names can differ. Verify the selected release's products, toolchain requirements
and platform support before adding it. Use only the products needed by the target.

| Upstream package | Preferred use and constraints |
| --- | --- |
| [apple/swift-log](https://github.com/apple/swift-log) | Structured logging through `Logging`; reusable libraries accept/use the logging API and leave backend/bootstrap selection to the application. |
| [apple/swift-crypto](https://github.com/apple/swift-crypto) | Supported cross-platform cryptographic primitives through `Crypto`; prefer supported APIs and platform CryptoKit integration rather than custom crypto. Use `CryptoExtras` only when required. |
| [apple/swift-nio](https://github.com/apple/swift-nio) | Event-driven networking and protocol infrastructure; add only needed NIO products, keep event loops nonblocking and give groups/channels explicit ownership and shutdown. |
| [apple/swift-collections](https://github.com/apple/swift-collections) | Established collections such as deques and ordered collections when standard-library structures do not fit. |
| [apple/swift-algorithms](https://github.com/apple/swift-algorithms) | Sequence/collection algorithms instead of bespoke equivalents. |
| [apple/swift-async-algorithms](https://github.com/apple/swift-async-algorithms) | Async sequence composition with explicit cancellation, buffering and lifetime behavior. |
| [apple/swift-argument-parser](https://github.com/apple/swift-argument-parser) | Typed CLI arguments, help and validation, including async commands. |
| [apple/swift-system](https://github.com/apple/swift-system) | Low-level system interfaces and file descriptors; document ownership and platform limits. |
| [apple/swift-atomics](https://github.com/apple/swift-atomics) | Necessary low-level atomic operations; prefer actors/structured concurrency for ordinary shared state. |
| [apple/swift-numerics](https://github.com/apple/swift-numerics) | Established numeric types/algorithms when the standard library is insufficient. |
| [apple/swift-metrics](https://github.com/apple/swift-metrics) | Backend-independent instrumentation; the executable owns bootstrap/export configuration. |
| [apple/swift-http-types](https://github.com/apple/swift-http-types) | Shared HTTP request/response types where compatible with the networking stack. |
| [swiftlang/swift-subprocess](https://github.com/swiftlang/swift-subprocess) | Supported asynchronous subprocess execution; check platform/deployment requirements and bound output and process lifetimes. |
| [swiftlang/swift-docc-plugin](https://github.com/swiftlang/swift-docc-plugin) | SwiftPM documentation generation/preview for libraries and executables; a documentation dependency, not a runtime product. |

For related needs, prefer the matching upstream projects such as
[swift-nio-ssl](https://github.com/apple/swift-nio-ssl),
[swift-nio-http2](https://github.com/apple/swift-nio-http2),
[swift-nio-extras](https://github.com/apple/swift-nio-extras) and
[swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle).
Apple ownership is a preference, not a substitute for suitability and maintenance
review. Swift Testing ships with modern official toolchains; do not add an extra
package dependency merely to `import Testing`.

### Fundamental native dependencies

- Prefer original-producer implementations or established community upstreams
  for standardized foundations. Use Xiph's reference
  [libopus](https://opus-codec.org/development/) for Opus and upstream
  [FFmpeg](https://ffmpeg.org/download.html) for media processing when needed.
  Apply the same rule to other foundational libraries; avoid custom reimplementations
  and abandoned forks when a supported upstream fits.
- Choose a thin maintained SwiftPM binding, system-library target/module map or
  verified binary target around that upstream. Distinguish an official library
  from a third-party Swift wrapper or binary distributor. Do not call a wrapper
  official without producer endorsement; prefer traceable source and releases.
- Record native versions, supported architectures/platforms, headers/ABI, build
  flags/features, licensing and transitive dependencies. Verify binary checksums
  and provenance; document required system packages and linkage. Keep C pointers,
  buffers, errors and resource cleanup behind a small documented Swift boundary.
  FFmpeg feature/license choices depend on its actual build. Installing this
  guidance does not install codecs or modify host libraries.

## Ignored output and reproducible variants

- The [Swift ignore template](swift/gitignore) excludes SwiftPM/Xcode compiler
  output, DocC archives and lint cache at any component depth. Scope additional
  generated paths to their actual component. Keep `Package.swift`,
  `Package.resolved`, Xcode projects, shared schemes and `.swiftpm` configuration;
  never ignore `.swiftpm/` wholesale because it can contain shared project state.
- Pin the exact compiler/Xcode release, package resolution and build tools, then
  record SDK/deployment target, OS/architecture, Swift language mode, configuration,
  feature flags and sanitizer settings. Separate build directories/cache keys by
  those inputs and lockfile content so alternating variants retain compatible
  output. A toolchain or variant change still requires its own compilation.
- Prefer a Git submodule pinned by the superproject's full commit for Git-hosted
  source dependencies consumed directly by the build. Where appropriate, integrate
  its package with SwiftPM's local path dependency support. Keep `.gitmodules`
  and the gitlink tracked outside ignored output; restore recorded revisions with
  `git submodule update --init --recursive --checkout`. Preserve established SwiftPM remote
  dependencies and their reviewed resolution instead of duplicating them as
  submodules. Follow generated `Docs/Dependencies.md` for shared policy.
  [SwiftPM package dependencies](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html),
  [Xcode dependency resolution in CI](https://developer.apple.com/documentation/xcode/building-swift-packages-or-apps-that-use-them-in-continuous-integration-workflows).

## Additional guidance

Use the defaults above for new Swift work. Keep repository-specific exceptions,
supported platforms and tested versions explicit in this project's profile.
Complete the [DocC setup and authoring guide](swift/DocC.md) during initialization
of every Swift project; revisit affected catalogs in each implementation phase.

## Discover before changing

- Inspect package manifests, resolved dependencies, Xcode projects/workspaces,
  schemes, test plans and existing scripts. Identify whether each target is a
  library, application, executable, plugin or macro before choosing commands.
- Record the Swift language mode, tools version, SDK/deployment targets and
  concurrency settings. Preserve existing package managers and version pins;
  inspect the documentation for that toolchain before using newer features.
- Discover the actual build, test and documentation entrypoints. A package check
  and an Xcode scheme check can exercise different targets and SDKs.

## Design and lifecycle

- Keep value semantics, ownership and mutation explicit. Respect actor isolation
  and existing main-actor UI boundaries; review state assumptions across `await`.
- Prefer direct `async`/`await` and structured concurrency for new asynchronous
  work where supported. Give unstructured tasks an owner, cancellation policy and
  error handling; cancellation is cooperative and needs appropriate handling.
- Keep networking, storage, clocks and UI boundaries testable using the project's
  existing abstractions. Preserve availability checks and platform-specific code.

## Logging and diagnostics

- Use the preferred SwiftLog API for meaningful operation decisions, outcomes and
  owned lifecycle transitions. Keep event names stable and attach safe structured
  metadata and correlation context; avoid payload dumps and noisy hot-path logs.
  Logging must preserve returned errors, cancellation and control flow.
- The application owns one process bootstrap, handler selection, thresholds,
  redaction, retention and any output flushing/shutdown. Reusable libraries accept
  or use the logging API without bootstrapping or selecting destinations. Keep
  credentials and unnecessary personal or payload data out of events and metadata;
  a downstream handler cannot infer which arbitrary values are sensitive.
- Inject loggers or capture handlers for relevant diagnostic tests. Verify useful
  events, context isolation and absence of sensitive values; keep process bootstrap
  tests isolated instead of repeatedly changing global logging state in unit tests.
  Use existing logging seams without introducing a separate diagnostics framework.

## Document every callable

- Use Swift documentation comments for functions, methods, initializers,
  deinitializers, subscripts and accessors at every visibility, including private
  helpers and test code. Describe behavior, parameters/results, errors, side effects,
  isolation, ownership and cancellation where relevant. For local closures or
  callbacks, put the behavioral explanation beside their declaration or use.
- Every Swift project must include a complete native DocC documentation package,
  including applications and executables. Create a catalog for each meaningful
  documented module/target with curated module and symbol topic groups, conceptual
  articles, tutorials and a tutorial overview, runnable examples and required
  resources. Follow the [catalog structure and completion checks](swift/DocC.md).
  Finish real product content during setup; a directory tree or generated symbol
  listing does not establish completeness. Keep symbol links release-correct.
- Validate the native DocC build in the project's TeamCity checks. Include
  symbols, articles, tutorials and resources. Keep maintained project guidance
  in YouTrack and link to the reference for the applicable release when available.
- Generate and inspect the documentation using the repository's supported tools.
  Review source comments separately: successful public DocC generation does not
  prove that private or test callables are documented.

## Tests and evidence

- Prefer Swift Testing for new unit tests when supported by the selected
  toolchain (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`). Preserve
  existing XCTest suites and UI testing infrastructure;
  introducing this profile alone does not authorize a test-framework migration.
- Await asynchronous operations directly in `async` tests. Use event confirmation
  or the existing callback-testing tools when the behavior requires them; avoid
  sleeps as synchronization. Isolate fixtures because tests can execute in parallel.
- Assert observable success, failure, cancellation and relevant state transitions.
  Run affected targets and the required regression gate; record exact toolchain,
  SDK, scheme/destination or package targets and excluded checks.
- Distinguish host package tests, simulator/device checks, native non-Apple builds,
  documentation builds and hosted CI. One result does not qualify the others.

## Official references

- [Swift Testing](https://developer.apple.com/documentation/testing) and
  [testing asynchronous code](https://docs.swift.org/latest/documentation/testing/testing-asynchronous-code/).
- [Task lifecycle and cancellation](https://developer.apple.com/documentation/swift/task/).
- [DocC](https://www.swift.org/documentation/docc/) and
  [curating documentation structure](https://www.swift.org/documentation/docc/adding-structure-to-your-documentation-pages).
