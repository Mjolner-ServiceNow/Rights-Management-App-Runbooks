# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

ServiceNow-driven automation runbooks for Active Directory and Entra ID, and the shared
PowerShell module they run on. PowerShell 7.2 is the floor. The repository is public and
holds no credentials. There is no infrastructure-as-code here: the Azure resources are
provisioned by hand for now, and the Bicep that used to live in `infra/` was removed
because it did not meet the bar. Do not re-add it without being asked.

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

Two more, both now also run by CI (see *Where enforcement actually lives*):

```powershell
./build/Test-ModuleManifestIntegrity.ps1              # Public/ functions vs FunctionsToExport, and help
./build/Assert-ModuleVersionBump.ps1 -BaseRef main    # pull requests only
```

### A single test

`Invoke-Tests.ps1` takes `-Tag`, which is how integration tests are excluded by default.
For one file or one `It`, call Pester directly:

```powershell
Invoke-Pester -Path ./tests/Unit/Logging.Tests.ps1
Invoke-Pester -Path ./tests/Unit/Logging.Tests.ps1 -FullNameFilter '*redact*'
```

CI installs Pester 5.8.0. `Invoke-Tests.ps1` caps itself with
`-MaximumVersion 5.99.99` and prints the version it loaded, so a machine that also has
Pester 6 still runs the suite on 5.x. Calling `Invoke-Pester` directly, as above, does not
get that cap — add `Import-Module Pester -MaximumVersion 5.99.99` first if a test behaves
oddly.

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
`Test-ModuleManifestIntegrity.ps1` checks both from the AST, per function rather than per
file, locally and in CI. A helper only the module calls goes in `Private/`, where neither
requirement applies.

### One identity, and the constraint that governs everything

A single user-assigned managed identity on the Hybrid Worker VM reads Key Vault and acts as
the app registration through a federated credential. There are no client secrets.

**The Automation Account must have no managed identity of its own.** Enabling one overrides
the Hybrid Worker VM's identity and breaks authentication everywhere. Nothing enforces this
now that the templates are gone — it is set by hand at provisioning time and named in
`Test-RmaPrerequisite`'s diagnostic. If authentication worked yesterday and does not today,
check this first.

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

Both gaps the docs used to overstate are now wired in
([.github/workflows/ci.yml](.github/workflows/ci.yml), job `module`):

- **`Test-ModuleManifestIntegrity.ps1` runs in CI.** It reads functions from the AST, so a
  second function defined inside a file named after another one is caught, and it checks
  `.SYNOPSIS` and `[CmdletBinding()]` per function rather than once per file.
- **`Assert-ModuleVersionBump.ps1` runs on every pull request.** If anything under
  `src/RMA.Runbooks` changed against the merge base with the target branch, `ModuleVersion`
  must be greater. `release.yml` still compares the `v*` tag against the manifest at
  release time; that is now a backstop rather than the first time anyone finds out.

One thing is still checked only by eye: nothing automated rejects customer-identifying
values in committed files. See *This repository is public* below.

## Releases are drafted automatically and published by hand

[release.yml](.github/workflows/release.yml) has two entry points, and
[build/Get-RmaReleasePlan.ps1](build/Get-RmaReleasePlan.ps1) is what tells them apart. A
push to `main` whose `ModuleVersion` has no release yet **drafts** one, package and SHA256
attached; a pushed `v*` tag **publishes**. Most pushes to `main` produce nothing, because a
release for that version already exists.

The last step stays human on purpose. A release here is not a marker — it is the artefact
somebody installs on every Hybrid Worker by hand, after which the runbooks have to be
republished. `Assert-ModuleVersionBump.ps1` requires a bump on every pull request that
touches the module, so publishing automatically would put out one release per module pull
request and let release cadence follow merge tempo rather than whether the fleet is ready.
A draft holds its `tag_name` without creating the tag, so nothing is public until someone
clicks Publish.

Clicking Publish creates the tag, and that tag push runs `release.yml` again. The plan
therefore never rebuilds a release that exists: v2.0.0's zip was rebuilt at that moment,
and since `Compress-Archive` stores checkout timestamps, its hash no longer matched the
notes people had copied. `New-RmaModulePackage.ps1` now writes the zip itself, in ordinal
order with a fixed timestamp. Do not put `Compress-Archive` back.

## This repository is public

Nothing may identify a customer: ServiceNow instance names, tenant or subscription IDs,
internal hostnames or IP ranges, real `sys_id` values. Fixtures use `contoso` and synthetic
GUIDs.

Real values belong in a `*.local.json`, which is gitignored. The CI check that rejected
Azure resource ids in committed parameter files went with the Bicep — until infrastructure
returns, nothing automated guards this, so check it by hand in review.

## Writing PowerShell here

The `powershell-7-expert` skill in `.claude/skills/` carries the house rules for modern
PowerShell 7 — error handling, function design, parallelism, REST integration, testability
and secret handling — with `references/house-rules.md` holding this repository's specifics.
Invoke it when writing or reviewing PowerShell.

## Trying a change on a real worker

`scripts/Invoke-RmaWorkerRun.ps1` runs a runbook or a script block from the working tree on
a test Hybrid Worker, through an Azure Bastion tunnel, before anything is pushed. Its
connection details and runbook parameters live in the gitignored `rma-worker.local.json`.
It needs Bastion on Standard or Premium with native client support switched on. Invoke the
`test-on-hybrid-worker` skill before using it. The skill has the prerequisites, the rules
(never guess a ServiceNow value, test environments only) and the traps.
