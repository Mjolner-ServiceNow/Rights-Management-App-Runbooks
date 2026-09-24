#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# What this script emits is what the release notes tell an administrator to verify before
# running code elevated on every Hybrid Worker. A hash that does not match its file, or a
# missing output, turns that instruction into theatre.

BeforeAll {
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:Packager = Join-Path $script:RepoRoot 'build/New-RmaModulePackage.ps1'
    $script:OutDir   = Join-Path ([IO.Path]::GetTempPath()) "rma-package-$([guid]::NewGuid().ToString('N'))"
    $script:Result   = & $script:Packager -OutputDirectory $script:OutDir
}

AfterAll {
    if ($script:OutDir -and (Test-Path $script:OutDir)) {
        Remove-Item $script:OutDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'New-RmaModulePackage' -Tag 'Unit', 'Release' {

    It 'produces both artefacts a worker needs' {
        # The module alone is not enough: without the provisioning script on the release,
        # bootstrapping a worker means a checkout or piping a mutable URL into iex.
        Test-Path $script:Result.Path         | Should -BeTrue
        Test-Path $script:Result.WorkerScript | Should -BeTrue
    }

    It 'names the package after the manifest version' {
        $version = (Import-PowerShellDataFile (Join-Path $script:RepoRoot 'src/RMA.Runbooks/RMA.Runbooks.psd1')).ModuleVersion
        $script:Result.Version | Should -Be $version
        Split-Path $script:Result.Path -Leaf | Should -Be "RMA.Runbooks-$version.zip"
    }

    It 'reports a <Name> hash that matches the file it describes' -ForEach @(
        @{ Name = 'package'; PathProperty = 'Path'; HashProperty = 'Sha256' }
        @{ Name = 'provisioning script'; PathProperty = 'WorkerScript'; HashProperty = 'WorkerScriptSha256' }
    ) {
        # The published hash is the only thing standing between a worker and a substituted
        # payload, so it has to describe the artefact actually attached to the release.
        $actual = (Get-FileHash $script:Result.$PathProperty -Algorithm SHA256).Hash
        $script:Result.$HashProperty | Should -Be $actual
        $script:Result.$HashProperty | Should -Match '^[0-9A-F]{64}$'
    }

    It 'ships the provisioning script unmodified' {
        # If the copy drifted from the source, the hash in the notes would verify a script
        # nobody reviewed.
        $source = Get-FileHash (Join-Path $script:RepoRoot 'scripts/Initialize-RmaWorker.ps1') -Algorithm SHA256
        $script:Result.WorkerScriptSha256 | Should -Be $source.Hash
    }

    It 'expands into a single top-level RMA.Runbooks folder' {
        # Initialize-RmaWorker.ps1 finds the module by looking for RMA.Runbooks.psd1 under
        # the expanded archive, and copies that directory's contents into the modules root.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($script:Result.Path)
        try {
            $roots = @($zip.Entries.FullName | ForEach-Object { ($_ -split '[\\/]')[0] } | Select-Object -Unique)
        } finally {
            $zip.Dispose()
        }
        $roots | Should -Be @('RMA.Runbooks')
    }

    Context 'reproducibility' {

        BeforeAll {
            # A copy, so the tests can change timestamps and contents without touching src/.
            $script:Scratch = Join-Path ([IO.Path]::GetTempPath()) "rma-repro-$([guid]::NewGuid().ToString('N'))"
            $script:Copy    = Join-Path $script:Scratch 'RMA.Runbooks'
            $null = New-Item -ItemType Directory -Path $script:Scratch -Force
            Copy-Item -Path (Join-Path $script:RepoRoot 'src/RMA.Runbooks') -Destination $script:Copy -Recurse

            function New-TestPackage {
                param([string] $Name)
                & $script:Packager -ModulePath $script:Copy -OutputDirectory (Join-Path $script:Scratch $Name)
            }
        }

        AfterAll {
            if ($script:Scratch -and (Test-Path $script:Scratch)) {
                Remove-Item $script:Scratch -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'yields the same hash for the same source, whatever the file timestamps' {
            # Every CI run checks out afresh, so timestamps always differ between the run
            # that drafts a release and any later one. v2.0.0's zip was rebuilt at publish
            # and its hash no longer matched the notes the draft had been created with.
            Get-ChildItem $script:Copy -File -Recurse | ForEach-Object { $_.LastWriteTime = [datetime]'2011-03-04 05:06:07' }
            $first = New-TestPackage -Name 'first'
            Get-ChildItem $script:Copy -File -Recurse | ForEach-Object { $_.LastWriteTime = [datetime]'2024-11-12 13:14:15' }
            $second = New-TestPackage -Name 'second'

            $second.Sha256 | Should -Be $first.Sha256
            # And the same as the package built from src/ itself, whose timestamps are
            # whatever the checkout left.
            $first.Sha256 | Should -Be $script:Result.Sha256
        }

        It 'yields a different hash when a file changes' {
            # Without this, the test above would also pass for a packager that ignored
            # the files altogether.
            $before = New-TestPackage -Name 'before'
            Add-Content -Path (Join-Path $script:Copy 'RMA.Runbooks.psm1') -Value '# changed'
            $after = New-TestPackage -Name 'after'

            $after.Sha256 | Should -Not -Be $before.Sha256
        }
    }
}
