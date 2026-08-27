# Contributing

## Before you open a pull request

```powershell
./build/Invoke-Format.ps1
./build/Invoke-Analysis.ps1 -FailOn Error,Warning
./build/Invoke-Tests.ps1
```

CI runs the same three and will not merge without them. CI has no Azure access, so it runs
on forks and first-time contributors without exposing anything.

## Rules

**Never reimplement queue handling.** Claiming, terminal state, retry, bounds, correlation
and redaction live in `RMA.Runbooks`. A runbook that does its own is rejected in review.
That duplication is exactly what produced the defects this repository exists to fix.

**Bump `ModuleVersion` when you touch the module.** Deployment pins by version, so an
unbumped change cannot be rolled out or rolled back. CI enforces this.

**Never log a payload object.** Use `Write-RmaLog` with named fields. A payload can carry a
password, and one did.

**Never `Install-Module` in a runbook.** Declare it in `#Requires` and add it to
`scripts/Initialize-RmaWorker.ps1` with a pinned version.

**Suppressions need a justification.** A `SuppressMessageAttribute` without a real
`Justification` will be asked about in review.

## This repository is public

Do not commit anything that identifies a customer: ServiceNow instance names, tenant or
subscription IDs, internal hostnames or IP ranges, or real record sys_ids. Test fixtures use
`contoso` and obviously-synthetic GUIDs; keep it that way.

The files under `infra/` ending in `.parameters.<env>.json` are **templates** and must keep
their `REPLACE_WITH_` placeholders. Real values go in `.parameters.<env>.local.json`, which
is gitignored. CI fails the build if a committed template contains an Azure resource id.

## Adding a runbook

1. Copy `src/runbooks/Create-EntraUser.ps1`.
2. Change the `#Requires` set to what you actually call, nothing more.
3. Change the `-Command` string to the ServiceNow command name.
4. Write the body. Throw to fail the job; return normally to complete it.
5. Add an idempotency pre-check if a repeat execution would write twice.
6. Add a test if the body has branching logic worth protecting.

## Changing the shared module

Add a test first. The module is the blast radius for all 63 runbooks, and the coverage
floor exists to keep it that way.
