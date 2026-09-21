#Requires -Version 5.1
<#
.SYNOPSIS
    Runs all Pester v5 unit tests for aPeSecrets.

.PARAMETER Path
    Specific test file or folder to run. Defaults to all files under Tests\Unit\.

.PARAMETER Verbosity
    Pester output detail level. Default: Normal.
    Values: None, Normal, Detailed, Diagnostic.

.EXAMPLE
    .\Tests\Run-Tests.ps1

.EXAMPLE
    .\Tests\Run-Tests.ps1 -Path .\Tests\Unit\CredentialResolver.Tests.ps1 -Verbosity Detailed
#>
[CmdletBinding()]
param(
    [string]$Path      = '',
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Verbosity = 'Normal'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pesterModule = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.0.0' } | Select-Object -First 1
if (-not $pesterModule) {
    Write-Host "Pester 5.0+ is required but was not found. Install with: Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser" -ForegroundColor Red
    exit 1
}
Import-Module Pester -MinimumVersion 5.0 -Force

$testPath = if ($Path) { $Path } else { Join-Path $PSScriptRoot 'Unit' }

$config = New-PesterConfiguration
$config.Run.Path        = $testPath
$config.Run.PassThru    = $true
$config.Output.Verbosity = $Verbosity

$result = Invoke-Pester -Configuration $config

Write-Host ''
Write-Host ('=' * 60)
Write-Host '  Test Results'
Write-Host ('=' * 60)
Write-Host "  Passed  : $($result.PassedCount)"
Write-Host "  Failed  : $($result.FailedCount)"
Write-Host "  Skipped : $($result.SkippedCount)"
Write-Host "  Total   : $($result.TotalCount)"

if ($result.FailedCount -gt 0) {
    Write-Host ''
    Write-Host '  Some tests failed.' -ForegroundColor Red
    exit 1
} else {
    Write-Host ''
    Write-Host '  All tests passed.' -ForegroundColor Green
}
