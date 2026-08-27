#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'Az.Automation'; ModuleVersion = '1.9.0' }

<#
.SYNOPSIS
    Publishes the runbooks into an Automation Account.
.DESCRIPTION
    Runbooks only. The RMA.Runbooks module is NOT published here, and deliberately so.

    Modules imported into an Automation Account are made available to jobs running in an
    Azure sandbox. A Hybrid Runbook Worker loads modules from its own PSModulePath, and
    Azure does not push Automation Account modules onto it. Importing RMA.Runbooks into the
    Automation Account would therefore look like the dependency was satisfied while every
    runbook still failed at #Requires.

    RMA.Runbooks is installed on the worker by scripts/Initialize-RmaWorker.ps1, alongside
    the Graph and Exchange modules, and the version there must match the RequiredVersion in
    each runbook's #Requires. That match is enforced at parse time: a mismatch fails the job
    immediately with a precise message rather than part-way through.

    Safety property worth keeping: each runbook is imported as a Draft and then published.
    The currently published version keeps serving until the new draft is published, so a
    failed import cannot take a runbook offline.
.PARAMETER SkipVersionCheck
    Skip the check that the runbooks' #Requires version matches the module in this repo.
.EXAMPLE
    ./scripts/Publish-RmaContent.ps1 -ResourceGroup rg-rma-prod -AutomationAccountName aa-rma-prod
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()] [string] $ResourceGroup,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()] [string] $AutomationAccountName,

    [ValidateSet('PowerShell72', 'PowerShell')]
    [string] $RunbookType = 'PowerShell72',

    [string[]] $Name,
    [switch]   $SkipVersionCheck
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot   = Split-Path $PSScriptRoot -Parent
$runbookDir = Join-Path $repoRoot 'src/runbooks'
$moduleVersion = (Import-PowerShellDataFile (Join-Path $repoRoot 'src/RMA.Runbooks/RMA.Runbooks.psd1')).ModuleVersion

$files = @(Get-ChildItem $runbookDir -Filter '*.ps1' -File)
if ($Name) { $files = @($files | Where-Object { $_.BaseName -in $Name }) }
if ($files.Count -eq 0) { throw "No runbooks matched." }

# A runbook pinned to a version the repo no longer builds will fail on the worker at
# #Requires. Catching it here is cheaper than catching it in production.
if (-not $SkipVersionCheck) {
    $mismatched = foreach ($file in $files) {
        $content = Get-Content $file.FullName -Raw
        if ($content -match "ModuleName\s*=\s*'RMA\.Runbooks'\s*;\s*RequiredVersion\s*=\s*'([^']+)'") {
            if ($Matches[1] -ne $moduleVersion) { "$($file.BaseName) pins $($Matches[1])" }
        }
    }
    if ($mismatched) {
        throw "These runbooks pin an RMA.Runbooks version other than $moduleVersion, and will " +
        "fail on the worker at #Requires:`n  $($mismatched -join "`n  ")"
    }
}

Write-Host "Publishing $($files.Count) runbook(s) to $AutomationAccountName" -ForegroundColor Cyan
Write-Host "  runbooks expect RMA.Runbooks $moduleVersion on the Hybrid Worker" -ForegroundColor DarkGray

$failed = [System.Collections.Generic.List[string]]::new()
foreach ($file in $files) {
    if (-not $PSCmdlet.ShouldProcess($file.BaseName, 'Import and publish runbook')) { continue }
    try {
        # Draft first: the live version keeps serving until Publish is called.
        $null = Import-AzAutomationRunbook -ResourceGroupName $ResourceGroup `
            -AutomationAccountName $AutomationAccountName -Path $file.FullName `
            -Name $file.BaseName -Type $RunbookType -Force

        $null = Publish-AzAutomationRunbook -ResourceGroupName $ResourceGroup `
            -AutomationAccountName $AutomationAccountName -Name $file.BaseName

        Write-Host "  published $($file.BaseName)" -ForegroundColor Green
    } catch {
        Write-Host "  FAILED $($file.BaseName): $($_.Exception.Message)" -ForegroundColor Red
        $failed.Add($file.BaseName)
    }
}

if ($failed.Count -gt 0) { throw "Failed to publish: $($failed -join ', ')" }

Write-Host ''
Write-Host "Confirm RMA.Runbooks $moduleVersion is installed on every worker in the group," -ForegroundColor Yellow
Write-Host 'then run Test-RmaHealth before enabling any schedule.' -ForegroundColor Yellow
