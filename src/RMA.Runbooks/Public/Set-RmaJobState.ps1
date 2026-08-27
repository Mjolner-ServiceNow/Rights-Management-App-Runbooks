function Set-RmaJobState {
    <#
    .SYNOPSIS
        Writes a terminal or intermediate state back to the ServiceNow command queue.
    .DESCRIPTION
        One implementation. The previous library carried 63 copies of this function which
        had drifted into nine distinct variants, including one that posted to a different
        field name and no longer threw on failure, so failures from that runbook reached
        the queue with no reason attached.
    .PARAMETER ExceptionMessage
        Truncated to 4000 characters. A full PowerShell stack trace can exceed the
        ServiceNow field length and cause the update itself to fail.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Context,

        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]
        [string] $SysId,

        [Parameter(Mandatory)][ValidateSet('Pending', 'Work in Progress', 'Failed', 'Completed')]
        [string] $State,

        [AllowNull()][AllowEmptyString()]
        [string] $ExceptionMessage,

        [switch] $PassThru
    )

    $code = switch ($State) {
        'Pending'          { '1' }
        'Work in Progress' { '2' }
        'Failed'           { '3' }
        'Completed'        { '4' }
    }

    $payload = @{ status = $code }
    if (-not [string]::IsNullOrWhiteSpace($ExceptionMessage)) {
        $payload['exception'] = if ($ExceptionMessage.Length -gt 4000) {
            $ExceptionMessage.Substring(0, 3997) + '...'
        } else { $ExceptionMessage }
    }

    if (-not $PSCmdlet.ShouldProcess("ServiceNow job $SysId", "Set state to '$State'")) { return }

    try {
        $response = Invoke-RmaRestMethod `
            -Uri "$($Context.BaseUri)/api/now/table/x_autps_active_dir_command_queue/$SysId" `
            -Method PATCH -Headers $Context.Headers -Body ($payload | ConvertTo-Json -Compress)
    } catch {
        # Deliberately rethrown. If the queue cannot be told a job finished, the job is
        # stranded, and the caller has to know. Invoke-RmaQueueLoop logs and continues so
        # one bad update does not abandon the remaining queue.
        throw "Unable to set ServiceNow job '$SysId' to '$State': $($_.Exception.Message)"
    }

    Write-RmaLog -Level Information -Message 'Job state updated' -Data @{ sysId = $SysId; state = $State }
    if ($PassThru) { $response.result }
}
