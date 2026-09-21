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
            $plan = & $script:Plan -RefType branch -RefName main -ExistingRelease @('v0.9.0') `
                -ManifestPath $script:Manifest

            $plan.Proceed | Should -BeTrue
            $plan.Draft   | Should -BeTrue
            $plan.Tag     | Should -Be "v$script:Version"
        }

        It 'does nothing when a release for that version already exists' {
            # Otherwise every subsequent push to main piles up another draft.
            $plan = & $script:Plan -RefType branch -RefName main `
                -ExistingRelease @("v$script:Version") -ManifestPath $script:Manifest

            $plan.Proceed | Should -BeFalse
            $plan.Reason  | Should -Match 'already exists'
        }

        It 'does nothing when only a bare tag exists, with no release' {
            # A draft holds its tag_name without creating the tag, and a tag can outlive a
            # deleted release, so the caller passes both and either one counts.
            $plan = & $script:Plan -RefType branch -RefName main `
                -ExistingRelease @("v$script:Version") -ManifestPath $script:Manifest

            $plan.Proceed | Should -BeFalse
        }
    }

    Context 'a v* tag push' {

        It 'publishes when the tag agrees with the manifest' {
            $plan = & $script:Plan -RefType tag -RefName "v$script:Version" `
                -ExistingRelease @() -ManifestPath $script:Manifest

            $plan.Proceed | Should -BeTrue
            $plan.Draft   | Should -BeFalse
        }

        It 'publishes even when a release for that version exists, because the tag is deliberate' {
            # This is how a draft gets promoted, and how a deleted release is recreated.
            $plan = & $script:Plan -RefType tag -RefName "v$script:Version" `
                -ExistingRelease @("v$script:Version") -ManifestPath $script:Manifest

            $plan.Proceed | Should -BeTrue
            $plan.Draft   | Should -BeFalse
        }

        It 'refuses a tag that disagrees with the manifest' {
            # A release whose asset version disagrees with its tag is how a worker ends up
            # running a module the runbooks are not pinned to.
            { & $script:Plan -RefType tag -RefName 'v9.9.9' -ExistingRelease @() `
                    -ManifestPath $script:Manifest } |
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
                $null = & $script:Plan -RefType branch -RefName main -ExistingRelease @() `
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
