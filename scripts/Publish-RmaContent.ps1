#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'Az.Automation'; ModuleVersion = '1.9.0' }

<#
.SYNOPSIS
    Publishes the runbooks into an Automation Account, linked to a PowerShell 7.6 Runtime
    environment.
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

    How the interpreter version is selected. PowerShell 7.4 and 7.6 exist only in the
    Runtime environment experience. Import-AzAutomationRunbook's -Type parameter stops at
    PowerShell72, and the API rejects a runtimeEnvironment on a PowerShell72 runbook with
    "The property runtimeEnvironment cannot be configured for runbookType PowerShell72".
    So each runbook is imported as type PowerShell and then linked to a Runtime
    environment, and that link is what determines the interpreter version.

    Why 7.6. It is the current PowerShell LTS, supported until 14 November 2028.
    PowerShell 7.4 leaves support on 10 November 2026 and 7.2 is already out of support in
    PowerShell and retires in Azure Automation on 30 September 2026.

    Migrating a runbook published by an earlier version of this script. Runbook type is
    immutable through PUT, which is what Import-AzAutomationRunbook uses, so importing over
    a PowerShell72 runbook fails with "Runbook Type cannot be modified". PATCH can change
    the type, and can set the Runtime environment in the same call. This script detects any
    runbook whose type is not PowerShell and migrates it in place before importing.

    Safety property worth keeping: each runbook is imported as a Draft and then published.
    The currently published version keeps serving until the new draft is published, so a
    failed import cannot take a runbook offline. The Runtime environment PATCH is applied
    while the draft is pending, which preserves both the draft and the published version.
.PARAMETER RuntimeEnvironmentName
    The Runtime environment to link every runbook to. It must already exist: this script
    publishes content and does not create infrastructure. Create it in the Automation
    account under Runtime Environments, or with a PUT to the runtimeEnvironments API.
.PARAMETER RuntimeVersion
    The PowerShell version the named Runtime environment is expected to be. Checked before
    anything is published, so a Runtime environment name that points at the wrong version
    fails here rather than at the first job.
.PARAMETER SkipVersionCheck
    Skip the check that the runbooks' #Requires version matches the module in this repo.
.EXAMPLE
    ./scripts/Publish-RmaContent.ps1 -ResourceGroup rg-rma-prod -AutomationAccountName aa-rma-prod
.NOTES
    The worker must have an interpreter matching the Runtime environment version, installed
    and registered by scripts/Initialize-RmaWorkerHost.ps1. A runbook linked to a 7.6
    Runtime environment on a worker with no powershell_7_6_path never starts.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()] [string] $ResourceGroup,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()] [string] $AutomationAccountName,

    [ValidateNotNullOrEmpty()]
    [string] $RuntimeEnvironmentName = 'Powershell_7-6',

    [ValidateSet('7.6', '7.4')]
    [string] $RuntimeVersion = '7.6',

    [string[]] $Name,
    [switch]   $SkipVersionCheck
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$apiVersion = '2024-10-23'

$repoRoot   = Split-Path $PSScriptRoot -Parent
$runbookDir = Join-Path $repoRoot 'src/runbooks'
$moduleVersion = (Import-PowerShellDataFile (Join-Path $repoRoot 'src/RMA.Runbooks/RMA.Runbooks.psd1')).ModuleVersion

$context = Get-AzContext
if (-not $context) { throw 'No Azure context. Run Connect-AzAccount first.' }

$accountPath = (
    "/subscriptions/$($context.Subscription.Id)/resourceGroups/$ResourceGroup" +
    "/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName"
)

# Runtime environments are not exposed by the Az.Automation cmdlets, so they are reached
# through the management API. Invoke-AzRestMethod reuses the current Az context, so this
# adds no new authentication path.
function Invoke-AutomationApi {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'PATCH')]  [string] $Method,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]     [string] $RelativePath,

        [string] $Payload,
        [switch] $AllowNotFound
    )

    $splat = @{
        Path   = '{0}{1}?api-version={2}' -f $script:accountPath, $RelativePath, $script:apiVersion
        Method = $Method
    }
    if ($Payload) { $splat['Payload'] = $Payload }

    $response = Invoke-AzRestMethod @splat

    if ($response.StatusCode -eq 404 -and $AllowNotFound) { return $null }
    if ($response.StatusCode -ge 400) {
        throw "$Method $RelativePath returned $($response.StatusCode): $($response.Content)"
    }
    if ($response.Content) { return ($response.Content | ConvertFrom-Json) }
    return $null
}

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

# Checked before anything is published: a Runtime environment that does not exist, or that
# is the wrong version, would otherwise surface as a job that never starts.
$runtime = Invoke-AutomationApi -Method GET -RelativePath "/runtimeEnvironments/$RuntimeEnvironmentName" -AllowNotFound
if (-not $runtime) {
    throw "Runtime environment '$RuntimeEnvironmentName' does not exist in $AutomationAccountName. " +
    "Create a PowerShell $RuntimeVersion Runtime environment (Automation account > Runtime Environments), " +
    'or pass -RuntimeEnvironmentName with the name of an existing one.'
}

$runtimeLanguage = $runtime.properties.runtime.language
$runtimeReported = $runtime.properties.runtime.version
if ($runtimeLanguage -ne 'PowerShell' -or $runtimeReported -ne $RuntimeVersion) {
    throw "Runtime environment '$RuntimeEnvironmentName' is $runtimeLanguage $runtimeReported, but " +
    "PowerShell $RuntimeVersion was expected. Runtime language and version are immutable, so point " +
    '-RuntimeEnvironmentName at a different Runtime environment.'
}

Write-Host "Publishing $($files.Count) runbook(s) to $AutomationAccountName" -ForegroundColor Cyan
Write-Host "  runtime      : $RuntimeEnvironmentName (PowerShell $runtimeReported)" -ForegroundColor DarkGray
Write-Host "  runbooks expect RMA.Runbooks $moduleVersion on the Hybrid Worker" -ForegroundColor DarkGray

# Sets the Runtime environment, and normalises the runbook type on the way. Identical body
# for the migration PATCH and the post-import PATCH, so both are idempotent.
$patchBody = @{
    properties = @{
        runbookType        = 'PowerShell'
        runtimeEnvironment = $RuntimeEnvironmentName
    }
} | ConvertTo-Json -Depth 5

$failed = [System.Collections.Generic.List[string]]::new()
foreach ($file in $files) {
    if (-not $PSCmdlet.ShouldProcess($file.BaseName, "Publish, linked to $RuntimeEnvironmentName")) { continue }
    try {
        $existing = Invoke-AutomationApi -Method GET -RelativePath "/runbooks/$($file.BaseName)" -AllowNotFound

        # Import-AzAutomationRunbook would fail with "Runbook Type cannot be modified" on a
        # runbook published as PowerShell72 by an earlier version of this script. PATCH is
        # the only operation that can change the type, so it goes first.
        if ($existing -and $existing.properties.runbookType -ne 'PowerShell') {
            Write-Host "  migrating $($file.BaseName) from type $($existing.properties.runbookType)" -ForegroundColor Yellow
            $null = Invoke-AutomationApi -Method PATCH -RelativePath "/runbooks/$($file.BaseName)" -Payload $patchBody
        }

        # Draft first: the live version keeps serving until Publish is called.
        $null = Import-AzAutomationRunbook -ResourceGroupName $ResourceGroup `
            -AutomationAccountName $AutomationAccountName -Path $file.FullName `
            -Name $file.BaseName -Type 'PowerShell' -Force

        # The interpreter version comes from the Runtime environment, not from -Type. A
        # newly created runbook has no link until this runs.
        $null = Invoke-AutomationApi -Method PATCH -RelativePath "/runbooks/$($file.BaseName)" -Payload $patchBody

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
Write-Host "Confirm every worker in the group has RMA.Runbooks $moduleVersion and an interpreter" -ForegroundColor Yellow
Write-Host "registered for PowerShell $runtimeReported, then run Test-RmaHealth before enabling any schedule." -ForegroundColor Yellow
