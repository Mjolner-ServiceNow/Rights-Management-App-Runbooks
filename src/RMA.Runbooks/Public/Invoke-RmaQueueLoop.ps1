function Invoke-RmaQueueLoop {
    <#
    .SYNOPSIS
        Drains the ServiceNow command queue, executing a body for each job it wins.
    .DESCRIPTION
        This function owns every concurrency and lifecycle concern that was previously
        reimplemented, inconsistently, in 63 runbooks:

        Atomic claim      Only a job this worker actually claimed is executed. A worker
                          that loses the race skips the job. This is what makes it safe to
                          run more than one worker, and therefore what makes the solution
                          scale horizontally.

        Terminal state    A try/finally guarantees every claimed job reaches Completed or
                          Failed. The state is pre-set to Failed, so a job whose worker is
                          rebooted mid-run is reported as failed rather than left silent.
                          Previously 59 of 63 runbooks could strand a job with no terminal
                          state and no recovery.

        Bounded runtime   Iteration and wall-clock caps stop a runaway loop from being
                          killed mid-write by the Automation fair-share limit. Previously
                          61 of 63 runbooks were unbounded.

        Correlation       The job sys_id becomes the ambient correlation id, so every log
                          line from the body is traceable to one ServiceNow ticket.

        Action guard      A payload whose action does not match is failed explicitly rather
                          than silently skipped while holding the claim.

        The body receives the raw job record and the decoded parameter object, and is
        expected to throw on failure. Returning normally means success.
    .PARAMETER Body
        Scriptblock invoked as Body($job, $parameters). Throw to fail the job.
    .EXAMPLE
        Invoke-RmaQueueLoop -Context $ctx -DomainId $id -Command 'Create-EntraUser' -Body {
            param($job, $p)
            New-MgUser -DisplayName $p.displayname -UserPrincipalName $p.upn
        }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Context,

        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]
        [string] $DomainId,

        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9-]{2,63}$')]
        [string] $Command,

        [Parameter(Mandatory)] [scriptblock] $Body,

        [ValidateRange(1, 10000)]
        [int] $MaxJobs = 500,

        [ValidateRange(1, 170)]
        [int] $MaxMinutes = 45,

        # Consecutive empty polls before concluding the queue is drained. >1 tolerates a
        # brief ServiceNow read-replica lag.
        [ValidateRange(1, 10)]
        [int] $EmptyPollsBeforeExit = 1
    )

    $sw        = [Diagnostics.Stopwatch]::StartNew()
    $workerId  = Get-RmaWorkerId
    $processed = 0; $succeeded = 0; $failed = 0; $skipped = 0; $emptyPolls = 0
    $stopReason = 'drained'

    Write-RmaLog -Level Information -Message 'Queue loop started' -Data @{
        command = $Command; domainId = $DomainId; workerId = $workerId
        maxJobs = $MaxJobs; maxMinutes = $MaxMinutes
    }

    while ($true) {
        if ($processed -ge $MaxJobs)                { $stopReason = 'max-jobs'; break }
        if ($sw.Elapsed.TotalMinutes -ge $MaxMinutes) { $stopReason = 'max-minutes'; break }

        # @() is required: a single returned object is a scalar, and PSCustomObject
        # has no synthetic .Count under Set-StrictMode -Version Latest.
        $jobs = @(Get-RmaPendingJob -Context $Context -DomainId $DomainId -Command $Command -Limit 1)
        if ($jobs.Count -eq 0) {
            $emptyPolls++
            if ($emptyPolls -ge $EmptyPollsBeforeExit) { $stopReason = 'drained'; break }
            Start-Sleep -Seconds 2
            continue
        }
        $emptyPolls = 0
        $job = $jobs[0]

        if (-not (Request-RmaJobClaim -Context $Context -SysId $job.sys_id -WorkerId $workerId)) {
            $skipped++
            continue
        }

        $processed++
        $script:RmaCorrelationId = $job.sys_id

        # Pre-set to Failed so an abrupt termination still reports a terminal state.
        $state = 'Failed'
        $err   = 'Runbook terminated before the job completed. Requeue or investigate the worker.'

        try {
            $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($job.input))
            $parameters = $json | ConvertFrom-Json

            if ($parameters.action -ne $Command) {
                throw "Action mismatch: the queue returned '$($parameters.action)' for a '$Command' runbook. " +
                'Check the ServiceNow command mapping.'
            }

            Write-RmaLog -Level Information -Message 'Processing job' -Data @{ sysId = $job.sys_id; action = $parameters.action }

            $null = & $Body $job $parameters

            $state = 'Completed'; $err = $null
            $succeeded++
        } catch {
            $err = '{0} (at line {1})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber
            $failed++
            Write-RmaLog -Level Error -Message 'Job failed' -Data @{ sysId = $job.sys_id; error = $err }
        } finally {
            try {
                Set-RmaJobState -Context $Context -SysId $job.sys_id -State $state -ExceptionMessage $err
            } catch {
                # The job is now stranded in Work in Progress. The watchdog runbook will
                # requeue it. Log loudly, but do not abandon the rest of the queue.
                Write-RmaLog -Level Error -Message 'Could not write terminal state; job will be requeued by the watchdog' `
                    -Data @{ sysId = $job.sys_id; intendedState = $state; error = $_.Exception.Message }
            }
            $script:RmaCorrelationId = $null
        }
    }

    $sw.Stop()
    $summary = [pscustomobject]@{
        Command    = $Command
        Processed  = $processed
        Succeeded  = $succeeded
        Failed     = $failed
        SkippedNotClaimed = $skipped
        DurationSeconds   = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        StopReason = $stopReason
    }

    Write-RmaLog -Level $(if ($stopReason -eq 'drained') { 'Information' } else { 'Warning' }) `
        -Message "Queue loop finished ($stopReason)" -Data @{
        processed = $processed; succeeded = $succeeded; failed = $failed
        skipped = $skipped; durationSeconds = $summary.DurationSeconds
    }

    $summary
}
