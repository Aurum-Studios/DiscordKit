<!-- copyright:begin
File: COPYRIGHT.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Repository copyright

This is the editable copyright policy for original material in every Git-tracked
file, including source, tests, documentation, configuration, assets and tooling.
The default follows the notice style of DiscordKit, MiniCarson's reusable library.
Each generated repository owns and can modify its own copy of this policy.

## Editable notice

Edit the JSON below, then run the synchronization command. Keep the marker lines
and key names. Years are an explicit year or inclusive range; the tool never
changes them from the system clock or rewrites Git history.

<!-- copyright:settings -->
```json
{
  "creator": "Carson Rau",
  "years": "2026",
  "holder": "Aurum Studios",
  "website": "https://aurum-studios.com",
  "exclude": [
    "LICENSE*", "**/LICENSE*", "NOTICE*", "**/NOTICE*",
    "COPYING*", "**/COPYING*", "vendor/**", "**/vendor/**",
    "third_party/**", "**/third_party/**", "ThirdParty/**", "**/ThirdParty/**",
    "**/*.docc/**", "Docs/Parity/changes/2026-11-11-gateway-reconnect-budget.md",
    "Docs/Tasks/MC-29-D1/**", "Docs/Tasks/MC-33-Gateway-Recovery/**",
    "Docs/Tasks/ci-reliability/**", "Docs/Tasks/isolated-4-core-runner/**",
    "Docs/Tasks/private-http-eof-drain/**", "Tools/ci/legacy-actions/**",
    "Tests/DiscordHTTPTests/MC29RateAccountingTests.swift", "Tools/ci/artifact-sdk/**"
  ]
}
```
<!-- /copyright:settings -->

| Field | Contract |
| --- | --- |
| creator | Creator name, rendered as `Created by <creator>.` |
| years | Four-digit year or ordered `YYYY-YYYY` range |
| holder | Copyright holder, rendered as `Copyright (c) <years> <holder>.` |
| website | Absolute HTTPS company or project URL |
| exclude | Repository-relative, case-sensitive shell globs for separately owned material; do not use absolute paths, backslashes or parent traversal |

All fields are required; unknown keys, blank text, control characters and comment
delimiters are rejected before writing. Review ownership before changing these
values. The per-file `File:` line is derived from the repository-relative path.

The repository's existing [copyright notice](COPYRIGHT) and license also cover
the DocC catalogs, retained verification records and fixtures listed above.
The template check leaves their original bytes and historical notices intact.

## Update and check

Use Python 3.9 or newer and Git, from the repository root:

```sh
python3 Scripts/sync_copyright.py
python3 Scripts/sync_copyright.py --apply
```

The default check prints drift and exits 1 without writing. `--apply` updates
managed notices and exits 0 on success. Errors exit 1. `--root <folder>` selects
an explicit Git repository root. Stage intended new files with Git before
running; untracked and ignored files are outside synchronization. The tool reads
the Git index's path list and updates working-tree contents, preserving staged
content, executable modes, BOMs and existing newline conventions. Inspect the
diff and stage/commit it yourself. Commit the policy and updates together.

Supported source/configuration formats receive native comments with the creator,
copyright and website. Markdown receives an HTML comment. Frontmatter, shebangs,
Python encoding declarations, Swift toolchain directives, PHP opening tags,
Docker parser directives, CSS charsets and XML declarations keep their required
positions. PHP that starts outside a PHP block is covered centrally. Only the leading block between
`copyright:begin` and `copyright:end` is managed; body text is preserved.

Strict JSON, binaries and unknown/comment-free formats are covered by this policy
without injected text. Symlinks and submodule checkouts are never followed or
modified. Existing independent copyright notices and excluded paths retain
their own attribution and terms. The command reports inline, central and retained
file counts; inspect new formats and ownership exceptions during review. Unmerged
Git entries, unsafe paths, missing tracked files and malformed managed blocks
fail preflight before any write. An I/O failure during apply may leave partial
updates; fix the error and rerun. No Git, network or publication writes occur.

In the initializer toolkit, editing this root policy also refreshes the bundled
default on apply. Future generation applies that default to fully rendered files
and selected language resources. Existing projects keep their own policy and
conflict-protected content; updating the initializer does not rewrite them.

## Licensing and third-party material

Copyright attribution is independent of permission to use, copy or distribute
material. This policy does not select a license, grant new rights, or replace an
existing LICENSE, NOTICE, dependency license or third-party copyright. Preserve
those texts and record separately owned paths in `exclude`. Choose and review
the actual project's license independently before publication.
