#Requires -Version 7.2
<#
.SYNOPSIS
    Decides whether the current ref should produce a release, and whether it is a draft.
.DESCRIPTION
    Two entry points into release.yml, and this is the only thing that tells them apart.

    A tag push is deliberate: somebody typed the version. It publishes, and the tag must
    agree with the manifest, because a release whose asset version disagrees with its tag
    is how a worker ends up running a module the runbooks are not pinned to.

    A push to main is not deliberate. It drafts, because a release here is not a marker:
    it is the artefact somebody installs on every Hybrid Worker by hand, after which the
    runbooks have to be republished. Assert-ModuleVersionBump.ps1 requires a bump on every
    pull request that touches the module, so publishing automatically would put out one
    release per module pull request and let release cadence be driven by merge tempo
    rather than by whether the fleet is ready. The package, the hash and the notes are
    built either way; a person decides when it ships.

    Nothing is produced when a release for that version already exists, so repeated pushes
    to main do not pile up drafts. A draft release holds its tag_name without creating the
    tag, which is why existing releases are checked and not just existing tags.
.PARAMETER RefType
    'tag' or 'branch', from github.ref_type.
.PARAMETER RefName
    github.ref_name: the tag for a tag push, the branch for a branch push.
.PARAMETER ExistingRelease
    Tag names that already have a release or a tag. Discovered from gh and git when the
    parameter is omitted, and supplied directly by the tests.
.OUTPUTS
    An object with Proceed, Draft, Tag, Version and Reason. Also written to GITHUB_OUTPUT
    when that variable is set.
.EXAMPLE
    ./build/Get-RmaReleasePlan.ps1 -RefType branch -RefName main
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][ValidateSet('tag', 'branch')]
    [string] $RefType,

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
    [string] $RefName,

    [AllowEmptyCollection()]
    [string[]] $ExistingRelease,

    [ValidateNotNullOrEmpty()]
    [string] $ManifestPath = "$PSScriptRoot/../src/RMA.Runbooks/RMA.Runbooks.psd1"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RmaReleasePlanInternal {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]   $RefType,
        [Parameter(Mandatory)][string]   $RefName,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $ExistingRelease,
        [Parameter(Mandatory)][string]   $ManifestPath
    )

    $version = (Import-PowerShellDataFile $ManifestPath).ModuleVersion
    $tag     = "v$version"

    if ($RefType -eq 'tag') {
        $tagged = $RefName -replace '^v', ''
        if ($tagged -ne $version) {
            throw "Tag $RefName does not match ModuleVersion $version. Bump the manifest or move the tag."
        }
        return [pscustomobject]@{
            Proceed = $true; Draft = $false; Tag = $RefName; Version = $version
            Reason  = "Tag $RefName agrees with the manifest; publishing."
        }
    }

    if ($ExistingRelease -contains $tag) {
        return [pscustomobject]@{
            Proceed = $false; Draft = $false; Tag = $tag; Version = $version
            Reason  = "$tag already exists; nothing to draft."
        }
    }

    [pscustomobject]@{
        Proceed = $true; Draft = $true; Tag = $tag; Version = $version
        Reason  = "ModuleVersion is $version and $tag does not exist yet; drafting a release for a human to publish."
    }
}

if (-not $PSBoundParameters.ContainsKey('ExistingRelease')) {
    # Both, because a draft release holds its tag_name without creating the tag, and a tag
    # can exist from a release that was later deleted.
    $ExistingRelease = @(
        @(gh release list --limit 200 --json tagName --jq '.[].tagName' 2>$null)
        @(git tag -l 'v*')
    ) | Where-Object { $_ } | Select-Object -Unique
}

$plan = Get-RmaReleasePlanInternal -RefType $RefType -RefName $RefName `
    -ExistingRelease $ExistingRelease -ManifestPath $ManifestPath

Write-Host $plan.Reason
if ($env:GITHUB_OUTPUT) {
    "proceed=$($plan.Proceed.ToString().ToLowerInvariant())" | Add-Content $env:GITHUB_OUTPUT
    "draft=$($plan.Draft.ToString().ToLowerInvariant())"     | Add-Content $env:GITHUB_OUTPUT
    "tag=$($plan.Tag)"                                       | Add-Content $env:GITHUB_OUTPUT
    "version=$($plan.Version)"                               | Add-Content $env:GITHUB_OUTPUT
}
$plan
