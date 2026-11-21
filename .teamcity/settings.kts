// copyright:begin
// File: .teamcity/settings.kts
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com
// copyright:end

import jetbrains.buildServer.configs.kotlin.*
import jetbrains.buildServer.configs.kotlin.projectFeatures.youtrack

version = "2025.11"

/** Keep credential values in TeamCity secure storage, outside these versioned settings. */
fun credential(name: String): String = DslContext.getParameter(name, "").trim().also { reference ->
    require(reference.isEmpty() || reference.matches(Regex("""credentialsJSON:\S+"""))) {
        "Set $name to a TeamCity secure-storage reference."
    }
}

/** Enable release publication only with a scoped GitHub App and a named approver and agent. */
private fun releasePublisher(): Publisher? {
    val connection = DslContext.getParameter("github.releaseConnectionId", "").trim()
    if (connection.isEmpty()) return null
    return Publisher(connection, DslContext.getParameter("github.releaseApprover", "").trim(),
        DslContext.getParameter("github.releaseAgentName", "").trim())
}

val youTrackIds = DslContext.getParameter("youtrack.projectIds", "").trim()
val youTrackToken = credential("youtrack.tokenRef")
require(youTrackIds.isEmpty() == youTrackToken.isEmpty()) { "Set both YouTrack project IDs and the token reference." }
val statusToken = credential("github.statusTokenRef")
val watchPullRequests = DslContext.getParameter("github.pullRequests", "false") == "true"
require(!watchPullRequests || statusToken.isNotEmpty()) { "Set github.statusTokenRef before enabling pull request discovery." }

project {
    if (youTrackIds.isNotEmpty()) features {
        youtrack {
            id = "AurumYouTrack"
            displayName = "Aurum Studios YouTrack"
            host = "https://issues.aurum-studios.com"
            projectExtIds = youTrackIds
            accessToken = youTrackToken
        }
    }
    VerificationBuilds.forEach { buildType(it) }
    buildType(certification(statusToken, watchPullRequests))
    buildType(KnowledgeBaseValidation)
    buildType(UpstreamReview)
    periodicTiming(DslContext.getParameter("ci.periodicTiming", "false") == "true").forEach { buildType(it) }
    controlledTiming().forEach { buildType(it) }
    releasePublisher()?.let {
        releaseBuilds(it, credential("teamcity.certificationTokenRef"), credential("github.readTokenRef"))
            .forEach { buildType(it) }
    }
}
