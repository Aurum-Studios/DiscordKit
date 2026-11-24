# copyright:begin
# File: Tools/ci/teamcity_wsl.ps1
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com
# copyright:end

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidatePattern('\A[A-Za-z0-9][A-Za-z0-9_.-]*\z')]
    [string] $Distribution,
    [Parameter(Mandatory = $true, Position = 1)]
    [ValidatePattern('\A[A-Za-z][A-Za-z0-9]*\z')]
    [string] $Build,
    [switch] $Pipeline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$git = (Get-Command git.exe -CommandType Application).Source
$wsl = (Get-Command wsl.exe -CommandType Application).Source
$head = & $git rev-parse --verify HEAD
if ($LASTEXITCODE -ne 0 -or $env:DISCORDKIT_VCS_REVISION -cnotmatch '\A[0-9a-f]{40}\z' -or
    $head -cne $env:DISCORDKIT_VCS_REVISION) {
    throw 'The Windows checkout must contain the exact TeamCity revision.'
}
$shallow = & $git rev-parse --is-shallow-repository
if ($LASTEXITCODE -ne 0 -or $shallow -cne 'false') {
    throw 'The WSL bridge requires a full TeamCity Git checkout.'
}
if ([string]::IsNullOrWhiteSpace($env:DISCORDKIT_WSL_SCRIPT) -or
    [string]::IsNullOrWhiteSpace($env:DISCORDKIT_WSL_TEMP)) {
    throw 'TeamCity did not provide the WSL build command and temp directory.'
}

$checkout = (Get-Item -LiteralPath '.').FullName
$teamcity = Join-Path $checkout '.build\teamcity'
if ($Pipeline) {
    # Pipeline jobs can have an incremental Windows checkout. Retain downloaded inputs.
    & $git clean -ffdx -- '.build/teamcity/out/pipeline'
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not clear the previous Windows pipeline artifacts.'
    }
}
$bridge = Join-Path $teamcity 'wsl-bridge.sh'
$scratch = Join-Path $env:DISCORDKIT_WSL_TEMP ('discordkit-wsl-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$utf8 = [System.Text.UTF8Encoding]::new($false)

try {
    $bundle = Join-Path $scratch 'candidate.bundle'
    & $git bundle create $bundle HEAD
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not bundle the TeamCity candidate.'
    }
    [System.IO.Directory]::CreateDirectory($teamcity) | Out-Null
    $shell = [System.IO.File]::ReadAllText((Join-Path $checkout 'Tools\ci\teamcity_wsl.sh'))
    $lineFeed = [string][char]10
    $windowsNewline = [string][char]13 + $lineFeed
    [System.IO.File]::WriteAllText($bridge, $shell.Replace($windowsNewline, $lineFeed), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $scratch 'build.sh'),
        $env:DISCORDKIT_WSL_SCRIPT.Replace($windowsNewline, $lineFeed) + $lineFeed, $utf8)

    # Preserve the build contract without passing the Windows PATH or credentials.
    $env:DISCORDKIT_WSL_CHECKOUT = $checkout
    $env:DISCORDKIT_WSL_STAGE = $scratch
    $env:WSLENV = @(
        'CI/u',
        'DISCORDKIT_CI_BUILD_ID/u',
        'DISCORDKIT_CI_CHAIN_ID/u',
        'DISCORDKIT_CI_REPOSITORY/u',
        'DISCORDKIT_VCS_REVISION/u',
        'PYTHONUNBUFFERED/u',
        'SWIFTNIO_STRICT/u',
        'DISCORDKIT_WSL_CHECKOUT/up',
        'DISCORDKIT_WSL_STAGE/up'
    ) -join ':'

    $arguments = @(
        '--distribution', $Distribution, '--cd', $checkout, '--exec', '/usr/bin/env',
        'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        '/bin/bash', '--noprofile', '--norc', './.build/teamcity/wsl-bridge.sh', $Build
    )
    & $wsl @arguments
    $buildExitCode = $LASTEXITCODE
    $staged = Join-Path $scratch 'results'
    if (Test-Path -LiteralPath $staged -PathType Container) {
        # Failed native jobs can still stage diagnostics. The bridge withholds their receipts.
        $output = Join-Path $teamcity 'out'
        foreach ($file in (Get-ChildItem -LiteralPath $staged -Recurse -File -Force)) {
            $relativePath = $file.FullName.Substring($staged.Length + 1)
            $destination = Join-Path $output $relativePath
            [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destination)) | Out-Null
            [System.IO.File]::Copy($file.FullName, $destination)
        }
    } elseif ($buildExitCode -eq 0) {
        throw 'The successful WSL build did not stage its TeamCity artifacts.'
    }
} finally {
    if (Test-Path -LiteralPath $bridge -PathType Leaf) {
        Remove-Item -LiteralPath $bridge -Force -ErrorAction Continue
    }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction Continue
}

exit $buildExitCode
