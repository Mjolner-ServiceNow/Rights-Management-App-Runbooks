function Update-RmaJobHeartbeat {
    <#
    .SYNOPSIS
        Renews this worker's claim on a job it is still running. Returns $true only if the
        claim is still its own.
    .DESCRIPTION
        The watchdog requeues any job whose claimed_at is older than StaleAfterMinutes. A
        full directory import runs for hours, so without renewal the watchdog would requeue
        it while it was still running, and a second worker would start the same import.

        The PATCH carries the same condition as the claim, plus the worker id: status=2 and
        worker_id equal to this worker. It is also checked on the way back, against the
        record ServiceNow returns, because nothing proves yet that the instance honours a
        query on a single-record PATCH (see Request-RmaJobClaim). A renewal therefore never
        reports success for a job that has finished, been requeued, or been claimed by
        someone else.

        Invoke-RmaQueueLoop calls this from a background thread for every job it runs, so
        a runbook body does not call it itself.
    .PARAMETER WorkerId
        The id the job was claimed with. Defaults to this execution's, as the claim does.
    .EXAMPLE
        Update-RmaJobHeartbeat -Context $ctx -SysId $job.sys_id
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [PSTypeName('Rma.ServiceNowContext')] $Context,

        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]
        [string] $SysId,

        [ValidateNotNullOrEmpty()]
        [string] $WorkerId = (Get-RmaWorkerId)
    )

    # Escaped whole: the worker id carries a slash and the machine name.
    $query = [uri]::EscapeDataString("status=2^worker_id=$WorkerId")
    $uri = "$($Context.BaseUri)/api/now/table/x_autps_active_dir_command_queue/$SysId" +
    "?sysparm_query=$query&sysparm_fields=status,worker_id,claimed_at"

    $body = @{ claimed_at = Get-RmaGlideDateTime } | ConvertTo-Json -Compress

    if (-not $PSCmdlet.ShouldProcess("ServiceNow job $SysId", 'Renew claim')) { return $false }

    # Not caught. A failed request is not a lost claim, and the caller has to tell the two
    # apart: the first is retried on the next beat, the second is not.
    $response = Invoke-RmaRestMethod -Uri $uri -Method PATCH -Headers $Context.Headers -Body $body -MaxAttempts 2

    $result = Get-RmaProperty -InputObject $response -Name 'result'
    $held   = $null -ne $result -and
    "$(Get-RmaProperty -InputObject $result -Name 'status')" -eq '2' -and
    (Get-RmaProperty -InputObject $result -Name 'worker_id') -eq $WorkerId

    Write-RmaLog -Level $(if ($held) { 'Debug' } else { 'Warning' }) `
        -Message $(if ($held) { 'Job claim renewed' } else { 'Job claim no longer held by this worker' }) `
        -Data @{ sysId = $SysId; workerId = $WorkerId; held = [bool] $held }

    [bool] $held
}
