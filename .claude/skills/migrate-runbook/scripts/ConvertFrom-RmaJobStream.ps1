#Requires -Version 7.2

<#
.SYNOPSIS
    Reads the Write-RmaLog records back out of an Automation job's streams.
.DESCRIPTION
    Part of the migrate-runbook skill, used by Start-RmaTestJob.ps1. Takes the job's stream
    entries in the order Automation wrote them and returns every Write-RmaLog record in
    them, parsed from JSON.

    Output, Warning and Verbose records arrive as one line each. Error records do not
    (#147). Automation stores the error stream as PowerShell's formatted error view, one
    stream entry per line, and the record is wrapped onto continuation lines:

        Write-RmaLog: C:\...\Invoke-RmaQueueLoop.ps1:240
        Line |
         240 |  .             Write-RmaLog -Level Error -Message 'Job failed' -Data @{  .
             |                ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
             | {"timestamp":"...","level":"Error","message":"Job
             | failed","runbook":"Invoke-RmaQueueLoop",...}

    The wrap takes the place of a space, and Output entries can fall between the lines of
    one error record. So the continuation lines of the error stream alone are joined back
    together with a space before parsing. If that is not valid JSON, they are joined again
    without one, for a wrap that split a number or a keyword. A wrap inside a string that
    split a word would come back with a space in it; none has been seen.
.PARAMETER Stream
    The job's stream entries in order, each with Type (Output, Error, Warning, ...) and
    Text.
.EXAMPLE
    ./ConvertFrom-RmaJobStream.ps1 -Stream @([pscustomobject]@{ Type = 'Output'; Text = $line })
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][AllowEmptyCollection()]
    [object[]] $Stream
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function ConvertFrom-RecordText {
    param([string] $Text)
    try {
        $Text | ConvertFrom-Json
    } catch {
        Write-Verbose "Not a log record: $($_.Exception.Message)"
    }
}

# Joined with a space first, because the wrap takes the place of one; then without, for a
# wrap that split a number or a keyword.
function ConvertFrom-WrappedRecord {
    param([string[]] $Line)
    $record = ConvertFrom-RecordText -Text ($Line -join ' ')
    if (-not $record) { $record = ConvertFrom-RecordText -Text ($Line -join '') }
    $record
}

$pending = $null
foreach ($entry in $Stream) {
    $lines = "$($entry.Text)" -replace '\x1b\[[0-9;]*m', '' -split '\r?\n'
    foreach ($line in $lines) {
        if ($entry.Type -eq 'Error') {
            # The message lines of the error view are '     | <text>'. The underline above
            # them has the same prefix, but nothing is pending when it comes.
            if ($line -match '^\s+\| (.*)$') {
                $content = $Matches[1]
                if ($content.StartsWith('{"timestamp"')) {
                    if ($pending) { ConvertFrom-WrappedRecord -Line $pending }
                    $pending = [System.Collections.Generic.List[string]]::new()
                    $pending.Add($content)
                } elseif ($pending) {
                    $pending.Add($content)
                }
                continue
            }
            if ($pending) {
                ConvertFrom-WrappedRecord -Line $pending
                $pending = $null
            }
        }

        $at = $line.IndexOf('{"timestamp"')
        if ($at -ge 0) { ConvertFrom-RecordText -Text $line.Substring($at) }
    }
}
if ($pending) { ConvertFrom-WrappedRecord -Line $pending }
