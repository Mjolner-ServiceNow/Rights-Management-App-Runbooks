# Rights Management App — Runbooks

Automation runbooks that connect ServiceNow to Active Directory and Microsoft Entra ID,
and the shared PowerShell module they run on.

This repository holds no credentials and deploys nothing itself. The Azure resources the
runbooks need are provisioned by hand for now — there is no infrastructure-as-code here.
See [`docs/INSTALLATION.md`](docs/INSTALLATION.md) for what to create.

| | |
|---|---|
| **Shared module** | [`src/RMA.Runbooks`](src/RMA.Runbooks) — queue handling, identity, logging |
| **Runbooks** | [`src/runbooks`](src/runbooks) |
| **Scripts** | [`scripts`](scripts) — provision a worker, publish content, create the app registration |
| **CI** | [`.github/workflows/ci.yml`](.github/workflows/ci.yml) — validation only, no Azure access |
| **Release** | [`.github/workflows/release.yml`](.github/workflows/release.yml) — packages the module for worker installation |
| **Architecture** | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| **Installation** | [`docs/INSTALLATION.md`](docs/INSTALLATION.md) — start here |
| **Updating** | [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) |
| **Go-live checklist** | [`docs/PRODUCTION-CHECKLIST.md`](docs/PRODUCTION-CHECKLIST.md) |
| **Operations** | [`docs/RUNBOOK-OPERATIONS.md`](docs/RUNBOOK-OPERATIONS.md) |

## Why this repository exists

It replaces a library in which the same 200-line preamble was pasted into 63 runbooks. That
structure produced four defects the customer's engineers found in production:

| Defect | Now |
|---|---|
| No atomic job claim, so two runs could execute the same job | `Request-RmaJobClaim` performs a conditional update and verifies it won |
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
./build/Test-ModuleManifestIntegrity.ps1          # manifest vs reality
```

CI runs the first three on every pull request; run the manifest check yourself. None of
them touch Azure, so the workflow needs no secrets and runs safely on forks.

## Writing a runbook

Every runbook is the same eight lines of setup plus a body. Copy
[`src/runbooks/Create-EntraUser.ps1`](src/runbooks/Create-EntraUser.ps1).

```powershell
#Requires -Modules @{ ModuleName = 'RMA.Runbooks'; RequiredVersion = '1.0.0' }

$context = Test-RmaPrerequisite -Instance $Instance -DomainId $DomainId -VaultName $VaultName `
    -ManagedIdentityClientId $ManagedIdentityClientId -ServiceNowUserName $ServiceNowUserName

Invoke-RmaQueueLoop -Context $context -DomainId $DomainId -Command 'Your-Command' -Body {
    param($job, $p)
    # Business logic only. Throw to fail the job; return normally to complete it.
}
```

Claiming, terminal state, retry, bounds, correlation and redaction are handled for you.
Do not reimplement them.

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
