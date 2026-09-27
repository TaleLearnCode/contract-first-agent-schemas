<#
.SYNOPSIS
    Lint every contract in the repo against the agent-ready ruleset.

.DESCRIPTION
    after.openapi.yaml  files MUST pass  (they are the contracts we would ship)
    before.openapi.yaml files MUST fail  (proves each rule actually catches the problem)

    Treating the "before" files as negative tests is the style-guide equivalent of
    "contracts have tests": a rule nobody has seen fail is a rule nobody trusts.

.PARAMETER Spectral
    Path to the Spectral CLI. Defaults to $env:SPECTRAL, then 'spectral' on the PATH.

.EXAMPLE
    ./scripts/Invoke-ContractLint.ps1

.EXAMPLE
    ./scripts/Invoke-ContractLint.ps1 -Spectral C:\tools\spectral.exe
#>
[CmdletBinding()]
param(
    [string] $Spectral = $(if ($env:SPECTRAL) { $env:SPECTRAL } else { 'spectral' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    $ruleset = 'governance/agent-ready.spectral.yaml'
    $failed  = $false

    Write-Host '== AFTER contracts (must pass) =='
    foreach ($file in Get-ChildItem -Path 'schemas/*/after.openapi.yaml' | Sort-Object FullName) {
        $relative = [IO.Path]::GetRelativePath($repoRoot, $file.FullName) -replace '\\', '/'
        & $Spectral lint --quiet --fail-severity=warn -r $ruleset $relative
        if ($LASTEXITCODE -eq 0) {
            Write-Host "PASS  $relative"
        }
        else {
            Write-Host "FAIL  $relative  <- an agent-ready contract regressed"
            $failed = $true
        }
    }

    Write-Host ''
    Write-Host '== BEFORE contracts (must fail) =='
    foreach ($file in Get-ChildItem -Path 'schemas/*/before.openapi.yaml' | Sort-Object FullName) {
        $relative = [IO.Path]::GetRelativePath($repoRoot, $file.FullName) -replace '\\', '/'
        & $Spectral lint --quiet --fail-severity=error -r $ruleset $relative | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "FAIL  $relative  <- passed, so the ruleset no longer catches this anti-pattern"
            $failed = $true
        }
        else {
            Write-Host "PASS  $relative  (rejected as expected)"
        }
    }
}
finally {
    Pop-Location
}

exit ([int] $failed)
