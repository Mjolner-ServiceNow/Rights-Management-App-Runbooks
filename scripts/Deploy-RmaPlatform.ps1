#Requires -Version 7.2

<#
.SYNOPSIS
    Deploys the Azure infrastructure from the Bicep template, creating the resource group
    if it does not exist. Interactive and idempotent.
.DESCRIPTION
    The template is designed to be deployed by hand, by whoever owns the subscription. This
    script is a convenience wrapper around `az deployment`, not a requirement: the
    equivalent az commands work just as well and are printed as it goes.

    What it adds over a bare `az deployment create`:

      - Fails fast on the cheap things first: not signed in, no such subscription,
        placeholders left in the parameter file.
      - Runs what-if, and refuses to continue if the plan contains a Delete or if the
        what-if itself failed. A gate that only works when nothing goes wrong is not a gate.
      - Asserts afterwards that the Automation Account has no managed identity. Enabling one
        silently breaks Hybrid Worker authentication and is the most common way to break
        this platform.
      - Prints the outputs needed for the remaining manual steps, labelling which GUID is
        the client id and which is the principal id.

    Scope. A resource-group-scoped template cannot create its own resource group, so the
    default path deploys at subscription scope and needs Contributor on the subscription.
    If you only hold Contributor on one resource group, create the group yourself and pass
    -WorkloadOnly to deploy infra/workload.bicep into it. Both paths create the same
    resources.

    Re-running is safe. ARM converges an existing deployment rather than recreating it.
.PARAMETER Environment
    Selects infra/main.parameters.<environment>.json, or the .local.json override if present.
.PARAMETER ResourceGroup
    Overrides resourceGroupName from the parameter file.
.PARAMETER WorkloadOnly
    Deploy into an existing resource group instead of creating one.
.PARAMETER WhatIfOnly
    Show the plan and stop. Safe to run at any time.
.EXAMPLE
    ./scripts/Deploy-RmaPlatform.ps1 -Environment dev -WhatIfOnly
.EXAMPLE
    ./scripts/Deploy-RmaPlatform.ps1 -Environment prod -SubscriptionId <guid>
.EXAMPLE
    ./scripts/Deploy-RmaPlatform.ps1 -Environment prod -WorkloadOnly -ResourceGroup rg-existing
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('dev', 'test', 'prod')]
    [string] $Environment,

    [string] $ResourceGroup,
    [string] $SubscriptionId,
    [switch] $WorkloadOnly,
    [switch] $WhatIfOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
$template = Join-Path $repoRoot $(if ($WorkloadOnly) { 'infra/workload.bicep' } else { 'infra/main.bicep' })

# Prefer a local override. The committed parameter file is a template with placeholders,
# because this repository is public; real subscription and resource ids belong in
# main.parameters.<env>.local.json, which is gitignored.
$parameters = Join-Path $repoRoot "infra/main.parameters.$Environment.local.json"
if (-not (Test-Path $parameters)) {
    $parameters = Join-Path $repoRoot "infra/main.parameters.$Environment.json"
}

foreach ($path in $template, $parameters) {
    if (-not (Test-Path $path)) { throw "Not found: $path" }
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI not found. Install it from https://aka.ms/azure-cli'
}

# --------------------------------------------------------------- preconditions
if ($SubscriptionId) {
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        throw "Could not select subscription '$SubscriptionId'. Run 'az login' and confirm you have access."
    }
}

$account = az account show --query '{name:name, id:id}' -o json 2>$null | ConvertFrom-Json
if (-not $account) { throw "Not signed in to Azure. Run 'az login' first." }

$parsed = Get-Content $parameters -Raw | ConvertFrom-Json

if (-not $ResourceGroup) {
    $ResourceGroup = $parsed.parameters.resourceGroupName.value
    if (-not $ResourceGroup) {
        throw "No -ResourceGroup given and 'resourceGroupName' is not set in $(Split-Path $parameters -Leaf)."
    }
}
$location = $parsed.parameters.location.value
if (-not $location) { throw "'location' is not set in $(Split-Path $parameters -Leaf)." }

$placeholders = $parsed.parameters.PSObject.Properties |
Where-Object { "$($_.Value.value)" -like 'REPLACE_WITH_*' }
if ($placeholders) {
    throw "Fill these in first, in $(Split-Path $parameters -Leaf): $($placeholders.Name -join ', ')"
}

$groupExists = (az group exists --name $ResourceGroup) -eq 'true'
if ($WorkloadOnly -and -not $groupExists) {
    throw "Resource group '$ResourceGroup' does not exist, and -WorkloadOnly will not create it.`n" +
    "  Create it:   az group create --name $ResourceGroup --location $location`n" +
    '  Or drop -WorkloadOnly and let the template create it.'
}

Write-Host ''
Write-Host "Subscription   : $($account.name)  ($($account.id))"
Write-Host "Resource group : $ResourceGroup$(if (-not $groupExists) { '  (will be created)' })"
Write-Host "Location       : $location"
Write-Host "Template       : $(Split-Path $template -Leaf)"
Write-Host "Parameters     : $(Split-Path $parameters -Leaf)"

$scopeArgs = if ($WorkloadOnly) {
    @('group', '--resource-group', $ResourceGroup)
} else {
    @('sub', '--location', $location)
}

# --------------------------------------------------------------------- what-if
Write-Host ''
Write-Host '=== What-if ===' -ForegroundColor Cyan

$plan = az deployment $scopeArgs[0] what-if $scopeArgs[1] $scopeArgs[2] `
    --template-file $template --parameters $parameters 2>&1 | Out-String
$whatIfExit = $LASTEXITCODE

Write-Host $plan

# A gate that only holds when nothing goes wrong is not a gate. Without this check a
# what-if that failed for any reason would print its error and the script would deploy
# anyway. Looking before you leap has to mean not leaping when you could not look.
if ($whatIfExit -ne 0) {
    $hint = switch -Regex ($plan) {
        'ResourceGroupNotFound' { "The resource group does not exist. Drop -WorkloadOnly to have the template create it, or run: az group create --name $ResourceGroup --location $location" }
        'AuthorizationFailed'   { 'Insufficient rights. Subscription-scope deployment needs Contributor on the subscription; -WorkloadOnly needs it only on the resource group.' }
        'InvalidTemplate|BCP'   { 'The template failed validation. Run: az bicep build --file infra/main.bicep' }
        'already consumed'      { 'The Azure CLI could not render the real error - that is a CLI bug, not a template problem. The cause is the last "Code:" or "Message:" line above.' }
        default                 { 'The cause is usually the last "Code:" or "Message:" line above.' }
    }
    throw "What-if failed (exit $whatIfExit). Nothing was deployed.`n  $hint"
}

if ($plan -match '(?m)^\s*[-~]?\s*Delete') {
    throw 'The plan contains a Delete. Review it before proceeding; this platform holds a Key Vault and an Automation Account.'
}

if ($WhatIfOnly) {
    Write-Host 'What-if only. Nothing deployed.' -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------- deploy
if (-not $PSCmdlet.ShouldProcess($ResourceGroup, "Deploy RMA platform ($Environment)")) { exit 0 }

Write-Host ''
Write-Host '=== Deploying ===' -ForegroundColor Cyan
$name = "rma-$Environment-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"

$raw = az deployment $scopeArgs[0] create $scopeArgs[1] $scopeArgs[2] `
    --name $name --template-file $template --parameters $parameters `
    --query properties.outputs -o json

if ($LASTEXITCODE -ne 0) {
    throw "Deployment failed (exit $LASTEXITCODE). The cause is usually the last " +
    '"Code:" or "Message:" line in the output above.'
}
if (-not $raw) { throw 'The deployment reported success but returned no outputs. Check it in the portal.' }
$out = $raw | ConvertFrom-Json

# ---------------------------------------------------------------------- verify
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

# --------------------------------------------------------------------- outputs
Write-Host ''
Write-Host '=== Deployed ===' -ForegroundColor Cyan
Write-Host "  Resource group       : $ResourceGroup"
Write-Host "  Automation Account   : $($out.automationAccountName.value)"
Write-Host "  Hybrid Worker Group  : $($out.hybridWorkerGroupName.value)"
Write-Host "  Key Vault            : $($out.keyVaultName.value)"
Write-Host ''
Write-Host '  Managed identity, CLIENT id    (runbook -ManagedIdentityClientId):' -ForegroundColor Yellow
Write-Host "    $($out.managedIdentityClientId.value)"
Write-Host '  Managed identity, PRINCIPAL id (federated credential SUBJECT):' -ForegroundColor Yellow
Write-Host "    $($out.managedIdentityPrincipalId.value)"
Write-Host ''
Write-Host '  Different GUIDs. Swapping them creates a federated credential that saves' -ForegroundColor DarkYellow
Write-Host '  without error and fails only later, at token exchange.' -ForegroundColor DarkYellow

Write-Host ''
Write-Host '=== Next ===' -ForegroundColor Cyan
Write-Host '  1. Attach the user-assigned identity to the Hybrid Worker VM.'
Write-Host '  2. Register the VM into the Hybrid Worker Group and install extension v2.'
Write-Host '  3. Run scripts/Initialize-RmaWorker.ps1 on the VM (elevated).'
Write-Host '  4. Run scripts/Set-RmaAppRegistration.ps1, then grant admin consent and the'
Write-Host '     Exchange Recipient Administrator role.'
Write-Host '  5. Add the two secrets to the Key Vault.'
Write-Host '  6. Run scripts/Publish-RmaContent.ps1.'
Write-Host '  7. Work through docs/PRODUCTION-CHECKLIST.md.'
