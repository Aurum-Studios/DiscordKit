// copyright:begin
// File: .teamcity/Builds.kt
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com
// copyright:end

import jetbrains.buildServer.configs.kotlin.*
import jetbrains.buildServer.configs.kotlin.buildFeatures.CommitStatusPublisher
import jetbrains.buildServer.configs.kotlin.buildFeatures.PullRequests
import jetbrains.buildServer.configs.kotlin.buildFeatures.commitStatusPublisher
import jetbrains.buildServer.configs.kotlin.buildFeatures.pullRequests
import jetbrains.buildServer.configs.kotlin.buildSteps.script
import jetbrains.buildServer.configs.kotlin.triggers.ScheduleTrigger
import jetbrains.buildServer.configs.kotlin.triggers.schedule
import jetbrains.buildServer.configs.kotlin.triggers.vcs

internal const val incoming = ".build/teamcity/in"
internal const val output = ".build/teamcity/out"
internal const val defaultBranch = "+:<default>"
internal const val repositoryName = "Aurum-Studios/DiscordKit"
internal const val currentBuildId = "%teamcity.build.id%"
private const val receiptBuildId = "discordkit.build.id"
private const val doccArtifact = "DiscordKitLibrary.doccarchive.tar.gz"
private const val candidateBranches = "+:*\n-:gh-pages\n-:refs/heads/gh-pages"
private const val linuxSwiftImage = "docker.io/library/swift:6.4.1-noble@sha256:6304481cf2717966b7ba175162e397ea2f2cc3161909f2b2a5cf40036079a0f7"
private const val linuxAgent = "linux.ci.aurum-studios.com"
private const val windowsAgent = "windows.ci.aurum-studios.com"
private val windowsWslDistribution = DslContext.getParameter("ci.windowsWslDistribution", "AurumCI").also {
    require(it.isEmpty() || it.matches(Regex("[A-Za-z0-9][A-Za-z0-9_.-]*"))) {
        "Set ci.windowsWslDistribution to the WSL2 distribution visible to the Windows agent account."
    }
}
private val windowsWslNative = DslContext.getParameter("ci.windowsWslNative", "true") == "true"

internal enum class Agent(val os: String, val architecture: String) {
    Linux("Linux", "amd64|x86_64"),
    Mac("Mac", "aarch64|arm64"),
}

/** Define one clean, agent-side job using the source root connected by TeamCity. */
internal fun agentBuild(
    buildId: String,
    displayName: String,
    command: String,
    minutes: Int,
    agent: Agent = Agent.Linux,
    native: Boolean = false,
    receipt: Boolean = false,
    bundleEvidence: Boolean = false,
    wsl: Boolean = false,
    configure: BuildType.() -> Unit = {},
): BuildType = BuildType {
    val linuxNative = native && agent == Agent.Linux
    val useWsl = agent == Agent.Linux && wsl && windowsWslDistribution.isNotEmpty() &&
        (!linuxNative || windowsWslNative)
    id(buildId)
    name = displayName
    enablePersonalBuilds = false
    vcs {
        root(DslContext.settingsRoot)
        checkoutMode = CheckoutMode.ON_AGENT
        cleanCheckout = true
        branchFilter = candidateBranches
        if (native) checkoutDir = "discordkit-native"
    }
    requirements {
        matches("teamcity.agent.jvm.os.arch", agent.architecture)
        if (useWsl) {
            matches("teamcity.agent.name", listOf(linuxAgent, windowsAgent).joinToString("|") { Regex.escape(it) })
        } else {
            contains("teamcity.agent.jvm.os.name", agent.os)
            if (linuxNative) equals("env.DISCORDKIT_AGENT_SWIFT_IMAGE", linuxSwiftImage)
        }
    }
    params {
        param("env.CI", "true")
        param("env.DISCORDKIT_VCS_REVISION", "%build.vcs.number%")
        param("env.DISCORDKIT_CI_BUILD_ID", currentBuildId)
        param("env.PYTHONUNBUFFERED", "1")
        param("env.SWIFTNIO_STRICT", "1")
        if (linuxNative) param("env.DISCORDKIT_CI_SWIFT_IMAGE", linuxSwiftImage)
    }
    failureConditions { executionTimeoutMin = minutes }
    if (receipt) {
        artifactRules = "+:$output/receipts/$buildId.json => receipts"
        outputParams {
            exposeAllParameters = false
            param(receiptBuildId, currentBuildId)
        }
    }
    val macPython = if (agent == Agent.Mac) """
        if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 12))' 2>/dev/null; then
            mac_python=/Library/Frameworks/Python.framework/Versions/3.14/bin
            if [ -x "${'$'}mac_python/python3" ]; then
                export PATH="${'$'}mac_python:${'$'}PATH"
            fi
        fi
    """.trimIndent() + "\n" else ""
    val pythonSetup = macPython + """
        python3 --version
        python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else "DiscordKit CI requires Python 3.12 or newer")'
    """.trimIndent() + "\n"
    val macSdk = if (native && agent == Agent.Mac) """
        macos_version="${'$'}(sw_vers -productVersion)"
        echo "macOS ${'$'}macos_version"
        case "${'$'}macos_version" in
            26.*|27.*) ;;
            *) echo 'DiscordKit requires macOS 26 or 27 for this lane' >&2; exit 1 ;;
        esac
        if ! xcodebuild -version >/dev/null 2>&1; then
            fallback_xcode=/Applications/Xcode-beta.app/Contents/Developer
            if [ -x "${'$'}fallback_xcode/usr/bin/xcodebuild" ]; then
                export DEVELOPER_DIR="${'$'}fallback_xcode"
            fi
        fi
        xcodebuild -version
        SDKROOT="${'$'}(xcrun --sdk macosx --show-sdk-path)"
        test -d "${'$'}SDKROOT"
        export SDKROOT
    """.trimIndent() + "\n" else ""
    val macToolchain = if (native && agent == Agent.Mac) macSdk + """
        python3 Tools/ci/teamcity_toolchain.py --bin-output $output/swift-bin \
            --evidence $output/evidence/swift-toolchain.json
        swift_bin="${'$'}(cat $output/swift-bin)"
        export PATH="${'$'}swift_bin:${'$'}PATH"
    """.trimIndent() + "\n" else ""
    val linuxToolchain = if (linuxNative) """
        if [ "${'$'}{DISCORDKIT_AGENT_SWIFT_IMAGE:-}" != "${'$'}DISCORDKIT_CI_SWIFT_IMAGE" ]; then
            echo 'The Linux agent image does not provide the pinned DiscordKit Swift release' >&2
            exit 1
        fi
        swift_bin=/opt/discordkit/swift/usr/bin
        if [ -x "${'$'}swift_bin/swift" ]; then
            export PATH="${'$'}swift_bin:${'$'}PATH"
        fi
    """.trimIndent() + "\n" else ""
    val packEvidence = "$artifactTransport pack $output/evidence $output/${archiveParts(evidenceArchive)}"
    val preserveFailedEvidence = if (bundleEvidence) """
        trap 'status=${'$'}?; $packEvidence || :; exit "${'$'}status"' EXIT
    """.trimIndent() + "\n" else ""
    val finishEvidence = if (bundleEvidence) "\ntrap - EXIT\n$packEvidence" else ""
    fun scriptBody(toolchain: String) =
        "set -eu\n$pythonSetup$preserveFailedEvidence$toolchain$command$finishEvidence" +
        if (receipt) "\npython3 Tools/ci/teamcity_gate.py record $buildId" else ""
    if (useWsl) params {
        param("env.DISCORDKIT_WSL_SCRIPT", scriptBody(""))
        param("env.DISCORDKIT_WSL_TEMP", "%system.teamcity.build.tempDir%")
    }
    steps {
        script {
            name = displayName
            if (useWsl) conditions { equals("teamcity.agent.name", linuxAgent) }
            scriptContent = scriptBody(linuxToolchain + macToolchain)
        }
        if (useWsl) script {
            name = "$displayName (Windows WSL)"
            conditions { equals("teamcity.agent.name", windowsAgent) }
            scriptContent = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned " +
                "-File Tools\\ci\\teamcity_wsl.ps1 $windowsWslDistribution $buildId"
        }
    }
    configure()
}

/** Fail closed when any synchronized prerequisite is missing, cancelled or unsuccessful. */
internal fun Dependencies.passed(
    upstream: Collection<BuildType>,
    reuse: ReuseBuilds = ReuseBuilds.NO,
    sameAgent: Boolean = false,
) {
    upstream.distinct().forEach { producer ->
        snapshot(producer) {
            synchronizeRevisions = true
            runOnSameAgent = sameAgent
            reuseBuilds = reuse
            onDependencyFailure = FailureAction.FAIL_TO_START
            onDependencyCancel = FailureAction.FAIL_TO_START
        }
    }
}

/** Resolve IDs and artifacts only from the prerequisite build in this chain. */
internal fun BuildType.chainBuildId() = "%dep.${id!!.value}.$receiptBuildId%"

/** Receipt paths use the same short ID assigned by agentBuild. */
private fun BuildType.receiptName() = id!!.value.removePrefix("${DslContext.projectId.value}_")

internal fun Dependencies.sameChainArtifact(producer: BuildType, rules: String) {
    artifacts(producer) {
        buildRule = sameChain()
        artifactRules = rules
    }
}

private data class NativePlatform(val id: String, val value: String, val agent: Agent)

private val platforms = listOf(
    NativePlatform("Linux", "linux-x64", Agent.Linux),
    NativePlatform("Mac", "macos-arm64", Agent.Mac),
)

private val compileLanes = linkedMapOf(
    "BuildCore" to listOf("root", "macros", "extensions"),
    "BuildPackages" to listOf("tooling", "load", "consumers"),
    "BuildBenchmarks" to listOf("benchmarks", "timing-support", "timing", "foundation", "media"),
    "BuildRelease" to listOf("release"),
)

private val testLanes = linkedMapOf(
    "TestCore" to listOf("root-01", "root-02", "root-03", "root-04", "authoring", "fixtures"),
    "TestPackages" to listOf("load", "tooling", "audit", "consumers", "benchmarks"),
)
private val testInputs = mapOf(
    "TestCore" to compileLanes.getValue("BuildCore"),
    "TestPackages" to compileLanes.getValue("BuildPackages") + compileLanes.getValue("BuildBenchmarks"),
)
// Reuse the representative configuration ID for each bundle during the import.
private val retainedLaneIds = mapOf(
    "BuildCore" to "BuildRoot",
    "BuildPackages" to "BuildTooling",
    "TestCore" to "TestRoot01",
    "TestPackages" to "TestTooling",
)

private const val artifactTransport = "python3 Tools/ci/teamcity_artifact_transport.py"
private const val evidenceArchive = "evidence.tar.gz"

/** Keep archive extensions out of directory names so TeamCity uploads each part separately. */
private fun archiveParts(archive: String) = archive.replace('.', '-') + "-parts"
private fun splitArchive(archive: String) = "$artifactTransport split $output/$archive $output/${archiveParts(archive)}"
private fun joinArchive(archive: String) = "$artifactTransport join $incoming/${archiveParts(archive)} $incoming/$archive"
private fun publishArchive(archive: String) = "+:$output/${archiveParts(archive)}/* => ${archiveParts(archive)}"
private fun downloadArchive(archive: String) = "+:${archiveParts(archive)}/* => $incoming/${archiveParts(archive)}"
private val documentationInputs = listOf("root", "macros", "extensions").map { "documentation-inputs/$it.tar.gz" }

/** Invoke platform-specific phases and retain individual diagnostics and declared outputs. */
private fun nativeBuild(
    platform: NativePlatform,
    lane: String,
    commands: List<String>,
    minutes: Int,
    qualification: BuildType? = null,
    artifacts: String = "",
    uploads: List<String> = emptyList(),
    downloads: List<String> = emptyList(),
    configure: BuildType.() -> Unit = {},
) = agentBuild(platform.id + retainedLaneIds.getOrDefault(lane, lane), "$lane / ${platform.value}",
    (downloads.map(::joinArchive) + commands.map { "python3 Tools/ci/teamcity_native.py $it --separate-evidence" } +
        uploads.map(::splitArchive))
        .joinToString("\n"), minutes, platform.agent, native = true, receipt = true, bundleEvidence = true, wsl = true) {
    publishArtifacts = PublishMode.ALWAYS
    artifactRules += "\n${publishArchive(evidenceArchive)}"
    if (artifacts.isNotEmpty()) artifactRules += "\n$artifacts"
    uploads.forEach { artifactRules += "\n${publishArchive(it)}" }
    params {
        param("env.DISCORDKIT_CI_CHAIN_ID", qualification?.chainBuildId() ?: currentBuildId)
        param("env.DISCORDKIT_CI_REPOSITORY", repositoryName)
    }
    configure()
}

private val qualifications = platforms.associateWith { nativeBuild(it, "Qualify", listOf("qualify ${it.value}"), 30) }

private val builds = platforms.associateWith { platform ->
    compileLanes.mapValues { (lane, graphs) ->
        val qualification = qualifications.getValue(platform)
        val components = if (lane == "BuildRelease" && platform.agent == Agent.Mac) graphs + "apple" else graphs
        nativeBuild(platform, lane, components.map { "build ${platform.value} $it" }, 150 * components.size,
            qualification, uploads = graphs.map { "$it.tar.gz" }) {
            dependencies { passed(qualifications.values) }
        }
    }
}

private val checks = platforms.associateWith { platform ->
    val qualification = qualifications.getValue(platform)
    testLanes.mapValues { (lane, suites) ->
        val publicApi = lane == "TestCore" && platform.agent == Agent.Mac
        val groups = if (publicApi) suites + "public-api" else suites
        val inputs = testInputs.getValue(lane)
        val producers = compileLanes.filterValues { graphs -> graphs.any { it in inputs } }
        nativeBuild(platform, lane, groups.map { "check ${platform.value} $it --clean-inputs" },
            125 * groups.size, qualification, uploads = if (publicApi) documentationInputs else emptyList(),
            downloads = inputs.map { "$it.tar.gz" }) {
            dependencies {
                val platformBuilds = builds.getValue(platform)
                passed(listOf(qualification))
                // SwiftPM products encode the checkout path and carry exact host ABI receipts.
                passed(producers.keys.map(platformBuilds::getValue),
                    sameAgent = platform.agent == Agent.Linux && windowsWslNative && windowsWslDistribution.isNotEmpty())
                producers.forEach { (producer, graphs) ->
                    val rules = graphs.filter { it in inputs }.joinToString("\n") { downloadArchive("$it.tar.gz") }
                    sameChainArtifact(platformBuilds.getValue(producer), rules)
                }
            }
        }
    }
}

private val repositoryChecks = agentBuild("CheckSource", "Repository checks", """
    node_version="${'$'}(node --version)"
    echo "Node.js ${'$'}node_version"
    case "${'$'}node_version" in
        v24.*) ;;
        *) echo 'DiscordKit CI requires Node.js 24' >&2; exit 1 ;;
    esac
    npm --version
    python3 Scripts/sync_copyright.py
    git show --format= --check --first-parent HEAD
    python3 Tools/ci/preflight.py source --output $output/preflight/source
    for group in ci-python tooling-python benchmark-python browser; do
        python3 Tools/ci/preflight.py group --group "${'$'}group" --output "$output/preflight/${'$'}group"
    done
    python3 Tools/DiscordKitTools/scripts/release_check.py maintenance --repository . --record Docs/Release/maintenance.json
""".trimIndent(), 150, receipt = true, wsl = true) {
    publishArtifacts = PublishMode.ALWAYS
    artifactRules += "\n+:$output/preflight/** => preflight"
}

private val verification = builds.values.flatMap { it.values } + checks.values.flatMap { it.values } + repositoryChecks
private val mac = platforms.single { it.agent == Agent.Mac }
private val publicApi = checks.getValue(mac).getValue("TestCore")
internal val DocumentationArchive = nativeBuild(mac, "Documentation", listOf("documentation ${mac.value}"), 40,
    qualifications.getValue(mac), uploads = listOf(doccArtifact), downloads = documentationInputs) {
    dependencies {
        passed(listOf(qualifications.getValue(mac)) + verification)
        sameChainArtifact(publicApi, documentationInputs.joinToString("\n", transform = ::downloadArchive))
    }
}

private val packages = platforms.map { platform ->
    val qualification = qualifications.getValue(platform)
    nativeBuild(platform, "Source", listOf("package ${platform.value}"), 25, qualification,
        "+:$output/*.tar.gz\n+:$output/*.tar.gz.sha256\n+:$output/*.json") {
        dependencies { passed(listOf(qualification) + verification) }
    }
}

internal val VerificationBuilds = qualifications.values + verification + packages + DocumentationArchive
private val required = VerificationBuilds + KnowledgeBaseValidation

/** Require a passed receipt from each selected job and publish the chain's certification. */
internal fun certification(statusToken: String, watchPullRequests: Boolean): BuildType {
    val evidence = required.joinToString(" ") { "${it.receiptName()}=${it.chainBuildId()}" }
    val command = "${joinArchive(doccArtifact)}\npython3 Tools/ci/teamcity_gate.py certify $evidence"
    return agentBuild("Certification", "Offline certification", command, 10, wsl = true) {
        artifactRules = "+:$output/certification.json"
        publishArtifacts = PublishMode.SUCCESSFUL
        dependencies {
            passed(required)
            required.forEach { producer ->
                val stageReceipt = "receipts/${producer.receiptName()}.json => $incoming/receipts"
                val docc = if (producer == DocumentationArchive) "\n${downloadArchive(doccArtifact)}" else ""
                sameChainArtifact(producer, stageReceipt + docc)
            }
        }
        triggers {
            vcs {
                branchFilter = if (watchPullRequests) "$candidateBranches\n-pr:*\n+pr:draft=false sourceRepo=same" else candidateBranches
            }
        }
        if (statusToken.isNotEmpty()) features {
            commitStatusPublisher {
                vcsRootExtId = DslContext.settingsRootId.value
                publisher = github {
                    githubUrl = "https://api.github.com"
                    authType = personalToken { token = statusToken }
                }
            }
            if (watchPullRequests) pullRequests {
                vcsRootExtId = DslContext.settingsRootId.value
                provider = github {
                    authType = token { token = statusToken }
                    filterAuthorRole = PullRequests.GitHubRoleFilter.MEMBER_OR_COLLABORATOR
                    filterTargetBranch = "+:refs/heads/main"
                    ignoreDrafts = true
                    discoveryMode = PullRequests.branchesDiscoveryMode.source
                }
            }
        }
    }
}

/** Collect weekly upstream review inputs separately from the human maintenance gate. */
internal val UpstreamReview = agentBuild("UpstreamReview", "Upstream review evidence", """
    mkdir -p .build/upstream-review
    python3 -m unittest discover -s Tools/ci -p test_ci_helpers.py -k upstream -v
    python3 Tools/ci/review_upstream.py
    git diff --exit-code
    cat .build/upstream-review/review.md
""".trimIndent(), 15) {
    vcs { branchFilter = defaultBranch }
    publishArtifacts = PublishMode.ALWAYS
    artifactRules = "+:.build/upstream-review/** => upstream-review"
    triggers {
        schedule {
            schedulingPolicy = weekly { dayOfWeek = ScheduleTrigger.DAY.Monday; hour = 14 }
            branchFilter = defaultBranch
            triggerBuild = always()
            withPendingChangesOnly = false
        }
    }
}
