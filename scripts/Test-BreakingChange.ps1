<#
.SYNOPSIS
    Semantic diff gate: block breaking changes that are not a major version bump.

.DESCRIPTION
    Policy (see README "Governance"):
      * Any oasdiff finding at WARN or above counts as breaking. Adding a value to a
        closed status enum is only a WARN in oasdiff, but for an agent that has hard-coded
        PENDING | CONFIRMED | FAILED it is exactly as breaking as removing a field.
      * A breaking change is allowed only when info.version's MAJOR number increases.

.PARAMETER Base
    The currently published contract.

.PARAMETER Proposed
    The contract being proposed.

.PARAMETER OasDiff
    Path to the oasdiff CLI. Defaults to $env:OASDIFF, then 'oasdiff' on the PATH.

.EXAMPLE
    ./scripts/Test-BreakingChange.ps1 schemas/status-enum/after.openapi.yaml governance/examples/status-enum.breaking-change.openapi.yaml
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)] [string] $Base,
    [Parameter(Mandatory, Position = 1)] [string] $Proposed,
    [string] $OasDiff = $(if ($env:OASDIFF) { $env:OASDIFF } else { 'oasdiff' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MajorVersion {
    param([string] $Path)
    # First indented `version:` line is info.version in these contracts.
    $line = Select-String -Path $Path -Pattern '^\s+version:\s*"?(\d+)\.' | Select-Object -First 1
    if (-not $line) { throw "No info.version found in $Path" }
    [int] $line.Matches[0].Groups[1].Value
}

& $OasDiff breaking --fail-on WARN $Base $Proposed
if ($LASTEXITCODE -eq 0) {
    Write-Host "No breaking changes: $Proposed"
    exit 0
}

$baseMajor     = Get-MajorVersion $Base
$proposedMajor = Get-MajorVersion $Proposed

if ($proposedMajor -gt $baseMajor) {
    Write-Host "Breaking changes accepted: major version bumped $baseMajor -> $proposedMajor."
    Write-Host "Remember: publish Deprecation/Sunset headers on v$baseMajor and notify consumers."
    exit 0
}

# GitHub Actions picks this line up as an annotation on the PR.
Write-Host "::error file=$Proposed::Breaking change without a major version bump (still v$proposedMajor). Block + notify."
exit 1
