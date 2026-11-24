#!/usr/bin/env bash
# copyright:begin
# File: Tools/ci/teamcity_wsl.sh
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com
# copyright:end

set -euo pipefail
umask 077

fail() {
    printf 'DiscordKit WSL: %s\n' "$1" >&2
    exit 1
}

build=$1
case "$build" in
    LinuxQualify|LinuxBuildRoot|LinuxBuildTooling|LinuxBuildBenchmarks|LinuxBuildRelease|LinuxTestRoot01|LinuxTestTooling|LinuxSource)
        swift_bin=/opt/discordkit/swift/usr/bin
        [[ -x "$swift_bin/swift" && -x "$swift_bin/swiftc" ]] \
            || fail 'The AurumCI Swift toolchain is missing.'
        export PATH="$swift_bin:$PATH"
        ;;
    CheckSource|ValidateYouTrackDocumentation|Certification) ;;
    *) fail "This job does not run on the Windows WSL bridge: $build." ;;
esac

kernel=$(uname -r)
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 && "$kernel" == *[Ww][Ss][Ll]2* ]] \
    || fail 'The distribution must run WSL2 on Linux x64.'
. /etc/os-release
[[ "$ID/$VERSION_ID" == ubuntu/24.04 ]] || fail 'The distribution must provide Ubuntu 24.04.'
printf 'DiscordKit WSL runtime: Ubuntu %s, Linux x86_64, kernel %s\n' "$VERSION_ID" "$kernel"

revision=${DISCORDKIT_VCS_REVISION:?TeamCity revision is required}
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail 'Invalid TeamCity revision.'
bridge=$(realpath -e -- "${DISCORDKIT_WSL_CHECKOUT:?Windows checkout is required}")
stage=$(realpath -e -- "${DISCORDKIT_WSL_STAGE:?Windows staging directory is required}")
[[ "$bridge" == "$(pwd -P)" && -f "$stage/candidate.bundle" && -f "$stage/build.sh" ]] \
    || fail 'The Windows checkout, Git bundle and build script must be accessible from WSL.'
unset DISCORDKIT_WSL_CHECKOUT DISCORDKIT_WSL_STAGE

home=$(realpath -e -- "${HOME:?Linux home directory is required}")
state="$home/.cache/discordkit-teamcity"
[[ "$(realpath -m -- "$state")" == "$state" ]] || fail 'The Linux workspace must be inside the WSL home.'
mkdir -p -- "$state"
case "$(stat -f -c %T -- "$state")" in
    ext2/ext3|btrfs|xfs) ;;
    *) fail 'Use a native Linux filesystem for the SwiftPM workspace.' ;;
esac
[[ -O "$state" && -w "$state" ]] || fail 'The WSL agent user must own the SwiftPM workspace.'

# Producers and consumers use the same absolute path on the Windows agent.
# A lock protects the path even if a cancelled Windows process has not stopped WSL yet.
exec 9>"$state/checkout.lock"
flock -n 9 || fail 'Another DiscordKit build still owns the WSL checkout.'
checkout="$state/checkout"
[[ "$(realpath -m -- "$checkout")" == "$checkout" ]] || fail 'Unsafe WSL checkout path.'
node_install=
cleanup() {
    if [[ -n "$node_install" ]]; then
        rm -rf -- "$node_install" || printf 'DiscordKit WSL: Could not clean %s\n' "$node_install" >&2
    fi
    rm -rf -- "$checkout" || printf 'DiscordKit WSL: Could not clean %s\n' "$checkout" >&2
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cleanup
git clone --quiet --no-checkout -- "$stage/candidate.bundle" "$checkout"
cd "$checkout"
[[ "$(git rev-parse --verify HEAD)" == "$revision" ]] || fail 'The Git bundle names a different revision.'
git config core.autocrlf false
git checkout --quiet --detach "$revision"

teamcity=.build/teamcity
copy_tree() {
    local source=$1 destination=$2
    [[ -z "$(find "$source" ! -type f ! -type d -print -quit)" ]] \
        || fail "Non-regular path in CI transfer: $source."
    mkdir -p -- "$(dirname -- "$destination")"
    cp -R -- "$source" "$destination"
}

if [[ -d "$bridge/$teamcity/in" ]]; then
    copy_tree "$bridge/$teamcity/in" "$teamcity/in"
fi

if [[ "$build" == CheckSource ]]; then
    if [[ -x /opt/agent-node/bin/node && -x /opt/agent-node/bin/npm ]]; then
        export PATH="/opt/agent-node/bin:$PATH"
    fi
    if ! node -e 'process.exit(Number(process.platform !== "linux" || process.arch !== "x64" || !process.version.startsWith("v24.")))' 2>/dev/null \
            || ! command -v npm >/dev/null; then
        # WSL imports the filesystem without the agent container's environment.
        node_version=24.22.1
        node_dist="node-v$node_version-linux-x64.tar.xz"
        node_install=$(mktemp -d "$state/node.XXXXXX")
        archive="$node_install/$node_dist"
        curl --fail --silent --show-error --location --retry 2 --proto '=https' --proto-redir '=https' \
            --connect-timeout 10 --max-time 90 --output "$archive" \
            "https://nodejs.org/dist/v$node_version/$node_dist"
        printf '%s  %s\n' 6c172a9ab6718f7b801fb5a7bd486af2ee5e32758086a04b84fcce2aa77095e6 "$archive" \
            | sha256sum --check
        tar -xJf "$archive" --directory "$node_install" --strip-components=1 --no-same-owner
        export PATH="$node_install/bin:$PATH"
    fi
fi

status=0
/bin/bash --noprofile --norc "$stage/build.sh" || status=$?

out="$teamcity/out"
staged="$stage/results"
stage_artifact() {
    copy_tree "$out/$1" "$staged/$1"
}
stage_outputs() {
    local path
    if [[ -d "$out/pipeline" ]]; then
        stage_artifact pipeline
        return
    fi
    case "$build" in
        CheckSource)
            if [[ -d "$out/preflight" ]]; then stage_artifact preflight; fi
            ;;
        ValidateYouTrackDocumentation)
            if (( status == 0 )); then stage_artifact knowledge-base/validation.json; fi
            ;;
        Certification)
            if (( status == 0 )); then stage_artifact certification.json; fi
            ;;
        Linux*)
            shopt -s nullglob
            for path in "$out/"*-parts; do
                stage_artifact "${path##*/}"
            done
            if [[ "$build" == LinuxSource ]] && (( status == 0 )); then
                for path in "$out/"*.tar.gz "$out/"*.tar.gz.sha256 "$out/"*.json; do
                    stage_artifact "${path##*/}"
                done
            fi
            ;;
    esac
    if [[ "$build" != Certification ]] && (( status == 0 )); then
        stage_artifact "receipts/$build.json"
    fi
}
stage_outputs
exit "$status"
