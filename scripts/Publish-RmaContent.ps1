#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'Az.Automation'; ModuleVersion = '1.9.0' }

<#
.SYNOPSIS
    Publishes the RMA.Runbooks module and the runbooks into an Automation Account.
.DESCRIPTION
    Manual equivalent of a deployment pipeline. Run it from a machine with the Az modules
    and Contributor on the Automation Account.

    Safety properties worth knowing, because they are the reason this is not just a loop
    over Import-AzAutomationRunbook:

      - The module import is asynchronous. A runbook started against a half-imported module
        fails in a way that looks like a code defect, so this waits for Succeeded.
      - Runbooks are imported as Draft and then published. The currently published version
        keeps serving until the new draft is published, so a failed import cannot take a
        runbook offline.
      - The module is staged in a storage account because New-AzAutomationModule imports
        from a URI. If you would rather not create one, publish RMA.Runbooks to an internal
        PowerShell repository and pass -ContentLinkUri yourself.
.PARAMETER StorageAccountName
    Existing storage account used to stage the module zip. A container named 'modules' is
    created if absent. The blob is removed afterwards unless -KeepStagedPackage is set.
.EXAMPLE
    ./scripts/Publish-RmaContent.ps1 -ResourceGroup rg-rma-prod `
        -AutomationAccountName aa-rma-prod -StorageAccountName strmaprodstaging
.EXAMPLE
    ./scripts/Publish-RmaContent.ps1 -ResourceGroup rg-rma-prod `
        -AutomationAccountName aa-rma-prod -RunbooksOnly
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()] [string] $ResourceGroup,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()] [string] $AutomationAccountName,

    [string] $StorageAccountName,
    [switch] $RunbooksOnly,
    [switch] $ModuleOnly,
    [switch] $KeepStagedPackage,

    [ValidateSet('PowerShell72', 'PowerShell')]
    [string] $RunbookType = 'PowerShell72'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot   = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $repoRoot 'src/RMA.Runbooks'
$runbookDir = Join-Path $repoRoot 'src/runbooks'
$version    = (Import-PowerShellDataFile (Join-Path $modulePath 'RMA.Runbooks.psd1')).ModuleVersion

Write-Host "RMA.Runbooks $version -> $AutomationAccountName" -ForegroundColor Cyan

# ------------------------------------------------------------------ module
if (-not $RunbooksOnly) {
    if (-not $StorageAccountName) {
        throw 'StorageAccountName is required to publish the module. Use -RunbooksOnly to skip the module.'
    }

    $zip = Join-Path ([IO.Path]::GetTempPath()) "RMA.Runbooks-$version.zip"
    Compress-Archive -Path $modulePath -DestinationPath $zip -Force
    Write-Host "  packaged $([math]::Round((Get-Item $zip).Length / 1KB)) KB"

    $blobName = "RMA.Runbooks-$version.zip"
    $ctx = (Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $StorageAccountName).Context

    if (-not (Get-AzStorageContainer -Name 'modules' -Context $ctx -ErrorAction SilentlyContinue)) {
        $null = New-AzStorageContainer -Name 'modules' -Context $ctx -Permission Off
    }

    if ($PSCmdlet.ShouldProcess($blobName, 'Stage module package')) {
        $null = Set-AzStorageBlobContent -File $zip -Container 'modules' -Blob $blobName -Context $ctx -Force
        $sas = New-AzStorageBlobSASToken -Container 'modules' -Blob $blobName -Context $ctx `
            -Permission r -ExpiryTime (Get-Date).AddHours(2) -FullUri
        Write-Host '  staged'

        $null = New-AzAutomationModule -ResourceGroupName $ResourceGroup `
            -AutomationAccountName $AutomationAccountName -Name 'RMA.Runbooks' -ContentLinkUri $sas

        # Asynchronous. Wait, or the runbook publish below races a partial module.
        $deadline = (Get-Date).AddMinutes(15)
        do {
            Start-Sleep -Seconds 15
            $module = Get-AzAutomationModule -ResourceGroupName $ResourceGroup `
                -AutomationAccountName $AutomationAccountName -Name 'RMA.Runbooks'
            Write-Host "  import state: $($module.ProvisioningState)"
        } while ($module.ProvisioningState -notin 'Succeeded', 'Failed' -and (Get-Date) -lt $deadline)

        if ($module.ProvisioningState -ne 'Succeeded') {
            throw "Module import did not succeed (state: $($module.ProvisioningState)). Runbooks were not published."
        }
        Write-Host "  module $($module.Version) imported" -ForegroundColor Green

        if (-not $KeepStagedPackage) {
            Remove-AzStorageBlob -Container 'modules' -Blob $blobName -Context $ctx -Force
        }
    }
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------- runbooks
if (-not $ModuleOnly) {
    $files  = @(Get-ChildItem $runbookDir -Filter '*.ps1' -File)
    $failed = [System.Collections.Generic.List[string]]::new()

    Write-Host "Publishing $($files.Count) runbook(s)..."
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
}

Write-Host ''
Write-Host 'Done. Run Test-RmaHealth on the Hybrid Worker before enabling any schedule.' -ForegroundColor Cyan
