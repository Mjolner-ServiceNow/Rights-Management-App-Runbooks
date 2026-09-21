# Contributing

## Before you open a pull request

```powershell
./build/Invoke-Format.ps1
./build/Invoke-Analysis.ps1 -FailOn Error,Warning
./build/Invoke-Tests.ps1
./build/Assert-Coverage.ps1 -Path ./tests/Coverage.xml -MinimumPercent 70
./build/Test-ModuleManifestIntegrity.ps1
```

CI runs all five and will not merge without them, plus a check that `ModuleVersion` was
bumped when the module changed. CI has no Azure access, so it runs on forks and
first-time contributors without exposing anything.

From a shell rather than inside a `pwsh` session, use the `-Command` form for
`Invoke-Analysis.ps1`: `pwsh -File` passes `-FailOn Error,Warning` as one literal string.
`-FailOn` validates its input, so that mistake now fails loudly instead of passing the
build.

## Rules

**Never reimplement queue handling.** Claiming, terminal state, retry, bounds, correlation
and redaction live in `RMA.Runbooks`. A runbook that does its own is rejected in review.
That duplication is exactly what produced the defects this repository exists to fix.

**Bump `ModuleVersion` when you touch the module,** in the manifest and in the
`#Requires` `RequiredVersion` of every runbook. Deployment pins by version, so an unbumped
change cannot be rolled out or rolled back, and a worker that already has that version
will not pick up a different build of it. `build/Assert-ModuleVersionBump.ps1` enforces
this on every pull request.

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

Keep real subscription ids, resource ids and instance names in a `*.local.json`, which is
gitignored. Nothing in CI checks this now that the infrastructure templates are gone, so it
is a review responsibility.

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
