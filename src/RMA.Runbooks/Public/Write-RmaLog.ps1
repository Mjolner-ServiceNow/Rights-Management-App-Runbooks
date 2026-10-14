function Write-RmaLog {
    <#
    .SYNOPSIS
        Emits one structured, single-line JSON log record.
    .DESCRIPTION
        Azure Automation forwards job streams to Log Analytics. Emitting JSON on a single
        line makes every field queryable in KQL instead of requiring string parsing.

        The message and every value are passed through ConvertTo-RmaSafeLogValue, so a
        secret-named field, or a token, credential or key=value secret inside a string, is
        redacted before it reaches the log. That is a safety net: build -Message from
        constant text, and put values in -Data as named fields.
    .PARAMETER Level
        Severity. Information goes to the information stream, never the success stream:
        a record written with Write-Output became part of the return value of every
        function that logged before returning. Error and Warning go to their native
        streams so Automation surfaces them on the job summary. Debug goes to the verbose stream,
        which Automation captures when 'Log verbose records' is enabled on the runbook;
        it does not use Write-Debug, because Automation does not capture that stream.
    .PARAMETER CorrelationId
        Defaults to the ambient correlation id set by Invoke-RmaQueueLoop, which is the
        ServiceNow job sys_id. That is what lets one ticket be traced end to end.
    .PARAMETER Command
        Defaults to the queue command Invoke-RmaQueueLoop is running, so every record of a
        run can be found by it, the runbook body's own included. The runbook field cannot
        do that: it is the file that logged, and in an Automation job a runbook runs from a
        temporary file named by a GUID (#124).
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

        [string] $Command = $script:RmaCommand,

        [string] $Runbook = $(if ($MyInvocation.PSCommandPath) { [IO.Path]::GetFileNameWithoutExtension($MyInvocation.PSCommandPath) } else { 'unknown' })
    )

    $record = [ordered]@{
        timestamp     = (Get-Date).ToUniversalTime().ToString('o')
        level         = $Level
        message       = ConvertTo-RmaSafeLogValue -InputObject $Message
        runbook       = $Runbook
        command       = $Command
        correlationId = $CorrelationId
        worker        = [Environment]::MachineName
    }

    if ($PSBoundParameters.ContainsKey('Data') -and $Data.Count -gt 0) {
        $record['data'] = ConvertTo-RmaSafeLogValue -InputObject $Data
    }

    $line = $record | ConvertTo-Json -Depth 10 -Compress

    # Information is not written with Write-Output. Connect-RmaServiceNow logged and then
    # returned its context, so the caller received @($line, $context), and under StrictMode
    # $context.BaseUri threw. Every function that logs and returns had the same defect.
    #
    # Debug is routed to Write-Verbose without -Verbose:$false. Suppressing it there made
    # every Debug record unreachable, including 'Job claim lost to another worker', which
    # is the one line that makes claim contention visible.
    switch ($Level) {
        'Error'       { Write-Error   $line -ErrorAction Continue }
        'Warning'     { Write-Warning $line }
        'Debug'       { Write-Verbose $line }
        default       { Write-Information $line -InformationAction Continue }
    }
}
