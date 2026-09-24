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

    A tag push never rebuilds a release that already exists. Publishing a draft from the
    Releases page creates its tag, and that tag push lands here. Rebuilding then replaced
    the package and its hash under notes people had already copied, and v2.0.0 failed its
    own hash check on the first worker it was installed on. A published release's assets
    are what workers verify against, so they are never touched again. A draft that meets a
    hand-pushed tag is refused rather than guessed at: its package was built from the
    commit it was drafted at, which need not be the one the tag names.
.PARAMETER RefType
    'tag' or 'branch', from github.ref_type.
.PARAMETER RefName
    github.ref_name: the tag for a tag push, the branch for a branch push.
.PARAMETER PublishedRelease
    Tag names of published releases.
.PARAMETER DraftRelease
    Tag names of draft releases. A draft holds its tag name without creating the tag.
.PARAMETER ExistingTag
    Tag names that exist in git, whether or not a release does. A tag can outlive a
    deleted release. Ignored for a tag push, where the pushed tag always exists.

    All three are discovered from gh and git when none of them is passed, and are supplied
    directly by the tests.
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
    [string[]] $PublishedRelease = @(),

    [AllowEmptyCollection()]
    [string[]] $DraftRelease = @(),

    [AllowEmptyCollection()]
    [string[]] $ExistingTag = @(),

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
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $PublishedRelease,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $DraftRelease,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $ExistingTag,
        [Parameter(Mandatory)][string]   $ManifestPath
    )

    $version = (Import-PowerShellDataFile $ManifestPath).ModuleVersion
    $tag     = "v$version"

    if ($RefType -eq 'tag') {
        $tagged = $RefName -replace '^v', ''
        if ($tagged -ne $version) {
            throw "Tag $RefName does not match ModuleVersion $version. Bump the manifest or move the tag."
        }
        if ($PublishedRelease -contains $RefName) {
            return [pscustomobject]@{
                Proceed = $false; Draft = $false; Tag = $RefName; Version = $version
                Reason  = "$RefName is already published; its assets and their hashes are what workers verify against, so nothing is rebuilt."
            }
        }
        if ($DraftRelease -contains $RefName) {
            throw ("A draft release for $RefName exists, and pushing the tag does not publish it. " +
                'Its package was built from the commit it was drafted at, which need not be the one ' +
                'this tag names. Delete the draft and re-run this workflow to build from the tag, ' +
                'or delete the tag and publish the draft from the Releases page.')
        }
        return [pscustomobject]@{
            Proceed = $true; Draft = $false; Tag = $RefName; Version = $version
            Reason  = "Tag $RefName agrees with the manifest and has no release; publishing."
        }
    }

    if (($PublishedRelease + $DraftRelease + $ExistingTag) -contains $tag) {
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

$supplied = 'PublishedRelease', 'DraftRelease', 'ExistingTag' |
Where-Object { $PSBoundParameters.ContainsKey($_) }
if (-not $supplied) {
    # Fails loudly: an empty answer from a gh that could not reach the API reads as "no
    # release exists", which on a tag push means rebuilding assets that are already out.
    $json = gh release list --limit 200 --json 'tagName,isDraft'
    if ($LASTEXITCODE -ne 0) {
        throw "gh release list exited with $LASTEXITCODE; cannot tell which releases exist."
    }
    $releases = @($json | ConvertFrom-Json)
    $PublishedRelease = @($releases | Where-Object { -not $_.isDraft } | ForEach-Object tagName)
    $DraftRelease     = @($releases | Where-Object { $_.isDraft } | ForEach-Object tagName)
    $ExistingTag      = @(git tag -l 'v*' | Where-Object { $_ })
}

$plan = Get-RmaReleasePlanInternal -RefType $RefType -RefName $RefName `
    -PublishedRelease $PublishedRelease -DraftRelease $DraftRelease `
    -ExistingTag $ExistingTag -ManifestPath $ManifestPath

Write-Host $plan.Reason
if ($env:GITHUB_OUTPUT) {
    "proceed=$($plan.Proceed.ToString().ToLowerInvariant())" | Add-Content $env:GITHUB_OUTPUT
    "draft=$($plan.Draft.ToString().ToLowerInvariant())"     | Add-Content $env:GITHUB_OUTPUT
    "tag=$($plan.Tag)"                                       | Add-Content $env:GITHUB_OUTPUT
    "version=$($plan.Version)"                               | Add-Content $env:GITHUB_OUTPUT
}
$plan
