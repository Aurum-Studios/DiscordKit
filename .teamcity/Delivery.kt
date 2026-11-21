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

/** Pass the requested version and full SHA without inserting user input into shell text. */
private fun BuildType.releaseInputs() {
    params {
        text("release.version", "", label = "Major.Minor.Build", description = "GitHub release version, without v",
            display = ParameterDisplay.PROMPT, allowEmpty = false)
        text("release.commit", "", label = "Certified commit SHA", description = "Full 40-character Git commit SHA",
            display = ParameterDisplay.PROMPT, allowEmpty = false)
        param("env.RELEASE_VERSION", "%release.version%")
        param("env.RELEASE_COMMIT", "%release.commit%")
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
        password("env.TEAMCITY_TOKEN", certificationToken)
    }
}

/** Pack the exact certified commit in a read-only build and publish its sealed assets after approval. */
internal fun releaseBuilds(publisher: Publisher, certificationToken: String, readToken: String): List<BuildType> {
    require(certificationToken.isNotEmpty()) { "Set teamcity.certificationTokenRef before enabling GitHub releases." }
    val arguments = "--version \"\$RELEASE_VERSION\" --commit \"\$RELEASE_COMMIT\""
    val prepare = agentBuild("PrepareRelease", "Prepare GitHub release", """
        python3 -m unittest discover -s Tools/ci -p 'test*release*.py'
        python3 Tools/ci/github_release.py prepare $arguments --output $output/release
    """.trimIndent(), 20) {
        artifactRules = "+:$output/release/** => release"
        publishArtifacts = PublishMode.SUCCESSFUL
        releaseEvidence(certificationToken)
        releaseInputs()
        if (readToken.isNotEmpty()) params { password("env.GH_TOKEN", readToken) }
    }
    val publish = agentBuild("PublishGitHubRelease", "Publish GitHub release",
        "python3 Tools/ci/github_release.py publish $arguments --output $incoming/release", 30) {
        publication(publisher)
        releaseEvidence(certificationToken)
        releaseInputs()
        params {
            param("reverse.dep.${prepare.id!!.value}.release.version", "%release.version%")
            param("reverse.dep.${prepare.id!!.value}.release.commit", "%release.commit%")
        }
        dependencies {
            passed(listOf(prepare))
            sameChainArtifact(prepare, "release/* => $incoming/release")
        }
    }
    return listOf(prepare, publish)
}
