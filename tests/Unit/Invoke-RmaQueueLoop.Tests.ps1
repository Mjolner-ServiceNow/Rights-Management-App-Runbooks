#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force

    $script:Context = [pscustomobject]@{
        PSTypeName = 'Rma.ServiceNowContext'
        Instance   = 'contoso'
        BaseUri    = 'https://contoso.service-now.com'
        Headers    = @{}
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

    Context 'a queue row without a sys_id' {
        It 'skips the row instead of throwing out of the loop' {
            # Reading $job.sys_id unguarded threw under StrictMode from outside the
            # try/finally, so one malformed row abandoned every remaining job.
            $script:Polls = 0
            Mock -ModuleName RMA.Runbooks Get-RmaPendingJob {
                $script:Polls++
                if ($script:Polls -eq 1) { @([pscustomobject]@{ input = '' }) } else { @() }
            }
            Mock -ModuleName RMA.Runbooks Request-RmaJobClaim { $true }
            Mock -ModuleName RMA.Runbooks Start-Sleep {}

            $result = Invoke-RmaQueueLoop -Context $script:Context -DomainId $script:DomainId `
                -Command 'Create-EntraUser' -Body { }

            $result.StopReason | Should -Be 'drained'
            $result.Processed  | Should -Be 0
            $script:States.Count | Should -Be 0
            Should -Invoke -ModuleName RMA.Runbooks Write-RmaLog -ParameterFilter {
                $Level -eq 'Error' -and $Message -match 'no sys_id'
            }
        }
    }

    Context 'a payload the queue could not supply' {
        It 'fails the job with a message naming the missing field' {
            Mock -ModuleName RMA.Runbooks Get-RmaPendingJob {
                if ($script:Served) { @() } else { $script:Served = $true; @([pscustomobject]@{ sys_id = ('7' * 32) }) }
            }
            Mock -ModuleName RMA.Runbooks Request-RmaJobClaim { $true }
            $script:Served = $false

            $result = Invoke-RmaQueueLoop -Context $script:Context -DomainId $script:DomainId `
                -Command 'Create-EntraUser' -Body { }

            $result.Failed | Should -Be 1
            $script:States[0].State | Should -Be 'Failed'
            $script:States[0].Error | Should -Match "no 'input' payload"
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

    Context 'a fleet of workers contending for one queue' {

        # A shared queue in which every row belongs to exactly one worker. From inside a
        # single worker that is indistinguishable from a real race: claims on rows it owns
        # succeed, claims on everyone else's fail, and the rows it loses stay Pending and
        # keep coming back. Deterministic, so the assertions below are not probabilistic.
        BeforeEach {
            $script:Pending    = [System.Collections.Generic.List[string]]::new()
            $script:Owner      = @{}
            $script:Executed   = [System.Collections.Generic.List[string]]::new()
            $script:ClaimOrder = [System.Collections.Generic.List[string]]::new()
            $script:Worker     = 0

            Mock -ModuleName RMA.Runbooks Start-Sleep {}

            Mock -ModuleName RMA.Runbooks Get-RmaPendingJob {
                $take = [math]::Min($Limit, $script:Pending.Count)
                if ($take -eq 0) { return @() }
                @($script:Pending[0..($take - 1)] | ForEach-Object {
                        [pscustomobject]@{
                            sys_id = $_
                            input  = [Convert]::ToBase64String(
                                [Text.Encoding]::UTF8.GetBytes('{"action":"Create-EntraUser"}'))
                        }
                    })
            }

            Mock -ModuleName RMA.Runbooks Request-RmaJobClaim {
                $script:ClaimOrder.Add($SysId)
                if ($script:Owner[$SysId] -ne $script:Worker) { return $false }
                $null = $script:Pending.Remove($SysId)
                $true
            }
        }

        It 'executes every job exactly once across contending workers' {
            # The property that must survive batching. A batch is a window, not a lock:
            # if walking it ever executed a row whose claim was lost, or the same row
            # twice, duplicate execution would be back - the defect this module exists
            # to remove.
            $workers = 4
            0..39 | ForEach-Object {
                $sysId = '{0:x32}' -f $_
                $script:Pending.Add($sysId)
                $script:Owner[$sysId] = $_ % $workers
            }

            $pass = 0
            while ($script:Pending.Count -gt 0 -and $pass -lt 20) {
                $script:Worker = $pass % $workers
                $null = Invoke-RmaQueueLoop -Context $script:Context -DomainId $script:DomainId `
                    -Command 'Create-EntraUser' -BatchSize 10 -Body { param($job, $p) $null = $p; $script:Executed.Add($job.sys_id) }
                $pass++
            }

            $script:Pending.Count  | Should -Be 0
            $script:Executed.Count | Should -Be 40
            ($script:Executed | Select-Object -Unique).Count | Should -Be 40
        }

        It 'walks past a row it cannot claim instead of stalling behind it' {
            # The regression that motivated batching. With one row per poll the worker
            # re-reads the same unclaimable head row until it gives up, and reports
            # claim-contention with a full queue and nothing done.
            $head = '{0:x32}' -f 99
            $script:Pending.Add($head); $script:Owner[$head] = 1
            0..4 | ForEach-Object {
                $sysId = '{0:x32}' -f $_
                $script:Pending.Add($sysId); $script:Owner[$sysId] = 0
            }
            $script:Worker = 0

            $starved = Invoke-RmaQueueLoop -Context $script:Context -DomainId $script:DomainId `
                -Command 'Create-EntraUser' -BatchSize 1 -Body { $script:Executed.Add('x') }

            $starved.Processed  | Should -Be 0
            $starved.StopReason | Should -Be 'claim-contention'

            $batched = Invoke-RmaQueueLoop -Context $script:Context -DomainId $script:DomainId `
                -Command 'Create-EntraUser' -BatchSize 10 -Body { $script:Executed.Add('x') }

            $batched.Processed | Should -Be 5
        }

        It 'lets every worker in a ten-worker fleet make progress' {
            # At Limit 1 the arithmetic is ((N-1)/N)^MaxConsecutiveSkips: with ten workers
            # a worker abandons its run often enough to matter. Batching has to remove
            # that, or adding workers buys contention rather than throughput.
            $workers = 10
            0..99 | ForEach-Object {
                $sysId = '{0:x32}' -f $_
                $script:Pending.Add($sysId)
                $script:Owner[$sysId] = $_ % $workers
            }

            $progress = 0..($workers - 1) | ForEach-Object {
                $script:Worker = $_
                (Invoke-RmaQueueLoop -Context $script:Context -DomainId $script:DomainId `
                    -Command 'Create-EntraUser' -BatchSize 20 -Body { }).Processed
            }

            $progress.Count | Should -Be $workers
            $progress | Should -Not -Contain 0
        }

        It 'enters the batch at a varying offset so workers do not collide on row 0' {
            # Without this every worker walks the same batch in the same order and they
            # queue up on row 0 exactly as they did when the poll fetched a single row.
            0..19 | ForEach-Object {
                $sysId = '{0:x32}' -f $_
                $script:Pending.Add($sysId)
                $script:Owner[$sysId] = 1          # owned by nobody in this run
            }
            $script:Worker = 0

            $firstTouched = 1..10 | ForEach-Object {
                $script:ClaimOrder.Clear()
                $null = Invoke-RmaQueueLoop -Context $script:Context -DomainId $script:DomainId `
                    -Command 'Create-EntraUser' -BatchSize 20 -MaxConsecutiveSkips 1 -Body { }
                $script:ClaimOrder[0]
            }

            $firstTouched.Count | Should -Be 10
            ($firstTouched | Select-Object -Unique).Count | Should -BeGreaterThan 1
        }
    }
}
