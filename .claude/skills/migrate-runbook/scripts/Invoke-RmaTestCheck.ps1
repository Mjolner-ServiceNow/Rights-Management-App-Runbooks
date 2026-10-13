#Requires -Version 7.2

<#
.SYNOPSIS
    Runs a script block on the TEST Hybrid Worker with ServiceNow, and optionally Active
    Directory and Microsoft Graph, already connected as the runbooks connect.
.DESCRIPTION
    Part of the migrate-runbook skill: for creating test fixtures and for checking the state
    a runbook left behind. Values come from rma-worker.local.json; none is committed or
    printed. Runs through scripts/Invoke-RmaWorkerRun.ps1, so the working tree's module is
    the one loaded, and as the SSH user, not SYSTEM.

    Before the script block runs, the worker session has:
      $snContext        the ServiceNow context Test-RmaPrerequisite returns
      Get-TestQueueRow  Get-TestQueueRow -SysId <id> returns status, exception and command
      $server           with -ActiveDirectory: @{ Server; Credential } for every AD cmdlet,
                        the service account's credential from Key Vault
      Microsoft Graph   with -Graph: connected through Connect-RmaGraph

    Test environments only.
.PARAMETER ScriptBlock
    What to run. It is sent as text, so it cannot use local variables; put values in it.
.PARAMETER ConfigPath
    The worker config. For a parallel run, a copy with its own Worker.Port.
.PARAMETER RemoteRoot
    The folder on the worker. For a parallel run, one per agent, for example C:/RmaDev-55.
.EXAMPLE
    ./Invoke-RmaTestCheck.ps1 -ActiveDirectory -ScriptBlock { (Get-ADUser rma-test-unlock -Properties LockedOut @server).LockedOut }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
    [switch] $ActiveDirectory,
    [switch] $Graph,
    [string] $ConfigPath,
    [string] $RemoteRoot = 'C:/RmaDev'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $repoRoot 'rma-worker.local.json' }
$c = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json -AsHashtable

$prefix = @'
$ErrorActionPreference = 'Stop'
$snContext = Test-RmaPrerequisite -Instance '__INST__' -VaultName '__KV__' -ManagedIdentityClientId '__MI__' -ServiceNowUserName '__SNUSER__' 6>$null
function Get-TestQueueRow {
    param([Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string] $SysId)
    (Invoke-RmaRestMethod -Uri "$($snContext.BaseUri)/api/now/table/x_autps_active_dir_command_queue/$($SysId)?sysparm_fields=status,exception,command" -Headers $snContext.Headers).result
}
'@
if ($ActiveDirectory) {
    $prefix += @'
Import-Module ActiveDirectory -WarningAction SilentlyContinue
$server = @{ Server = '__DC__'; Credential = Get-RmaSecret -VaultName '__KV__' -Name '__SECRET__' -ManagedIdentityClientId '__MI__' -AsCredential -UserName '__ADUSER__' }
'@
}
if ($Graph) {
    $prefix += @'
Import-Module Microsoft.Graph.Authentication -RequiredVersion 2.39.0
Connect-RmaGraph -Context $snContext -TenantId '__TENANT__' -ApplicationId '__APP__' 6>$null
'@
}

$values = @{
    __INST__ = 'Instance'; __KV__ = 'VaultName'; __MI__ = 'ManagedIdentityClientId'; __SNUSER__ = 'ServiceNowUserName'
    __DC__ = 'DomainController'; __SECRET__ = 'AdSecretName'; __ADUSER__ = 'AdUserName'; __TENANT__ = 'TenantId'; __APP__ = 'ApplicationId'
}
foreach ($placeholder in $values.Keys) {
    if ($prefix.Contains($placeholder)) {
        $value = $c[$values[$placeholder]]
        if (-not $value) { throw "$ConfigPath has no $($values[$placeholder])." }
        $prefix = $prefix.Replace($placeholder, $value)
    }
}

& (Join-Path $repoRoot 'scripts/Invoke-RmaWorkerRun.ps1') -ConfigPath $ConfigPath -RemoteRoot $RemoteRoot `
    -ScriptBlock ([scriptblock]::Create($prefix + "`n" + $ScriptBlock.ToString()))
