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
import jetbrains.buildServer.configs.kotlin.buildSteps.ScriptBuildStep
import jetbrains.buildServer.configs.kotlin.pipelines.Job
import jetbrains.buildServer.configs.kotlin.pipelines.Pipeline
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

/** Configure identical shell prerequisites for classic builds and pipeline jobs. */
private class AgentExecution(private val agent: Agent, native: Boolean, wsl: Boolean) {
    private val linuxNative = native && agent == Agent.Linux
    val useWsl = agent == Agent.Linux && wsl && windowsWslDistribution.isNotEmpty() &&
        (!linuxNative || windowsWslNative)

    /** Admit the configured OS/toolchain or the explicit Linux and WSL routes. */
    fun requireAgent(requirements: Requirements) = with(requirements) {
        matches("teamcity.agent.jvm.os.arch", agent.architecture)
        if (useWsl) {
            matches("teamcity.agent.name", listOf(linuxAgent, windowsAgent).joinToString("|") { Regex.escape(it) })
        } else {
            contains("teamcity.agent.jvm.os.name", agent.os)
            if (linuxNative) equals("env.DISCORDKIT_AGENT_SWIFT_IMAGE", linuxSwiftImage)
        }
    }

    /** Pass TeamCity identity to the driver and add WSL bridge inputs when needed. */
    fun parameters(parameters: ParametrizedWithType, wslScript: String) {
        parameters.param("env.CI", "true")
        parameters.param("env.DISCORDKIT_VCS_REVISION", "%build.vcs.number%")
        parameters.param("env.DISCORDKIT_CI_BUILD_ID", currentBuildId)
        parameters.param("env.PYTHONUNBUFFERED", "1")
        parameters.param("env.SWIFTNIO_STRICT", "1")
        if (linuxNative) parameters.param("env.DISCORDKIT_CI_SWIFT_IMAGE", linuxSwiftImage)
        if (useWsl) {
            parameters.param("env.DISCORDKIT_WSL_SCRIPT", wslScript)
            parameters.param("env.DISCORDKIT_WSL_TEMP", "%system.teamcity.build.tempDir%")
        }
    }

    private val macPython = if (agent == Agent.Mac) """
        if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 12))' 2>/dev/null; then
            mac_python=/Library/Frameworks/Python.framework/Versions/3.14/bin
            if [ -x "${'$'}mac_python/python3" ]; then
                export PATH="${'$'}mac_python:${'$'}PATH"
            fi
        fi
    """.trimIndent() + "\n" else ""
    private val pythonSetup = macPython + """
        python3 --version
        python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else "DiscordKit CI requires Python 3.12 or newer")'
    """.trimIndent() + "\n"
    private val macSdk = if (native && agent == Agent.Mac) """
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
    private val macToolchain = if (native && agent == Agent.Mac) macSdk + """
        python3 Tools/ci/teamcity_toolchain.py --bin-output $output/swift-bin \
            --evidence $output/evidence/swift-toolchain.json
        swift_bin="${'$'}(cat $output/swift-bin)"
        export PATH="${'$'}swift_bin:${'$'}PATH"
    """.trimIndent() + "\n" else ""
    private val linuxToolchain = if (linuxNative) """
        if [ "${'$'}{DISCORDKIT_AGENT_SWIFT_IMAGE:-}" != "${'$'}DISCORDKIT_CI_SWIFT_IMAGE" ]; then
            echo 'The Linux agent image does not provide the pinned DiscordKit Swift release' >&2
            exit 1
        fi
        swift_bin=/opt/discordkit/swift/usr/bin
        if [ -x "${'$'}swift_bin/swift" ]; then
            export PATH="${'$'}swift_bin:${'$'}PATH"
        fi
    """.trimIndent() + "\n" else ""
    /** Format a fail-fast script and retain diagnostics when a native command fails. */
    fun body(command: String, bridge: Boolean, bundleEvidence: Boolean, receipt: String? = null): String {
        val toolchain = if (bridge) "" else linuxToolchain + macToolchain
        val pack = "$artifactTransport pack $output/evidence $output/${archiveParts(evidenceArchive)}"
        val preserve = if (bundleEvidence) "trap 'status=${'$'}?; $pack || :; exit \"${'$'}status\"' EXIT\n" else ""
        val finish = if (bundleEvidence) "\ntrap - EXIT\n$pack" else ""
        val record = receipt?.let { "\npython3 Tools/ci/teamcity_gate.py record $it" }.orEmpty()
        return "set -eu\n$pythonSetup$preserve$toolchain$command$finish$record"
    }

    /** Run a pipeline job under a bounded supervisor in the selected agent's Linux or macOS checkout. */
    fun pipelineBody(job: String, command: String, minutes: Int, bridge: Boolean,
                     bundleEvidence: Boolean, outputs: List<String>): String {
        val arguments = outputs.joinToString(" ") { "'$it'" }
        val script = body(command, bridge, bundleEvidence)
        val supervisor = """
            run_pipeline_job() {
                DISCORDKIT_PIPELINE_SCRIPT=${'$'}(cat)
                export DISCORDKIT_PIPELINE_SCRIPT
                python3 Tools/ci/teamcity_pipeline.py $job $minutes $arguments
            }
            run_pipeline_job <<'DISCORDKIT_JOB_SCRIPT'
        """.trimIndent()
        return "set -eu\n$pythonSetup$supervisor\n$script\nDISCORDKIT_JOB_SCRIPT"
    }

    /** Invoke the staged Linux command from the Windows agent's PowerShell. */
    fun windowsCommand(job: String) = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned " +
        "-File Tools\\ci\\teamcity_wsl.ps1 $windowsWslDistribution $job"

    /** Route the platform scripts through the same TeamCity step conditions. */
    fun steps(job: String, displayName: String, localScript: String): List<ScriptBuildStep> {
        val local = ScriptBuildStep {
            name = displayName
            if (useWsl) conditions { equals("teamcity.agent.name", linuxAgent) }
            scriptContent = localScript
        }
        val windows = if (useWsl) ScriptBuildStep {
            name = "$displayName (Windows WSL)"
            conditions { equals("teamcity.agent.name", windowsAgent) }
            scriptContent = windowsCommand(job)
        } else null
        return listOfNotNull(local, windows)
    }
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
    val execution = AgentExecution(agent, native, wsl)
    val receiptName = if (receipt) buildId else null
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
    requirements { execution.requireAgent(this) }
    params { execution.parameters(this, execution.body(command, true, bundleEvidence, receiptName)) }
    failureConditions { executionTimeoutMin = minutes }
    if (receipt) {
        artifactRules = "+:$output/receipts/$buildId.json => receipts"
        outputParams {
            exposeAllParameters = false
            param(receiptBuildId, currentBuildId)
        }
    }
    steps { execution.steps(buildId, displayName, execution.body(command, false, bundleEvidence, receiptName)).forEach(::step) }
    configure()
}

/** Register a fresh pipeline job with independent, individually published artifacts. */
private fun Pipeline.agentJob(
    jobId: String,
    displayName: String,
    command: String,
    minutes: Int,
    agent: Agent = Agent.Linux,
    native: Boolean = false,
    outputs: List<String>,
    configure: Job.() -> Unit = {},
) {
    val execution = AgentExecution(agent, native, wsl = true)
    val artifacts = if (native) outputs + archiveParts(evidenceArchive) else outputs
    val localScript = execution.pipelineBody(jobId, command, minutes, false, native, artifacts)
    job {
        id(jobId)
        name = displayName
        allowReuse = false
        repositories { repository(DslContext.settingsRoot, checkoutPath = ".") }
        requirements { execution.requireAgent(this) }
        params {
            execution.parameters(this, execution.pipelineBody(jobId, command, minutes, true, native, artifacts))
            param(receiptBuildId, currentBuildId)
            if (execution.useWsl) param("env.DISCORDKIT_PIPELINE_LOCAL_SCRIPT", localScript)
        }
        steps {
            step(ScriptBuildStep {
                name = displayName
                // TeamCity 2026.2 drops step conditions when serializing pipeline jobs.
                // CMD skips the leading label. On Linux, exec replaces the shell.
                scriptContent = if (execution.useWsl) """
                    :; exec /bin/bash -c "${'$'}DISCORDKIT_PIPELINE_LOCAL_SCRIPT"
                    @echo off
                    ${execution.windowsCommand(jobId)} -Pipeline
                """.trimIndent() else localScript
            })
        }
        outputFiles { pipelineArtifacts("$output/pipeline/**") }
        configure()
    }
    outputParams { param("$receiptBuildId.$jobId", "%job.$jobId.$receiptBuildId%") }
}

/** Fail closed when any synchronized prerequisite is missing, cancelled or unsuccessful. */
internal fun Dependencies.passed(
    upstream: Collection<IdOwner>,
    reuse: ReuseBuilds = ReuseBuilds.NO,
    sameAgent: Boolean = false,
) {
    upstream.distinct().forEach { producer ->
        snapshot(requireNotNull(producer.id)) {
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

/** Resolve one exact job ID from the selected pipeline instance. */
private fun Pipeline.chainBuildId(job: String) = "%dep.${id!!.value}.$receiptBuildId.$job%"

/** Match individual same-chain files and require them before starting the consumer. */
internal fun Dependencies.sameChainArtifact(producer: IdOwner, rules: String) {
    artifacts(requireNotNull(producer.id)) {
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
/** Verify downloaded parts, replacing a previously joined copy only in incremental pipeline checkouts. */
private fun joinArchive(archive: String, replace: Boolean = false): String {
    val option = if (replace) " --replace" else ""
    return "$artifactTransport join $incoming/${archiveParts(archive)} $incoming/$archive$option"
}
private fun publishArchive(archive: String) = "+:$output/${archiveParts(archive)}/* => ${archiveParts(archive)}"
private fun downloadArchive(archive: String, prefix: String = "") =
    "+:$prefix${archiveParts(archive)}/* => $incoming/${archiveParts(archive)}"
private val documentationInputs = listOf("root", "macros", "extensions").map { "documentation-inputs/$it.tar.gz" }

/** Keep phase evidence separate and transport each archive as individually verified parts. */
private fun nativeCommands(
    commands: List<String>, uploads: List<String>, downloads: List<String>, replaceDownloads: Boolean = false,
): String =
    (downloads.map { joinArchive(it, replaceDownloads) } +
        commands.map { "python3 Tools/ci/teamcity_native.py $it --separate-evidence" } +
        uploads.map(::splitArchive)).joinToString("\n")

/** Define a pipeline over the same VCS root used by the classic certification chain. */
private fun candidatePipeline(pipelineId: String, title: String, configure: Pipeline.() -> Unit) = Pipeline {
    id(pipelineId)
    name = title
    repositories { repository(DslContext.settingsRoot) }
    configure()
}

/** Run native work and reconstruct fresh archives from the downloads in the incremental checkout. */
private fun Pipeline.nativeJob(
    platform: NativePlatform,
    lane: String,
    commands: List<String>,
    minutes: Int,
    qualification: Pipeline? = null,
    uploads: List<String> = emptyList(),
    downloads: List<String> = emptyList(),
    outputs: List<String> = emptyList(),
    configure: Job.() -> Unit = {},
) = agentJob(platform.id + lane, "$lane / ${platform.value}",
    // Pipeline cleanup preserves the incoming tree, including archives reconstructed by a previous job.
    nativeCommands(commands, uploads, downloads, replaceDownloads = true),
    minutes, platform.agent, native = true,
    outputs = outputs + uploads.map(::archiveParts)) {
    params {
        param("env.DISCORDKIT_CI_CHAIN_ID", qualification?.chainBuildId(platform.id + "Qualify") ?: currentBuildId)
        param("env.DISCORDKIT_CI_REPOSITORY", repositoryName)
    }
    configure()
}

private val qualifications = candidatePipeline("CandidatePlatforms", "DiscordKit platform qualification") {
    platforms.forEach { nativeJob(it, "Qualify", listOf("qualify ${it.value}"), 30) }
}

private val releaseCompilation = candidatePipeline("ReleaseCompilation", "DiscordKit release compilation") {
    dependencies { passed(listOf(qualifications)) }
    platforms.forEach { platform ->
        val components = if (platform.agent == Agent.Mac) listOf("release", "apple") else listOf("release")
        nativeJob(platform, "BuildRelease", components.map { "build ${platform.value} $it" }, 150 * components.size,
            qualifications, uploads = listOf("release.tar.gz"))
    }
}

/** Keep matching build and test jobs on compatible agents with a stable SwiftPM checkout path. */
private fun nativeBuild(
    platform: NativePlatform,
    lane: String,
    commands: List<String>,
    minutes: Int,
    uploads: List<String> = emptyList(),
    downloads: List<String> = emptyList(),
    configure: BuildType.() -> Unit = {},
) = agentBuild(platform.id + retainedLaneIds.getOrDefault(lane, lane), "$lane / ${platform.value}",
    nativeCommands(commands, uploads, downloads), minutes, platform.agent,
    native = true, receipt = true, bundleEvidence = true, wsl = true) {
    publishArtifacts = PublishMode.ALWAYS
    artifactRules += "\n${publishArchive(evidenceArchive)}"
    uploads.forEach { artifactRules += "\n${publishArchive(it)}" }
    params {
        param("env.DISCORDKIT_CI_CHAIN_ID", qualifications.chainBuildId(platform.id + "Qualify"))
        param("env.DISCORDKIT_CI_REPOSITORY", repositoryName)
    }
    configure()
}

private val builds = platforms.associateWith { platform ->
    compileLanes.mapValues { (lane, graphs) ->
        nativeBuild(platform, lane, graphs.map { "build ${platform.value} $it" }, 150 * graphs.size,
            uploads = graphs.map { "$it.tar.gz" }) {
            dependencies { passed(listOf(qualifications)) }
        }
    }
}

private val compileBuilds = builds.values.flatMap { it.values }

private val checks = platforms.associateWith { platform ->
    testLanes.mapValues { (lane, suites) ->
        val publicApi = lane == "TestCore" && platform.agent == Agent.Mac
        val groups = if (publicApi) suites + "public-api" else suites
        val inputs = testInputs.getValue(lane)
        val producers = compileLanes.filterValues { graphs -> graphs.any { it in inputs } }
        nativeBuild(platform, lane, groups.map { "check ${platform.value} $it --clean-inputs" },
            125 * groups.size, uploads = if (publicApi) documentationInputs else emptyList(),
            downloads = inputs.map { "$it.tar.gz" }) {
            dependencies {
                val platformBuilds = builds.getValue(platform)
                val artifactBuilds = producers.keys.map(platformBuilds::getValue)
                passed(listOf(qualifications, releaseCompilation) + (compileBuilds - artifactBuilds.toSet()))
                // SwiftPM products encode the checkout path and carry exact host ABI receipts.
                passed(artifactBuilds,
                    sameAgent = platform.agent == Agent.Linux && windowsWslNative && windowsWslDistribution.isNotEmpty())
                producers.forEach { (producer, graphs) ->
                    val rules = graphs.filter { it in inputs }.joinToString("\n") { downloadArchive("$it.tar.gz") }
                    sameChainArtifact(platformBuilds.getValue(producer), rules)
                }
            }
        }
    }
}

private val repositoryChecks = """
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
""".trimIndent()

private val repositoryVerification = candidatePipeline("RepositoryVerification", "DiscordKit repository verification") {
    dependencies { passed(listOf(releaseCompilation) + compileBuilds) }
    agentJob("CheckSource", "Repository checks", repositoryChecks, 150, outputs = listOf("preflight"))
    agentJob("ValidateYouTrackDocumentation", "Validate YouTrack documentation", """
        mkdir -p $output/knowledge-base
        python3 Scripts/youtrack_knowledge_base.py verify --root . --revision "${'$'}DISCORDKIT_VCS_REVISION" > $output/knowledge-base/validation.json
    """.trimIndent(), 15, outputs = listOf("knowledge-base/validation.json"))
}

private val testBuilds = checks.values.flatMap { it.values }
private val mac = platforms.single { it.agent == Agent.Mac }
private val publicApi = checks.getValue(mac).getValue("TestCore")
private const val documentationJob = "MacDocumentation"

private val exports = candidatePipeline("CandidateExports", "DiscordKit candidate exports") {
    dependencies { passed(listOf(qualifications, repositoryVerification) + testBuilds) }
    platforms.forEach {
        nativeJob(it, "Source", listOf("package ${it.value}"), 25, qualifications,
            outputs = listOf("DiscordKit-*.tar.gz", "DiscordKit-*.tar.gz.sha256", "DiscordKit-*.json"))
    }
    nativeJob(mac, "Documentation", listOf("documentation ${mac.value}"), 40, qualifications,
        uploads = listOf(doccArtifact), downloads = documentationInputs) {
        download {
            artifacts(publicApi) {
                buildRule = sameChain()
                artifactRules = documentationInputs.joinToString("\n") { downloadArchive(it) }
                cleanDestination = true
            }
        }
    }
}

internal val VerificationBuilds = compileBuilds + testBuilds
internal val VerificationPipelines = listOf(qualifications, releaseCompilation, repositoryVerification, exports)

/** Define the complete set of mandatory receipts and verify each against its original build ID. */
internal fun certification(statusToken: String, watchPullRequests: Boolean): BuildType {
    val buildEvidence = VerificationBuilds.map { build ->
        build.id!!.value.removePrefix("${DslContext.projectId.value}_") to build.chainBuildId()
    }
    val pipelineEvidence = VerificationPipelines.flatMap { pipeline ->
        pipeline.jobs.map { job -> job.id to pipeline.chainBuildId(job.id) }
    }
    val evidence = (buildEvidence + pipelineEvidence).joinToString(" ") { (job, id) -> "$job=$id" }
    val command = "${joinArchive(doccArtifact)}\npython3 Tools/ci/teamcity_gate.py certify $evidence"
    return agentBuild("Certification", "Offline certification", command, 10, wsl = true) {
        artifactRules = "+:$output/certification.json"
        publishArtifacts = PublishMode.SUCCESSFUL
        dependencies {
            passed(VerificationBuilds + VerificationPipelines)
            VerificationBuilds.zip(buildEvidence).forEach { (producer, evidence) ->
                sameChainArtifact(producer, "receipts/${evidence.first}.json => $incoming/receipts")
            }
            VerificationPipelines.forEach { pipeline ->
                val rules = pipeline.jobs.map { "${it.id}/receipts/${it.id}.json => $incoming/receipts" }
                val docc = if (pipeline == exports) listOf(downloadArchive(doccArtifact, "$documentationJob/")) else emptyList()
                sameChainArtifact(pipeline, (rules + docc).joinToString("\n"))
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
