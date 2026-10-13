#Requires -Version 7.2

<#
.SYNOPSIS
    Creates or updates a runbook in the TEST Automation Account from the working tree, and
    publishes it.
.DESCRIPTION
    Part of the migrate-runbook skill. The Automation Account comes from the
    AutomationAccount object in rma-worker.local.json, so no test value is committed.
    The runbook is created as type PowerShell on the runtime environment the existing
    runbooks use, its content replaced with the file, and published. The published content
    is then read back and compared with the file, so a stale draft cannot pass for the new
    one.

    Test environments only. Never point the config at an Automation Account that serves a
    customer.
.PARAMETER Runbook
    Name of a runbook in src/runbooks, without .ps1.
.PARAMETER ConfigPath
    The worker config. Defaults to rma-worker.local.json at the repository root.
.EXAMPLE
    ./.claude/skills/migrate-runbook/scripts/Publish-RmaTestRunbook.ps1 -Runbook Enable-EntraUser
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9-]+$')]
    [string] $Runbook,

    [string] $ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $repoRoot 'rma-worker.local.json' }
$config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json -AsHashtable
$aa = $config['AutomationAccount']
if (-not $aa -or -not $aa['ResourceGroup'] -or -not $aa['Name']) {
    throw "$ConfigPath has no AutomationAccount with ResourceGroup and Name. See rma-worker.example.json."
}

$file = Join-Path $repoRoot "src/runbooks/$Runbook.ps1"
if (-not (Test-Path $file)) { throw "Runbook not found: $file" }

$subscription = (& az account show --query id -o tsv)
if ($LASTEXITCODE -ne 0) { throw 'az account show failed. Sign in with az login.' }
$base = "https://management.azure.com/subscriptions/$subscription/resourceGroups/$($aa['ResourceGroup'])/providers/Microsoft.Automation/automationAccounts/$($aa['Name'])"
$runtime = if ($aa['RuntimeEnvironment']) { $aa['RuntimeEnvironment'] } else { 'Powershell_7-6' }

if (-not $PSCmdlet.ShouldProcess("$($aa['Name'])/$Runbook", "Create or update from $file and publish")) { return }

$location = & az rest --method get --url "$base`?api-version=2023-11-01" --query location -o tsv
$synopsis = ((Get-Content $file) -join "`n") -replace '(?s).*?\.SYNOPSIS\s*\n\s*([^\n]+).*', '$1'
$body = @{
    location   = $location
    properties = @{ runbookType = 'PowerShell'; runtimeEnvironment = $runtime; description = $synopsis.Trim(); logProgress = $false; logVerbose = $false }
} | ConvertTo-Json -Compress
$bodyFile = New-TemporaryFile
try {
    Set-Content -Path $bodyFile -Value $body -NoNewline
    & az rest --method put --url "$base/runbooks/$Runbook`?api-version=2023-05-15-preview" --body "@$bodyFile" -o none
    if ($LASTEXITCODE -ne 0) { throw "Creating $Runbook failed." }
} finally { Remove-Item $bodyFile -ErrorAction SilentlyContinue }

& az automation runbook replace-content -g $aa['ResourceGroup'] --automation-account-name $aa['Name'] -n $Runbook --content "@$file" -o none 2>$null
if ($LASTEXITCODE -ne 0) { throw "Replacing the content of $Runbook failed." }
& az automation runbook publish -g $aa['ResourceGroup'] --automation-account-name $aa['Name'] -n $Runbook -o none 2>$null
if ($LASTEXITCODE -ne 0) { throw "Publishing $Runbook failed." }

# Azure strips the trailing newline and may return CRLF; neither is a difference.
$published = New-TemporaryFile
try {
    & az rest --method get --url "$base/runbooks/$Runbook/content?api-version=2023-11-01" --output-file $published
    $normalise = { param($Text) ($Text -replace "`r", '').TrimEnd("`n") }
    $same = (& $normalise (Get-Content -Raw $published)) -ceq (& $normalise (Get-Content -Raw $file))
} finally { Remove-Item $published -ErrorAction SilentlyContinue }

$state = & az rest --method get --url "$base/runbooks/$Runbook`?api-version=2023-05-15-preview" --query properties.state -o tsv
[pscustomobject]@{ Runbook = $Runbook; State = $state; RuntimeEnvironment = $runtime; MatchesWorkingTree = $same }
if (-not $same) { throw "The published $Runbook does not match $file." }
