#Requires -Version 7.2
<#
.SYNOPSIS
    Fails the build when line coverage falls below a floor.
.DESCRIPTION
    The floor is deliberately modest. Its purpose is to stop coverage regressing as the
    module grows, not to chase a number.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Path,
    [ValidateRange(0, 100)][int]   $MinimumPercent = 70
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Path)) { throw "Coverage report not found at '$Path'." }

[xml]$report = Get-Content $Path -Raw
$counter = $report.report.counter | Where-Object { $_.type -eq 'LINE' } | Select-Object -First 1
if (-not $counter) { throw 'No LINE counter in the coverage report.' }

$covered = [int]$counter.covered
$missed  = [int]$counter.missed
$total   = $covered + $missed
$percent = if ($total -eq 0) { 0 } else { [math]::Round(($covered / $total) * 100, 1) }

Write-Host "Line coverage: $percent% ($covered/$total)"
if ($env:GITHUB_STEP_SUMMARY) {
    "### Coverage: $percent% ($covered/$total lines)" | Add-Content $env:GITHUB_STEP_SUMMARY
}

if ($percent -lt $MinimumPercent) {
    throw "Coverage $percent% is below the $MinimumPercent% floor."
}
Write-Host 'Coverage floor met.'
