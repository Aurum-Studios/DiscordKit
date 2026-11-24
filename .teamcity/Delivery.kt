// copyright:begin
// File: .teamcity/Delivery.kt
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com
// copyright:end

import jetbrains.buildServer.configs.kotlin.*
import jetbrains.buildServer.configs.kotlin.buildFeatures.approval
import jetbrains.buildServer.configs.kotlin.buildFeatures.gitHubAppBuildScopedToken

/** Identify and validate the operator, agent and GitHub App for a publication job. */
internal data class Publisher(val connection: String, val approver: String, val agent: String) {
    init {
        require(connection.matches(Regex("[A-Za-z][A-Za-z0-9_-]*"))) { "Use a TeamCity GitHub App connection ID." }
        require(approver.matches(Regex("[A-Za-z0-9][A-Za-z0-9_.@-]*"))) { "Set an authorized TeamCity approver." }
        require(agent.isNotEmpty()) { "Set the trusted Linux x64 publication agent name." }
    }
}

/** Restrict publication to the default branch, one build at a time, with explicit approval. */
private fun BuildType.publication(publisher: Publisher) {
    type = BuildTypeSettings.Type.DEPLOYMENT
    maxRunningBuilds = 1
    vcs { branchFilter = defaultBranch }
    requirements { equals("teamcity.agent.name", publisher.agent) }
    params { param("env.GH_TOKEN", "") }
    features {
        approval {
            id = "PublicationApproval"
            approvalRules = "user:${publisher.approver}"
            manualRunsApproved = false
        }
        gitHubAppBuildScopedToken {
            id = "DiscordKitGitHubAppToken"
            parameterName = "env.GH_TOKEN"
            connectionId = publisher.connection
            targetRepositories = "DiscordKit"
        }
    }
}

/** Keep the promoted certification while checking out current release tooling. */
private fun Dependencies.promotedCertification(certification: BuildType) {
    snapshot(requireNotNull(certification.id)) {
        synchronizeRevisions = false
        reuseBuilds = ReuseBuilds.SUCCESSFUL
        onDependencyFailure = FailureAction.FAIL_TO_START
        onDependencyCancel = FailureAction.FAIL_TO_START
    }
}

/** Authenticate read-only TeamCity evidence independently of the GitHub publication credential. */
private fun BuildType.releaseEvidence(certificationToken: String) {
    vcs { branchFilter = defaultBranch }
    params {
        param("env.GITHUB_REPOSITORY", repositoryName)
        param("env.RELEASE_DEFAULT_BRANCH", "main")
        param("env.TEAMCITY_URL", "https://ci.aurum-studios.com")
        param("env.TEAMCITY_VCS_ROOT_ID", DslContext.settingsRootId.value)
        param("env.TEAMCITY_DEFAULT_BRANCH", "%teamcity.build.branch.is_default%")
        param("env.RELEASE_VERSION", "%release.version%")
        password("env.TEAMCITY_TOKEN", certificationToken)
    }
}

/** Pack the exact certified commit in a read-only build and publish its sealed assets after approval. */
internal fun releaseBuilds(
    certification: BuildType,
    publisher: Publisher,
    certificationToken: String,
    readToken: String,
): List<BuildType> {
    require(certificationToken.isNotEmpty()) { "Set teamcity.certificationTokenRef before enabling GitHub releases." }
    val arguments = "--version \"\$RELEASE_VERSION\""
    val prepare = agentBuild("PrepareRelease", "Prepare GitHub release", """
        python3 -m unittest discover -s Tools/ci -p 'test*release*.py'
        python3 Tools/ci/github_release.py prepare $arguments --output $output/release
    """.trimIndent(), 20) {
        artifactRules = "+:$output/release/** => release"
        publishArtifacts = PublishMode.SUCCESSFUL
        releaseEvidence(certificationToken)
        params { param("release.version", "") }
        dependencies { promotedCertification(certification) }
        if (readToken.isNotEmpty()) params { password("env.GH_TOKEN", readToken) }
    }
    val publish = agentBuild("PublishGitHubRelease", "Publish GitHub release",
        "python3 Tools/ci/github_release.py publish $arguments --output $incoming/release", 30) {
        publication(publisher)
        releaseEvidence(certificationToken)
        description = "Promote a successful Offline certification build and publish its exact source revision."
        params {
            text("release.version", "", label = "Release version",
                description = "Enter 1.2 or 1.2.3. TeamCity appends the promoted certification number as +build.",
                display = ParameterDisplay.PROMPT,
                regex = """v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?""",
                validationMessage = "Enter a release version such as 1.2 or 1.2.3.")
            param("override.dep.${prepare.id!!.value}.release.version", "%release.version%")
        }
        dependencies {
            promotedCertification(certification)
            passed(listOf(prepare))
            sameChainArtifact(prepare, "release/* => $incoming/release")
        }
    }
    return listOf(prepare, publish)
}
