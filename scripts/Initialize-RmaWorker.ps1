#Requires -Version 7.2
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Provisions a Hybrid Worker with the exact, pinned module set, including RMA.Runbooks.
    Idempotent.
.DESCRIPTION
    Replaces the runtime Install-Module calls that were previously inside every runbook.
    Runbooks now assert their dependencies with #Requires and never mutate the host.

    Also installs the RMA.Runbooks shared module. This is not optional and cannot be done
    from Azure: modules imported into an Automation Account are only available to jobs
    running in an Azure sandbox. A Hybrid Runbook Worker loads modules from its own
    PSModulePath, so the shared module has to be present on this machine or every runbook
    fails at #Requires.

    Also removes module versions that are not on the pinned list, which is how the disk
    consumed by the accumulated versions is reclaimed.

    Run at build time via VM extension or configuration management, not from a runbook.
.PARAMETER ModuleSource
    Where to get RMA.Runbooks from. Either a path to a repository checkout, a path to a
    package produced by build/New-RmaModulePackage.ps1, or the URL of a release asset.
    Defaults to the checkout this script is part of.
.PARAMETER SkipSharedModule
    Install only the third-party dependencies. Use when RMA.Runbooks is delivered by
    separate configuration management.
.PARAMETER PruneUnpinned
    Removes non-pinned versions of managed modules. Review the -WhatIf output first.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('RmaAvoidRuntimeModuleInstall', '',
    Justification = 'This script is the worker provisioner the rule directs authors to. It is run at build time by configuration management, never from a runbook. Versions are pinned, which RmaRequirePinnedModuleVersion verifies.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $PruneUnpinned,
    [string] $ModuleSource,
    [switch] $SkipSharedModule
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The single source of truth for what belongs on a worker.
# Changing a version here is a reviewed, released change.
$pinned = @(
    @{ Name = 'Microsoft.Graph.Authentication'; Version = '2.39.0' }
    @{ Name = 'Microsoft.Graph.Users'; Version = '2.39.0' }
    @{ Name = 'Microsoft.Graph.Users.Actions'; Version = '2.39.0' }
    @{ Name = 'Microsoft.Graph.Groups'; Version = '2.39.0' }
    @{ Name = 'Microsoft.Graph.Identity.DirectoryManagement'; Version = '2.39.0' }
    @{ Name = 'Microsoft.Graph.Identity.SignIns'; Version = '2.39.0' }
    @{ Name = 'ExchangeOnlineManagement'; Version = '3.10.1' }
)

# Graph submodule versions must match each other. They share Microsoft.Graph.Core and the
# Authentication module's assemblies, and mixing versions in one session produces assembly
# load failures that read as missing cmdlets. The #Requires in every runbook pins the same
# version, which is what makes a mismatch fail at parse time instead.

# No Microsoft.Graph.Beta.* submodule is pinned because nothing calls a Get-MgBeta* cmdlet
# any more. If that changes, add the single submodule needed and never the
# Microsoft.Graph.Beta meta-module, which pulls 40+ submodules and over a gigabyte.

# MSAL.PS is deliberately absent. It is archived by Microsoft and its bundled
# Microsoft.Identity.Client conflicts with the Graph SDK's. The managed identity design
# removes the only reason it was ever present.
$forbidden = @('MSAL.PS', 'Microsoft.Graph', 'Microsoft.Graph.Beta', 'AzureAD', 'MSOnline')

Write-Host '=== Windows features ==='
$rsat = Get-WindowsFeature -Name 'RSAT-AD-PowerShell' -ErrorAction SilentlyContinue
if ($rsat -and -not $rsat.Installed) {
    if ($PSCmdlet.ShouldProcess('RSAT-AD-PowerShell', 'Install Windows feature')) {
        Install-WindowsFeature -Name 'RSAT-AD-PowerShell' | Out-Null
        Write-Host '  installed RSAT-AD-PowerShell'
    }
} else { Write-Host '  RSAT-AD-PowerShell already present' }

Write-Host ''
Write-Host '=== Forbidden modules ==='
foreach ($name in $forbidden) {
    $found = Get-Module -ListAvailable -Name $name -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq $name }
    if ($found -and $PSCmdlet.ShouldProcess($name, 'Uninstall forbidden module (all versions)')) {
        Uninstall-Module -Name $name -AllVersions -Force -ErrorAction Continue
        Write-Host "  removed $name"
    }
}

Write-Host ''
Write-Host '=== Pinned modules ==='
foreach ($module in $pinned) {
    $have = Get-Module -ListAvailable -Name $module.Name |
    Where-Object { $_.Version.ToString() -eq $module.Version }

    if ($have) {
        Write-Host ('  {0,-52} {1}  present' -f $module.Name, $module.Version)
    } elseif ($PSCmdlet.ShouldProcess("$($module.Name) $($module.Version)", 'Install pinned module')) {
        Install-Module -Name $module.Name -RequiredVersion $module.Version `
            -Repository PSGallery -Scope AllUsers -Force -AllowClobber
        Write-Host ('  {0,-52} {1}  INSTALLED' -f $module.Name, $module.Version)
    }
}

if ($PruneUnpinned) {
    Write-Host ''
    Write-Host '=== Pruning unpinned versions ==='
    foreach ($module in $pinned) {
        $extra = Get-Module -ListAvailable -Name $module.Name |
        Where-Object { $_.Version.ToString() -ne $module.Version }
        foreach ($old in $extra) {
            if ($PSCmdlet.ShouldProcess("$($old.Name) $($old.Version)", 'Uninstall unpinned version')) {
                Uninstall-Module -Name $old.Name -RequiredVersion $old.Version -Force -ErrorAction Continue
                Write-Host ('  removed {0} {1}' -f $old.Name, $old.Version)
            }
        }
    }
}

# --------------------------------------------------------------------------------
# RMA.Runbooks
#
# Installed here, on the worker, because Azure Automation cannot deliver it. Module
# imports on an Automation Account serve Azure sandbox jobs only; a Hybrid Runbook
# Worker resolves modules from its own PSModulePath.
# --------------------------------------------------------------------------------
if (-not $SkipSharedModule) {
    Write-Host ''
    Write-Host '=== RMA.Runbooks (shared module) ==='

    # PowerShell 7 keeps AllUsers modules separately from Windows PowerShell. Runbooks run on
    # PowerShell 7.6, so this is the path that matters. All 7.x versions share it, so it does
    # not change with the runtime version.
    $modulesRoot = if ($IsWindows -or $null -eq $IsWindows) {
        Join-Path $env:ProgramFiles 'PowerShell\Modules'
    } else {
        '/usr/local/share/powershell/Modules'
    }

    if (-not $ModuleSource) {
        $ModuleSource = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/RMA.Runbooks'
    }

    $staging = Join-Path ([IO.Path]::GetTempPath()) "rma-module-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $staging -Force

    try {
        # Resolve the source down to a directory containing RMA.Runbooks.psd1.
        # Initialised because StrictMode makes reading an unassigned variable an error, and
        # a ModuleSource that does not exist leaves every branch below unentered.
        $sourceDir = $null

        if ($ModuleSource -match '^https?://') {
            Write-Host "  downloading $ModuleSource"
            $download = Join-Path $staging 'package.zip'
            Invoke-WebRequest -Uri $ModuleSource -OutFile $download -UseBasicParsing
            Expand-Archive -Path $download -DestinationPath $staging -Force
            $sourceDir = (Get-ChildItem $staging -Recurse -Filter 'RMA.Runbooks.psd1' | Select-Object -First 1).Directory
        } elseif ($ModuleSource -like '*.zip') {
            Expand-Archive -Path $ModuleSource -DestinationPath $staging -Force
            $sourceDir = (Get-ChildItem $staging -Recurse -Filter 'RMA.Runbooks.psd1' | Select-Object -First 1).Directory
        } elseif (Test-Path -LiteralPath $ModuleSource) {
            $sourceDir = Get-Item -LiteralPath $ModuleSource
        }

        if (-not $sourceDir -or -not (Test-Path (Join-Path $sourceDir 'RMA.Runbooks.psd1'))) {
            throw ("RMA.Runbooks.psd1 not found under '$ModuleSource'. This machine has no " +
                'repository checkout, so pass -ModuleSource with the path to a package built by ' +
                'build/New-RmaModulePackage.ps1, or the URL of the release asset. Pass ' +
                '-SkipSharedModule to provision the third-party dependencies only.')
        }

        $version = (Import-PowerShellDataFile (Join-Path $sourceDir 'RMA.Runbooks.psd1')).ModuleVersion
        $target  = Join-Path $modulesRoot "RMA.Runbooks\$version"

        if (Test-Path (Join-Path $target 'RMA.Runbooks.psd1')) {
            Write-Host ('  {0,-52} {1}  present' -f 'RMA.Runbooks', $version)
        } elseif ($PSCmdlet.ShouldProcess("RMA.Runbooks $version", "Install to $modulesRoot")) {
            $null = New-Item -ItemType Directory -Path $target -Force
            Copy-Item -Path (Join-Path $sourceDir '*') -Destination $target -Recurse -Force
            Write-Host ('  {0,-52} {1}  INSTALLED' -f 'RMA.Runbooks', $version)
        }

        # Prove it actually loads here, rather than discovering it at three in the morning.
        $found = Get-Module -ListAvailable -Name 'RMA.Runbooks' |
        Where-Object { $_.Version.ToString() -eq $version }
        if (-not $found -and -not $WhatIfPreference) {
            throw "RMA.Runbooks $version was installed to '$target' but is not discoverable. " +
            "Check that '$modulesRoot' is on PSModulePath for the account the Hybrid Worker runs as (local SYSTEM)."
        }

        if ($PruneUnpinned) {
            foreach ($old in Get-ChildItem (Join-Path $modulesRoot 'RMA.Runbooks') -Directory -ErrorAction SilentlyContinue |
                Where-Object Name -NE $version) {
                if ($PSCmdlet.ShouldProcess("RMA.Runbooks $($old.Name)", 'Remove superseded version')) {
                    Remove-Item $old.FullName -Recurse -Force
                    Write-Host "  removed RMA.Runbooks $($old.Name)"
                }
            }
        }
    } finally {
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host 'Worker provisioning complete.'
Write-Host 'Run Test-RmaHealth from the Automation Account against this worker to verify.'
