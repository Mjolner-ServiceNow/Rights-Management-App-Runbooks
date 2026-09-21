# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

ServiceNow-driven automation runbooks for Active Directory and Entra ID, the shared
PowerShell module they run on, and the Bicep for the Azure resources they need. PowerShell
7.2 is the floor. The repository is public and holds no credentials.

Read [README.md](README.md) for the component map, [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
for the identity and job-lifecycle design, and [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md)
for the review rules. This file covers what those leave implicit.

## Commands

The gate, in the order CI runs it. Run all of it before claiming a change is done:

```powershell
./build/Invoke-Format.ps1 -Check                  # omit -Check to apply formatting
./build/Invoke-Analysis.ps1 -FailOn Error,Warning
./build/Invoke-Tests.ps1                          # -CI for detailed output
./build/Assert-Coverage.ps1 -Path ./tests/Coverage.xml -MinimumPercent 70
```

Note the comma with no space in `-FailOn Error,Warning`. Under `pwsh -File`, arguments are
passed as raw strings and PowerShell never parses them into an array: `-FailOn Error, Warning`
binds `Warning` to `-Path`, and `-FailOn Error,Warning` arrives as one literal string that
matches no severity, so the gate reports success no matter what the analyzer found. From a
shell, use the `-Command` form:

```bash
pwsh -NoProfile -Command "& ./build/Invoke-Analysis.ps1 -FailOn Error,Warning"
```

Inside a `pwsh` session, and in `.github/workflows/ci.yml`, `-FailOn Error, Warning` is
parsed correctly. Do not "fix" the workflow to match this file.

Two more, not run by CI (see *Where enforcement actually lives*):

```powershell
./build/Test-ModuleManifestIntegrity.ps1   # Public/*.ps1 vs FunctionsToExport, and help
az bicep build --file infra/main.bicep
```

### A single test

`Invoke-Tests.ps1` takes `-Tag`, which is how integration tests are excluded by default.
For one file or one `It`, call Pester directly:

```powershell
Invoke-Pester -Path ./tests/Unit/Logging.Tests.ps1
Invoke-Pester -Path ./tests/Unit/Logging.Tests.ps1 -FullNameFilter '*redact*'
```

CI installs Pester 5.8.0. A machine with Pester 6 also installed will load 6 by default;
pin with `Import-Module Pester -MaximumVersion 5.99.99` if a test behaves oddly.

## Architecture

### The module owns the queue contract; runbooks own business logic only

A runbook is eight lines of setup plus a body — copy
[src/runbooks/Create-EntraUser.ps1](src/runbooks/Create-EntraUser.ps1). `Invoke-RmaQueueLoop`
wraps the body and guarantees the parts that went wrong in the library this replaces:

- `Request-RmaJobClaim` claims atomically — a conditional PATCH filtered on `status=1`,
  then a read-back comparing `worker_id` to its own. Two workers cannot run one job.
- `try`/`finally` guarantees a terminal state. Throwing from the body fails the job;
  returning normally completes it. Neither path can strand a job at In Progress.
- Correlation flows from the loop as `$script:RmaCorrelationId`, set to the ServiceNow job
  `sys_id` and cleared in `finally`. Do not invent your own.

A runbook that claims, retries, bounds or sets terminal state itself is rejected in review.
That duplication is the defect this repository exists to remove.

### Module loading and state

[RMA.Runbooks.psm1](src/RMA.Runbooks/RMA.Runbooks.psm1) dot-sources `Private/` before
`Public/` and sets `Set-StrictMode -Version Latest`, so undeclared variables are errors at
runtime, not silent nulls. `$script:RmaCorrelationId` and `$script:RmaTokenCache` are
module-scoped and deliberately unexported.

Every function in `Public/` must appear in `FunctionsToExport` in
[RMA.Runbooks.psd1](src/RMA.Runbooks/RMA.Runbooks.psd1) and must carry comment-based help.
`Test-ModuleManifestIntegrity.ps1` checks both — run it yourself; CI does not.

### One identity, and the constraint that governs everything

A single user-assigned managed identity on the Hybrid Worker VM reads Key Vault and acts as
the app registration through a federated credential. There are no client secrets.

**The Automation Account must have no managed identity of its own.** Enabling one overrides
the Hybrid Worker VM's identity and breaks authentication everywhere. It is asserted in
`infra/modules/automation.bicep`, re-checked by `scripts/Deploy-RmaPlatform.ps1` after
deployment, and named in `Test-RmaPrerequisite`'s diagnostic. If authentication worked
yesterday and does not today, check this first.

The VM also has a system-assigned identity that the Hybrid Worker extension creates
automatically, so IMDS requests must always pass `client_id` or they return the wrong
identity. The client ID and the principal ID are different GUIDs and are not
interchangeable — client ID for IMDS, principal ID for RBAC and the federated subject.

## Rules with teeth

Five custom PSScriptAnalyzer rules in [build/rules/RmaRules.psm1](build/rules/RmaRules.psm1),
each written against a defect that reached production. The code is the specification:

| Rule | Catches |
|---|---|
| `RmaAvoidEmptyCatchBlock` | a `catch` that discards the error |
| `RmaAvoidRuntimeModuleInstall` | `Install-Module` inside a runbook |
| `RmaRequirePinnedModuleVersion` | `Install-Module` without a pinned version |
| `RmaAvoidScriptScopeReturn` | a bare `return` at script scope, which exits the whole runbook |
| `RmaAvoidUnredactedObjectLogging` | logging a whole payload object |

Log with `Write-RmaLog -Level <level> -Message <string> -Data @{ named = $fields }`. It
redacts through `ConvertTo-RmaSafeLogValue`. Never pass a response or payload object whole —
one of them carried a password.

Dependencies are `#Requires` assertions, never runtime installs. New modules go in
`scripts/Initialize-RmaWorker.ps1` with a pinned version.

Suppressions are allowed but need a real `Justification`.

## Where enforcement actually lives

The docs overstate CI in two places. What CI actually runs is in
[.github/workflows/ci.yml](.github/workflows/ci.yml):

- **`Test-ModuleManifestIntegrity.ps1` is not in CI.** README says CI runs all five local
  commands; it runs four. An export missing from the manifest reaches `main`.
- **No `ModuleVersion` bump is enforced on a pull request.** CONTRIBUTING says CI enforces
  it. The only check is in `release.yml`, comparing the `v*` tag against the manifest at
  release time — so an unbumped module change passes PR CI and fails later, at tagging.

Treat both as things to check by hand until they are wired in.

## This repository is public

Nothing may identify a customer: ServiceNow instance names, tenant or subscription IDs,
internal hostnames or IP ranges, real `sys_id` values. Fixtures use `contoso` and synthetic
GUIDs.

`infra/*.parameters.<env>.json` are templates and must keep their `REPLACE_WITH_`
placeholders; real values belong in `*.local.json`, which is gitignored. CI fails the build
if a committed template contains an Azure resource id or a filled-in
`hybridWorkerVmResourceId`.

## Writing PowerShell here

The `powershell-7-expert` skill in `.claude/skills/` carries the house rules for modern
PowerShell 7 — error handling, function design, parallelism, REST integration, testability
and secret handling — with `references/house-rules.md` holding this repository's specifics.
Invoke it when writing or reviewing PowerShell.
