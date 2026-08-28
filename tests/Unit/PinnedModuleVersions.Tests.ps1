#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path

    # The $pinned list in the provisioner is the single source of truth for what a worker
    # gets. Read as text rather than dot-sourced: the provisioner declares
    # '#Requires -RunAsAdministrator', so it cannot be loaded on a CI runner.
    $provisioner = Get-Content (Join-Path $repoRoot 'scripts/Initialize-RmaWorker.ps1') -Raw
    $script:pinned = @{}
    $pinPattern = "@\{\s*Name\s*=\s*'([^']+)'\s*;\s*Version\s*=\s*'([^']+)'\s*\}"
    foreach ($match in [regex]::Matches($provisioner, $pinPattern)) {
        $script:pinned[$match.Groups[1].Value] = $match.Groups[2].Value
    }

    # Every RequiredVersion the runbooks declare.
    $requirePattern = "#Requires -Modules @\{\s*ModuleName\s*=\s*'([^']+)'\s*;\s*RequiredVersion\s*=\s*'([^']+)'\s*\}"
    $script:declared = foreach ($file in Get-ChildItem (Join-Path $repoRoot 'src/runbooks') -Filter '*.ps1' -File) {
        $content = Get-Content $file.FullName -Raw
        foreach ($match in [regex]::Matches($content, $requirePattern)) {
            [pscustomobject]@{
                Runbook = $file.BaseName
                Module  = $match.Groups[1].Value
                Version = $match.Groups[2].Value
            }
        }
    }
}

Describe 'Pinned module versions' -Tag 'Unit' {

    It 'reads the provisioner pin list' {
        # Guards the two tests below: a regex that silently matched nothing would make them
        # pass vacuously.
        $script:pinned.Count | Should -BeGreaterThan 0
        $script:declared.Count | Should -BeGreaterThan 0
    }

    It 'declares the version in each runbook that the provisioner actually installs' {
        # A worker provisioned with Microsoft.Graph 2.39.0 while a runbook pins 2.25.0 fails
        # at parse time on every job routed to it. The two lists moved independently once,
        # during the 7.6 upgrade. This is what stops that recurring.
        $mismatched = foreach ($requirement in $script:declared) {
            if ($script:pinned.ContainsKey($requirement.Module) -and
                $script:pinned[$requirement.Module] -ne $requirement.Version) {
                '{0} requires {1} {2}, provisioner installs {3}' -f
                $requirement.Runbook, $requirement.Module, $requirement.Version, $script:pinned[$requirement.Module]
            }
        }
        $mismatched | Should -BeNullOrEmpty
    }

    It 'installs every third-party module the runbooks require' {
        # RMA.Runbooks is excluded: it is installed from this repository, not the gallery,
        # and Publish-RmaContent.ps1 already checks it against the module manifest.
        $thirdParty = @($script:declared | Where-Object { $_.Module -ne 'RMA.Runbooks' })
        $unprovisioned = foreach ($requirement in $thirdParty) {
            if (-not $script:pinned.ContainsKey($requirement.Module)) {
                '{0} requires {1}, which the provisioner does not install' -f $requirement.Runbook, $requirement.Module
            }
        }
        $unprovisioned | Should -BeNullOrEmpty
    }

    It 'keeps every Microsoft.Graph submodule on one version' {
        # The submodules share Microsoft.Graph.Core and the Authentication module's
        # assemblies. Mixing versions in one session produces assembly load failures that
        # present as missing cmdlets, which sends you looking at permissions instead.
        $graphPins = @($script:pinned.Keys | Where-Object { $_ -like 'Microsoft.Graph.*' })
        $graphPins.Count | Should -BeGreaterThan 0

        $versions = @($graphPins | ForEach-Object { $script:pinned[$_] } | Select-Object -Unique)
        $versions.Count | Should -Be 1
    }
}
