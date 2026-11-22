<!-- copyright:begin
File: Docs/Languages/README.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Language guidance

Read the selected profiles relevant to the files and task being changed.
Framework profiles supplement their base language. In mixed repositories,
apply each profile within its own component; existing project choices and
explicit user instructions govern toolchain and framework decisions.

Before choosing tools or dependencies, read **Preferred tools and dependencies**
and **Additional guidance** in the relevant profiles. Use applicable preferences
for new choices; preserve established manifests, lockfiles and supported targets.
Framework preferences supplement the base language within that component.
Resolve material conflicts before changing dependencies. Unspecified entries
leave the choice open; a listed preference is not a requirement to add it.

Edit this project's copied profiles to record project-specific tools, package
identifiers, source repository or documentation links, purpose and constraints.
These local edits do not change the initializer's reusable defaults.

The root `.gitignore` combines common rules with each selected profile's
`<profile>/gitignore` fragment. Those copies are editable references; changing
one does not automatically rewrite the root file. Scope rules to component
roots in mixed projects and follow [dependency and build guidance](../Dependencies.md)
for committed pins, variants, source submodules and compatible cache reuse.

- [Swift](swift.md)

The resolved selection is recorded in `.air/project.json` under `guidance.languages`.
Profiles are instructions, not installed toolchains or configured checks.
Configure actual commands using [the testing guide](../Testing.md); an empty
validation command list remains unconfigured. Existing repositories need a
reviewed adaptation when changing selection; the generator refuses conflicting files.
