function Invoke-RmaQueueLoop {
    <#
    .SYNOPSIS
        Drains the ServiceNow command queue, executing a body for each job it wins.
    .DESCRIPTION
        This function owns every concurrency and lifecycle concern that was previously
        reimplemented, inconsistently, in 63 runbooks:

        Atomic claim      Only a job this worker actually claimed is executed. A worker
                          that loses the race skips the job. This is what makes it safe to
                          run more than one worker.

        Batched polling   Each poll fetches up to BatchSize rows and the worker walks the
                          batch, starting at a random offset. This is what makes more than
                          one worker actually faster. See the note below.

        Terminal state    A try/finally guarantees every claimed job reaches Completed or
                          Failed. The state is pre-set to Failed, so a job whose worker is
                          rebooted mid-run is reported as failed rather than left silent.
                          Previously 59 of 63 runbooks could strand a job with no terminal
                          state and no recovery.

        Bounded runtime   Iteration and wall-clock caps stop a runaway loop from being
                          killed mid-write by the Automation fair-share limit. Previously
                          61 of 63 runbooks were unbounded. Both caps are also checked
                          between rows of a batch, so a large BatchSize cannot overshoot.

        Correlation       The job sys_id becomes the ambient correlation id, so every log
                          line from the body is traceable to one ServiceNow ticket.

        Action guard      A payload whose action does not match is failed explicitly rather
                          than silently skipped while holding the claim.

        Claim backoff     A batch in which every claim was lost is backed off and, after
                          MaxConsecutiveSkips such batches in a row, the loop stops with
                          reason 'claim-contention'. A lost claim leaves the row Pending,
                          so the next poll returns the same rows; without a backoff and a
                          ceiling that is an unthrottled request loop against ServiceNow
                          for the whole MaxMinutes window, and MaxJobs never applies
                          because nothing was processed.

        Why the batch matters. Polling one row at a time makes every worker contend for the
        same head of the queue: one wins and the rest lose, every time, so adding workers
        raises the wasted-PATCH rate without raising throughput. Worse, a worker that keeps
        losing the head row never reaches the rows behind it, and stops with
        'claim-contention' having processed nothing while the queue is full. Fetching a
        window and entering it at a random offset spreads workers across distinct rows, so
        contention falls roughly as BatchSize rises.

        The body receives the raw job record and the decoded parameter object, and is
        expected to throw on failure. Returning normally means success.
    .PARAMETER Body
        Scriptblock invoked as Body($job, $parameters). Throw to fail the job.
    .PARAMETER BatchSize
        Rows fetched per poll. Raise it with the number of workers; the default suits a
        small fleet. A batch is a unit of work, not a transaction: rows the worker does not
        reach stay Pending for the next poll or another worker.
    .PARAMETER MaxConsecutiveSkips
        Consecutive *batches* in which a claim was attempted and none was won, before the
        loop gives up. Counting batches rather than individual lost claims is what makes
        this meaningful under batching: losing most of a batch and winning the rest is a
        healthy outcome, and would otherwise exhaust the budget within one poll.
    .EXAMPLE
        Invoke-RmaQueueLoop -Context $ctx -DomainId $id -Command 'Create-EntraUser' -Body {
            param($job, $p)
            New-MgUser -DisplayName $p.displayname -UserPrincipalName $p.upn
        }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [PSTypeName('Rma.ServiceNowContext')] $Context,

        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]
        [string] $DomainId,

        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9-]{2,63}$')]
        [string] $Command,

        [Parameter(Mandatory)] [scriptblock] $Body,

        [ValidateRange(1, 10000)]
        [int] $MaxJobs = 500,

        [ValidateRange(1, 170)]
        [int] $MaxMinutes = 45,

        # Rows per poll. Get-RmaPendingJob caps this at 100.
        [ValidateRange(1, 100)]
        [int] $BatchSize = 20,

        # Consecutive empty polls before concluding the queue is drained. >1 tolerates a
        # brief ServiceNow read-replica lag.
        [ValidateRange(1, 10)]
        [int] $EmptyPollsBeforeExit = 1,

        # Consecutive fully-lost batches before the loop gives up. In a healthy queue a
        # batch yields at least one win, so a long run of them means either heavy
        # contention or a ServiceNow that is failing every PATCH.
        [ValidateRange(1, 1000)]
        [int] $MaxConsecutiveSkips = 5
    )

    $sw        = [Diagnostics.Stopwatch]::StartNew()
    $workerId  = Get-RmaWorkerId
    $processed = 0; $succeeded = 0; $failed = 0; $skipped = 0; $emptyPolls = 0

    # Two counters, because the two things they guard are not the same. idleBatches drives
    # the backoff and rises on any batch that produced no work, including a batch of rows
    # too malformed to claim. contentionBatches drives the stop, and rises only when claims
    # were actually attempted and all of them were lost - the one case where stopping is
    # the right answer rather than a misdiagnosis.
    $idleBatches = 0; $contentionBatches = 0
    $stopReason = 'drained'

    Write-RmaLog -Level Information -Message 'Queue loop started' -Data @{
        command = $Command; domainId = $DomainId; workerId = $workerId
        maxJobs = $MaxJobs; maxMinutes = $MaxMinutes; batchSize = $BatchSize
    }

    :queue while ($true) {
        if ($processed -ge $MaxJobs)                  { $stopReason = 'max-jobs'; break }
        if ($sw.Elapsed.TotalMinutes -ge $MaxMinutes) { $stopReason = 'max-minutes'; break }

        # @() is required: a single returned object is a scalar, and PSCustomObject
        # has no synthetic .Count under Set-StrictMode -Version Latest.
        $jobs = @(Get-RmaPendingJob -Context $Context -DomainId $DomainId -Command $Command -Limit $BatchSize)
        if ($jobs.Count -eq 0) {
            $emptyPolls++
            if ($emptyPolls -ge $EmptyPollsBeforeExit) { $stopReason = 'drained'; break }
            Start-Sleep -Seconds 2
            continue
        }
        $emptyPolls = 0

        # The whole point of the batch. Without a random entry point every worker walks the
        # same batch in the same order and they collide on row 0 exactly as they did when
        # the poll fetched one row.
        $offset = if ($jobs.Count -gt 1) { Get-Random -Maximum $jobs.Count } else { 0 }
        $claimsAttempted = 0
        $claimsWon       = 0

        for ($i = 0; $i -lt $jobs.Count; $i++) {
            # Checked per row, not per batch: a batch of 100 must not run 99 jobs past
            # MaxJobs, and must not run past MaxMinutes into the fair-share limit.
            if ($processed -ge $MaxJobs)                  { $stopReason = 'max-jobs'; break queue }
            if ($sw.Elapsed.TotalMinutes -ge $MaxMinutes) { $stopReason = 'max-minutes'; break queue }

            $job = $jobs[($offset + $i) % $jobs.Count]

            # Read before anything else and outside the try below. A row without sys_id
            # cannot be claimed, executed or reported on, and reading it unguarded threw
            # out of the whole loop under StrictMode - one malformed row abandoning the
            # rest of the queue.
            $sysId = Get-RmaProperty -InputObject $job -Name 'sys_id'
            if ([string]::IsNullOrWhiteSpace($sysId)) {
                $skipped++
                Write-RmaLog -Level Error -Message 'Queue row has no sys_id; skipping it' -Data @{ command = $Command }
                continue
            }

            $claimsAttempted++
            if (-not (Request-RmaJobClaim -Context $Context -SysId $sysId -WorkerId $workerId)) {
                # No sleep here. There are other rows in this batch, and walking on to one
                # of them is both faster and less contended than waiting for this one.
                $skipped++
                continue
            }
            $claimsWon++

            $processed++
            $script:RmaCorrelationId = $sysId

            # Pre-set to Failed so an abrupt termination still reports a terminal state.
            $state = 'Failed'
            $err   = 'Runbook terminated before the job completed. Requeue or investigate the worker.'

            try {
                # Guarded so a malformed row fails the job with a message an operator can
                # act on, rather than with a StrictMode property-not-found from deep
                # inside here.
                $encoded = Get-RmaProperty -InputObject $job -Name 'input'
                if ([string]::IsNullOrWhiteSpace($encoded)) {
                    throw "Queue row has no 'input' payload. Check the ServiceNow business rule that populates it."
                }

                $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
                $parameters = $json | ConvertFrom-Json

                $action = Get-RmaProperty -InputObject $parameters -Name 'action'
                if ($action -ne $Command) {
                    throw "Action mismatch: the queue returned '$action' for a '$Command' runbook. " +
                    'Check the ServiceNow command mapping.'
                }

                Write-RmaLog -Level Information -Message 'Processing job' -Data @{ sysId = $sysId; action = $action }

                $null = & $Body $job $parameters

                $state = 'Completed'; $err = $null
                $succeeded++
            } catch {
                $err = '{0} (at line {1})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber
                $failed++
                Write-RmaLog -Level Error -Message 'Job failed' -Data @{ sysId = $sysId; error = $err }
            } finally {
                try {
                    Set-RmaJobState -Context $Context -SysId $sysId -State $state -ExceptionMessage $err
                } catch {
                    # The job is now stranded in Work in Progress. The watchdog runbook will
                    # requeue it. Log loudly, but do not abandon the rest of the queue.
                    Write-RmaLog -Level Error -Message 'Could not write terminal state; job will be requeued by the watchdog' `
                        -Data @{ sysId = $sysId; intendedState = $state; error = $_.Exception.Message }
                }
                $script:RmaCorrelationId = $null
            }
        }

        if ($claimsWon -gt 0) {
            $idleBatches = 0; $contentionBatches = 0
            continue
        }

        $idleBatches++
        if ($claimsAttempted -gt 0) {
            $contentionBatches++
            if ($contentionBatches -ge $MaxConsecutiveSkips) { $stopReason = 'claim-contention'; break }
        }

        # The rows are still Pending, so the next poll returns them again. Back off before
        # asking, or a persistently failing batch polls as fast as the network allows.
        Start-Sleep -Milliseconds ([math]::Min(2000, 100 * $idleBatches))
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
