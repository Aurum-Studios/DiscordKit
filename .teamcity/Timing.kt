// copyright:begin
// File: .teamcity/Timing.kt
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com
// copyright:end

import jetbrains.buildServer.configs.kotlin.*
import jetbrains.buildServer.configs.kotlin.triggers.ScheduleTrigger
import jetbrains.buildServer.configs.kotlin.triggers.schedule

/** Run the selected informational profiles sequentially and retain each profile's evidence. */
internal fun periodicTiming(scheduleEnabled: Boolean): BuildType =
    agentBuild("TimingStress", "Informational timing / macos-arm64", """
        case "${'$'}TIMING_PROFILE" in
            all) set -- stress soak integration ;;
            stress|soak|integration) set -- "${'$'}TIMING_PROFILE" ;;
            *) echo 'Select all, stress, soak, or integration' >&2; exit 2 ;;
        esac
        python3 Tools/ci/platform_probe.py --platform macos-arm64 --output $output/platform
        status=0
        for profile in "${'$'}@"; do
            if ! python3 Tools/ci/timing_jobs.py periodic --profile "${'$'}profile" --output "$output/timing/${'$'}profile"; then
                status=1
            fi
        done
        git diff --exit-code
        exit "${'$'}status"
    """.trimIndent(), 45 + 65 + 120, Agent.Mac, native = true) {
        vcs { branchFilter = defaultBranch }
        maxRunningBuilds = 1
        publishArtifacts = PublishMode.ALWAYS
        artifactRules = "+:$output/platform/** => platform\n+:$output/timing/** => timing"
        params {
            select("timing.profile", "all", label = "Informational timing profile", display = ParameterDisplay.PROMPT,
                options = listOf("all", "stress", "soak", "integration"))
            param("env.TIMING_PROFILE", "%timing.profile%")
        }
        if (scheduleEnabled) triggers {
            schedule {
                schedulingPolicy = weekly { dayOfWeek = ScheduleTrigger.DAY.Sunday; hour = 7; minute = 41 }
                branchFilter = defaultBranch
                triggerBuild = always()
                withPendingChangesOnly = false
            }
        }
    }

/** Capture or evaluate an explicitly selected comparison on one compatible host. */
internal fun controlledTiming(): List<BuildType> = listOf(
    Triple("Linux", "linux-x64", Agent.Linux), Triple("Mac", "macos-arm64", Agent.Mac),
).map { (id, platform, agent) ->
    agentBuild("${id}TimingComparison", "Controlled timing comparison / $platform", """
        python3 Tools/ci/platform_probe.py --platform $platform --output $output/platform
        case "${'$'}TIMING_STAGE" in
            capture)
                python3 Tools/ci/timing_jobs.py controlled --stage capture --spec "${'$'}TIMING_SPEC" \
                    --noise-series "${'$'}TIMING_NOISE_SERIES" --output $output/timing
                ;;
            evaluate)
                python3 Tools/ci/timing_jobs.py controlled --stage evaluate --series "${'$'}TIMING_SERIES" \
                    --policy "${'$'}TIMING_POLICY" --output $output/timing
                ;;
            *) exit 2 ;;
        esac
        git diff --exit-code
    """.trimIndent(), 110, agent, native = true) {
        maxRunningBuilds = 1
        publishArtifacts = PublishMode.ALWAYS
        artifactRules = "+:$output/platform/** => platform\n+:$output/timing/** => timing"
        params {
            select("timing.stage", "capture", display = ParameterDisplay.PROMPT, options = listOf("capture", "evaluate"))
            text("timing.spec", "", label = "Capture specification", display = ParameterDisplay.PROMPT)
            text("timing.noiseSeries", "", label = "Capture noise series", display = ParameterDisplay.PROMPT)
            text("timing.series", "", label = "Recorded evaluation series", display = ParameterDisplay.PROMPT)
            text("timing.policy", "", label = "Reviewed evaluation policy", display = ParameterDisplay.PROMPT)
            param("env.TIMING_STAGE", "%timing.stage%")
            param("env.TIMING_SPEC", "%timing.spec%")
            param("env.TIMING_NOISE_SERIES", "%timing.noiseSeries%")
            param("env.TIMING_SERIES", "%timing.series%")
            param("env.TIMING_POLICY", "%timing.policy%")
        }
    }
}
