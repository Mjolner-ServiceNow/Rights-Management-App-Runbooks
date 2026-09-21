#Requires -Version 7.2
<#
.SYNOPSIS
    Fails when the module changed without a ModuleVersion bump.
.DESCRIPTION
    Deployment pins by version: a runbook's #Requires names an exact RequiredVersion, and
    Initialize-RmaWorker.ps1 installs that version on the worker. A change shipped under a
    version that already exists cannot be rolled out or rolled back, and a worker that
    already has 1.1.0 will not pick up a different 1.1.0.

    CONTRIBUTING.md said CI enforced this. It did not: the only check was in release.yml,
    comparing the v* tag against the manifest at tagging time, so an unbumped change passed
    pull-request CI and failed later, at release, in front of whoever was cutting it.
.PARAMETER BaseRef
    The ref to compare against, normally origin/main. The comparison is against the merge
    base, so an out-of-date branch is not asked to bump for someone else's change.
.EXAMPLE
    ./build/Assert-ModuleVersionBump.ps1 -BaseRef origin/main
#>
[CmdletBinding()]
[OutputType([void])]
param(
    [ValidateNotNullOrEmpty()]
    [string] $BaseRef = 'origin/main',

    [ValidateNotNullOrEmpty()]
    [string] $ModulePath = 'src/RMA.Runbooks',

    [ValidateNotNullOrEmpty()]
    [string] $ManifestPath = 'src/RMA.Runbooks/RMA.Runbooks.psd1'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# In a function, not at script scope: RmaAvoidScriptScopeReturn flags a bare return
# outside one, and the early exits below are exactly the shape it exists to catch.
function Assert-RmaModuleVersionBump {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()] [string] $BaseRef,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()] [string] $ModulePath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()] [string] $ManifestPath
    )

    $mergeBase = (git merge-base $BaseRef HEAD 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not find a merge base with '$BaseRef'. Fetch it first: git fetch origin main. Git said: $mergeBase"
    }
    $mergeBase = $mergeBase.Trim()

    $changed = @(git diff --name-only $mergeBase HEAD -- $ModulePath)
    if ($changed.Count -eq 0) {
        Write-Host "No change under $ModulePath since $($mergeBase.Substring(0, 8)); no bump required."
        return
    }

    Write-Host "Changed under ${ModulePath}:"
    $changed | ForEach-Object { Write-Host "  $_" }

    # The manifest as it is on the base, read without checking anything out.
    $baseManifest = (git show "${mergeBase}:${ManifestPath}" 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'The manifest is new on this branch; nothing to compare against.'
        return
    }

    # Import-PowerShellDataFile needs a file, and the base version only exists in git.
    $temp = Join-Path ([IO.Path]::GetTempPath()) "rma-base-manifest-$([guid]::NewGuid().ToString('N')).psd1"
    try {
        Set-Content -Path $temp -Value $baseManifest -Encoding utf8
        $baseVersion = [version](Import-PowerShellDataFile $temp).ModuleVersion
    } finally {
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
    }

    $headVersion = [version](Import-PowerShellDataFile $ManifestPath).ModuleVersion

    Write-Host "  base: $baseVersion"
    Write-Host "  head: $headVersion"

    if ($headVersion -le $baseVersion) {
        throw ("$ModulePath changed but ModuleVersion is still $headVersion (base $baseVersion). " +
            'Bump it in the manifest and in the #Requires RequiredVersion of every runbook, ' +
            'or the change cannot be rolled out or rolled back.')
    }
    Write-Host "ModuleVersion bumped $baseVersion -> $headVersion."
}

Assert-RmaModuleVersionBump -BaseRef $BaseRef -ModulePath $ModulePath -ManifestPath $ManifestPath
