function Set-RmaHeartbeatJob {
    <#
    .SYNOPSIS
        Tells the heartbeat thread which job it is now keeping alive.
    .DESCRIPTION
        The first renewal is due one interval after this call, which is when the claim was
        written. Counters start again from zero, so what Clear-RmaHeartbeatJob reports is
        about this job alone.

        A thread that has already died is reported here, at the start of the job, rather
        than only at its end: an import that runs for hours without a heartbeat will be
        requeued by the watchdog, and the operator should know that before it happens.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)] [PSTypeName('Rma.Heartbeat')] $Heartbeat,

        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]
        [string] $SysId
    )

    $state = $Heartbeat.State
    [System.Threading.Monitor]::Enter($state.SyncRoot)
    try {
        $state.Renewals   = 0
        $state.Failures   = 0
        $state.LastError  = $null
        $state.Lost       = $false
        $state.NextDueUtc = [datetime]::UtcNow.AddSeconds($Heartbeat.IntervalSeconds)
        $state.SysId      = $SysId
    } finally {
        [System.Threading.Monitor]::Exit($state.SyncRoot)
    }

    if ($state.Fatal -and -not $Heartbeat.FatalReported) {
        $Heartbeat.FatalReported = $true
        Write-RmaLog -Level Error -Message 'Heartbeat thread is not running; a long job will be requeued by the watchdog' `
            -Data @{ sysId = $SysId; error = $state.Fatal }
    }
}
