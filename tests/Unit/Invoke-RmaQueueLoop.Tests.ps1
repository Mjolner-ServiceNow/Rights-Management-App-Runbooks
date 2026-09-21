#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force

    $script:Context = [pscustomobject]@{
        Instance = 'contoso'
        BaseUri  = 'https://contoso.service-now.com'
        Headers  = @{}
    }
    $script:DomainId = 'abcdef0123456789abcdef0123456789'

    function New-TestJob {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Test factory.')]
        param([string]$SysId, [string]$Action)
        [pscustomobject]@{
            sys_id = $SysId
            input  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{ action = $Action } | ConvertTo-Json)))
        }
    }
}

Describe 'Invoke-RmaQueueLoop' -Tag 'Unit', 'Concurrency' {

    BeforeEach {
        $script:States = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName RMA.Runbooks Write-RmaLog {}
        Mock -ModuleName RMA.Runbooks Set-RmaJobState {
            $script:States.Add([pscustomobject]@{ SysId = $SysId; State = $State; Error = $ExceptionMessage })
        }
    }

    Context 'a job that succeeds' {
        It 'marks it Completed' {
            $job = New-TestJob -SysId ('a' * 32) -Action 'Create-EntraUser'
            Mock -ModuleName RMA.Runbooks Get-RmaPendingJob { if ($script:Served) { @() } else { $script:Served = $true; @($job) } }
            Mock -ModuleName RMA.Runbooks Request-RmaJobClaim { $true }
            $script:Served = $false

            $result = Invoke-RmaQueueLoop -Context $script:Context -DomainId $script:DomainId `
                -Command 'Create-EntraUser' -Body { param($job, $parameters) $null = $job, $parameters }

            $result.Succeeded | Should -Be 1
            $result.Failed    | Should -Be 0
            $script:States[0].State | Should -Be 'Completed'
        }
    }

    Context 'a job whose body throws' {
        It 'marks it Failed and records the reason' {
            $job = New-TestJob -SysId ('b' * 32) -Action 'Create-EntraUser'
            Mock -ModuleName RMA.Runbooks Get-RmaPendingJob { if ($script:Served) { @() } else { $script:Served = $true; @($job) } }
            Mock -ModuleName RMA.Runbooks Request-RmaJobClaim { $true }
            $script:Served = $false

            $result = Invoke-RmaQueueLoop -Context $script:Context -DomainId $script:DomainId `
                -Command 'Create-EntraUser' -Body { throw 'directory object not found' }

            $result.Failed | Should -Be 1
            $script:States[0].State | Should -Be 'Failed'
            $script:States[0].Error | Should -Match 'directory object not found'
        }
    }

    Context 'an action mismatch' {
        It 'fails the job instead of stranding it' {
            # The original defect: 59 runbooks set Work in Progress, skipped the body when
            # the action did not match, and never wrote a terminal state. The job sat in
            # Work in Progress forever with nothing to recover it.
            $job = New-TestJob -SysId ('c' * 32) -Action 'Some-OtherCommand'
            Mock -ModuleName RMA.Runbooks Get-RmaPendingJob { if ($script:Served) { @() } else { $script:Served = $true; @($job) } }
            Mock -ModuleName RMA.Runbooks Request-RmaJobClaim { $true }
            $script:Served = $false

            $result = Invoke-RmaQueueLoop -Context $script:Context -DomainId $script:DomainId `
                -Command 'Create-EntraUser' -Body { }

            $result.Failed | Should -Be 1
            $script:States.Count | Should -Be 1
            $script:States[0].State | Should -Be 'Failed'
            $script:States[0].Error | Should -Match 'Action mismatch'
        }
    }

    Context 'a job this worker did not win' {
        It 'is never executed and never has its state changed' {
            $job = New-TestJob -SysId ('d' * 32) -Action 'Create-EntraUser'
            Mock -ModuleName RMA.Runbooks Get-RmaPendingJob { if ($script:Polls++ -gt 0) { @() } else { @($job) } }
            Mock -ModuleName RMA.Runbooks Request-RmaJobClaim { $false }
            $script:Polls = 0
            $script:Ran = $false

            $result = Invoke-RmaQueueLoop -Context $script:Context -DomainId $script:DomainId `
                -Command 'Create-EntraUser' -Body { $script:Ran = $true }

            $script:Ran | Should -BeFalse
            $result.SkippedNotClaimed | Should -Be 1
            $script:States.Count | Should -Be 0
        }
    }

    Context 'a job this worker can never claim' {
        It 'backs off and stops instead of polling without bound' {
            # Measured before the ceiling existed: 90,637 polls in 60 seconds. A lost
            # claim leaves the row Pending, so the next poll returns the same job, and
            # neither MaxJobs (nothing is processed) nor the empty-poll exit applies.
            Mock -ModuleName RMA.Runbooks Get-RmaPendingJob { @(New-TestJob -SysId ('9' * 32) -Action 'Create-EntraUser') }
            Mock -ModuleName RMA.Runbooks Request-RmaJobClaim { $false }
            Mock -ModuleName RMA.Runbooks Start-Sleep {}

            $result = Invoke-RmaQueueLoop -Context $script:Context -DomainId $script:DomainId `
                -Command 'Create-EntraUser' -MaxConsecutiveSkips 5 -Body { }

            $result.StopReason        | Should -Be 'claim-contention'
            $result.SkippedNotClaimed | Should -Be 5
            $result.Processed         | Should -Be 0
            $script:States.Count      | Should -Be 0

            Should -Invoke -ModuleName RMA.Runbooks Get-RmaPendingJob -Times 5 -Exactly
            # Four backoffs: the fifth skip reaches the ceiling and breaks before sleeping.
            Should -Invoke -ModuleName RMA.Runbooks Start-Sleep -Times 4 -Exactly
        }

        It 'resets the run of skips after a claim it does win' {
            $script:Attempt = 0
            Mock -ModuleName RMA.Runbooks Get-RmaPendingJob { @(New-TestJob -SysId ('8' * 32) -Action 'Create-EntraUser') }
            Mock -ModuleName RMA.Runbooks Request-RmaJobClaim { $script:Attempt++; $script:Attempt -eq 3 }
            Mock -ModuleName RMA.Runbooks Start-Sleep {}

            $result = Invoke-RmaQueueLoop -Context $script:Context -DomainId $script:DomainId `
                -Command 'Create-EntraUser' -MaxConsecutiveSkips 3 -Body { }

            # lose, lose, win, lose, lose, lose. Without the reset the third loss overall
            # would have stopped the loop before the job it actually won.
            $result.Processed         | Should -Be 1
            $result.SkippedNotClaimed | Should -Be 5
            $result.StopReason        | Should -Be 'claim-contention'
        }
    }

    Context 'safety limits' {
        It 'stops at MaxJobs and reports why' {
            Mock -ModuleName RMA.Runbooks Get-RmaPendingJob { @(New-TestJob -SysId ('e' * 32) -Action 'Create-EntraUser') }
            Mock -ModuleName RMA.Runbooks Request-RmaJobClaim { $true }

            $result = Invoke-RmaQueueLoop -Context $script:Context -DomainId $script:DomainId `
                -Command 'Create-EntraUser' -MaxJobs 3 -Body { }

            $result.Processed  | Should -Be 3
            $result.StopReason | Should -Be 'max-jobs'
        }
    }

    Context 'when the terminal state write fails' {
        It 'does not abandon the remaining queue' {
            # A failed state write strands one job for the watchdog. It must not stop the
            # loop, or one bad row takes the whole queue down.
            Mock -ModuleName RMA.Runbooks Get-RmaPendingJob {
                if ($script:Left-- -gt 0) { @(New-TestJob -SysId ('f' * 32) -Action 'Create-EntraUser') } else { @() }
            }
            Mock -ModuleName RMA.Runbooks Request-RmaJobClaim { $true }
            Mock -ModuleName RMA.Runbooks Set-RmaJobState { throw 'ServiceNow unavailable' }
            $script:Left = 3

            $result = Invoke-RmaQueueLoop -Context $script:Context -DomainId $script:DomainId `
                -Command 'Create-EntraUser' -Body { }

            $result.Processed | Should -Be 3
            Should -Invoke -ModuleName RMA.Runbooks Write-RmaLog -ParameterFilter { $Level -eq 'Error' }
        }
    }
}
