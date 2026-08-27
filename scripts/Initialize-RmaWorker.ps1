#Requires -Version 7.2
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Provisions a Hybrid Worker with the exact, pinned module set. Idempotent.
.DESCRIPTION
    Replaces the runtime Install-Module calls that were previously inside every runbook.
    Runbooks now assert their dependencies with #Requires and never mutate the host.

    Also removes module versions that are not on the pinned list, which is how the disk
    consumed by the accumulated versions is reclaimed.

    Run at build time via VM extension or configuration management, not from a runbook.
.PARAMETER PruneUnpinned
    Removes non-pinned versions of managed modules. Review the -WhatIf output first.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('RmaAvoidRuntimeModuleInstall', '',
    Justification = 'This script is the worker provisioner the rule directs authors to. It is run at build time by configuration management, never from a runbook. Versions are pinned, which RmaRequirePinnedModuleVersion verifies.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $PruneUnpinned
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The single source of truth for what belongs on a worker.
# Changing a version here is a reviewed, released change.
$pinned = @(
    @{ Name = 'Microsoft.Graph.Authentication'; Version = '2.25.0' }
    @{ Name = 'Microsoft.Graph.Users'; Version = '2.25.0' }
    @{ Name = 'Microsoft.Graph.Users.Actions'; Version = '2.25.0' }
    @{ Name = 'Microsoft.Graph.Groups'; Version = '2.25.0' }
    @{ Name = 'Microsoft.Graph.Identity.DirectoryManagement'; Version = '2.25.0' }
    @{ Name = 'Microsoft.Graph.Identity.SignIns'; Version = '2.25.0' }
    # Submodule only. NEVER install the Microsoft.Graph.Beta meta-module: it pulls 40+
    # submodules and over a gigabyte to satisfy two calls to Get-MgBetaUser.
    @{ Name = 'Microsoft.Graph.Beta.Users'; Version = '2.25.0' }
    @{ Name = 'ExchangeOnlineManagement'; Version = '3.7.2' }
)

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

Write-Host ''
Write-Host 'Worker provisioning complete.'
