#Requires -Version 7.2
<#
.SYNOPSIS
    Builds the two release artefacts: the module zip and the provisioning script.
.DESCRIPTION
    Azure Automation modules are only available to jobs running in an Azure sandbox. A
    Hybrid Runbook Worker loads modules from its own PSModulePath, so RMA.Runbooks has to be
    installed on the worker like any other dependency.

    This produces the artefact that Initialize-RmaWorker.ps1 consumes, and a copy of
    Initialize-RmaWorker.ps1 itself. Both go on the GitHub release with their SHA256, so a
    worker can be provisioned from a versioned URL with no credentials and no checkout:
    the release notes carry a command that downloads the script, verifies it, and runs it
    against the verified module.

    Shipping the script as an asset rather than telling people to pipe it into
    Invoke-Expression is deliberate. #Requires is a parse-time directive for script files
    and is silently ignored when the text is run through Invoke-Expression, so
    -RunAsAdministrator and -Version 7.2 would both stop being enforced; parameters cannot
    be passed that way either, so the script would run with its defaults and only then
    report an error, having already done work. A release asset has an immutable URL tied to
    a tag and a hash that can be checked, which a branch URL has neither of.

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

$repoRoot    = Split-Path $PSScriptRoot -Parent
$modulePath  = Join-Path $repoRoot 'src/RMA.Runbooks'
$manifest    = Join-Path $modulePath 'RMA.Runbooks.psd1'
$workerSource = Join-Path $repoRoot 'scripts/Initialize-RmaWorker.ps1'

$null = Test-ModuleManifest -Path $manifest -ErrorAction Stop
$version = (Import-PowerShellDataFile $manifest).ModuleVersion

$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$zip = Join-Path (Resolve-Path $OutputDirectory) "RMA.Runbooks-$version.zip"

Compress-Archive -Path $modulePath -DestinationPath $zip -Force
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash

# The provisioning script ships beside the module it installs, from the same tag, so a
# worker can be bootstrapped without a checkout and without trusting a mutable branch URL.
$workerScript = Join-Path (Resolve-Path $OutputDirectory) 'Initialize-RmaWorker.ps1'
Copy-Item -Path $workerSource -Destination $workerScript -Force
$workerHash = (Get-FileHash $workerScript -Algorithm SHA256).Hash

Write-Host "RMA.Runbooks $version"
Write-Host "  package      : $zip"
Write-Host "  size         : $([math]::Round((Get-Item $zip).Length / 1KB)) KB"
Write-Host "  sha256       : $hash"
Write-Host "  worker script: $workerScript"
Write-Host "  sha256       : $workerHash"

if ($env:GITHUB_OUTPUT) {
    "version=$version"              | Add-Content $env:GITHUB_OUTPUT
    "package=$zip"                  | Add-Content $env:GITHUB_OUTPUT
    "sha256=$hash"                  | Add-Content $env:GITHUB_OUTPUT
    "workerScript=$workerScript"    | Add-Content $env:GITHUB_OUTPUT
    "workerScriptSha256=$workerHash" | Add-Content $env:GITHUB_OUTPUT
}

[pscustomobject]@{
    Version            = $version
    Path               = $zip
    Sha256             = $hash
    WorkerScript       = $workerScript
    WorkerScriptSha256 = $workerHash
}
