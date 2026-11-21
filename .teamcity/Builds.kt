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
    configure: BuildType.() -> Unit = {},
): BuildType = BuildType {
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
        contains("teamcity.agent.jvm.os.name", agent.os)
        matches("teamcity.agent.jvm.os.arch", agent.architecture)
        equals("aurum.ci.python", "true")
        if (native) equals("aurum.ci.discordkit", "true")
    }
    params {
        param("env.CI", "true")
        param("env.DISCORDKIT_VCS_REVISION", "%build.vcs.number%")
        param("env.DISCORDKIT_CI_BUILD_ID", currentBuildId)
        param("env.PYTHONUNBUFFERED", "1")
        param("env.SWIFTNIO_STRICT", "1")
    }
    failureConditions { executionTimeoutMin = minutes }
    if (receipt) {
        artifactRules = "+:$output/receipts/$buildId.json => receipts"
        outputParams {
            exposeAllParameters = false
            param(receiptBuildId, currentBuildId)
        }
    }
    val nativeSetup = if (native && agent == Agent.Mac) """
        case "${'$'}(sw_vers -productVersion)" in
            26.*) ;;
            *) echo 'DiscordKit requires macOS 26 for this lane' >&2; exit 1 ;;
        esac
        SDKROOT="${'$'}(xcrun --sdk macosx --show-sdk-path)"
        test -d "${'$'}SDKROOT"
        export SDKROOT
    """.trimIndent() + "\n" else ""
    steps {
        script {
            name = displayName
            scriptContent = "set -eu\n$nativeSetup$command" +
                if (receipt) "\npython3 Tools/ci/teamcity_gate.py record $buildId" else ""
        }
    }
    configure()
}

/** Fail closed when any synchronized prerequisite is missing, cancelled or unsuccessful. */
internal fun Dependencies.passed(upstream: Collection<BuildType>, reuse: ReuseBuilds = ReuseBuilds.NO) {
    upstream.distinct().forEach { producer ->
        snapshot(producer) {
            synchronizeRevisions = true
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

/** Use a lightweight composite to fan in a phase without occupying an agent. */
private fun barrier(buildId: String, displayName: String, prerequisites: Collection<BuildType>) = BuildType {
    id(buildId)
    name = displayName
    type = BuildTypeSettings.Type.COMPOSITE
    enablePersonalBuilds = false
    vcs { root(DslContext.settingsRoot); branchFilter = candidateBranches }
    dependencies { passed(prerequisites) }
}

private data class NativePlatform(val id: String, val value: String, val agent: Agent)

private val platforms = listOf(
    NativePlatform("Linux", "linux-x64", Agent.Linux),
    NativePlatform("Mac", "macos-arm64", Agent.Mac),
)

private val components = linkedMapOf(
    "Root" to "root", "Macros" to "macros", "Extensions" to "extensions", "Tooling" to "tooling",
    "Load" to "load", "Benchmarks" to "benchmarks", "TimingSupport" to "timing-support",
    "Timing" to "timing", "Foundation" to "foundation", "Media" to "media",
    "Consumers" to "consumers", "Release" to "release",
)

private val groups = linkedMapOf(
    "root-01" to listOf("Root"), "root-02" to listOf("Root"), "root-03" to listOf("Root"),
    "root-04" to listOf("Root"), "load" to listOf("Load"), "authoring" to listOf("Macros", "Extensions"),
    "tooling" to listOf("Tooling"), "audit" to listOf("Tooling"), "consumers" to listOf("Consumers"),
    "benchmarks" to listOf("Benchmarks", "TimingSupport", "Timing", "Foundation", "Media"),
    "fixtures" to emptyList(),
)

/** Convert a reviewed suite or component name into its stable configuration suffix. */
private fun suffix(value: String) = value.split('-').joinToString("") { it.replaceFirstChar(Char::uppercaseChar) }

/** Invoke one platform-specific phase and retain its diagnosis and any declared outputs. */
private fun nativeBuild(
    platform: NativePlatform,
    lane: String,
    command: String,
    minutes: Int,
    qualification: BuildType? = null,
    artifacts: String = "",
    configure: BuildType.() -> Unit = {},
) = agentBuild("${platform.id}$lane", "$lane / ${platform.value}",
    "python3 Tools/ci/teamcity_native.py $command", minutes, platform.agent, native = true, receipt = true) {
    publishArtifacts = PublishMode.ALWAYS
    artifactRules += "\n+:$output/evidence/** => evidence"
    if (artifacts.isNotEmpty()) artifactRules += "\n$artifacts"
    params {
        param("env.DISCORDKIT_CI_CHAIN_ID", qualification?.chainBuildId() ?: currentBuildId)
        param("env.DISCORDKIT_CI_REPOSITORY", repositoryName)
    }
    configure()
}

private val qualifications = platforms.associateWith { nativeBuild(it, "Qualify", "qualify ${it.value}", 30) }
private val platformsPassed = barrier("PlatformsPassed", "Required platforms qualified", qualifications.values)

private val builds = platforms.associateWith { platform ->
    val platformComponents = if (platform.agent == Agent.Mac) components + ("Apple" to "apple") else components
    platformComponents.mapValues { (key, component) ->
        val qualification = qualifications.getValue(platform)
        nativeBuild(platform, "Build$key", "build ${platform.value} $component", 150, qualification,
            if (component == "apple") "" else "+:$output/$component.tar.gz") {
            dependencies { passed(listOf(qualification, platformsPassed)) }
        }
    }
}
private val buildsPassed = barrier("BuildsPassed", "Required build producers passed", builds.values.flatMap { it.values })

private val checks = platforms.associateWith { platform ->
    val qualification = qualifications.getValue(platform)
    val suites = if (platform.agent == Agent.Mac) groups + ("public-api" to listOf("Root", "Macros", "Extensions")) else groups
    suites.mapValues { (group, dependencies) ->
        val producers = dependencies.associateWith { builds.getValue(platform).getValue(it) }
        nativeBuild(platform, "Test${suffix(group)}", "check ${platform.value} $group", 125, qualification,
            if (group == "public-api") "+:$output/documentation-inputs/*.tar.gz => documentation-inputs" else "") {
            dependencies {
                passed(listOf(qualification, buildsPassed) + producers.values)
                producers.forEach { (key, producer) ->
                    sameChainArtifact(producer, "${components.getValue(key)}.tar.gz => $incoming")
                }
            }
        }
    }
}

private val helpers = listOf("source", "ci-python", "tooling-python", "benchmark-python", "browser", "maintenance")
    .map { group ->
        val command = when (group) {
            "source" -> "python3 Scripts/sync_copyright.py\ngit show --format= --check --first-parent HEAD\n" +
                "python3 Tools/ci/preflight.py source --output $output/preflight"
            "maintenance" -> "python3 Tools/DiscordKitTools/scripts/release_check.py maintenance " +
                "--repository . --record Docs/Release/maintenance.json"
            else -> "python3 Tools/ci/preflight.py group --group $group --output $output/preflight"
        }
        agentBuild("Check${suffix(group)}", "Check / $group", command, 25, receipt = true) {
            if (group in listOf("browser", "ci-python")) requirements { equals("aurum.ci.node", "true") }
            publishArtifacts = PublishMode.ALWAYS
            artifactRules += "\n+:$output/preflight/** => preflight"
            dependencies { passed(listOf(buildsPassed)) }
        }
    }

private val testsPassed = barrier("TestsPassed", "Required test and audit jobs passed", helpers + checks.values.flatMap { it.values })
private val mac = platforms.single { it.agent == Agent.Mac }
private val publicApi = checks.getValue(mac).getValue("public-api")
internal val DocumentationArchive = nativeBuild(mac, "Documentation", "documentation ${mac.value}", 40,
    qualifications.getValue(mac), "+:$output/$doccArtifact") {
    dependencies {
        passed(listOf(qualifications.getValue(mac), publicApi, testsPassed))
        sameChainArtifact(publicApi, "documentation-inputs/*.tar.gz => $incoming/documentation-inputs")
    }
}

private val packages = platforms.map { platform ->
    val qualification = qualifications.getValue(platform)
    nativeBuild(platform, "Source", "package ${platform.value}", 25, qualification,
        "+:$output/*.tar.gz\n+:$output/*.tar.gz.sha256\n+:$output/*.json") {
        dependencies { passed(listOf(qualification, testsPassed)) }
    }
}

private val required = qualifications.values + builds.values.flatMap { it.values } +
    checks.values.flatMap { it.values } + helpers + packages + DocumentationArchive

/** Require a passed receipt from each selected job and publish the chain's certification. */
internal fun certification(statusToken: String, watchPullRequests: Boolean): BuildType {
    val evidence = required.joinToString(" ") { "${it.receiptName()}=${it.chainBuildId()}" }
    return agentBuild("Certification", "Offline certification", "python3 Tools/ci/teamcity_gate.py certify $evidence", 10) {
        artifactRules = "+:$output/certification.json"
        publishArtifacts = PublishMode.SUCCESSFUL
        dependencies {
            passed(required)
            required.forEach { producer ->
                val stageReceipt = "receipts/${producer.receiptName()}.json => $incoming/receipts"
                val docc = if (producer == DocumentationArchive) "\n$doccArtifact => $incoming" else ""
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

internal val VerificationBuilds = qualifications.values + platformsPassed + builds.values.flatMap { it.values } +
    buildsPassed + checks.values.flatMap { it.values } + helpers + DocumentationArchive + testsPassed + packages

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
