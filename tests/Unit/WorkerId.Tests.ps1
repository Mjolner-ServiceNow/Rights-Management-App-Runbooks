#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    $script:Machine = [Environment]::MachineName
}

Describe 'Get-RmaWorkerId' -Tag 'Unit', 'Concurrency' {

    BeforeEach {
        $script:SavedSandbox  = $env:AUTOMATION_ASSET_SANDBOX_ID
        $script:SavedMetadata = $env:PSPrivateMetadata
        $env:AUTOMATION_ASSET_SANDBOX_ID = $null
        $env:PSPrivateMetadata = $null
        Remove-Variable -Name PSPrivateMetadata -Scope Global -ErrorAction SilentlyContinue
    }

    AfterEach {
        $env:AUTOMATION_ASSET_SANDBOX_ID = $script:SavedSandbox
        $env:PSPrivateMetadata = $script:SavedMetadata
        Remove-Variable -Name PSPrivateMetadata -Scope Global -ErrorAction SilentlyContinue
    }

    It 'uses the Automation job id when the sandbox provides one' {
        # Global, because that is where the Automation sandbox puts it.
        Set-Variable -Name PSPrivateMetadata -Scope Global -Value ([pscustomobject]@{ JobId = [guid] '7d3c2a1b-0000-4000-8000-000000000001' })

        InModuleScope RMA.Runbooks { Get-RmaWorkerId } |
        Should -Be "$($script:Machine)/7d3c2a1b-0000-4000-8000-000000000001"
    }

    It 'reads the job id from a hashtable as well' {
        # Global, because that is where the Automation sandbox puts it.
        Set-Variable -Name PSPrivateMetadata -Scope Global -Value (@{ JobId = '7d3c2a1b-0000-4000-8000-000000000002' })

        InModuleScope RMA.Runbooks { Get-RmaWorkerId } |
        Should -Be "$($script:Machine)/7d3c2a1b-0000-4000-8000-000000000002"
    }

    It 'uses the sandbox id in a runtime-environment job, where the job id is unavailable' {
        # The shape observed in a real Hybrid Worker job on the PowerShell 7.6 runtime
        # environment: no $PSPrivateMetadata variable, an environment variable of that name
        # holding a stringified hashtable, and a sandbox id unique to the job.
        $env:PSPrivateMetadata = 'System.Collections.Hashtable'
        $env:AUTOMATION_ASSET_SANDBOX_ID = '5a4db0c1-0000-4000-8000-00000000000a'

        InModuleScope RMA.Runbooks { Get-RmaWorkerId } |
        Should -Be "$($script:Machine)/sandbox-5a4db0c1-0000-4000-8000-00000000000a"
    }

    It 'gives two concurrent jobs on one worker different ids' {
        # The property the claim read-back depends on. Before this, both got '<machine>/local'
        # and both believed they had won the same claim.
        $env:AUTOMATION_ASSET_SANDBOX_ID = '5a4db0c1-0000-4000-8000-00000000000a'
        $first = InModuleScope RMA.Runbooks { Get-RmaWorkerId }
        $env:AUTOMATION_ASSET_SANDBOX_ID = '5a4db0c1-0000-4000-8000-00000000000b'
        $second = InModuleScope RMA.Runbooks { Get-RmaWorkerId }

        $first | Should -Not -Be $second
    }

    It 'ignores a sandbox id that is not a GUID' {
        # It ends up inside a sysparm_query. Nothing from the environment goes there unchecked.
        $env:AUTOMATION_ASSET_SANDBOX_ID = 'x^status=1'

        InModuleScope RMA.Runbooks { Get-RmaWorkerId } | Should -Match '/process-\d+-\d{8}T\d{9}$'
    }

    It 'falls back to the process, never to a shared constant' {
        $id = InModuleScope RMA.Runbooks { Get-RmaWorkerId }

        $id | Should -Match "^$([regex]::Escape($script:Machine))/process-$PID-\d{8}T\d{9}$"
        $id | Should -Not -BeLike '*/local'
    }

    It 'is the same on every call in the process' {
        $ids = InModuleScope RMA.Runbooks { 1..3 | ForEach-Object { Get-RmaWorkerId } }

        @($ids | Select-Object -Unique).Count | Should -Be 1
    }

    It 'is the same from another runspace in the process, as the heartbeat thread needs' {
        $env:AUTOMATION_ASSET_SANDBOX_ID = '5a4db0c1-0000-4000-8000-00000000000a'
        $here = InModuleScope RMA.Runbooks { Get-RmaWorkerId }

        $manifest = (Resolve-Path "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1").Path
        $ps = [powershell]::Create()
        try {
            $there = $ps.AddScript({
                    param($Manifest)
                    Import-Module $Manifest
                    & (Get-Module RMA.Runbooks) { Get-RmaWorkerId }
                }.ToString()).AddArgument($manifest).Invoke()
        } finally {
            $ps.Dispose()
        }

        "$there" | Should -Be $here
    }
}
