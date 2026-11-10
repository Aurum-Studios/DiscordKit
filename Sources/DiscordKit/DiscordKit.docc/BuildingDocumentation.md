[//]: # "File: Sources/DiscordKit/DiscordKit.docc/BuildingDocumentation.md | Created by Carson Rau. | Copyright (c) 2026 Aurum Studios. | https://aurum-studios.com"

# Build and maintain the documentation

Generate independent product archives and a combined library archive with strict DocC diagnostics.

## Overview

### Build locally

Use the Swift 6.4.1 toolchain pinned by CI and its accompanying DocC:

```sh
python3 Tools/ci/emit_symbol_graphs.py --jobs 5
python3 Tools/ci/curate_docc.py --check
python3 Tools/ci/documentation_examples.py
python3 Tools/ci/build_docc.py
```

The emission helper uses the native SwiftPM build engine and committed dependency pins, disables experimental prebuilt dependencies, and normalizes graphs into `.build/out/symbolgraph`. It explicitly requests extension-block symbols so DocC can resolve public extensions to foreign types, including the `DiscordCore/Swift` and `DiscordCommandDSL/Swift` namespaces. The converter handles each root public library module, preserving its primary and owned extension graphs. It enables warnings as errors, diagnostic analysis and public documentation coverage. The umbrella catalog resolves cross-product contents links against those archives. DocC then merges them into `.build/documentation/DiscordKitLibrary.doccarchive` with one library navigator. The macro and extension packages emit separate graphs and catalogs; validate those packages explicitly as described in the repository release-tooling guide.

Open the merged archive in Xcode, or preview the umbrella catalog with the installed DocC command and the appropriate symbol graphs.

### Build the documentation website

Browse the [hosted documentation](https://aurum-studios.github.io/DiscordKit/). The independent Documentation workflow builds on every push and pull request alongside CI, then publishes successful default-branch builds to GitHub Pages. Pull requests and other branches produce a site artifact without publishing.

The workflow checks the macOS ARM64 platform, compiles the three packages independently with a five-job limit, and restores their sealed artifacts for conversion without recompiling. Artifacts must match the commit, workflow run and attempt, checkout path and toolchain. Python helpers run separately on the small Linux pool; publication requires both helper checks and site conversion to pass. A workflow rerun must use **Re-run all jobs** to produce matching compilation artifacts.

To reproduce the website build locally:

```sh
python3 Tools/ci/build_documentation_site.py --jobs 5 --hosting-base-path /DiscordKit
```

The helper emits public symbol graphs for the root, macro and extension packages with the native emission helper and bounded compiler jobs, validates curation and tutorial snapshots, converts the catalogs with strict diagnostics, and merges all public modules into one navigator. CI uses `--skip-symbol-graphs` after verifying and restoring compiled artifacts; this mode requires valid graphs for every public module. It exports `.build/documentation-site` using DocC's static-hosting transformation, including direct article and symbol routes and a root redirect to the library landing page. The local command generates files; the GitHub workflow handles publication. Use an empty hosting base path to serve at a domain root.

### Documentation layout

Each product has a catalog alongside its Swift source. The module page curates authored guides and an APIReference article. Reference pages extend the matching symbols and group initializers, cases, properties, methods, nested types and other members while retaining inline declaration documentation. Source comments describe precise parameter, error, concurrency and ownership contracts; guides explain how the pieces compose.

The umbrella catalog contains the package contents, learning paths, application recipes, operational guides, tutorial contents and twelve tutorials. Tutorial code resources mirror the independent examples and selected extension-library source. They use text resource suffixes to keep displayed manifest/example listings separate from compiled target source.

### Update a public API

1. Update the declaration's documentation and meaningful tests with its implementation.
2. Emit fresh public symbol graphs on the same platform/toolchain scope.
3. Run `python3 Tools/ci/curate_docc.py --write` and review the type/member curation diff.
4. Update the relevant task guide, tutorial or example for changed behavior.
5. Run `python3 Tools/ci/documentation_examples.py --write` when example code changes, then review its displayed snapshots.
6. Run the nonwriting checks and strict conversion again.

Reference generation uses compiler-produced ownership/member relationships and unambiguous symbol links. It never fetches upstream documentation or executes during a consumer build. Platform-specific public declarations require graphs from that platform; a macOS-generated reference inventory cannot establish the availability of a conditionally compiled Windows or Android API.

After changing the CI toolchain, emit fresh graphs with that same compiler and rerun curation with `--write` for the root, macro and extension packages. Compiler changes can expose additional public API even when source declarations are unchanged. For example, Swift 6.4.1 includes the public `@TaskLocal` projections `$configuration`, `$context` and `$loggerFactory` in `DiscordLog`'s graph; these provide the scoped `withValue` API and belong in its reference navigation. Review the generated diff, then run the nonwriting checks and strict conversion again.

### Validate content as well as syntax

```sh
python3 -m unittest discover -s Tools/ci -p 'test_*.py'
swift run --package-path Tools/DiscordKitTools DiscordKitTools documentation audit --repository .
python3 Tools/DiscordKitTools/scripts/release_check.py graph --repository .
```

Build each affected independent example, run its offline tests, and inspect representative rendered articles, tutorial listings and type pages. DocC validates syntax, resources and symbol links; it does not typecheck arbitrary fenced snippets or prove semantic completeness. Documentation coverage and source-comment presence are separate checks from live-service, device, platform and cryptographic qualification.

See the [DocC documentation](https://www.swift.org/documentation/docc) for authoring directives and the [repository validation guide](https://github.com/Aurum-Studios/DiscordKit/blob/main/Docs/CI.md) for the broader pipeline.
