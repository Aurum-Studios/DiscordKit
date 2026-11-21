<!--
File: Docs/CI.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# DiscordKit continuous integration

DiscordKit’s TeamCity chain verifies the same candidate on Ubuntu 24.04 x64
and macOS 26 or 27 ARM64 with Swift 6.4.1. The [versioned settings](../.teamcity/settings.kts)
use the three-agent Aurum Studios fleet. The number of concurrent builds depends
on agent availability and compatibility. Hosted import and qualification are
pending. [TeamCity project setup](TeamCitySetup.md)

## Certification chain

| Phase | Work | Admission |
| --- | --- | --- |
| Qualify | Native compiler, linker, runtime, SDKs and reviewed SwiftPM inventory on both platforms | Exact VCS revision assigned |
| Build | Twelve independent package components per platform, plus Apple SDK compile checks on macOS | Both qualifications pass |
| Test | Disjoint runtime suites, browser tests, local tooling and compiler fixtures, code and release audits, public API and strict DocC, upstream review freshness | All build producers pass |
| Export and certify | Native SwiftPM source exports, the verified DocC archive and a single aggregate receipt | Every required build, test and export passes for the same revision |

The two native lanes use the existing SwiftPM graphs for the root package,
macros, extensions, tooling, load tests, benchmarks, timing support and timing
products, examples and release-mode builds. The four root groups retain the
reviewed suite allocation. The other checks consume the graphs they need.
Runtime checks use the signed-off test inventories and SwiftPM `--skip-build`.
Compiler fixtures intentionally compile their fixtures during the test phase.
Apple device and simulator SDK compilation establishes build coverage for the
configured SDKs. The [native driver](../Tools/ci/teamcity_native.py) retains the
execution commands and results for each platform.

Snapshot dependencies enforce phase barriers. Artifact dependencies use
**Build from the same chain**. Every consumer verifies the producer archive,
checked-out revision, toolchain and host compatibility, and qualification
identity before restoring it. Swift test products encode absolute paths, so
eligible agents on one platform require the same resolved checkout path and
matching execution environments. Clean checkouts isolate the mutable job output.
The default SwiftPM worker budget is two per job and the native helper also
checks observed host resources before running the bounded commands.

Start **Offline certification** (`DiscordKit_Certification`) to run the full
chain. It also owns VCS-triggered runs once the project is connected. The final
job reconciles each required job's receipt against its TeamCity build ID and the
exact VCS hash. It publishes `certification.json` only when the expected receipts
and the sealed DocC archive are present. Failed or cancelled prerequisites prevent
certification. Branch protection should use the aggregate status once the hosted
publisher has been verified. [Merge check setup](TeamCitySetup.md#switch-github-merge-checks)

The source export jobs retain a SwiftPM source bundle, a SHA-256 sidecar and
native provenance for each platform. Run the [release job](ReleaseTooling.md#manual-github-releases)
from the default branch to publish a versioned source archive for an exact
certified `main` commit. Release publication is a separate approved deployment.

The required chain covers offline Linux and macOS behavior and the declared
Apple SDK compile checks. Windows and Android remain outside the full
certification scope. Real Discord calls, Apple device runtime execution and
controlled performance claims have their own qualification evidence.

## Documentation

The macOS public API job emits and seals DocC conversions for the root, macro and
extension packages. The **MacDocumentation** configuration merges those
same-chain inputs and publishes the parts of `DiscordKitLibrary.doccarchive.tar.gz`.
Download the entire `DiscordKitLibrary.doccarchive.tar.gz.parts` directory and
reconstruct the archive from a checkout of the same revision:

```sh
python3 Tools/ci/teamcity_artifact_transport.py join \
  DiscordKitLibrary.doccarchive.tar.gz.parts DiscordKitLibrary.doccarchive.tar.gz
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

Start the independent controlled timing job for Linux or macOS to capture a
frozen pair or evaluate a recorded series against its reviewed policy. The macOS
stress, soak and integration jobs are also available manually. Set the TeamCity
context parameter `ci.periodicTiming=true` to schedule those informational jobs
weekly after sizing agent capacity. They run outside offline certification.
[Benchmark capture and comparison](../Tools/DiscordBenchmarkSupport/README.md)

## Local validation and historical evidence

Run the source and helper checks from the root without hosted credentials.

```sh
python3 Tools/ci/preflight.py source --output .build/preflight/source
python3 -m unittest discover -s Tools/ci
node --test Browser/DiscordActivityBridge/*.test.mjs
```

Generate TeamCity configuration XML against the same DSL used by the server.
Use Java 21 and Maven 3.9 for the local check.

```sh
mvn -f .teamcity/pom.xml teamcity-configs:generate
```

Historical Actions fixtures live in [the legacy CI fixture directory](../Tools/ci/legacy-actions).
The [former CI guide](https://github.com/Aurum-Studios/DiscordKit/blob/8bfc38b5d6956340442cb7e92e66678f25176846/Docs/CI.md)
and [CI reliability records](Tasks/ci-reliability/PLAN.md) document the earlier
runs, platform evidence and recovery history.
