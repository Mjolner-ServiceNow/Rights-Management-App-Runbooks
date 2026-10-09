# Rights Management App — Runbooks

Automation runbooks that connect ServiceNow to Active Directory and Microsoft Entra ID,
and the shared PowerShell module they run on.

This repository holds no credentials and deploys nothing itself. The Azure resources the
runbooks need are provisioned by hand for now — there is no infrastructure-as-code here.
See [`docs/AZURE-RESOURCES.md`](docs/AZURE-RESOURCES.md) for what to create.

| | |
|---|---|
| **Shared module** | [`src/RMA.Runbooks`](src/RMA.Runbooks) — queue handling, identity, logging |
| **Runbooks** | [`src/runbooks`](src/runbooks) — see *Runbooks* below |
| **Scripts** | [`scripts`](scripts) — prepare a worker host, install the modules on it, create the app registration, try a change on a test worker |
| **CI** | [`.github/workflows/ci.yml`](.github/workflows/ci.yml) — validation only, no Azure access |
| **Release** | [`.github/workflows/release.yml`](.github/workflows/release.yml) — packages the module for worker installation |
| **Architecture** | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| **Azure resources** | [`docs/AZURE-RESOURCES.md`](docs/AZURE-RESOURCES.md) — what to build in Azure |
| **Installation** | [`docs/INSTALLATION.md`](docs/INSTALLATION.md) — start here |
| **Updating** | [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) |
| **Go-live checklist** | [`docs/PRODUCTION-CHECKLIST.md`](docs/PRODUCTION-CHECKLIST.md) |
| **Operations** | [`docs/RUNBOOK-OPERATIONS.md`](docs/RUNBOOK-OPERATIONS.md) |
| **Handover** | [`HANDOVER.md`](HANDOVER.md) — state of the work and the open points |
| **Decisions** | [`docs/DECISIONS.md`](docs/DECISIONS.md) — why things are as they are |
| **Work tracking** | [RMA 2.0 board](https://github.com/orgs/Mjolner-ServiceNow/projects/1) — every piece of work is an issue with an owner; see *Tracking work* in [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) |

## Why this repository exists

It replaces a library in which the same 200-line preamble was pasted into 63 runbooks. That
structure produced four defects the customer's engineers found in production:

| Defect | Now |
|---|---|
| No atomic job claim, so two runs could execute the same job | `Request-RmaJobClaim` sends a conditional update and verifies it won. **Not yet atomic:** ServiceNow ignores the condition, so this needs a server-side compare-and-set — see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#job-lifecycle) |
| 59 runbooks could strand a job with no terminal state | `Invoke-RmaQueueLoop` guarantees Completed or Failed via `try/finally`, with a watchdog behind it |
| Runtime `Install-Module` with no pinned version filled the worker's disk | Dependencies are `#Requires` assertions; provisioning is `scripts/Initialize-RmaWorker.ps1` |
| Module install ran before any configuration was validated | `#Requires` at parse time, then `Test-RmaPrerequisite` cheapest-check-first |

Secrets are gone too: the workload authenticates with a user-assigned managed identity,
federated to the app registration. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Local development

Requires PowerShell 7.2+, and Pester 5.5+ / PSScriptAnalyzer 1.25+ for the build scripts.

```powershell
./build/Invoke-Format.ps1                        # apply house formatting
./build/Invoke-Analysis.ps1 -FailOn Error,Warning # the gate CI runs
./build/Invoke-Tests.ps1                          # Pester with coverage
./build/Assert-Coverage.ps1 -Path ./tests/Coverage.xml -MinimumPercent 70
./build/Test-ModuleManifestIntegrity.ps1          # manifest vs reality
```

CI runs all of these on every pull request, with the formatter in `-Check` mode, plus
`build/Assert-ModuleVersionBump.ps1`, which fails a pull request that changes the module
without raising `ModuleVersion`. None of them touch Azure, so the workflow needs no secrets
and runs safely on forks.

## Runbooks

| Runbook | Started by | What it does |
|---|---|---|
| [`Create-EntraUser`](src/runbooks/Create-EntraUser.ps1) | The ServiceNow application, per request | The reference command runbook. A new command runbook starts as a copy of it. |
| [`Invoke-RmaQueueWatchdog`](src/runbooks/Invoke-RmaQueueWatchdog.ps1) | The ServiceNow application, on a cadence, per domain | Requeues jobs stranded in Work in Progress |
| [`Test-RmaHealth`](src/runbooks/Test-RmaHealth.ps1) | The ServiceNow application | Proves every dependency end to end and reports the result to ServiceNow |

The rest of the previous library's runbooks, including the live `Import-Entra*` commands,
are not migrated yet. See [`HANDOVER.md`](HANDOVER.md).

## Writing a runbook

Every runbook is the same setup plus a body. Copy
[`src/runbooks/Create-EntraUser.ps1`](src/runbooks/Create-EntraUser.ps1); this is an abridged
view of it:

```powershell
#Requires -Modules @{ ModuleName = 'RMA.Runbooks'; RequiredVersion = '2.1.0' }

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSStyle.OutputRendering = 'PlainText'   # the job pane prints ANSI codes literally

$context = Test-RmaPrerequisite -Instance $Instance -VaultName $VaultName `
    -ManagedIdentityClientId $ManagedIdentityClientId -ServiceNowUserName $ServiceNowUserName

$summary = Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Your-Command' -Body {
    param($job, $p)
    # Business logic only. Throw to fail the job; return normally to complete it.
}

Write-Output ($summary | Format-List | Out-String)
if ($summary.Failed -gt 0) { throw "$($summary.Failed) job(s) failed." }
```

The final `throw` is what makes the Automation job itself show as failed when any queue job
did. `tests/Unit/RunbookDefinition.Tests.ps1` rejects a runbook with parameter sets, without
the `PlainText` line, or calling a module function that is not exported.

Claiming, the heartbeat, terminal state, retry, bounds, correlation and redaction are
handled for you. Do not reimplement them.

## Rules the pipeline enforces

Five custom analyzer rules in [`build/rules`](build/rules), each written against a defect
that reached production:

- `RmaAvoidEmptyCatchBlock`
- `RmaAvoidRuntimeModuleInstall`
- `RmaRequirePinnedModuleVersion`
- `RmaAvoidScriptScopeReturn`
- `RmaAvoidUnredactedObjectLogging`

Run against the previous library they produce 235 findings. Suppressions are allowed but
must carry a `Justification`.

## Licence

[MIT](LICENSE). The customer may deploy, adapt and redistribute this in their own tenant.
See [`NOTICE.md`](NOTICE.md).
