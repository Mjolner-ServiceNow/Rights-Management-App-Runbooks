function Write-RmaLog {
    <#
    .SYNOPSIS
        Emits one structured, single-line JSON log record.
    .DESCRIPTION
        Azure Automation forwards job streams to Log Analytics. Emitting JSON on a single
        line makes every field queryable in KQL instead of requiring string parsing.

        Values are passed through ConvertTo-RmaSafeLogValue, so anything that looks like a
        secret is redacted before it reaches the log.
    .PARAMETER Level
        Severity. Error and Warning are additionally written to their native streams so
        Automation surfaces them on the job summary.
    .PARAMETER CorrelationId
        Defaults to the ambient correlation id set by Invoke-RmaQueueLoop, which is the
        ServiceNow job sys_id. That is what lets one ticket be traced end to end.
    .EXAMPLE
        Write-RmaLog -Level Information -Message 'User created' -Data @{ upn = $upn }
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateSet('Debug', 'Information', 'Warning', 'Error')]
        [string] $Level,

        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string] $Message,

        [hashtable] $Data,

        [string] $CorrelationId = $script:RmaCorrelationId,

        [string] $Runbook = $(if ($MyInvocation.PSCommandPath) { [IO.Path]::GetFileNameWithoutExtension($MyInvocation.PSCommandPath) } else { 'unknown' })
    )

    $record = [ordered]@{
        timestamp     = (Get-Date).ToUniversalTime().ToString('o')
        level         = $Level
        message       = $Message
        runbook       = $Runbook
        correlationId = $CorrelationId
        worker        = $env:COMPUTERNAME
    }

    if ($PSBoundParameters.ContainsKey('Data') -and $Data.Count -gt 0) {
        $record['data'] = ConvertTo-RmaSafeLogValue -InputObject $Data
    }

    $line = $record | ConvertTo-Json -Depth 10 -Compress

    switch ($Level) {
        'Error'       { Write-Error   $line -ErrorAction Continue }
        'Warning'     { Write-Warning $line }
        'Debug'       { Write-Verbose $line -Verbose:$false }
        default       { Write-Output  $line }
    }
}
