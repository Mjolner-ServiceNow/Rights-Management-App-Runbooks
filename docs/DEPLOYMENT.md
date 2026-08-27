# Deployment

The Bicep template is a **deployment artefact for the customer**, not something this
repository deploys on their behalf. Nothing here has, or needs, credentials for anyone's
Azure subscription.

- Infrastructure: deployed manually with the Azure CLI, or through the customer's own
  deployment process.
- Content (module and runbooks): published manually with `scripts/Publish-RmaContent.ps1`.
- CI validates the code on every pull request and never touches Azure.

## Prerequisites

| | |
|---|---|
| Azure CLI | logged in, Contributor on the target resource group |
| PowerShell | 7.2+ with `Az.Automation` and `Az.Storage` (for publishing content only) |
| Entra | Cloud Application Administrator, for the app registration step |
| Hybrid Worker VM | an Azure VM that will run the runbooks |

## 1. Infrastructure

Copy the parameter file for your environment and fill in the placeholders:

```jsonc
// infra/main.parameters.prod.json
"hybridWorkerVmResourceId":  { "value": "/subscriptions/.../virtualMachines/vm-rma-01" },
"allowedSubnetResourceId":   { "value": "/subscriptions/.../subnets/snet-automation" },
"alertEmailAddresses":       { "value": ["operations@example.com"] },
"secretsOfficerPrincipalIds":{ "value": ["<object id of your ops group>"] }
```

Preview, then deploy:

```powershell
./scripts/Deploy-RmaPlatform.ps1 -ResourceGroup rg-rma-prod -Environment prod -WhatIfOnly
./scripts/Deploy-RmaPlatform.ps1 -ResourceGroup rg-rma-prod -Environment prod
```

Or with the CLI directly, which is all the script does:

```bash
az deployment group what-if -g rg-rma-prod \
  --template-file infra/main.bicep --parameters infra/main.parameters.prod.json

az deployment group create -g rg-rma-prod \
  --template-file infra/main.bicep --parameters infra/main.parameters.prod.json
```

The script adds three things worth having: it refuses to proceed if the plan contains a
`Delete`, it asserts afterwards that the Automation Account has no managed identity, and it
labels which output GUID is the **client** ID and which is the **principal** ID.

Record both. They are different, and swapping them produces a federated credential that
saves without error and fails only at token exchange.

## 2. Hybrid Worker

1. Attach the user-assigned managed identity (`managedIdentityClientId` output) to the VM.
2. Register the VM into the Hybrid Worker Group and install extension v2. The extension
   enables a **system-assigned** identity on the VM as well; that is expected, and is why
   every IMDS call in this codebase passes `client_id` explicitly.
3. On the VM, elevated. This installs the pinned Graph and Exchange modules **and
   `RMA.Runbooks` itself**, which Azure cannot deliver to a Hybrid Worker:

```powershell
./scripts/Initialize-RmaWorker.ps1 -WhatIf     # review first
./scripts/Initialize-RmaWorker.ps1
./scripts/Initialize-RmaWorker.ps1 -PruneUnpinned   # reclaim disk from accumulated versions
```

   If the repository is not checked out on the worker, install the module from a release
   asset instead:

```powershell
./scripts/Initialize-RmaWorker.ps1 `
    -ModuleSource 'https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/releases/download/v1.0.0/RMA.Runbooks-1.0.0.zip'
```

   Verify before moving on:

```powershell
Get-Module -ListAvailable RMA.Runbooks | Select-Object Name, Version, ModuleBase
```

   It must be under `C:\Program Files\PowerShell\Modules` (AllUsers, PowerShell 7). Hybrid
   Worker jobs run as local SYSTEM, so a per-user install is invisible to them.

## 3. App registration

```powershell
./scripts/Set-RmaAppRegistration.ps1 `
    -DisplayName 'RMA Runbooks (prod)' `
    -ManagedIdentityPrincipalId '<managedIdentityPrincipalId output>' `
    -TenantId '<your tenant id>'
```

Idempotent. It creates the application, sets the API permissions, and creates the federated
credential with the managed identity as subject.

It deliberately stops short of two things, and prints them:

- **Granting admin consent.** A conscious decision that should have a person attached.
- **Assigning the Entra directory role.** Use **Exchange Recipient Administrator**, which
  covers every Exchange cmdlet these runbooks call. Not Exchange Administrator, and not
  Global Administrator.

It never creates a secret or a certificate. That is the point of the design.

## 4. Secrets

Two, and only two:

```bash
az keyvault secret set --vault-name <kv> --name servicenow-api-password     --value '<...>'
az keyvault secret set --vault-name <kv> --name ad-service-account-password --value '<...>'
```

Set expiry dates so the near-expiry notifications actually fire.

The deployment never writes these. An identity that can write a secret can read it, so
deployment tooling is deliberately kept out of that role.

## 5. Content

```powershell
./scripts/Publish-RmaContent.ps1 -ResourceGroup rg-rma-prod -AutomationAccountName aa-rma-prod
```

This publishes **runbooks only**. `RMA.Runbooks` is not imported into the Automation
Account, and deliberately so: an Automation Account module is available to Azure sandbox
jobs, not to a Hybrid Worker. Importing it would look like the dependency was satisfied
while every runbook still failed at `#Requires`. The module belongs on the worker, from
step 2.

Two behaviours that matter:

- **Runbooks are imported as Draft, then published.** The live version keeps serving until
  the new draft is published, so a failed import cannot take a runbook offline.
- **Version pins are checked first.** If a runbook pins an `RMA.Runbooks` version other than
  the one in this repository, publishing is refused. That mismatch would otherwise surface
  as a parse-time failure on the worker.

To publish a subset:

```powershell
./scripts/Publish-RmaContent.ps1 ... -Name Create-EntraUser, Test-RmaHealth
```

## 6. Verify before enabling anything

```powershell
Start-AzAutomationRunbook -ResourceGroupName rg-rma-prod -AutomationAccountName aa-rma-prod `
    -Name 'Test-RmaHealth' -RunOn hwg-rma-prod -Parameters @{ ... }
```

Read-only. It exercises identity, Key Vault, ServiceNow, the domain record and the Graph
token exchange, and names the failing step if any. A green infrastructure deployment with a
broken identity looks identical to a working one until the first real job fails.

Then work through [`PRODUCTION-CHECKLIST.md`](PRODUCTION-CHECKLIST.md).

## Rollback and downtime

This is a queue consumer, not a request handler. There is no endpoint to take offline, so
"downtime" means jobs accumulate unprocessed in ServiceNow. Nothing is dropped.

| Scope | How | Time |
|---|---|---|
| Emergency stop | Disable the schedules. Jobs queue and are processed on re-enable. | seconds |
| One runbook | Publish the previous draft from the Automation Account. | ~2 min |
| Module | Re-run `Initialize-RmaWorker.ps1` on each worker from the previous tag, then re-publish the runbooks that pin it. Both sides must move together; a half-rollback produces a clean parse-time refusal rather than a subtle failure. | ~10 min |
| Infrastructure | Re-deploy from the previous tag. Bicep is declarative; state converges. | ~10 min |

### Draining before a planned change

```powershell
Get-AzAutomationSchedule -ResourceGroupName $rg -AutomationAccountName $aa |
    Set-AzAutomationSchedule -IsEnabled $false

while (Get-AzAutomationJob -ResourceGroupName $rg -AutomationAccountName $aa -Status Running) {
    Start-Sleep 30
}
# MaxMinutes bounds every run, so this always terminates.
```
