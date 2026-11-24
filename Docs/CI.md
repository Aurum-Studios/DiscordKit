<!--
File: Docs/CI.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# DiscordKit continuous integration

DiscordKit’s TeamCity chain verifies the same candidate on Ubuntu 24.04 x64
and macOS 26 or 27 ARM64 with Swift 6.4.1. The [versioned settings](../.teamcity/settings.kts)
use Kotlin-defined Pipelines on TeamCity 2026.2 and the three-agent Aurum
Studios fleet. Actual concurrency depends on agent availability and
compatibility. Hosted import and qualification of the pipeline topology are
pending. [TeamCity project setup](TeamCitySetup.md)

## Certification chain

| Phase | Work | Admission |
| --- | --- | --- |
| Qualify | **CandidatePlatforms** qualifies the native compiler, linker, runtime, SDKs and reviewed SwiftPM inventory on both platforms | Exact VCS revision assigned |
| Build | Classic core, package and benchmark builds plus **ReleaseCompilation**, which checks release-mode builds on both platforms and the Apple SDKs on macOS | Both qualifications pass |
| Test | Classic core and package suites on each platform, including compiler fixtures and macOS public API and strict DocC conversions | All classic build jobs and both release compilations pass |
| Repository checks | **RepositoryVerification** runs source, Python, browser and maintenance checks and validates the YouTrack guide inventory | All classic build jobs and both release compilations pass. Runs alongside native tests. |
| Export | **CandidateExports** packages a SwiftPM source archive on each platform and assembles the macOS DocC archive | All native tests and repository checks pass |
| Certify | Classic **Offline certification** checks the required job receipts and reconstructs and hashes the DocC archive | All prerequisites and artifacts come from the same candidate chain |

These four pipelines use four pipeline slots. The project defines 15 classic
configurations by default, down from 26. Release preparation and approved
publication add two, for 17 instead of 28. The classic configuration count
includes six native build configurations, four native test configurations,
the certification gate, upstream review and three timing configurations.
TeamCity Professional accounts for pipeline slots separately.
[TeamCity licensing](https://www.jetbrains.com/help/teamcity/licensing-policy.html)

The native configurations use the existing SwiftPM graphs for the root package,
macros, extensions, tooling, load tests, benchmarks, timing support and timing
products, examples and release-mode builds. The four root groups retain the
reviewed suite allocation. The other checks consume the graphs they need.
Runtime checks use the signed-off test inventories and SwiftPM `--skip-build`.
Compiler fixtures intentionally compile their fixtures during the test phase.
Apple device and simulator SDK compilation establishes build coverage for the
configured SDKs. The [native driver](../Tools/ci/teamcity_native.py) retains the
execution commands and results for each platform.

Snapshot dependencies synchronize revisions and enforce the phase barriers.
Artifact dependencies select **Build from the same chain**. Every SwiftPM
consumer verifies archive contents, revision, toolchain, host compatibility
and qualification identity before restoring. The native build and test
configurations that exchange SwiftPM products use a fixed checkout path.
Classic same-agent dependencies keep Linux producers and their consumers on
the same native Linux or Windows WSL agent. Independent bundles can use
separate compatible agents. [TeamCity dependencies](https://www.jetbrains.com/help/teamcity/configuring-dependencies.html)

Between test groups, the native driver clears the selected SwiftPM output
before restoring its verified archive. Each phase keeps separate diagnostics.
The default SwiftPM worker budget is two per job. The native helper also checks
observed host resources before starting bounded commands.

TeamCity uploads each archive part as a separate file. Use artifact directory
names such as `root-tar-gz-parts` so TeamCity treats the destination as a
directory and keeps each file separate. The consumer verifies the manifest
and reconstructs `root.tar.gz` before restoring the native build.

Native jobs also bundle diagnostics into `evidence-tar-gz-parts`, including
evidence collected before a failed command. Download the directory and use
the same `join` command with `evidence.tar.gz` as the output, then extract it
to inspect the logs and reports.

Start **Offline certification** (`DiscordKit_Certification`) to run the full
chain. It also owns VCS-triggered runs once the project is connected. The final
job reconciles each required classic configuration and each required pipeline
job against its own TeamCity build ID and the exact VCS hash. It publishes
`certification.json` only after all expected receipts and the sealed DocC
archive verify. Failed or cancelled prerequisites prevent certification.
When GitHub status publishing is configured, the same classic configuration
reports the merge check. [Merge check setup](TeamCitySetup.md#switch-github-merge-checks)

The source export jobs retain a SwiftPM source bundle, a SHA-256 sidecar and
native provenance for each platform. Run the [release job](ReleaseTooling.md#manual-github-releases)
from the default branch to publish a versioned source archive for an exact
certified `main` commit. Release publication is a separate approved deployment.

The required chain covers offline Linux and macOS behavior and the declared
Apple SDK compile checks. Windows and Android remain outside the full
certification scope. Real Discord calls, Apple device runtime execution and
controlled performance claims have their own qualification evidence.

## Documentation

The macOS core test configuration emits and seals DocC conversions for the
root, macro and extension packages. The macOS documentation job in
**CandidateExports** merges those same-chain inputs. In the run's artifacts,
open the documentation job's artifact group and download the entire
`DiscordKitLibrary-doccarchive-tar-gz-parts` directory, including `manifest.json`.
From a checkout of the same revision, reconstruct and extract the archive.

```sh
python3 Tools/ci/teamcity_artifact_transport.py join \
  DiscordKitLibrary-doccarchive-tar-gz-parts DiscordKitLibrary.doccarchive.tar.gz
tar -xzf DiscordKitLibrary.doccarchive.tar.gz
```

Open `DiscordKitLibrary.doccarchive` in Xcode. Certification records the
reconstructed archive's SHA-256 digest. TeamCity transports native build bundles,
DocC inputs, and the final DocC bundle as files of up to 32 MiB. Consumers verify
each part and the full archive before using it.

## Maintenance and timing

**Upstream review evidence** retains the weekly official-source collection and
can also run manually. A maintainer reviews the evidence and updates the committed
`Docs/Release/maintenance.json` when appropriate. The separate freshness gate
reports an expired review and keeps the candidate uncertified until the record
is current. [Upstream review procedure](ReleaseTooling.md#upstream-review-and-dated-transitions)

Start the controlled timing job for Linux or macOS to capture a frozen pair
or evaluate a recorded series against its reviewed policy. To run periodic
timing manually, open **Informational timing / macos-arm64**
(`DiscordKit_TimingStress`) and set `timing.profile` to `all` (default),
`stress`, `soak` or `integration`. The run retains artifacts under
`timing/<profile>`. The `all` selection runs the profiles sequentially and
records a failure if any profile fails. Set `ci.periodicTiming=true` to schedule
`all` on Sundays at 07:41 in TeamCity's schedule timezone. Timing runs
independently of Offline certification.
[Benchmark capture and comparison](../Tools/DiscordBenchmarkSupport/README.md)

## Local validation and historical evidence

Run the source and helper checks from the root without hosted credentials.

```sh
python3 Tools/ci/preflight.py source --output .build/preflight/source
python3 -m unittest discover -s Tools/ci
node --test Browser/DiscordActivityBridge/*.test.mjs
```

Generate classic configuration XML and pipeline definitions against the
TeamCity 2026.2 DSL used by the server. Use Java 21 and Maven 3.9.

```sh
mvn -f .teamcity/pom.xml teamcity-configs:generate
```

Historical Actions fixtures live in [the legacy CI fixture directory](../Tools/ci/legacy-actions).
The [former CI guide](https://github.com/Aurum-Studios/DiscordKit/blob/8bfc38b5d6956340442cb7e92e66678f25176846/Docs/CI.md)
and [CI reliability records](Tasks/ci-reliability/PLAN.md) document the earlier
runs, platform evidence and recovery history.
