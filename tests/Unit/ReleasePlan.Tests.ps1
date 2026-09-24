#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# build/Get-RmaReleasePlan.ps1 is the only thing standing between "a module pull request
# was merged" and "a release the whole fleet is expected to install". Every branch of it
# is exercised here rather than discovered on main.

BeforeAll {
    $script:Plan     = (Resolve-Path "$PSScriptRoot/../../build/Get-RmaReleasePlan.ps1").Path
    $script:Manifest = (Resolve-Path "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1").Path
    $script:Version  = (Import-PowerShellDataFile $script:Manifest).ModuleVersion
}

Describe 'Get-RmaReleasePlan' -Tag 'Unit', 'Release' {

    Context 'a push to main' {

        It 'drafts when the version has no release yet' {
            # Drafting, not publishing: a release here is the artefact somebody installs
            # on every worker by hand, so a merge must not be what ships it.
            $plan = & $script:Plan -RefType branch -RefName main -PublishedRelease @('v0.9.0') `
                -ManifestPath $script:Manifest

            $plan.Proceed | Should -BeTrue
            $plan.Draft   | Should -BeTrue
            $plan.Tag     | Should -Be "v$script:Version"
        }

        It 'does nothing when a <Kind> for that version already exists' -ForEach @(
            # Otherwise every subsequent push to main piles up another draft. A draft holds
            # its tag_name without creating the tag, and a tag can outlive a deleted
            # release, so any one of the three counts.
            @{ Kind = 'published release'; Parameter = 'PublishedRelease' }
            @{ Kind = 'draft release'; Parameter = 'DraftRelease' }
            @{ Kind = 'bare tag'; Parameter = 'ExistingTag' }
        ) {
            $existing = @{ $Parameter = @("v$script:Version") }
            $plan = & $script:Plan -RefType branch -RefName main @existing `
                -ManifestPath $script:Manifest

            $plan.Proceed | Should -BeFalse
            $plan.Reason  | Should -Match 'already exists'
        }
    }

    Context 'a v* tag push' {

        It 'publishes when the tag agrees with the manifest and has no release' {
            # How a deleted release is recreated, and the hand-pushed path with no draft.
            $plan = & $script:Plan -RefType tag -RefName "v$script:Version" `
                -ExistingTag @("v$script:Version") -ManifestPath $script:Manifest

            $plan.Proceed | Should -BeTrue
            $plan.Draft   | Should -BeFalse
        }

        It 'rebuilds nothing when the release is already published' {
            # Publishing a draft from the Releases page creates the tag, and that push lands
            # here. Rebuilding replaced the zip, whose bytes carry file timestamps, under
            # notes people had already copied: v2.0.0 failed its own hash check this way.
            $plan = & $script:Plan -RefType tag -RefName "v$script:Version" `
                -PublishedRelease @("v$script:Version") -ExistingTag @("v$script:Version") `
                -ManifestPath $script:Manifest

            $plan.Proceed | Should -BeFalse
            $plan.Reason  | Should -Match 'already published'
        }

        It 'refuses a hand-pushed tag while a draft for it exists' {
            # The draft's package was built from the commit it was drafted at. Publishing
            # it under a tag on another commit, or rebuilding over it, would each leave the
            # hash in the notes describing something other than what the tag names.
            { & $script:Plan -RefType tag -RefName "v$script:Version" `
                    -DraftRelease @("v$script:Version") -ManifestPath $script:Manifest } |
            Should -Throw '*draft release*exists*'
        }

        It 'refuses a tag that disagrees with the manifest' {
            # A release whose asset version disagrees with its tag is how a worker ends up
            # running a module the runbooks are not pinned to.
            { & $script:Plan -RefType tag -RefName 'v9.9.9' -PublishedRelease @() -ManifestPath $script:Manifest } |
            Should -Throw "*does not match ModuleVersion $script:Version*"
        }
    }

    Context 'the outputs the workflow reads' {

        It 'writes lowercase booleans to GITHUB_OUTPUT' {
            # GitHub compares these as strings: 'True' never equals 'true', and the whole
            # workflow would silently skip every step.
            $file = Join-Path ([IO.Path]::GetTempPath()) "gh-output-$([guid]::NewGuid().ToString('N'))"
            $env:GITHUB_OUTPUT = $file
            try {
                $null = & $script:Plan -RefType branch -RefName main -PublishedRelease @() `
                    -ManifestPath $script:Manifest
                $written = Get-Content $file -Raw
            } finally {
                $env:GITHUB_OUTPUT = $null
                Remove-Item $file -Force -ErrorAction SilentlyContinue
            }

            $written | Should -Match 'proceed=true'
            $written | Should -Match 'draft=true'
            $written | Should -Match "tag=v$([regex]::Escape($script:Version))"
        }
    }
}
