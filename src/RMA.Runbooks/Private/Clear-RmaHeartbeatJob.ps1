function Clear-RmaHeartbeatJob {
    <#
    .SYNOPSIS
        Stops renewing the current job and returns what the heartbeat did for it.
    .DESCRIPTION
        Called before the job's terminal state is written. A renewal still in flight then
        finds the job no longer current and discards its result, so a job that completed
        normally is never reported as a lost claim.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [PSTypeName('Rma.Heartbeat')] $Heartbeat
    )

    $state = $Heartbeat.State
    [System.Threading.Monitor]::Enter($state.SyncRoot)
    try {
        $state.SysId      = $null
        $state.NextDueUtc = [datetime]::MaxValue
        [pscustomobject]@{
            Renewals  = $state.Renewals
            Failures  = $state.Failures
            LastError = $state.LastError
            Lost      = $state.Lost
            Fatal     = $state.Fatal
        }
    } finally {
        [System.Threading.Monitor]::Exit($state.SyncRoot)
    }
}
