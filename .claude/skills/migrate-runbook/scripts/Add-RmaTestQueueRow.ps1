#Requires -Version 7.2

<#
.SYNOPSIS
    Queues one Pending row on the TEST ServiceNow instance's command queue and returns its
    sys_id.
.DESCRIPTION
    Part of the migrate-runbook skill. The row's command is the payload's action, its
    domain is DomainId from rma-worker.local.json, and its input is the payload as base64
    JSON, as the ServiceNow application writes it. The payload is never printed: it may
    carry a password, so only the sys_id comes back. It travels to the worker inside the
    script block, because only the worker can read the ServiceNow password from Key Vault.

    The row stays on the queue until a runbook for its command takes it. A row whose
    payload carries a secret keeps it in the queue table (#130); use throwaway values.

    Test environments only.
.PARAMETER Payload
    The payload. It must have an 'action', which becomes the row's command.
.PARAMETER ConfigPath
    The worker config. For a parallel run, a copy with its own Worker.Port.
.PARAMETER RemoteRoot
    The folder on the worker. For a parallel run, one per agent.
.EXAMPLE
    ./Add-RmaTestQueueRow.ps1 -Payload @{ action = 'Enable-ADUser'; user = 'rma-test-unlock' }
#>
[CmdletBinding()]
[OutputType([string])]
param(
    [Parameter(Mandatory)] [hashtable] $Payload,
    [string] $ConfigPath,
    [string] $RemoteRoot = 'C:/RmaDev'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $Payload['action']) { throw "The payload needs an 'action'; it becomes the row's command." }
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $repoRoot 'rma-worker.local.json' }
$c = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json -AsHashtable

$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Compress -Depth 5)))
$text = @'
$row = @{ command = '__ACTION__'; status = '1'; domain = '__DOMAIN__'; input = '__INPUT__' } | ConvertTo-Json
$created = (Invoke-RmaRestMethod -Method POST -Uri "$($snContext.BaseUri)/api/now/table/x_autps_active_dir_command_queue" -Headers $snContext.Headers -Body $row).result
"QUEUED $($created.sys_id)"
'@.Replace('__ACTION__', $Payload['action']).Replace('__DOMAIN__', $c['DomainId']).Replace('__INPUT__', $encoded)

$output = & (Join-Path $PSScriptRoot 'Invoke-RmaTestCheck.ps1') -ConfigPath $ConfigPath -RemoteRoot $RemoteRoot -ScriptBlock ([scriptblock]::Create($text))
$line = @($output) -match '^QUEUED [0-9a-f]{32}$' | Select-Object -First 1
if (-not $line) { throw 'The row was not created; see the output above.' }
$line.Substring(7)
