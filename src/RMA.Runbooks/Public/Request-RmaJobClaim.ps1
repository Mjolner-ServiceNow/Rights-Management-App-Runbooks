function Request-RmaJobClaim {
    <#
    .SYNOPSIS
        Attempts to atomically claim a queued job. Returns $true only if this worker won.
    .DESCRIPTION
        This is the fix for duplicate execution.

        The previous pattern read a Pending job and then unconditionally PATCHed it to
        Work in Progress. Two concurrent executions both read the same row and both ran
        it. Nothing in the library used a conditional update, an ETag, or a worker id.

        Here the PATCH is filtered on status=1, so it only transitions a row that is still
        Pending, and the caller then verifies that the worker id echoed back is its own.
        A worker that loses the race gets $false and moves on.

        Correctness depends on the filtered PATCH being a single server-side operation.
        Confirm this against the target ServiceNow instance during the technical workshop.
        If the instance does not honour it, replace the call with a Scripted REST endpoint
        that performs the compare-and-set server side; the signature of this function does
        not change.
    .PARAMETER WorkerId
        Unique per execution. Defaults to machine plus Automation job id, which
        distinguishes two runs on the same worker.
    .EXAMPLE
        if (-not (Request-RmaJobClaim -Context $ctx -SysId $job.sys_id)) { continue }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Context,

        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]
        [string] $SysId,

        [ValidateNotNullOrEmpty()]
        [string] $WorkerId = (Get-RmaWorkerId)
    )

    $uri = "$($Context.BaseUri)/api/now/table/x_autps_active_dir_command_queue/$SysId" +
    '?sysparm_query=status%3D1'

    $body = @{
        status     = '2'
        worker_id  = $WorkerId
        claimed_at = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Compress

    try {
        $response = Invoke-RmaRestMethod -Uri $uri -Method PATCH -Headers $Context.Headers -Body $body -MaxAttempts 2
    } catch {
        # A failed claim must never be swallowed. Treating it as "not claimed" is the safe
        # outcome: the job stays Pending and some worker retries it later. The previous
        # code caught this and continued, which executed an unclaimed job in a loop.
        Write-RmaLog -Level Warning -Message 'Job claim request failed; treating as not claimed' -Data @{
            sysId = $SysId; error = $_.Exception.Message
        }
        return $false
    }

    $result = Get-RmaProperty -InputObject $response -Name 'result'
    $won    = $null -ne $result -and (Get-RmaProperty -InputObject $result -Name 'worker_id') -eq $WorkerId

    Write-RmaLog -Level $(if ($won) { 'Information' } else { 'Debug' }) `
        -Message $(if ($won) { 'Job claimed' } else { 'Job claim lost to another worker' }) `
        -Data @{ sysId = $SysId; workerId = $WorkerId; won = [bool] $won }

    [bool] $won
}

function Get-RmaWorkerId {
    <#
    .SYNOPSIS
        Returns an identifier unique to this runbook execution.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $jobId = 'local'
    if (Get-Variable -Name PSPrivateMetadata -Scope Global -ErrorAction SilentlyContinue) {
        $meta = Get-Variable -Name PSPrivateMetadata -Scope Global -ValueOnly
        if ($meta -and $meta.PSObject.Properties.Name -contains 'JobId' -and $meta.JobId) {
            $jobId = "$($meta.JobId)"
        }
    }
    '{0}/{1}' -f $env:COMPUTERNAME, $jobId
}
