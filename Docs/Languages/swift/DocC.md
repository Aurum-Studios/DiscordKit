<!-- copyright:begin
File: Docs/Languages/swift/DocC.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Complete Swift DocC setup

Use this guide when initializing or maintaining any Swift project: libraries,
applications, command-line executables, plugins and macros. It supplements the
[Swift profile](../swift.md). The initializer must author a real catalog against
the project's targets before calling Swift setup complete. This guide and its
illustrative examples are authoring material, not the project's finished docs.

## Discover targets and configure generation

1. Inspect Package.swift and Xcode targets/schemes, supported platforms, source
   layout and existing catalogs. Identify which modules need independent reference
   and how users enter the product. Preserve useful existing content.
2. Use the official [Swift-DocC plugin](https://github.com/swiftlang/swift-docc-plugin)
   for SwiftPM packages. Add a current compatible stable release to the manifest's
   package dependencies, without linking a runtime product. Record its reviewed
   requirement and resolution. Use Xcode's documentation build for targets needing
   its SDKs/resources; inspect the real scheme and destination before configuring
   `xcodebuild docbuild`.
3. For each meaningful documented Swift module, add a target-owned catalog such
   as `Sources/TargetName/TargetName.docc`. In an Xcode project, include the catalog
   in the appropriate target. Align catalog and module names with actual symbol
   graphs. Do not invent a library product solely to generate documentation for
   an executable; the plugin supports executables too.
4. Define the public distribution audience and contributor audience. Public
   libraries normally expose public/open symbol graphs; internal application or
   executable documentation may need `--symbol-graph-minimum-access-level internal`
   on supported plugin versions. Keep internal material out of public publication.
   Source comments at every visibility remain required regardless of graph scope.
5. Configure real generation and preview commands in the repository's scripts
   and validation records. Run them, retain diagnostics and inspect the rendered
   entrypoints; do not leave the documentation command unconfigured at completion.

## Required catalog content

Replace `SampleKit` and `Greeting` throughout this illustrative layout with actual
module and symbol names. Organize by user goals and domain concepts; adapt the
article set to implemented behavior instead of adding empty pages.

```text
Sources/SampleKit/SampleKit.docc/
  SampleKit.md
  GettingStarted.md
  Architecture.md
  ConcurrencyAndLifecycle.md
  Troubleshooting.md
  Symbols/
    Greeting.md
  Tutorials/
    Tutorials.tutorial
    FirstWorkflow.tutorial
  Resources/
    first-workflow.swift
    greeting-flow.svg
```

- **Module landing:** explain the module's purpose, audience, supported use and
  entrypoints. Curate `## Topics` into meaningful `###` groups with articles,
  important types/functions and tutorials. Avoid an unstructured symbol dump.
- **Symbols:** document types and every member in source. Add symbol extension
  pages where longer explanations or custom member organization help. Use DocC
  symbol links, including disambiguated links for overloads; let generated
  relationships handle inherited API. Keep type member groups useful and complete.
- **Articles:** cover installation and first success; architecture/dependency
  boundaries; concurrency, ownership, cancellation and shutdown; error handling,
  troubleshooting and recovery. Add configuration, native interop, compatibility,
  migration and operations articles when the product has those concerns.
- **Tutorials:** include a tutorial overview/table of contents and at least one
  end-to-end tutorial using real APIs, prerequisites, ordered steps, explanations,
  complete runnable code and expected results. Include cleanup and a next step.
- **Resources:** check in actual code listings, downloads and meaningful diagrams,
  images or video when useful. Give media accessible descriptions, use unique
  names and ensure directives resolve the exact resources. Do not add empty
  artwork or files just to populate the tree.

Link the catalog from the product README/documentation index and link relevant
guides back to symbols. Maintain a coherent navigation path across modules.

## Module landing and symbol organization

For a module exposing a documented `Greeting` type with a documented static
`message(for:)` method, its landing page can begin as follows. Replace the prose
and symbols with the product's actual contract.

```markdown
# ``SampleKit``

Create a greeting for a named recipient.

## Overview

SampleKit demonstrates a synchronous, side-effect-free API. Start with the setup
article, then complete the tutorial and explore the reference.

## Topics

### Get started
- <doc:GettingStarted>
- <doc:Tutorials>

### Understand the design
- <doc:Architecture>
- <doc:ConcurrencyAndLifecycle>

### Create greetings
- ``Greeting``

### Resolve problems
- <doc:Troubleshooting>
```

A symbol extension page adds discussion and custom member groups without
duplicating the source declaration's parameter contract:

```markdown
# ``SampleKit/Greeting``

Create messages for named recipients.

## Topics

### Generate a message
- ``message(for:)``
```

Write conceptual articles as titled Markdown pages with useful abstracts,
prerequisites, explanations and links to real symbols. `GettingStarted.md` must
give the actual package URL/product or application setup, supported versions and
a runnable first example with its expected output. Explain applicable failure
paths; do not replace missing contracts with generic headings.

## Tutorial overview and executable steps

This example assumes a SwiftPM executable client already depends on SampleKit
and has a `Sources/Client/main.swift` entrypoint. The finished product tutorial
must explain how to establish that starting state, including its actual manifest
dependency and target product, rather than assuming an undocumented setup.

An overview in `Tutorials/Tutorials.tutorial` links the individual lessons:

```text
@Tutorials(name: "SampleKit") {
    @Intro(title: "Build with SampleKit") {
        Learn to call the greeting API from a SwiftPM client.
    }
    @Chapter(name: "First steps") {
        Create and run a first greeting.
        @Image(source: "greeting-flow.svg", alt: "Client calls Greeting.message and prints its result.")
        @TutorialReference(tutorial: "doc:FirstWorkflow")
    }
}
```

A complete first lesson in `Tutorials/FirstWorkflow.tutorial` can use this
structure. Larger workflows should use multiple steps and progressive, runnable
code listings rather than a single unexplained final file.

```text
@Tutorial(time: 5) {
    @Intro(title: "Create your first greeting") {
        Start with the SwiftPM Client executable configured in GettingStarted.
        You need the supported stable Swift toolchain and its SampleKit dependency.
    }
    @Section(title: "Call the API") {
        @ContentAndMedia {
            Replace the client's main.swift with the code below. The call returns
            a message without performing I/O; the client prints that result.
        }
        @Steps {
            @Step {
                Import SampleKit and create a greeting for Taylor.
                @Code(name: "main.swift", file: "first-workflow.swift")
            }
            @Step {
                From the client package root, run `swift run Client`.
                Expect `Hello, Taylor!` on standard output and exit status zero.
            }
        }
    }
    @Section(title: "Finish and continue") {
        @ContentAndMedia {
            Review the result and explore the API's design.
        }
        @Steps {
            @Step {
                No persistent resources were created. Keep the example for reuse
                or remove the disposable client.
            }
            @Step {
                Continue with <doc:Architecture> to understand the API's design
                and extension points.
            }
        }
    }
}
```

The referenced `Resources/first-workflow.swift` contains the complete client:

```swift
// Tutorial client: print one greeting using the package's public API.
import SampleKit

print(Greeting.message(for: "Taylor"))
```

The overview's chapter requires an image. Save this small diagram as
`Resources/greeting-flow.svg`, or supply a product-specific illustration with
an accurate accessible description:

```xml
<svg xmlns="http://www.w3.org/2000/svg" width="600" height="100" viewBox="0 0 600 100">
  <title>Client calls Greeting.message and prints its result</title>
  <rect width="600" height="100" fill="white"/>
  <g fill="none" stroke="black" stroke-width="2">
    <rect x="10" y="20" width="160" height="60" rx="8"/>
    <path d="M170 50h70m-12-8 12 8-12 8"/>
    <rect x="240" y="20" width="350" height="60" rx="8"/>
  </g>
  <g fill="black" font-family="sans-serif" font-size="20" text-anchor="middle">
    <text x="90" y="57">Client</text>
    <text x="415" y="57">Greeting.message(for:)</text>
  </g>
</svg>
```

Compile/run the tutorial against the same release and platforms that the docs
describe. Add example tests where they verify meaningful API behavior; compare
the actual output. DocC rendering alone does not compile code listings.

## Build, preview and inspect

With a compatible stable plugin already declared, run from the SwiftPM package
root. Replace `SampleKit` with the actual target and give separate targets unique
archive paths. The plugin builds the target and collects its symbol graph:

```sh
mkdir -p .build/docc
swift package --allow-writing-to-directory .build/docc generate-documentation \
  --target SampleKit --output-path .build/docc/SampleKit.doccarchive \
  --analyze --warnings-as-errors
swift package --disable-sandbox preview-documentation --target SampleKit
```

Inspect `swift package generate-documentation --help` for the selected plugin and
toolchain before adopting flags. The documented local preview command disables
SwiftPM's subprocess sandbox so the trusted DocC plugin can open its local HTTP
server on macOS; use it for a reviewed plugin and local preview. For Xcode, record the scheme, SDK/destination,
toolchain and resulting archive location separately. Keep generated archives,
sites and caches out of source control; check in the catalog and intended assets.

Treat unresolved symbol/doc/resource links, missing abstract warnings and other
DocC diagnostics as failures. Review rendered module landing pages, topic groups,
member navigation, article paths, tutorial steps/code/media, accessibility and
cross-module links. Review private/test source contracts separately; neither
SwiftLint's presence check nor public symbol generation proves their completeness.

Use the project's TeamCity checks to qualify the actual DocC build. Include
navigable symbols, articles, tutorials and resources. Keep maintained project
guidance in YouTrack. If the project has a separately approved destination for
native reference, use supported `--transform-for-static-hosting` and
`--hosting-base-path` options as needed. Verify the index, linked assets and
navigation at the intended path before delivering the reference.

Record the exact revision, Swift/Xcode/plugin versions, targets/access scope,
commands, diagnostics, example execution and rendered review in the project's
verification evidence. A complete setup includes actual content and passing
checks; a scaffold alone remains pending.

## Official references

- [Swift-DocC plugin commands and permissions](https://github.com/swiftlang/swift-docc-plugin).
- [Organizing documentation](https://docs.swift.org/latest/documentation/docc/adding-structure-to-your-documentation-pages/).
- [Tutorial authoring syntax](https://github.com/swiftlang/swift-docc/blob/main/Sources/docc/DocCDocumentation.docc/Reference%20Syntax/Tutorials%20Syntax/building-an-interactive-tutorial.md).
