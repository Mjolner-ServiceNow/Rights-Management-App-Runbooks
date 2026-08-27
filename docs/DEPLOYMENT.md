# Updating an installation

For a first-time setup, use [`INSTALLATION.md`](INSTALLATION.md). This document covers
changes to an installation that already works.

The Bicep template is a deployment artefact: it is deployed manually by whoever owns the
target subscription. This repository holds no credentials and deploys nothing itself. CI
validates code on pull requests and has no Azure access.

## What to update, and when

| You changed | Run | Also required |
|---|---|---|
| A runbook body | `Publish-RmaContent.ps1 -Name <runbook>` | — |
| The shared module | `Initialize-RmaWorker.ps1` on **every** worker, then `Publish-RmaContent.ps1` | Bump `ModuleVersion` and every `#Requires` that pins it |
| A pinned third-party module | `Initialize-RmaWorker.ps1` on **every** worker | Update the `#Requires` in affected runbooks |
| Infrastructure | `Deploy-RmaPlatform.ps1` | — |
| A Key Vault secret | Update the secret. Runbooks read it at start of run | — |

Rotating a password needs no redeployment. That is the point of it being in Key Vault.

## Updating the shared module

This is the only two-sided change, and getting it half-done is the main way to break a
working installation.

1. Bump `ModuleVersion` in `src/RMA.Runbooks/RMA.Runbooks.psd1`.
2. Update the `RequiredVersion` in the `#Requires` of every runbook that uses it.
3. Merge, tag, and let the release workflow publish the package.
4. Run `Initialize-RmaWorker.ps1` on **every** worker in the group.
5. Run `Publish-RmaContent.ps1`.

Steps 4 and 5 in that order. A worker carrying the new module while the runbooks still pin
the old one fails at parse time; so does the reverse. Both fail loudly and immediately
rather than subtly, which is intentional, but neither processes work.

`Publish-RmaContent.ps1` refuses to publish a runbook whose pin disagrees with the module in
the repository, so a forgotten step 2 is caught before it reaches Azure.

## Updating infrastructure

```powershell
./scripts/Deploy-RmaPlatform.ps1 -ResourceGroup rg-rma-prod -Environment prod -WhatIfOnly
./scripts/Deploy-RmaPlatform.ps1 -ResourceGroup rg-rma-prod -Environment prod
```

Bicep is declarative, so redeploying converges rather than duplicating. The script refuses
to proceed if the plan contains a `Delete`, which on this platform could mean the Key Vault
or the Automation Account.

## Downtime and rollback

This is a queue consumer, not a request handler. There is no endpoint to take offline, so
downtime means jobs accumulate unprocessed in ServiceNow. Nothing is dropped.

| Scope | How | Time |
|---|---|---|
| Emergency stop | Disable the schedules. Jobs queue and are processed on re-enable. | seconds |
| One runbook | Publish the previous draft from the Automation Account. | ~2 min |
| Shared module | Re-run `Initialize-RmaWorker.ps1` on each worker from the previous tag, then re-publish the runbooks that pin it. Both sides must move together. | ~10 min |
| Infrastructure | Re-deploy from the previous tag. | ~10 min |

Runbooks are always imported as a Draft and then published, so a failed import cannot take
a working runbook offline.

### Draining before a planned change

```powershell
Get-AzAutomationSchedule -ResourceGroupName $rg -AutomationAccountName $aa |
    Set-AzAutomationSchedule -IsEnabled $false

while (Get-AzAutomationJob -ResourceGroupName $rg -AutomationAccountName $aa -Status Running) {
    Start-Sleep 30
}
# Every run is bounded by MaxMinutes, so this always terminates.
```

Re-enable the schedules afterwards. Queued work is picked up on the next run.

## Adding a worker

Attach the same user-assigned managed identity to the new VM, register it into the Hybrid
Worker Group, and run `Initialize-RmaWorker.ps1` on it. No code change, no redeployment.

This is safe only because jobs are claimed atomically. On a design without that, a second
worker would double the duplicate-execution rate rather than the throughput.
