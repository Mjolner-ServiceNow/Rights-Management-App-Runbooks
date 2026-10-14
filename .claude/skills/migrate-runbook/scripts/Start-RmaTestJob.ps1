#Requires -Version 7.2

<#
.SYNOPSIS
    Starts a runbook as a real Automation job on the TEST Hybrid Worker group, waits for it,
    and returns what it did.
.DESCRIPTION
    Part of the migrate-runbook skill. The parameters are the runbook's own, taken from
    rma-worker.local.json; nothing is guessed. The job runs as SYSTEM on the worker, with the
    module installed there, so this is the final check a test over SSH is not.

    Returns one object: the job id and status, every Write-RmaLog record (level, message and
    the queue sys_id it names), the job's error records, and the distinct queue sys_ids the
    job worked on. With -ForbiddenText, it also says how many of those strings appear
    anywhere in the job's output and streams, without printing them: use it for a password
    a payload carried.

    Test environments only.
.PARAMETER Runbook
    Name of a runbook published in the test Automation Account (Publish-RmaTestRunbook.ps1).
.PARAMETER ForbiddenText
    Strings that must not appear in the job's output or streams.
.PARAMETER TimeoutMinutes
    How long to wait for the job to finish.
.EXAMPLE
    $job = ./Start-RmaTestJob.ps1 -Runbook Enable-ADUser
    $job.Records | Format-Table Level, Message, SysId
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9-]+$')]
    [string] $Runbook,

    [string[]] $ForbiddenText = @(),

    [ValidateRange(1, 60)]
    [int] $TimeoutMinutes = 15,

    [string] $ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $repoRoot 'rma-worker.local.json' }
$c = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json -AsHashtable
$aa = $c['AutomationAccount']
if (-not $aa -or -not $aa['ResourceGroup'] -or -not $aa['Name'] -or -not $aa['HybridWorkerGroup']) {
    throw "$ConfigPath has no AutomationAccount with ResourceGroup, Name and HybridWorkerGroup. See rma-worker.example.json."
}

# The runbook's own parameters, read from its AST, and the config values for them.
$file = Join-Path $repoRoot "src/runbooks/$Runbook.ps1"
$ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref] $null, [ref] $null)
$names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
$parameters = @(foreach ($name in $names) { if ($c.ContainsKey($name) -and $c[$name] -is [string]) { "$name=$($c[$name])" } })

$jobId = & az automation runbook start -g $aa['ResourceGroup'] --automation-account-name $aa['Name'] -n $Runbook `
    --run-on $aa['HybridWorkerGroup'] --parameters @parameters --query jobId -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or -not $jobId) { throw "Starting $Runbook failed." }

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do {
    Start-Sleep -Seconds 10
    $status = & az automation job show -g $aa['ResourceGroup'] --automation-account-name $aa['Name'] -n $jobId --query status -o tsv 2>$null
} until ($status -in 'Completed', 'Failed', 'Stopped', 'Suspended' -or (Get-Date) -gt $deadline)

$subscription = & az account show --query id -o tsv
$base = "https://management.azure.com/subscriptions/$subscription/resourceGroups/$($aa['ResourceGroup'])/providers/Microsoft.Automation/automationAccounts/$($aa['Name'])/jobs/$jobId"
# Each stream entry is kept with its type: an Error record is wrapped across several
# entries and is put back together from the error stream alone (ConvertFrom-RmaJobStream).
$output = (& az rest --method get --url "$base/output?api-version=2023-11-01" 2>$null) -join "`n"
$entries = [System.Collections.Generic.List[pscustomobject]]::new()
$entries.Add([pscustomobject]@{ Type = 'Output'; Text = $output })
$streams = (& az rest --method get --url "$base/streams?api-version=2023-11-01" `
        --query 'value[].{id: properties.jobStreamId, type: properties.streamType}' -o json 2>$null) -join "`n" | ConvertFrom-Json
# The id ends in the entry's sequence number, so sorting by it restores the order written.
foreach ($stream in @($streams | Sort-Object id)) {
    $text = (& az rest --method get --url "$base/streams/$($stream.id)?api-version=2023-11-01" --query properties.streamText -o tsv 2>$null) -join "`n"
    $entries.Add([pscustomobject]@{ Type = $stream.type; Text = $text })
}
$all = ($entries.Text -join "`n") -replace '\x1b\[[0-9;]*m', ''

$records = foreach ($record in & (Join-Path $PSScriptRoot 'ConvertFrom-RmaJobStream.ps1') -Stream $entries) {
    # Plain null checks: '?.' does not stop the rest of a chain, so a record without data
    # would still index into null.
    $data = $record.PSObject.Properties['data']?.Value
    $sysId = $null; $errorText = $null
    if ($null -ne $data) {
        foreach ($key in 'queueSysId', 'sysId') {
            if (-not $sysId -and $data.PSObject.Properties[$key]) { $sysId = $data.PSObject.Properties[$key].Value }
        }
        if ($data.PSObject.Properties['error']) { $errorText = $data.PSObject.Properties['error'].Value }
    }
    [pscustomobject]@{
        Timestamp = $record.timestamp; Level = $record.level; Message = $record.message; SysId = $sysId; Error = $errorText
    }
}
# The same record reaches both the output and a stream; keep the first of each. An Error
# record is read once its last line is, so the records are put back in time order.
$seen = [System.Collections.Generic.HashSet[string]]::new()
$records = @($records | Sort-Object -Stable Timestamp |
        Where-Object { $seen.Add("$($_.Timestamp)|$($_.Level)|$($_.Message)|$($_.SysId)|$($_.Error)") } |
        Select-Object Level, Message, SysId, Error)

[pscustomobject]@{
    JobId              = $jobId
    Status             = $status
    Records            = $records
    Errors             = @($records | Where-Object { $_.Error } | ForEach-Object Error | Sort-Object -Unique)
    SysIds             = @($records | Where-Object { $_.SysId -match '^[0-9a-f]{32}$' } | ForEach-Object SysId | Sort-Object -Unique)
    ForbiddenTextFound = @($ForbiddenText | Where-Object { $_ -and $all.Contains($_) }).Count
}
