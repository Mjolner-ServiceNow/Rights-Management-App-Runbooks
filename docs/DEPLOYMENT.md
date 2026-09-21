# Updating an installation

For a first-time setup, use [`INSTALLATION.md`](INSTALLATION.md). This document covers
changes to an installation that already works.

This repository holds no credentials and deploys nothing itself. CI validates code on pull
requests and has no Azure access. There is no infrastructure-as-code here either: the Azure
resources are created and changed by hand, in the portal or with the CLI.

## What to update, and when

| You changed | Run | Also required |
|---|---|---|
| A runbook body | `Publish-RmaContent.ps1 -Name <runbook>` | — |
| The shared module | `Initialize-RmaWorker.ps1` on **every** worker, then `Publish-RmaContent.ps1` | Bump `ModuleVersion` and every `#Requires` that pins it |
| A pinned third-party module | `Initialize-RmaWorker.ps1` on **every** worker | Update the `#Requires` in affected runbooks |
| An Azure resource | By hand, in the portal or with the CLI | Keep the Automation Account identity at **None** |
| A Key Vault secret | Update the secret. Runbooks read it at start of run | — |

Rotating a password needs no redeployment. That is the point of it being in Key Vault.

## Updating the shared module

This is the only two-sided change, and getting it half-done is the main way to break a
working installation.

1. Bump `ModuleVersion` in `src/RMA.Runbooks/RMA.Runbooks.psd1`.
2. Update the `RequiredVersion` in the `#Requires` of every runbook that uses it.
3. Merge. The release workflow drafts a release for the new version automatically, with
   the package and its SHA256 attached.
4. **Publish the draft** when you are about to provision the workers. Nothing is public
   and no tag exists until you do. This is the one deliberate step, and it is deliberate
   because of 5 and 6.
5. On **every** worker in the group, elevated, paste the command block from the release
   notes. It downloads `Initialize-RmaWorker.ps1` from that release, checks its SHA256,
   and runs it against the verified module package — no checkout, and both hashes
   generated into the notes by the release workflow. Add `-WhatIf` to the last line to
   preview it first; the download and hash check still happen, nothing is installed.
6. Run `Publish-RmaContent.ps1`, then `Test-RmaHealth`.

Steps 5 and 6 in that order. A worker carrying the new module while the runbooks still pin
the old one fails at parse time; so does the reverse. Both fail loudly and immediately
rather than subtly, which is intentional, but neither processes work.

Three things catch a half-done change before it reaches a worker. Steps 1 and 2 are checked
against each other by `tests/Unit/PinnedModuleVersions.Tests.ps1`; step 1 on its own is
required by `build/Assert-ModuleVersionBump.ps1` on every pull request that touches the
module; and `Publish-RmaContent.ps1` refuses to publish a runbook whose pin disagrees with
the module in the repository.

Pushing a `v*` tag by hand still publishes immediately, without the draft step. Use it to
re-cut a release that was deleted, not as the normal path.

## Changing infrastructure

There is no template and no deployment script. Change the resource directly, in the portal
or with `az`, and note what you changed — there is no plan to diff against and no what-if
to review, so a mistake is only visible in its effect.

Two changes are load-bearing and easy to make by accident:

- **Never enable a managed identity on the Automation Account.** It overrides the Hybrid
  Worker VM's identity and every runbook stops authenticating. Nothing blocks it.
- **The Key Vault firewall in production** allows only the worker's subnet. Moving the VM
  to another subnet breaks secret reads until the rule follows it.

## Downtime and rollback

This is a queue consumer, not a request handler. There is no endpoint to take offline, so
downtime means jobs accumulate unprocessed in ServiceNow. Nothing is dropped.

| Scope | How | Time |
|---|---|---|
| Emergency stop | Disable the schedules. Jobs queue and are processed on re-enable. | seconds |
| One runbook | Publish the previous draft from the Automation Account. | ~2 min |
| Shared module | Re-run `Initialize-RmaWorker.ps1` on each worker from the previous tag, then re-publish the runbooks that pin it. Both sides must move together. | ~10 min |
| Infrastructure | Revert the change by hand. No template to roll back to. | varies |

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
