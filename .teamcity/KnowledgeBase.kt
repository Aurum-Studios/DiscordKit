// copyright:begin
// File: .teamcity/KnowledgeBase.kt
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com
// copyright:end

import jetbrains.buildServer.configs.kotlin.triggers.vcs

/** Render the exact checked-out guide inventory without YouTrack credentials. */
internal val KnowledgeBaseValidation = agentBuild(
    "ValidateYouTrackDocumentation",
    "Validate YouTrack documentation",
    "mkdir -p $output/knowledge-base\n" +
        "python3 Scripts/youtrack_knowledge_base.py verify --root . --revision %build.vcs.number% " +
        "> $output/knowledge-base/validation.json",
    15,
    receipt = true,
) {
    artifactRules += "\n+:$output/knowledge-base/validation.json => knowledge-base"
    triggers {
        vcs {
            branchFilter = defaultBranch
            triggerRules = listOf(
                ".air/project.json", ".air/youtrack/**", ".teamcity/**", "Scripts/youtrack_*.py",
                "README.md", "CONTRIBUTING.md", "CHANGELOG.md", "Docs/**",
            ).joinToString("\n") { "+:$it" }
        }
    }
}
