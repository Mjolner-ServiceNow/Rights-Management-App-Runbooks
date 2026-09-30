function Start-RmaHeartbeat {
    <#
    .SYNOPSIS
        Starts the background thread that keeps the current job's claim alive.
    .DESCRIPTION
        One thread per queue loop, not per job. It renews whichever job the loop has
        registered with Set-RmaHeartbeatJob, once that job has run for IntervalSeconds, and
        does nothing otherwise. A job that finishes inside one interval, which is nearly
        all of them, therefore costs no request at all.

        A thread, because the body cannot do this itself. Get-ADUser -Filter * against a
        large directory is one blocking call that can outlast the watchdog's threshold on
        its own, and nothing in the body runs until it returns.

        The thread imports this module afresh: a new runspace inherits nothing from the
        caller. It never logs, because nothing reads its streams; it records what happened
        in the shared state, and the loop logs that when the job ends.
    .PARAMETER Renew
        What one renewal does. Returns $true while the claim is held, $false once it is
        lost, and throws when the request failed. The default calls Update-RmaJobHeartbeat;
        tests pass their own so no request leaves the process.
    .PARAMETER ModuleManifest
        Imported by the thread before it starts. Empty skips the import, which only a test
        with its own Renew wants.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [PSTypeName('Rma.ServiceNowContext')] $Context,

        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string] $WorkerId,

        [Parameter(Mandatory)][ValidateRange(1, 3600)]
        [int] $IntervalSeconds,

        # After a failed request. Shorter than the interval, so one transient failure does
        # not cost a whole interval of the watchdog's margin.
        [ValidateRange(1, 3600)]
        [int] $RetrySeconds = 60,

        [ValidateRange(10, 60000)]
        [int] $TickMilliseconds = 1000,

        [scriptblock] $Renew = {
            param($Context, $SysId, $WorkerId)
            Update-RmaJobHeartbeat -Context $Context -SysId $SysId -WorkerId $WorkerId -Confirm:$false
        },

        [AllowEmptyString()]
        [string] $ModuleManifest = (Join-Path $ExecutionContext.SessionState.Module.ModuleBase 'RMA.Runbooks.psd1')
    )

    $state = [hashtable]::Synchronized(@{
            SysId      = $null
            NextDueUtc = [datetime]::MaxValue
            Renewals   = 0
            Failures   = 0
            LastError  = $null
            Lost       = $false
            Fatal      = $null
            Ready      = $false
            # A wait handle rather than a sleep, so stopping the thread takes effect at
            # once instead of at the end of the current tick. Every run that claims a job
            # pays for the stop, and a one-second sleep made it cost up to a second.
            Stop       = [System.Threading.ManualResetEventSlim]::new($false)
        })

    # A scriptblock stays bound to the runspace that created it, and invoking it from
    # another is undefined behaviour. The thread gets the text and compiles its own.
    $thread = {
        param($State, $ModuleManifest, $Context, $WorkerId, $IntervalSeconds, $RetrySeconds, $TickMilliseconds, $Renew)

        $ErrorActionPreference = 'Stop'
        Set-StrictMode -Version Latest
        try {
            if ($ModuleManifest) { Import-Module $ModuleManifest }
            $renewBlock = [scriptblock]::Create($Renew)
            $State.Ready = $true

            while (-not $State.Stop.Wait($TickMilliseconds)) {
                $sysId = $State.SysId
                if (-not $sysId -or [datetime]::UtcNow -lt $State.NextDueUtc) { continue }

                $held = $false; $failure = $null
                try {
                    $held = [bool] (& $renewBlock $Context $sysId $WorkerId)
                } catch {
                    $failure = $_.Exception.Message
                }

                [System.Threading.Monitor]::Enter($State.SyncRoot)
                try {
                    # The job may have ended while the request was in flight. What came
                    # back is then about a job the loop has finished with, and recording it
                    # would report a lost claim for a job that simply completed.
                    if ($State.SysId -eq $sysId) {
                        if ($null -ne $failure) {
                            $State.Failures++
                            $State.LastError  = $failure
                            $State.NextDueUtc = [datetime]::UtcNow.AddSeconds([math]::Min($RetrySeconds, $IntervalSeconds))
                        } elseif ($held) {
                            $State.Renewals++
                            $State.NextDueUtc = [datetime]::UtcNow.AddSeconds($IntervalSeconds)
                        } else {
                            # Lost for good. Renewing again cannot win it back, and would
                            # only repeat the request every interval until the job ends.
                            $State.Lost       = $true
                            $State.NextDueUtc = [datetime]::MaxValue
                        }
                    }
                } finally {
                    [System.Threading.Monitor]::Exit($State.SyncRoot)
                }
            }
        } catch {
            $State.Fatal = $_.Exception.Message
        }
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    $null = $ps.AddScript($thread.ToString()).AddParameters(@{
            State            = $state
            ModuleManifest   = $ModuleManifest
            Context          = $Context
            WorkerId         = $WorkerId
            IntervalSeconds  = $IntervalSeconds
            RetrySeconds     = $RetrySeconds
            TickMilliseconds = $TickMilliseconds
            Renew            = $Renew.ToString()
        })

    [pscustomobject]@{
        PSTypeName      = 'Rma.Heartbeat'
        State           = $state
        IntervalSeconds = $IntervalSeconds
        PowerShell      = $ps
        Runspace        = $runspace
        Handle          = $ps.BeginInvoke()
        FatalReported   = $false
    }
}
