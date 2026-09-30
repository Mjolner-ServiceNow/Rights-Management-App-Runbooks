#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force

    $script:Context = [pscustomobject]@{
        PSTypeName = 'Rma.ServiceNowContext'
        Instance   = 'contoso'
        BaseUri    = 'https://contoso.service-now.com'
        Headers    = @{}
    }
    $script:SysId    = 'a' * 32
    $script:WorkerId = 'WORKER01/0f8fad5b-d9cb-469f-a165-70867728950e'

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

Describe 'Update-RmaJobHeartbeat' -Tag 'Unit' {

    BeforeEach {
        Mock -ModuleName RMA.Runbooks Write-RmaLog {}
    }

    It 'reports the claim held when ServiceNow returns it In Progress under this worker' {
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod {
            [pscustomobject]@{ result = [pscustomobject]@{ status = '2'; worker_id = $script:WorkerId } }
        }

        Update-RmaJobHeartbeat -Context $script:Context -SysId $script:SysId -WorkerId $script:WorkerId |
        Should -BeTrue
    }

    It 'filters the PATCH on status and on this worker, and writes only claimed_at' {
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod {
            [pscustomobject]@{ result = [pscustomobject]@{ status = '2'; worker_id = $script:WorkerId } }
        }

        $null = Update-RmaJobHeartbeat -Context $script:Context -SysId $script:SysId -WorkerId $script:WorkerId

        Should -Invoke -ModuleName RMA.Runbooks Invoke-RmaRestMethod -Times 1 -Exactly -ParameterFilter {
            $query = [uri]::UnescapeDataString(([regex]::Match($Uri, 'sysparm_query=([^&]+)')).Groups[1].Value)
            $fields = @(($Body | ConvertFrom-Json).PSObject.Properties.Name)
            $Method -eq 'PATCH' -and
            $Uri -like "*/x_autps_active_dir_command_queue/$($script:SysId)?*" -and
            $query -eq "status=2^worker_id=$($script:WorkerId)" -and
            # A renewal that also wrote status could resurrect a job that has already
            # reached a terminal state.
            ($fields -join ',') -eq 'claimed_at' -and
            # ISO 8601 was stored as midnight, so a renewal renewed nothing.
            ($Body | ConvertFrom-Json -DateKind String).claimed_at -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
        }
    }

    It 'reports the claim lost when the job has already reached a terminal state' {
        # Checked on the way back as well as in the query, because nothing proves yet that
        # ServiceNow honours a query on a single-record PATCH.
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod {
            [pscustomobject]@{ result = [pscustomobject]@{ status = '4'; worker_id = $script:WorkerId } }
        }

        Update-RmaJobHeartbeat -Context $script:Context -SysId $script:SysId -WorkerId $script:WorkerId |
        Should -BeFalse
    }

    It 'reports the claim lost when another worker holds it' {
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod {
            [pscustomobject]@{ result = [pscustomobject]@{ status = '2'; worker_id = 'WORKER02/other' } }
        }

        Update-RmaJobHeartbeat -Context $script:Context -SysId $script:SysId -WorkerId $script:WorkerId |
        Should -BeFalse
    }

    It 'reports the claim lost when ServiceNow returns no record' {
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod { [pscustomobject]@{ result = $null } }

        Update-RmaJobHeartbeat -Context $script:Context -SysId $script:SysId -WorkerId $script:WorkerId |
        Should -BeFalse
    }

    It 'throws when the request fails, rather than reporting a lost claim' {
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod { throw 'PATCH failed after 2 attempt(s) (HTTP 503)' }

        { Update-RmaJobHeartbeat -Context $script:Context -SysId $script:SysId -WorkerId $script:WorkerId } |
        Should -Throw '*HTTP 503*'
    }

    It 'sends nothing under -WhatIf' {
        Mock -ModuleName RMA.Runbooks Invoke-RmaRestMethod {}

        Update-RmaJobHeartbeat -Context $script:Context -SysId $script:SysId -WorkerId $script:WorkerId -WhatIf |
        Should -BeFalse
        Should -Invoke -ModuleName RMA.Runbooks Invoke-RmaRestMethod -Times 0 -Exactly
    }
}

Describe 'Heartbeat thread' -Tag 'Unit', 'Concurrency' {

    # Every test here runs the real thread with its own Renew script, so no request leaves
    # the process. The script reaches the test through the context, which is the one object
    # both runspaces share.

    BeforeAll {
        function New-ThreadContext {
            [pscustomobject]@{
                PSTypeName = 'Rma.ServiceNowContext'
                BaseUri    = 'https://contoso.service-now.com'
                Headers    = @{}
                Calls      = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
            }
        }

        function Wait-Until {
            param([scriptblock] $Condition, [int] $TimeoutMs = 5000)
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while (-not (& $Condition)) {
                if ($sw.ElapsedMilliseconds -ge $TimeoutMs) { return $false }
                Start-Sleep -Milliseconds 25
            }
            $true
        }
    }

    BeforeEach {
        Mock -ModuleName RMA.Runbooks Write-RmaLog {}
        $script:Heartbeat = $null
    }

    AfterEach {
        if ($script:Heartbeat) {
            InModuleScope RMA.Runbooks -Parameters @{ Heartbeat = $script:Heartbeat } {
                param($Heartbeat)
                Stop-RmaHeartbeat -Heartbeat $Heartbeat -GraceMilliseconds 200
            }
        }
    }

    It 'renews a job that runs longer than the interval' {
        $ctx = New-ThreadContext
        $script:Heartbeat = InModuleScope RMA.Runbooks -Parameters @{ Ctx = $ctx } {
            param($Ctx)
            Start-RmaHeartbeat -Context $Ctx -WorkerId 'w' -IntervalSeconds 1 -TickMilliseconds 50 `
                -ModuleManifest '' -Renew { param($c, $s) $c.Calls.Enqueue($s); $true }
        }

        $beat = InModuleScope RMA.Runbooks -Parameters @{ Heartbeat = $script:Heartbeat; SysId = $script:SysId } {
            param($Heartbeat, $SysId)
            Set-RmaHeartbeatJob -Heartbeat $Heartbeat -SysId $SysId
            Start-Sleep -Milliseconds 2600
            Clear-RmaHeartbeatJob -Heartbeat $Heartbeat
        }

        $beat.Renewals | Should -BeGreaterOrEqual 2
        $beat.Lost     | Should -BeFalse
        $beat.Fatal    | Should -BeNullOrEmpty
        $ctx.Calls.ToArray() | Should -Not -Contain '' -Because 'every renewal names the job'
        @($ctx.Calls.ToArray() | Select-Object -Unique) | Should -Be @($script:SysId)
    }

    It 'never renews a job that ends within one interval' {
        $ctx = New-ThreadContext
        $script:Heartbeat = InModuleScope RMA.Runbooks -Parameters @{ Ctx = $ctx } {
            param($Ctx)
            Start-RmaHeartbeat -Context $Ctx -WorkerId 'w' -IntervalSeconds 60 -TickMilliseconds 20 `
                -ModuleManifest '' -Renew { param($c, $s) $c.Calls.Enqueue($s); $true }
        }

        $beat = InModuleScope RMA.Runbooks -Parameters @{ Heartbeat = $script:Heartbeat; SysId = $script:SysId } {
            param($Heartbeat, $SysId)
            Set-RmaHeartbeatJob -Heartbeat $Heartbeat -SysId $SysId
            Start-Sleep -Milliseconds 300
            Clear-RmaHeartbeatJob -Heartbeat $Heartbeat
        }

        $beat.Renewals   | Should -Be 0
        $ctx.Calls.Count | Should -Be 0
    }

    It 'records a lost claim and stops renewing it' {
        $ctx = New-ThreadContext
        $script:Heartbeat = InModuleScope RMA.Runbooks -Parameters @{ Ctx = $ctx } {
            param($Ctx)
            Start-RmaHeartbeat -Context $Ctx -WorkerId 'w' -IntervalSeconds 1 -TickMilliseconds 50 `
                -ModuleManifest '' -Renew { param($c, $s) $c.Calls.Enqueue($s); $false }
        }

        $beat = InModuleScope RMA.Runbooks -Parameters @{ Heartbeat = $script:Heartbeat; SysId = $script:SysId } {
            param($Heartbeat, $SysId)
            Set-RmaHeartbeatJob -Heartbeat $Heartbeat -SysId $SysId
            Start-Sleep -Milliseconds 3200
            Clear-RmaHeartbeatJob -Heartbeat $Heartbeat
        }

        $beat.Lost       | Should -BeTrue
        $beat.Renewals   | Should -Be 0
        $ctx.Calls.Count | Should -Be 1 -Because 'a lost claim cannot be won back by asking again'
    }

    It 'records a failed renewal and retries it' {
        $ctx = New-ThreadContext
        $script:Heartbeat = InModuleScope RMA.Runbooks -Parameters @{ Ctx = $ctx } {
            param($Ctx)
            Start-RmaHeartbeat -Context $Ctx -WorkerId 'w' -IntervalSeconds 1 -RetrySeconds 1 -TickMilliseconds 50 `
                -ModuleManifest '' -Renew { param($c, $s) $c.Calls.Enqueue($s); throw 'HTTP 503' }
        }

        $beat = InModuleScope RMA.Runbooks -Parameters @{ Heartbeat = $script:Heartbeat; SysId = $script:SysId } {
            param($Heartbeat, $SysId)
            Set-RmaHeartbeatJob -Heartbeat $Heartbeat -SysId $SysId
            Start-Sleep -Milliseconds 2600
            Clear-RmaHeartbeatJob -Heartbeat $Heartbeat
        }

        $beat.Failures  | Should -BeGreaterOrEqual 2
        $beat.LastError | Should -Be 'HTTP 503'
        $beat.Lost      | Should -BeFalse -Because 'a failed request says nothing about who holds the claim'
    }

    It 'starts each job with fresh counters' {
        $ctx = New-ThreadContext
        $script:Heartbeat = InModuleScope RMA.Runbooks -Parameters @{ Ctx = $ctx } {
            param($Ctx)
            Start-RmaHeartbeat -Context $Ctx -WorkerId 'w' -IntervalSeconds 1 -TickMilliseconds 50 `
                -ModuleManifest '' -Renew { param($c, $s) $c.Calls.Enqueue($s); $false }
        }

        $beat = InModuleScope RMA.Runbooks -Parameters @{ Heartbeat = $script:Heartbeat; SysId = $script:SysId } {
            param($Heartbeat, $SysId)
            Set-RmaHeartbeatJob -Heartbeat $Heartbeat -SysId $SysId
            Start-Sleep -Milliseconds 1600
            $null = Clear-RmaHeartbeatJob -Heartbeat $Heartbeat
            Set-RmaHeartbeatJob -Heartbeat $Heartbeat -SysId ('b' * 32)
            Clear-RmaHeartbeatJob -Heartbeat $Heartbeat
        }

        $beat.Lost | Should -BeFalse -Because 'the lost claim belonged to the previous job'
    }

    It 'discards a renewal that returns after the job has ended' {
        # The renewal is in flight when the job completes. Its answer - the job is no longer
        # In Progress - is true, but it is about a job the loop has finished with, and
        # recording it would report a lost claim for a job that simply completed.
        $ctx = New-ThreadContext
        $script:Heartbeat = InModuleScope RMA.Runbooks -Parameters @{ Ctx = $ctx } {
            param($Ctx)
            Start-RmaHeartbeat -Context $Ctx -WorkerId 'w' -IntervalSeconds 1 -TickMilliseconds 20 `
                -ModuleManifest '' -Renew { param($c, $s) $c.Calls.Enqueue($s); Start-Sleep -Milliseconds 600; $false }
        }

        InModuleScope RMA.Runbooks -Parameters @{ Heartbeat = $script:Heartbeat; SysId = $script:SysId } {
            param($Heartbeat, $SysId)
            Set-RmaHeartbeatJob -Heartbeat $Heartbeat -SysId $SysId
        }
        Wait-Until { $ctx.Calls.Count -ge 1 } | Should -BeTrue
        $beat = InModuleScope RMA.Runbooks -Parameters @{ Heartbeat = $script:Heartbeat } {
            param($Heartbeat)
            Clear-RmaHeartbeatJob -Heartbeat $Heartbeat
        }
        Start-Sleep -Milliseconds 900

        $beat.Lost | Should -BeFalse
        $script:Heartbeat.State.Lost | Should -BeFalse -Because 'the late answer must not be written either'
    }

    It 'reports a thread that could not start, once' {
        $ctx = New-ThreadContext
        $script:Heartbeat = InModuleScope RMA.Runbooks -Parameters @{ Ctx = $ctx } {
            param($Ctx)
            Start-RmaHeartbeat -Context $Ctx -WorkerId 'w' -IntervalSeconds 1 -TickMilliseconds 20 `
                -ModuleManifest (Join-Path ([IO.Path]::GetTempPath()) 'does-not-exist.psd1')
        }
        Wait-Until { $script:Heartbeat.State.Fatal } | Should -BeTrue

        InModuleScope RMA.Runbooks -Parameters @{ Heartbeat = $script:Heartbeat; SysId = $script:SysId } {
            param($Heartbeat, $SysId)
            Set-RmaHeartbeatJob -Heartbeat $Heartbeat -SysId $SysId
            Set-RmaHeartbeatJob -Heartbeat $Heartbeat -SysId ('b' * 32)
        }

        Should -Invoke -ModuleName RMA.Runbooks Write-RmaLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'Error' -and $Message -like 'Heartbeat thread is not running*'
        }
    }

    It 'stops promptly even while a renewal is hanging' {
        $ctx = New-ThreadContext
        $heartbeat = InModuleScope RMA.Runbooks -Parameters @{ Ctx = $ctx } {
            param($Ctx)
            Start-RmaHeartbeat -Context $Ctx -WorkerId 'w' -IntervalSeconds 1 -TickMilliseconds 20 `
                -ModuleManifest '' -Renew { param($c, $s) $c.Calls.Enqueue($s); Start-Sleep -Seconds 30; $true }
        }
        InModuleScope RMA.Runbooks -Parameters @{ Heartbeat = $heartbeat; SysId = $script:SysId } {
            param($Heartbeat, $SysId)
            Set-RmaHeartbeatJob -Heartbeat $Heartbeat -SysId $SysId
        }
        Wait-Until { $ctx.Calls.Count -ge 1 } | Should -BeTrue

        $elapsed = Measure-Command {
            InModuleScope RMA.Runbooks -Parameters @{ Heartbeat = $heartbeat } {
                param($Heartbeat)
                Stop-RmaHeartbeat -Heartbeat $Heartbeat -GraceMilliseconds 200
            }
        }

        $elapsed.TotalSeconds | Should -BeLessThan 5
        $heartbeat.Runspace.RunspaceStateInfo.State | Should -Be 'Closed'
    }

    It 'stops a thread still importing the module at once, and without a warning' {
        # Every run of short jobs ends like this. A warning here would be one per run.
        $ctx = New-ThreadContext
        $heartbeat = InModuleScope RMA.Runbooks -Parameters @{ Ctx = $ctx } {
            param($Ctx)
            Start-RmaHeartbeat -Context $Ctx -WorkerId 'w' -IntervalSeconds 60
        }

        $elapsed = Measure-Command {
            InModuleScope RMA.Runbooks -Parameters @{ Heartbeat = $heartbeat } {
                param($Heartbeat)
                Stop-RmaHeartbeat -Heartbeat $Heartbeat
            }
        }

        $elapsed.TotalMilliseconds | Should -BeLessThan 1000
        Should -Invoke -ModuleName RMA.Runbooks Write-RmaLog -Times 0 -Exactly -ParameterFilter { $Level -eq 'Warning' }
    }

    It 'imports the module in the thread, so the default renewal can run' {
        # The one test that uses the real manifest. It proves the thread can load the
        # module it needs; the renewal itself is still replaced, so nothing is sent.
        $ctx = New-ThreadContext
        $script:Heartbeat = InModuleScope RMA.Runbooks -Parameters @{ Ctx = $ctx } {
            param($Ctx)
            Start-RmaHeartbeat -Context $Ctx -WorkerId 'w' -IntervalSeconds 1 -TickMilliseconds 50 `
                -Renew { param($c) $c.Calls.Enqueue("$([bool] (Get-Command Update-RmaJobHeartbeat -ErrorAction SilentlyContinue))"); $true }
        }

        InModuleScope RMA.Runbooks -Parameters @{ Heartbeat = $script:Heartbeat; SysId = $script:SysId } {
            param($Heartbeat, $SysId)
            Set-RmaHeartbeatJob -Heartbeat $Heartbeat -SysId $SysId
        }
        Wait-Until { $ctx.Calls.Count -ge 1 } -TimeoutMs 15000 | Should -BeTrue

        $script:Heartbeat.State.Fatal | Should -BeNullOrEmpty
        $ctx.Calls.ToArray()[0] | Should -Be 'True'
    }
}

Describe 'Invoke-RmaQueueLoop heartbeat' -Tag 'Unit', 'Concurrency' {

    BeforeEach {
        $script:Events = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName RMA.Runbooks Write-RmaLog {}
        Mock -ModuleName RMA.Runbooks Request-RmaJobClaim { $true }
        Mock -ModuleName RMA.Runbooks Start-RmaHeartbeat {
            $script:Events.Add('start')
            [pscustomobject]@{ PSTypeName = 'Rma.Heartbeat' }
        }
        Mock -ModuleName RMA.Runbooks Set-RmaHeartbeatJob { $script:Events.Add("set:$SysId") }
        Mock -ModuleName RMA.Runbooks Clear-RmaHeartbeatJob {
            $script:Events.Add('clear')
            [pscustomobject]@{ Renewals = 0; Failures = 0; LastError = $null; Lost = $script:LostClaim; Fatal = $null }
        }
        Mock -ModuleName RMA.Runbooks Stop-RmaHeartbeat { $script:Events.Add('stop') }
        Mock -ModuleName RMA.Runbooks Set-RmaJobState { $script:Events.Add("state:$State") }
        $script:LostClaim = $false
        $script:Polls = 0
    }

    It 'starts no thread when the queue is empty' {
        Mock -ModuleName RMA.Runbooks Get-RmaPendingJob { @() }

        $null = Invoke-RmaQueueLoop -Context $script:Context -DomainId ('0' * 32) -Command 'Create-EntraUser' -Body {}

        $script:Events | Should -Not -Contain 'start'
        $script:Events | Should -Not -Contain 'stop'
    }

    It 'starts one thread for the run, registers each job, and clears it before the terminal state' {
        $jobs = @(
            (New-TestJob -SysId ('a' * 32) -Action 'Create-EntraUser'),
            (New-TestJob -SysId ('b' * 32) -Action 'Create-EntraUser')
        )
        Mock -ModuleName RMA.Runbooks Get-RmaPendingJob {
            $script:Polls++
            if ($script:Polls -eq 1) { @($jobs[0]) } elseif ($script:Polls -eq 2) { @($jobs[1]) } else { @() }
        }

        $null = Invoke-RmaQueueLoop -Context $script:Context -DomainId ('0' * 32) -Command 'Create-EntraUser' -Body {}

        ($script:Events -join ' ') | Should -Be (
            "start set:$('a' * 32) clear state:Completed set:$('b' * 32) clear state:Completed stop")
    }

    It 'stops the thread when the poll throws' {
        Mock -ModuleName RMA.Runbooks Get-RmaPendingJob {
            $script:Polls++
            if ($script:Polls -eq 1) { @(New-TestJob -SysId ('a' * 32) -Action 'Create-EntraUser') } else { throw 'ServiceNow unreachable' }
        }

        { Invoke-RmaQueueLoop -Context $script:Context -DomainId ('0' * 32) -Command 'Create-EntraUser' -Body {} } |
        Should -Throw '*unreachable*'
        $script:Events[-1] | Should -Be 'stop'
    }

    It 'logs an error when the claim was lost while the job ran, and still writes the state' {
        $script:LostClaim = $true
        Mock -ModuleName RMA.Runbooks Get-RmaPendingJob {
            $script:Polls++
            if ($script:Polls -eq 1) { @(New-TestJob -SysId ('a' * 32) -Action 'Create-EntraUser') } else { @() }
        }

        $null = Invoke-RmaQueueLoop -Context $script:Context -DomainId ('0' * 32) -Command 'Create-EntraUser' -Body {}

        Should -Invoke -ModuleName RMA.Runbooks Write-RmaLog -ParameterFilter {
            $Level -eq 'Error' -and $Message -like 'Claim was lost*'
        }
        $script:Events | Should -Contain 'state:Completed'
    }

    It 'passes HeartbeatMinutes to the thread as seconds' {
        Mock -ModuleName RMA.Runbooks Get-RmaPendingJob {
            $script:Polls++
            if ($script:Polls -eq 1) { @(New-TestJob -SysId ('a' * 32) -Action 'Create-EntraUser') } else { @() }
        }

        $null = Invoke-RmaQueueLoop -Context $script:Context -DomainId ('0' * 32) -Command 'Create-EntraUser' `
            -HeartbeatMinutes 7 -Body {}

        Should -Invoke -ModuleName RMA.Runbooks Start-RmaHeartbeat -Times 1 -Exactly -ParameterFilter { $IntervalSeconds -eq 420 }
    }
}
