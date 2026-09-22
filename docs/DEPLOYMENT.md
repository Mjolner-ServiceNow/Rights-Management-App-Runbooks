# Updating an installation

For a first-time setup, use [`INSTALLATION.md`](INSTALLATION.md). This document covers
changes to an installation that already works.

This repository holds no credentials and deploys nothing itself. CI validates code on pull
requests and has no Azure access. There is no infrastructure-as-code here either: the Azure
resources are created and changed by hand, in the portal or with the CLI.

## What to update, and when

| You changed | Run | Also required |
|---|---|---|
| A runbook body | Nothing here. The ServiceNow app pulls runbooks from this repository into the Automation Account | — |
| The shared module | `Initialize-RmaWorker.ps1` on **every** worker, then let the app re-publish the runbooks | Bump `ModuleVersion` and every `#Requires` that pins it |
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
6. Let the ServiceNow app pull the runbooks into the Automation Account, then run
   `Test-RmaHealth`.

Steps 5 and 6 in that order. A worker carrying the new module while the runbooks still pin
the old one fails at parse time; so does the reverse. Both fail loudly and immediately
rather than subtly, which is intentional, but neither processes work.

**Neither leaves anything to clean up.** `#Requires` is a parse-time directive, checked
before the script body runs, so `Invoke-RmaQueueLoop` is never reached and no claim is ever
attempted. Queue rows stay at `status = 1`, untouched: nothing moves to Work in Progress,
nothing strands, nothing needs requeueing. A version mismatch postpones work rather than
creating any, and the next run after the order is corrected picks it all up.

That is a consequence of where the check lives. Had it been inside the runbook body instead,
the job would be claimed first and fail afterwards, and a botched upgrade would leave rows
to recover rather than an order to fix.

**The error names the wrong cause**, which is what makes this look worse than it is:

```
ResourceUnavailable: The script 'Create-EntraUser.ps1' cannot be run because the
following modules that are specified by the "#requires" statements of the script are
missing: The module 'RMA.Runbooks' cannot be found with RequiredVersion '1.2.0'.
```

It says **missing** even when the module is installed and only the version differs — the
useful half of that sentence is the last clause, after everything else has said the module
is absent. Someone reading it under pressure goes looking for a failed installation. Check
the version first:

```powershell
Get-Module -ListAvailable RMA.Runbooks | Select-Object Version, ModuleBase
```

Two checks catch a half-done change, and both now run before the merge rather than at
publish time. Steps 1 and 2 are checked against each other by
`tests/Unit/PinnedModuleVersions.Tests.ps1`; step 1 on its own is required by
`build/Assert-ModuleVersionBump.ps1` on every pull request that touches the module. Since
the app publishes whatever is on `main`, `main` being consistent is what matters, and that
is exactly what these two enforce.

What no check can see is whether the **workers** have the version the runbooks pin. That
is caught at run time by `#Requires`, loudly and before any work is done, and by
`Test-RmaHealth`. It is the reason step 5 comes before step 6.

Superseded module versions may be left on a worker — runbooks pin an exact
`RequiredVersion`, so an old one is never loaded. Add `-PruneUnpinned` (with `-WhatIf`
first) when you want the disk back; the release notes carry the command. It matters most
for the Graph and Exchange modules, which are hundreds of megabytes rather than kilobytes.

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
| Emergency stop | Stop the ServiceNow application from starting runs. Jobs queue and are processed when it resumes. | seconds |
| One runbook | Publish the previous draft from the Automation Account. | ~2 min |
| Shared module | Re-run `Initialize-RmaWorker.ps1` on each worker from the previous tag, then re-publish the runbooks that pin it. Both sides must move together. | ~10 min |
| Infrastructure | Revert the change by hand. No template to roll back to. | varies |

Runbooks are always imported as a Draft and then published, so a failed import cannot take
a working runbook offline.

### Draining before a planned change

Stop the ServiceNow application from starting new runs first — there are no Azure
schedules to disable — then wait for the runs already in flight:

```powershell
while (Get-AzAutomationJob -ResourceGroupName $rg -AutomationAccountName $aa -Status Running) {
    Start-Sleep 30
}
# Every run is bounded by MaxMinutes, so this always terminates.
```

Let the application resume afterwards. Queued work is picked up by the next run it starts.

## Adding a worker

Attach the same user-assigned managed identity to the new VM, register it into the Hybrid
Worker Group, and run `Initialize-RmaWorker.ps1` on it. No code change, no redeployment.

This is safe only because jobs are claimed atomically. On a design without that, a second
worker would double the duplicate-execution rate rather than the throughput.
