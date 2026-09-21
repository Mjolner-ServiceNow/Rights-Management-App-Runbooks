#Requires -Version 7.2
<#
.SYNOPSIS
    Runs the Pester suite with code coverage over the shared module.
#>
[CmdletBinding()]
param(
    [switch] $CI,
    [string] $Tag
)

$ErrorActionPreference = 'Stop'

# MinimumVersion alone loads the newest Pester present, which on a machine that also has
# Pester 6 means the suite runs on a different major version than CI's 5.8.0. The cap
# keeps both on the same band; 5.5.0 stays the floor because that is what the #Requires in
# every test file asks for.
Import-Module Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99 -ErrorAction Stop
Write-Host "Pester $((Get-Module Pester).Version)"

$root = Split-Path $PSScriptRoot -Parent

$config = New-PesterConfiguration
$config.Run.Path        = "$root/tests"
$config.Run.Throw       = $true
$config.Output.Verbosity = if ($CI) { 'Detailed' } else { 'Normal' }

if ($Tag) { $config.Filter.Tag = $Tag }
# Integration tests need a live ServiceNow and Azure; excluded unless asked for.
else      { $config.Filter.ExcludeTag = 'Integration' }

$config.CodeCoverage.Enabled      = $true
$config.CodeCoverage.Path         = @("$root/src/RMA.Runbooks/Public", "$root/src/RMA.Runbooks/Private")
$config.CodeCoverage.OutputFormat = 'JaCoCo'
$config.CodeCoverage.OutputPath   = "$root/tests/Coverage.xml"

$config.TestResult.Enabled      = $true
$config.TestResult.OutputFormat = 'NUnitXml'
$config.TestResult.OutputPath   = "$root/tests/TestResults.xml"

Invoke-Pester -Configuration $config
