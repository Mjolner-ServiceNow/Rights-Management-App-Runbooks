function Stop-RmaHeartbeat {
    <#
    .SYNOPSIS
        Ends the heartbeat thread and releases its runspace.
    .DESCRIPTION
        Signals the thread to finish, then gives it a few seconds. A renewal in flight can
        hold it for up to the request timeout, and the loop should not wait that long to
        return its summary, so after the grace period the pipeline is stopped outright.
        Nothing is lost by that: the job it was renewing has already reached its terminal
        state.

        A thread that is still importing the module is stopped at once rather than waited
        for. It has renewed nothing yet, and a run of short jobs ends before the import
        does, so waiting would make every such run pay for an import it never used.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)] [PSTypeName('Rma.Heartbeat')] $Heartbeat,

        [ValidateRange(0, 60000)]
        [int] $GraceMilliseconds = 5000
    )

    $Heartbeat.State.Stop.Set()
    try {
        $grace = if ($Heartbeat.State.Ready) { $GraceMilliseconds } else { 0 }
        if ($Heartbeat.Handle.AsyncWaitHandle.WaitOne($grace)) {
            $null = $Heartbeat.PowerShell.EndInvoke($Heartbeat.Handle)
        } else {
            # Not followed by EndInvoke: on a stopped pipeline it throws "The pipeline has
            # been stopped", which is the outcome asked for, and would be logged as a
            # warning on every run of short jobs.
            $Heartbeat.PowerShell.Stop()
        }
    } catch {
        # The thread records its own failures in State.Fatal. Anything that surfaces here
        # is about stopping it, and must not replace the loop's summary with an exception.
        Write-RmaLog -Level Warning -Message 'Heartbeat thread did not stop cleanly' -Data @{ error = $_.Exception.Message }
    } finally {
        $Heartbeat.PowerShell.Dispose()
        $Heartbeat.Runspace.Dispose()
        $Heartbeat.State.Stop.Dispose()
    }
}
