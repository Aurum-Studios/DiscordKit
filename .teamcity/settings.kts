// copyright:begin
// File: .teamcity/settings.kts
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com
// copyright:end

import jetbrains.buildServer.configs.kotlin.*
import jetbrains.buildServer.configs.kotlin.projectFeatures.activeStorage
import jetbrains.buildServer.configs.kotlin.projectFeatures.s3CompatibleStorage
import jetbrains.buildServer.configs.kotlin.projectFeatures.youtrack

version = "2026.2"

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

val artifactAccount = DslContext.getParameter("artifactStorage.r2AccountId", "").trim()
val artifactAccessKeyId = DslContext.getParameter("artifactStorage.r2AccessKeyId", "").trim()
val artifactSecret = credential("artifactStorage.r2SecretRef")
val artifactStorageEnabled = listOf(artifactAccount, artifactAccessKeyId, artifactSecret).any { it.isNotEmpty() }
val artifactStorageId = "DiscordKitPrivateArtifacts"
val r2Identifier = Regex("[a-f0-9]{32}")
require(!artifactStorageEnabled || (
    artifactAccount.matches(r2Identifier) && artifactAccessKeyId.matches(r2Identifier) && artifactSecret.isNotEmpty()
)) {
    "Set the R2 account ID, bucket access key ID and TeamCity secure-storage secret reference together."
}

val offlineCertification = certification(statusToken, watchPullRequests)

project {
    if (artifactStorageEnabled) features {
        s3CompatibleStorage {
            id = artifactStorageId
            storageName = "DiscordKit private artifacts"
            endpoint = "https://$artifactAccount.r2.cloudflarestorage.com"
            bucketName = "discordkit-builds"
            accessKeyID = artifactAccessKeyId
            accessKey = artifactSecret
            // Use direct uploads with bounded parts for large native and pipeline artifacts.
            enablePresignedURLUpload = true
            forceVirtualHostAddressing = false
            multipartThreshold = "8MB"
            multipartChunksize = "16MB"
            verifyIntegrityAfterUpload = true
        }
        activeStorage {
            id = "DiscordKitActiveArtifacts"
            activeStorageID = artifactStorageId
        }
    }
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
    buildType(offlineCertification)
    VerificationPipelines.forEach { pipeline(it) }
    buildType(UpstreamReview)
    buildType(periodicTiming(DslContext.getParameter("ci.periodicTiming", "false") == "true"))
    controlledTiming().forEach { buildType(it) }
    releasePublisher()?.let {
        releaseBuilds(offlineCertification, it, credential("teamcity.certificationTokenRef"),
            credential("github.readTokenRef"))
            .forEach { buildType(it) }
    }
}
