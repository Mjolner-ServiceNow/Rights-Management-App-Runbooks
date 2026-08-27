#Requires -Version 7.2

<#
.SYNOPSIS
    Deploys the Azure infrastructure from the Bicep template. Interactive and idempotent.
.DESCRIPTION
    The template is designed to be deployed by hand, by whoever owns the subscription. This
    script is a convenience wrapper around `az deployment group`, not a requirement: running
    the az commands directly works exactly as well, and the script prints them as it goes.

    What it adds over a bare `az deployment group create`:

      - Runs what-if first and refuses to continue if the plan contains a Delete. On this
        platform that could be the Key Vault or the Automation Account, so it should never
        happen as a side effect of a routine deployment.
      - Asserts afterwards that the Automation Account has no managed identity. Enabling one
        silently breaks Hybrid Worker authentication, and it is the single most common way
        to break this platform.
      - Prints the outputs you need for the remaining manual steps, including which GUID is
        which.

    Requires: Azure CLI, logged in, with Contributor on the target resource group.
.PARAMETER Environment
    Selects infra/main.parameters.<environment>.json.
.PARAMETER WhatIfOnly
    Show the plan and stop. Safe to run at any time.
.EXAMPLE
    ./scripts/Deploy-RmaPlatform.ps1 -ResourceGroup rg-rma-prod -Environment prod -WhatIfOnly
.EXAMPLE
    ./scripts/Deploy-RmaPlatform.ps1 -ResourceGroup rg-rma-prod -Environment prod
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
    [string] $ResourceGroup,

    [Parameter(Mandatory)][ValidateSet('dev', 'test', 'prod')]
    [string] $Environment,

    [string] $SubscriptionId,
    [switch] $WhatIfOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot  = Split-Path $PSScriptRoot -Parent
$template  = Join-Path $repoRoot 'infra/main.bicep'
$parameters = Join-Path $repoRoot "infra/main.parameters.$Environment.json"

foreach ($path in $template, $parameters) {
    if (-not (Test-Path $path)) { throw "Not found: $path" }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI not found. Install it from https://aka.ms/azure-cli'
}

if ($SubscriptionId) {
    Write-Host "Setting subscription $SubscriptionId"
    az account set --subscription $SubscriptionId
}

# Placeholders are a deployment failure waiting to happen; catch them here.
$placeholders = (Get-Content $parameters -Raw | ConvertFrom-Json).parameters.PSObject.Properties |
Where-Object { "$($_.Value.value)" -like 'REPLACE_WITH_*' }
if ($placeholders) {
    throw "Fill in these parameters in $parameters first: $($placeholders.Name -join ', ')"
}

# ---------------------------------------------------------------- what-if
Write-Host ''
Write-Host '=== What-if ===' -ForegroundColor Cyan
Write-Host "az deployment group what-if -g $ResourceGroup --template-file infra/main.bicep --parameters $(Split-Path $parameters -Leaf)"
Write-Host ''

$plan = az deployment group what-if `
    --resource-group $ResourceGroup `
    --template-file $template `
    --parameters $parameters 2>&1 | Out-String

Write-Host $plan

if ($plan -match '(?m)^\s*[-~]?\s*Delete') {
    throw 'The plan contains a Delete. Review it before proceeding; this platform holds a Key Vault and an Automation Account.'
}

if ($WhatIfOnly) {
    Write-Host 'What-if only. Nothing deployed.' -ForegroundColor Yellow
} else {
    # -------------------------------------------------------------- deploy
    if (-not $PSCmdlet.ShouldProcess($ResourceGroup, "Deploy RMA platform ($Environment)")) { return }

    Write-Host ''
    Write-Host '=== Deploying ===' -ForegroundColor Cyan
    $name = "rma-$Environment-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"

    $raw = az deployment group create `
        --resource-group $ResourceGroup `
        --name $name `
        --template-file $template `
        --parameters $parameters `
        --query properties.outputs -o json

    if ($LASTEXITCODE -ne 0) { throw 'Deployment failed. See the Azure CLI output above.' }
    $out = $raw | ConvertFrom-Json

    # ------------------------------------------------------------- verify
    Write-Host ''
    Write-Host '=== Verifying ===' -ForegroundColor Cyan
    $identityType = az automation account show `
        --resource-group $ResourceGroup --name $out.automationAccountName.value `
        --query 'identity.type' -o tsv 2>$null

    if ($identityType -and $identityType -ne 'None') {
        throw "The Automation Account has a '$identityType' managed identity. It must be None, " +
        'or the Hybrid Worker VM identity is overridden and every runbook fails to authenticate.'
    }
    Write-Host '  Automation Account identity: None (correct)' -ForegroundColor Green

    # ------------------------------------------------------------ outputs
    Write-Host ''
    Write-Host '=== Deployed ===' -ForegroundColor Cyan
    Write-Host "  Automation Account   : $($out.automationAccountName.value)"
    Write-Host "  Hybrid Worker Group  : $($out.hybridWorkerGroupName.value)"
    Write-Host "  Key Vault            : $($out.keyVaultName.value)"
    Write-Host ''
    Write-Host '  Managed identity, CLIENT id    (runbook -ManagedIdentityClientId):' -ForegroundColor Yellow
    Write-Host "    $($out.managedIdentityClientId.value)"
    Write-Host '  Managed identity, PRINCIPAL id (federated credential SUBJECT):' -ForegroundColor Yellow
    Write-Host "    $($out.managedIdentityPrincipalId.value)"
    Write-Host ''
    Write-Host '  These are different GUIDs. Swapping them produces a federated credential that' -ForegroundColor DarkYellow
    Write-Host '  saves without error and fails only at token exchange.' -ForegroundColor DarkYellow

    Write-Host ''
    Write-Host '=== Next ===' -ForegroundColor Cyan
    Write-Host '  1. Attach the user-assigned identity to the Hybrid Worker VM.'
    Write-Host '  2. Register the VM into the Hybrid Worker Group and install extension v2.'
    Write-Host '  3. Run scripts/Initialize-RmaWorker.ps1 on the VM (elevated).'
    Write-Host '  4. Run scripts/Set-RmaAppRegistration.ps1, then grant admin consent and the'
    Write-Host '     Exchange Recipient Administrator role.'
    Write-Host '  5. Add the two secrets to the Key Vault.'
    Write-Host '  6. Run scripts/Publish-RmaContent.ps1 to upload the module and runbooks.'
    Write-Host '  7. Work through docs/PRODUCTION-CHECKLIST.md.'
}
