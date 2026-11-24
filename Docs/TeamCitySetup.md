<!-- copyright:begin
File: Docs/TeamCitySetup.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Set up DiscordKit on TeamCity and YouTrack

DiscordKit adopts the portable Kotlin DSL and Air workflow from the private Aurum
Studios Blank template. TeamCity owns build, test, validation and release jobs.
YouTrack is the destination for issues and the project Knowledge Base. GitHub
continues to host the source and release assets.

## GitHub Actions retirement

GitHub Actions was disabled at repository level on November 21, 2026. GitHub
read-back confirmed that setting and returned no active runs. Keep Actions
disabled while qualifying TeamCity. Existing required checks, if any, can
block merging until the verified TeamCity check replaces them.
[GitHub Actions settings](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository)

## Create the YouTrack project

1. Check the Aurum Studios tracker for an existing DiscordKit project before
   creating a standard issue-tracking project named **DiscordKit**. Use
   `DISCORDKIT` as the project key if available and set the intended project
   lead and team. [Aurum Studios YouTrack](https://issues.aurum-studios.com),
   [YouTrack project API](https://www.jetbrains.com/help/youtrack/devportal/resource-api-admin-projects.html)
2. Record the verified project key in `.air/project.json`. Apply Blank's Air
   fields and board if the project is empty. For REST provisioning, use an
   account that can see all project issues and articles and manage its fields,
   bundles and board. Set
   `YOUTRACK_URL=https://issues.aurum-studios.com` and provide
   `YOUTRACK_TOKEN` through the trusted environment or secret manager. Use the
   schema read-back to record actual State field and value IDs. For an existing
   populated project, map its current State values through read-only discovery.
   [Adopted repository setup](YouTrack/Automatic-Setup.md#configure-an-adopted-repository)
3. Verify issue links and Air state transitions with the intended team. Confirm
   the article audience and source inventory before seeding the project
   library. [Knowledge Base setup](YouTrack/Knowledge-Base.md)

## Import the TeamCity project

For programmatic provisioning, set `TEAMCITY_URL=https://ci.aurum-studios.com`
and supply `TEAMCITY_TOKEN` through the trusted environment or secret manager.
Use an account with access to create the project, manage its VCS root and
versioned settings, and assign the intended agent pools. The pipeline topology
requires TeamCity 2026.2 or newer. Check the server version before importing.
[TeamCity authentication](https://www.jetbrains.com/help/teamcity/teamcity-cli-authentication.html)
[Kotlin DSL for pipelines](https://www.jetbrains.com/help/teamcity/pipelines-dsl.html)

1. Look up **DiscordKit** by external project ID `DiscordKit` and create it if
   absent. Add a Git VCS root for
   `https://github.com/Aurum-Studios/DiscordKit.git` with default
   branch `refs/heads/main` and branch specification `+:refs/heads/main`. Enable
   full agent-side checkout so historical certified commits are available to the
   release job. Add trusted review branches to the specification as needed for
   merge checks. [Aurum Studios TeamCity](https://ci.aurum-studios.com)
2. When the migration revision is available to TeamCity, enable **Versioned
   Settings** on the VCS root and import the portable Kotlin DSL from
   `.teamcity`. Store secure values outside VCS and use approved default-branch
   settings when running review revisions. Check the import status against the
   expected Git commit and inspect the classic configurations and pipelines.
   [Versioned settings](https://www.jetbrains.com/help/teamcity/storing-project-settings-in-version-control.html)
3. In the project, use **Actions → Generate token for a secure value** to store
   a YouTrack permanent token scoped to reading the DiscordKit project. In
   **Versioned Settings → Context Parameters**, set `youtrack.projectIds` to
   the verified project key and `youtrack.tokenRef` to the complete generated
   `credentialsJSON:` reference. Save them together. Verify that a real issue
   ID in a commit message links to YouTrack from the build's **Changes** tab.
   [TeamCity YouTrack integration](https://www.jetbrains.com/help/teamcity/youtrack.html)

## Configure R2 artifact storage

The DiscordKit project publishes new build artifacts to the private Standard R2
bucket `discordkit-builds` when the storage context is configured. Create an R2
S3 credential with **Object Read & Write** scoped to that bucket and keep public
access disabled. [Cloudflare R2 credentials](https://developers.cloudflare.com/r2/api/tokens/)

In **Versioned Settings → Context Parameters**, set the following values together.
Use **Actions → Generate token for a secure value** in the DiscordKit project
to store the secret access key and obtain its reference.

| Context parameter | Server value |
| --- | --- |
| `artifactStorage.r2AccountId` | Cloudflare account ID, 32 lowercase hexadecimal characters |
| `artifactStorage.r2AccessKeyId` | Bucket-scoped R2 S3 access key ID, 32 lowercase hexadecimal characters |
| `artifactStorage.r2SecretRef` | TeamCity `credentialsJSON:` reference to the R2 S3 secret access key |

With all three parameters empty, the DSL leaves storage selection to TeamCity's
default or inherited settings. Partial or malformed values fail settings
generation. When all three are configured, the DSL activates
`DiscordKitPrivateArtifacts` with presigned uploads, path-style addressing and
post-upload integrity checks. [TeamCity S3-compatible storage](https://www.jetbrains.com/help/teamcity/storing-build-artifacts-in-amazon-s3.html)

1. Verify the expected settings revision imported successfully and confirm in
   **Artifacts Storage** that `DiscordKitPrivateArtifacts` is active for DiscordKit.
2. Run **Offline certification** for the imported revision with fresh producer
   builds. Check that a native compile job publishes its archive parts and
   manifest to R2 and that a dependent native test restores them from the same
   producer. Verify the pipeline DocC export and fetch the final
   `certification.json` through the TeamCity REST artifact endpoint with
   `responseBuilder=core`, as release preparation does. To measure impact,
   compare upload and dependency download times for similar artifact sizes and
   agent placements. Account for any agent cache hits.
3. Keep prior storage available for older builds and use TeamCity cleanup rules
   for retention. If new uploads need to return to built-in storage, import a
   settings revision with `DiscordKitActiveArtifacts` selecting `DefaultStorage`.
   Keep the R2 registration and its working credentials so retained R2 artifacts
   remain readable. Verify new publication and representative older downloads.
   [TeamCity active storage](https://teamcity.jetbrains.com/app/dsl-documentation/projectFeatures/active-storage/index.html)

## Move an existing project to pipelines

1. Record the current settings revision, the project’s classic configuration
   IDs, and the GitHub check used by branch protection. Preserve any historical
   artifacts and job receipts needed from configurations that will be retired.
   Before import, check **Administration → Licenses** or read
   `GET /app/rest/server/licensingData` with an authorized account. Record
   `buildTypesLeft` and `pipelinesLeft` to compare before and after the change.
   [TeamCity licensing data](https://www.jetbrains.com/help/teamcity/rest/licensingdata.html)
2. Once the new revision is available, verify **Versioned Settings** reports a
   successful import of that revision. Check that DiscordKit has four
   pipelines and 15 classic configurations, or 17 if release publishing is
   enabled. Check the retired classic IDs and the server license counters.
   Archived configurations continue to count toward the license limit. TeamCity
   can remove the history of deleted configurations after its cleanup grace
   period, so preserve needed evidence before removing a leftover configuration.
   [TeamCity licensing](https://www.jetbrains.com/help/teamcity/licensing-policy.html)
   [Deleted configuration cleanup](https://www.jetbrains.com/help/teamcity/copy-move-delete-build-configuration.html)
3. Run **Offline certification** for the imported commit on `main` and verify the
   phase and agent placement checks below. Inspect the pipeline job artifact
   groups, the same-chain artifact sources, and the final `certification.json`.
   Confirm that every prerequisite points to its exact TeamCity build ID and
   that the GitHub status still appears on the same commit under the existing
   check context. Confirm that a failed or cancelled dependency withholds
   certification. [Certification chain](CI.md#certification-chain)
4. If the imported topology fails qualification, revert the settings change on
   the versioned settings branch. Check available classic configuration slots
   first because the older topology requires more of them. Verify the reverted
   settings import and run **Offline certification** on the rollback revision.
   Preserve the failed run and import diagnostics for comparison.

## Qualify the three build agents

Assign the three agents to pools available to DiscordKit. Verify compatible
agents by OS and architecture for classic configurations and pipeline jobs.
Jobs check the installed tools at runtime and report their versions. Provide
Git and Python 3.12 or newer on each agent. The browser bridge and CI helper
checks also require Node.js 24 and npm on the Linux agent.

Qualify Ubuntu 24.04 x64 and macOS 26 or 27 ARM64 with Swift 6.4.1. Native Linux
steps run directly on the existing containerized TeamCity agent. Its image
contains the [official Swift toolchain](https://hub.docker.com/_/swift) pinned
by digest in the TeamCity settings and reports the matching
`DISCORDKIT_AGENT_SWIFT_IMAGE` environment value. The DiscordKit native steps
select `/opt/discordkit/swift/usr/bin` when that dedicated toolchain is present.
Qualification records the image, observed compiler, linker, runtime library
hashes and Ubuntu package versions. The macOS job verifies the Swift package's
digest and notarized vendor signature, then unpacks it with `pkgutil` into
`~/.cache/aurum/discordkit/toolchain`. It can use framework Python 3.14 and
Xcode-beta when the agent's defaults do not satisfy the runtime checks.

Give compatible agents the same absolute TeamCity checkout path within each platform so
transferred SwiftPM products can resolve paths. On a shared host or filesystem,
use distinct physical work directories for the agents and map them to the
common checkout path inside each agent's environment. Compare the actual SDK
and toolchain paths, OS and kernel, and Linux Swift runtime libraries before
admitting agents that exchange native artifacts. [CI lanes and evidence](CI.md),
[Agent pools](https://www.jetbrains.com/help/teamcity/configuring-agent-pools.html)

The Linux certification jobs can also use `windows.ci.aurum-studios.com`
through its `AurumCI` WSL2 distribution. The Windows service account must
be able to launch the distribution and use a full Git checkout. Inside WSL,
provide the verified Ubuntu 24.04 x64 toolchain, including Swift 6.4.1 at
`/opt/discordkit/swift/usr/bin` and Python 3.12 or newer. Repository checks use
Linux Node.js 24 and npm, with a checksum-verified download when needed.
The bridge stages the exact TeamCity revision and inputs in a clean,
locked checkout on the distribution's Linux filesystem. After execution it
transfers the selected artifacts back to the Windows checkout for upload.
TeamCity keeps each Linux compile-and-test group on one agent so SwiftPM
paths and the full host compatibility facts match. Independent groups can
run on different agents.

Confirm compatibility on both agents after importing the DSL. To use a
different installed distribution, set the versioned settings context parameter
`ci.windowsWslDistribution`. Set it to an empty value to disable WSL routing,
or set `ci.windowsWslNative=false` to keep the Swift jobs on native Linux while
the repository checks, guide validation and certification remain eligible for WSL.
[Microsoft WSL command reference](https://learn.microsoft.com/en-us/windows/wsl/basic-commands)

Run **Offline certification** on a known `main` revision after TeamCity imports
the settings for that commit. Verify that both platform qualifications finish
before native compilation starts. Verify that all classic builds and both
release compilations finish before native tests and repository verification
start. Check that native test bundles restore only their matching producers.
Both source exports and the DocC assembly wait for all native tests and
repository verification.
The aggregate result must cover every required check for the selected SHA.

## Enable GitHub release publishing

The release configuration appears after you set its connection and required
parameters. Use a TeamCity GitHub App connection with **Enable build-scoped
tokens** selected, following Foilward and Pagebright. Confirm that the App
installation includes `Aurum-Studios/DiscordKit` and grants the **Contents**
write permission used to create tags and releases. TeamCity issues a scoped
installation token for each release build.
[Build-scoped tokens](https://www.jetbrains.com/help/teamcity/build-scoped-token.html)

| Context parameter | Server value |
| --- | --- |
| `github.releaseConnectionId` | TeamCity GitHub App connection ID for DiscordKit |
| `github.releaseApprover` | TeamCity username authorized to approve publication |
| `github.releaseAgentName` | Exact TeamCity name of the trusted release agent |
| `teamcity.certificationTokenRef` | `credentialsJSON:` reference for a TeamCity token that can read DiscordKit certification and artifacts |
| `github.readTokenRef` | Optional `credentialsJSON:` reference for an authenticated GitHub metadata read during release preparation |

Store the certification token through **Generate token for a secure value** and
enter its reference in the context parameter. After TeamCity imports the current
release settings, open a finished, successful **Offline certification** build on
`main` and confirm that **Actions → Promote** lists **Publish GitHub release**.
Use the current server settings if the promotion dialog offers a settings
choice. When a release is authorized, confirm that it waits for the named
approver, reuses the selected certification and appends its displayed build
number to the entered version. [Release procedure](ReleaseTooling.md#manual-github-releases)

## Switch GitHub merge checks

Store a GitHub token with commit-status write access in TeamCity and set
`github.statusTokenRef` to its `credentialsJSON:` reference. For trusted
GitHub pull-request builds, provide a token with pull-request read access and
set `github.pullRequests=true`. Verify that TeamCity publishes the aggregate
result for the expected SHA on GitHub. Replace any obsolete Actions check in
the repository's active rulesets or branch protection with the observed
TeamCity check. Verify that a failing or incomplete TeamCity run blocks
merging. [TeamCity Commit Status Publisher](https://www.jetbrains.com/help/teamcity/commit-status-publisher.html)

## Retain DocC artifacts

The macOS documentation job in **CandidateExports** retains the archive parts
and a SHA-256 manifest. Follow the download and reconstruction steps to open
the bundle in Xcode. The chain certificate records the reconstructed archive
digest and source SHA. [Download the DocC archive](CI.md#documentation)
