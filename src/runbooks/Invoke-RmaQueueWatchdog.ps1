#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'RMA.Runbooks'; RequiredVersion = '1.0.0' }

<#
.SYNOPSIS
    Requeues jobs stranded in Work in Progress. Covers every command in one runbook.
.DESCRIPTION
    A job is claimed, then its worker dies: the VM reboots, the network partitions, or the
    process is killed. Without this, that job stays in Work in Progress forever and no
    scheduled run will ever pick it up again, because the queue query only matches Pending.

    The watchdog is the safety net behind the try/finally in Invoke-RmaQueueLoop. The
    finally block handles the ordinary cases; this handles the ones where the process
    never reached it.

    Schedule every 15 minutes. StaleAfterMinutes must exceed the longest expected job by a
    comfortable margin, or a slow job will be requeued while it is still running.
.PARAMETER StaleAfterMinutes
    How long a claim may be held before it is presumed dead.
.PARAMETER MaxRequeue
    Ceiling per run. If more than this are stranded, something systemic is wrong and a
    human should look rather than the watchdog silently churning.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]  [string] $DomainId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{2,40}$')][string] $Instance,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $VaultName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $ManagedIdentityClientId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]            [string] $ServiceNowUserName,

    [ValidateRange(5, 1440)] [int] $StaleAfterMinutes = 30,
    [ValidateRange(1, 500)]  [int] $MaxRequeue        = 50
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$context = Test-RmaPrerequisite -Instance $Instance -DomainId $DomainId -VaultName $VaultName `
    -ManagedIdentityClientId $ManagedIdentityClientId -ServiceNowUserName $ServiceNowUserName

$cutoff = (Get-Date).ToUniversalTime().AddMinutes(-$StaleAfterMinutes)

# status=2 is Work in Progress. claimed_at is written by Request-RmaJobClaim.
$query = 'domain={0}^status=2^claimed_atRELATIVELT@minute@ago@{1}' -f $DomainId, $StaleAfterMinutes
$uri = '{0}/api/now/table/x_autps_active_dir_command_queue?sysparm_query={1}&sysparm_limit={2}' -f
$context.BaseUri, [uri]::EscapeDataString($query), ($MaxRequeue + 1)

function Invoke-RmaRequeue {
    [CmdletBinding(SupportsShouldProcess)]
    param($Context, $StaleJobs, [int]$StaleAfterMinutes)

    $requeued = 0
    foreach ($job in $StaleJobs) {
        $worker = Get-RmaProperty -InputObject $job -Name 'worker_id'
        $reason = "Requeued by watchdog: no terminal state from '$worker' within $StaleAfterMinutes minutes."

        if (-not $PSCmdlet.ShouldProcess($job.sys_id, 'Requeue to Pending')) { continue }

        try {
            Set-RmaJobState -Context $Context -SysId $job.sys_id -State 'Pending' -ExceptionMessage $reason
            $requeued++
            Write-RmaLog -Level Warning -Message 'Stranded job requeued' -Data @{ sysId = $job.sys_id; previousWorker = $worker }
        } catch {
            Write-RmaLog -Level Error -Message 'Could not requeue stranded job' -Data @{ sysId = $job.sys_id; error = $_.Exception.Message }
        }
    }
    Write-Output "Requeued $requeued of $($StaleJobs.Count) stranded job(s)."
}

$stale = @((Invoke-RmaRestMethod -Uri $uri -Method GET -Headers $context.Headers).result)

Write-RmaLog -Level Information -Message 'Watchdog scan complete' -Data @{
    strandedFound = $stale.Count; staleAfterMinutes = $StaleAfterMinutes; cutoffUtc = $cutoff.ToString('o')
}

if ($stale.Count -eq 0) {
    Write-Output 'No stranded jobs.'
} elseif ($stale.Count -gt $MaxRequeue) {
    # Deliberately refuse to act. Mass stranding means the workers or ServiceNow are
    # broken, and requeueing hundreds of jobs into a broken system makes it worse.
    Write-RmaLog -Level Error -Message 'Stranded job count exceeds MaxRequeue; refusing to requeue' `
        -Data @{ found = $stale.Count; maxRequeue = $MaxRequeue }
    throw "Found $($stale.Count) stranded jobs, above the MaxRequeue ceiling of $MaxRequeue. " +
    'This indicates a systemic failure. Investigate the workers before requeueing.'
} else {
    Invoke-RmaRequeue -Context $context -StaleJobs $stale -StaleAfterMinutes $StaleAfterMinutes
}
