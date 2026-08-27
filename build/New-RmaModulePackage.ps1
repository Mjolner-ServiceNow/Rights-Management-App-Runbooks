#Requires -Version 7.2
<#
.SYNOPSIS
    Packages RMA.Runbooks into a versioned zip for distribution to Hybrid Workers.
.DESCRIPTION
    Azure Automation modules are only available to jobs running in an Azure sandbox. A
    Hybrid Runbook Worker loads modules from its own PSModulePath, so RMA.Runbooks has to be
    installed on the worker like any other dependency.

    This produces the artefact that Initialize-RmaWorker.ps1 consumes. The release workflow
    attaches it to a GitHub release so workers can be provisioned from a versioned URL with
    no credentials.

    The zip contains a single top-level folder named RMA.Runbooks, so it expands directly
    into a module directory.
.EXAMPLE
    ./build/New-RmaModulePackage.ps1 -OutputDirectory ./out
#>
[CmdletBinding()]
param(
    [string] $OutputDirectory = "$PSScriptRoot/../out"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot   = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $repoRoot 'src/RMA.Runbooks'
$manifest   = Join-Path $modulePath 'RMA.Runbooks.psd1'

$null = Test-ModuleManifest -Path $manifest -ErrorAction Stop
$version = (Import-PowerShellDataFile $manifest).ModuleVersion

$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$zip = Join-Path (Resolve-Path $OutputDirectory) "RMA.Runbooks-$version.zip"

Compress-Archive -Path $modulePath -DestinationPath $zip -Force

$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
Write-Host "RMA.Runbooks $version"
Write-Host "  package : $zip"
Write-Host "  size    : $([math]::Round((Get-Item $zip).Length / 1KB)) KB"
Write-Host "  sha256  : $hash"

if ($env:GITHUB_OUTPUT) {
    "version=$version" | Add-Content $env:GITHUB_OUTPUT
    "package=$zip"     | Add-Content $env:GITHUB_OUTPUT
    "sha256=$hash"     | Add-Content $env:GITHUB_OUTPUT
}

[pscustomobject]@{ Version = $version; Path = $zip; Sha256 = $hash }
