# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **Every module function that logged at Information and then returned a value returned
  the log line as well.** `Write-RmaLog` wrote Information records with `Write-Output`,
  which is the success stream, so `Connect-RmaServiceNow` handed back
  `@($line, $context)` and `Test-RmaPrerequisite` failed on `$context.BaseUri` under
  StrictMode. `Test-RmaPrerequisite`, `Connect-RmaGraph`, `Connect-RmaExchange`,
  `Set-RmaJobState` and `Invoke-RmaQueueLoop` all log before they return, so every
  runbook was affected, not only the health check. Information now goes to the
  information stream. The unit tests had mocked `Write-RmaLog` away wherever a return
  value was checked, which is why none of them saw it; `tests/Unit/Logging.Tests.ps1` now
  runs `Connect-RmaServiceNow` against the real logger.
- `Test-RmaHealth` could not be started: Azure Automation rejects a runbook that declares
  parameter sets (*"Parameter sets in runbooks are not supported in this release"*), and
  2.0.0 gave it three. The Entra ID pair and the Active Directory pair are now ordinary
  optional parameters, and the script body enforces what the sets did: at least one
  whole pair, half a pair fails the job naming the missing half, and `AdSecretName`
  without the AD pair is refused. `tests/Unit/RunbookDefinition.Tests.ps1` fails any
  runbook in `src/runbooks` that declares a parameter set.
- `Test-RmaHealth` could never pass. Under `Set-StrictMode -Version Latest`, reading a
  property through an empty collection throws, and it did so twice: the queue check read
  `.Count` of `Get-RmaPendingJob`'s result, which is nothing at all when the queue is empty
  (the normal state, since nothing queues `Test-RmaHealth` jobs), and the summary read
  `.Check` of the failed checks, which is empty when every check passes. Both are in 1.2.0
  and 2.0.0.
  `tests/Unit/Test-RmaHealth.Tests.ps1` now runs the script against mocks instead of
  reading its metadata, which is how both surfaced.
- A failed `Test-RmaHealth` was close to unreadable in the Automation job pane, which
  hid the one line that mattered. `Format-Table` cut each check's detail at the pane's
  width, so a Key Vault failure stopped at `(HTT.` before its status code. The failed
  summary was logged at Error as well as thrown, so the pane interleaved two error records
  with the table. And the pane prints ANSI escape codes literally, so both were wrapped in
  colour sequences. Each check is now one line with its full detail below it, the summary
  is logged at Information, and every runbook sets `$PSStyle.OutputRendering` to
  `PlainText`, which `tests/Unit/RunbookDefinition.Tests.ps1` requires.
- An array in a log record's `data` changed JSON type with its length. The redactor
  returned arrays unwrapped, so PowerShell unrolled them: an empty array was logged as
  `null` and a one-element array as a bare value. `Test-RmaHealth`'s `checks` was a string
  for a domain with one directory and an array for a domain with both, so a KQL
  `mv-expand` over it gave different results by domain. Arrays are now always logged as
  arrays.

### Changed
- The runbooks require `RMA.Runbooks` 2.0.1. Install it on every Hybrid Worker before
  republishing them.

## [2.0.0] - 2026-09-24

### Added
- `docs/AZURE-RESOURCES.md` specifies ServiceNow's own app registration, which the
  application uses to publish runbooks and start jobs: Automation Contributor on the
  Automation Account only, no API permissions, and a credential that expires. The
  runbooks' app registration is now named as such, and the checklist's "no client secret"
  item says which of the two it means.
- `docs/AZURE-RESOURCES.md`, the specification of what to build in Azure: three resource
  groups (`rg-rma-automation-prod`, `rg-rma-shared-prod`, `rg-rma-workloads-prod`), every
  resource in them, the settings each one requires, the app registration's federated
  credential and API permissions, and the order to build them in. Every name ends in its
  environment. `INSTALLATION.md` step 1 now points at it
  instead of carrying its own shorter list, and the examples throughout use its names.

### Changed
- **Breaking: every configuration value is now a runbook parameter**, and the runbooks read
  nothing from ServiceNow but the command queue. The ServiceNow application already holds
  these values when it starts a job, so reading the domain record back at the start of
  every run cost a REST call and a failure point, and needed read access to one more
  table. The ServiceNow application and the workers must move to 2.0.0 together.
  - `Create-EntraUser` takes a new mandatory `TenantId`. `TenantId`, `ApplicationId` and
    `ManagedIdentityClientId` must be GUIDs, checked when the job binds its parameters
    rather than at token exchange.
  - `Test-RmaHealth` replaces `-IncludeActiveDirectory` with three parameter sets, one
    per combination of directories: `TenantId` and `ApplicationId` run the Graph check,
    `DomainController`, `AdUserName` and an optional `AdSecretName` run the AD check, and
    at least one pair is required. A domain with Entra switched off can therefore still be
    health-checked. The AD check now signs in with the AD service account from Key
    Vault instead of reading the RootDSE anonymously, so a wrong username or an expired
    password fails the health check rather than the first real job. The *Key Vault + ServiceNow + domain
    record* check is now *Key Vault + ServiceNow*.
  - `Test-RmaPrerequisite` loses `-DomainId` and `-RequireDomainField`, and its context no
    longer carries `DomainId` or `Domain`.
  - `Connect-RmaGraph` and `Connect-RmaExchange` take a mandatory `-TenantId` instead of
    reading it from the context.
  - `ARCHITECTURE.md` has a new *Runbook parameters* section listing every parameter, the
    ServiceNow domain record field it comes from, and why passwords, and only passwords,
    stay out of them.

### Removed
- `Get-RmaDomainConfig`. Nothing reads the domain record any more.
- Log Analytics, diagnostic settings, action groups and alert rules from the documentation.
  None of them is needed for the runbooks to run, and the ServiceNow application already
  tracks the status of every runbook job and flags the ones that fail.
  `RUNBOOK-OPERATIONS.md` now reads the job output in the Automation Account instead of
  querying Log Analytics, and describes each non-clean outcome by the stop reason or
  message a run logs rather than by an alert name. The checklist loses its Monitoring
  section.

### Fixed
- `docs/DEPLOYMENT.md` said to provision the workers before the runbooks, and why, but not
  what a mismatch looks like or what it costs. Both are now written down: `#Requires` is a
  parse-time directive, so the runbook body never runs, `Invoke-RmaQueueLoop` is never
  reached, no claim is attempted and queue rows stay at `status = 1` — a version mismatch
  postpones work rather than creating any. The error text is included verbatim because it
  says the module is **missing** even when it is installed and only the version differs,
  which sends whoever reads it looking for a failed installation.

## [1.2.0] - 2026-09-22

### Changed
- `Invoke-RmaQueueLoop` polls a batch of rows per request instead of one, and enters the
  batch at a random offset. Polling one row at a time made every worker contend for the
  same head of the queue: one won and the rest lost, every time, so adding workers raised
  the wasted-PATCH rate without raising throughput. Worse, a worker that kept losing the
  head row never reached the rows behind it and stopped with `claim-contention` having
  processed nothing while the queue was full — measured in `Invoke-RmaQueueLoop.Tests.ps1`,
  which runs the same fixture at `-BatchSize 1` (0 jobs done) and `-BatchSize 10` (5).
  New `-BatchSize` parameter, default 20; `Get-RmaPendingJob` already accepted up to 100
  and is unchanged.

- **Behaviour change:** `MaxConsecutiveSkips` now counts consecutive *batches* in which a
  claim was attempted and none was won, not individual lost claims, and its default drops
  from 25 to 5. Under batching the old meaning was actively misleading — losing most of a
  batch and winning the rest is a healthy outcome, and would have exhausted the budget
  within a single poll. The parameter name is unchanged, so no caller breaks; callers that
  pass an explicit value should divide it by roughly their batch size.

  Rows too malformed to claim now back the loop off without counting toward the ceiling,
  so a bad row can no longer be reported as contention. The stop stays bounded by
  `MaxMinutes`, as before.

  `MaxJobs` and `MaxMinutes` are now also checked between rows of a batch, so a large
  `BatchSize` cannot overshoot either cap.

### Added
- The release notes carry a second, clearly separate command for `-PruneUnpinned`.
  Pruning was documented only in `docs/INSTALLATION.md` and appeared in neither
  `docs/DEPLOYMENT.md`'s upgrade steps nor the block people now paste, so on the easiest
  path nothing was ever cleaned up — while the accumulation it prevents is the incident
  this repository was built around. It is kept out of the main block on purpose: it
  uninstalls things, and a destructive step does not belong in a command people run
  without reading.
- `Initialize-RmaWorker.ps1` ships as a release asset beside the module it installs, and
  the release notes carry a generated block that downloads it, checks its SHA256 and runs
  it against the verified package. A worker needs no checkout and no copied files.

  Deliberately not `iex (irm ...)`. `#Requires` is a parse-time directive for script files
  and is ignored when the text runs through `Invoke-Expression` — measured: a script with
  `#Requires -Version 99.0` is refused as a file and runs anyway through `iex` — so
  `-RunAsAdministrator` and `-Version 7.2` would both stop being enforced. Parameters
  cannot be passed that way either: `iex "$text -ModuleSource ..."` runs the body with its
  defaults and reports the error afterwards, having already installed modules. And a
  branch URL is mutable, so two workers provisioned a week apart would get different
  scripts, which is the opposite of what the version pinning here is for.
- `tests/Unit/ReleasePackage.Tests.ps1`, asserting that each published hash matches the
  artefact it describes and that the shipped script is byte-identical to the source. The
  hash in the notes is the only thing between a worker and a substituted payload.
- `build/Get-RmaReleasePlan.ps1` and a second entry point in `release.yml`. A push to
  `main` whose `ModuleVersion` has no release yet now **drafts** one, with the package and
  its SHA256 attached; a pushed `v*` tag still publishes. The last step stays human on
  purpose: a release here is not a marker but the artefact somebody installs on every
  Hybrid Worker by hand, and since `Assert-ModuleVersionBump.ps1` requires a bump on every
  module pull request, publishing automatically would put out one release per pull request
  and let release cadence follow merge tempo rather than whether the fleet is ready. A
  draft holds its `tag_name` without creating the tag, so nothing is public until someone
  publishes it. Covered by `tests/Unit/ReleasePlan.Tests.ps1`.
### Removed
- `scripts/Publish-RmaContent.ps1`. The ServiceNow app pulls the runbooks from this
  repository into the Automation Account, so the script published nothing anybody ran.

  The one safety property it carried — refusing to publish a runbook whose pinned
  `RMA.Runbooks` version disagrees with the module in the repository — is not lost; it
  moved earlier. `tests/Unit/PinnedModuleVersions.Tests.ps1` asserts the same thing in CI
  on every pull request, which matters more now, because the app publishes whatever is on
  `main` and `main` being self-consistent is the last check there is.

  What the script knew about Runtime environments is kept in `docs/INSTALLATION.md`, as a
  requirement on whatever does the importing rather than as a feature of a script: 7.4 and
  7.6 exist only in that experience, `-Type` stops at `PowerShell72`, the API refuses a
  `runtimeEnvironment` on a `PowerShell72` runbook, runbook type is immutable through PUT
  so a migration needs a PATCH first, and importing as a Draft keeps the live version
  serving if the import fails.

### Fixed
- **`docs/INSTALLATION.md` is now scoped to Azure only.** Setting up the ServiceNow
  application has its own guide, maintained outside this repository, and this one was
  duplicating part of it: step 1 had the reader confirm the application version, populate
  the domain record and check the integration account's permissions. That step is removed
  and the remaining nine renumbered.

  The guide now opens with a scope note saying to read the ServiceNow guide first, names
  the three values it produces (domain record sys_id, instance name, integration account
  username) in *Values to record*, and drops the ServiceNow administrator from the roles
  table because none of their work happens here. The two guides are to be merged into one
  end-to-end document once the solution is settled.

  `PRODUCTION-CHECKLIST.md`'s ServiceNow section is now a pointer to that guide and
  verifies nothing itself. The Azure-side consequence is still covered: the
  duplicate-execution test in section 7 proves the job claim works end to end, which is the
  behaviour that depends on the queue columns and on the conditional `PATCH` being atomic,
  so a ServiceNow-side problem still surfaces here rather than in production.
- **The installation guide described a scheduled design that was never how this works.**
  Every job is event-driven: ServiceNow writes a queue row and starts the runbook job that
  drains it. Step 10 had the customer create Azure Automation schedules for each runbook
  plus four offset hourly ones for the watchdog; all of it is removed, and the section now
  explains the event-driven flow and says to delete any schedules found in an existing
  installation, because a schedule competing with the application doubles claim contention
  for no gain.

  The same assumption was load-bearing in five other places and is corrected in each:
  `ARCHITECTURE.md`'s throughput formula (`workers × jobs-per-run ÷ schedule-interval`, of
  which the last term no longer exists), the emergency stop and drain procedure in
  `DEPLOYMENT.md`, the "stop everything" and alert-response guidance in
  `RUNBOOK-OPERATIONS.md`, two checklist items in `PRODUCTION-CHECKLIST.md`, and the
  docstrings of `Invoke-RmaQueueWatchdog.ps1` and `Test-RmaHealth.ps1`.

  The batched poll from the previous entry is unaffected, and matters more under this
  model rather than less: concurrency is now set by request arrival rather than by a worker
  count anyone configures, so overlapping runs are the normal case.
- Step 1 had the customer add `worker_id` and `claimed_at` to the command queue table by
  hand. They ship with the scoped application and arrive when it is updated. What is left
  in step 1 is the configuration only the customer can supply: the domain record and the
  integration account.
- Step 8 was headed *Publish the runbooks* under "Who: Contributor on the Automation
  Account", though its own body already said the application publishes them. The customer's
  only task there is creating the PowerShell 7.6 Runtime environment for the application to
  link them to.
- Step 9 had the customer trigger the health check by hand. The application runs it and
  surfaces the result in ServiceNow. The manual invocation is kept, demoted to what it
  actually is: a diagnostic for when the ServiceNow-side view is the thing that is broken.
- `docs/INSTALLATION.md` specified `claimed_at` as String (64). It must be a Date/Time
  field: `Invoke-RmaQueueWatchdog` queries it with the `RELATIVELT@minute@ago@` operator,
  and a date operator does not behave reliably against a string column. Caught before the
  column was built, which is the only reason it is a documentation fix rather than a
  migration.
- The `worker_id` / `claimed_at` blocker in `docs/PRODUCTION-CHECKLIST.md` and
  `docs/INSTALLATION.md` understated its own effect. It said the duplicate-execution
  protection would not work; in fact **nothing runs at all**. The Table API ignores unknown
  fields silently, so the claim `PATCH` appears to succeed and moves the row to Work in
  Progress, but the read-back finds no `worker_id`, every claim is lost, and rows strand
  with no terminal state. The difference matters: one reads as a missing safety net, the
  other as a full stop that also dirties the queue.
- `docs/ARCHITECTURE.md`'s scaling section implied that adding workers raises throughput
  because the claim makes it safe. The claim makes it *correct*; the batched poll is what
  makes it faster. Both are now stated, with `BatchSize` added as a fourth lever.
- The `job-claim-contention` response in `docs/RUNBOOK-OPERATIONS.md` described only one of
  its three causes. A ServiceNow instance failing every `PATCH` produces an identical
  summary to ordinary contention and is not harmless; the entry now separates them and says
  which log line tells them apart.
- `Initialize-RmaWorker.ps1 -WhatIf` failed on the URL path. The staging directory is
  created with `New-Item`, which honours `-WhatIf`, so it was never created, the download
  had nowhere to land, and the preview died on
  `Could not find a part of the path ...\package.zip`. The scratch operations inside that
  temp directory now run with `-WhatIf:$false`; the state changes `-WhatIf` is actually
  about stay behind `ShouldProcess`. Found by testing the `-WhatIf` advice in the new
  release notes before publishing it.

### Added (continued)
- `tests/Unit/PinnedModuleVersions.Tests.ps1` asserts that every runbook's `RMA.Runbooks`
  `RequiredVersion` matches the manifest. `Assert-ModuleVersionBump.ps1` requires the
  manifest to move but not the three `#Requires` lines that have to move with it, so a
  half-done bump passed CI and was caught only later by `Publish-RmaContent.ps1` — or
  would have produced a drafted release no runbook refers to.

## [1.1.0] - 2026-09-21

First release of the shared module. Everything below shipped in 1.0.0's development and
in the review that followed it; 1.1.0 is the first version a Hybrid Worker installs.

### Added
- `build/Assert-ModuleVersionBump.ps1`, run by CI on every pull request. If anything under
  `src/RMA.Runbooks` changed against the merge base, `ModuleVersion` must be greater.
  CONTRIBUTING.md claimed CI enforced this; the only check was in `release.yml` at tagging
  time, so an unbumped change passed pull-request CI and failed later in front of whoever
  was cutting the release. `Test-ModuleManifestIntegrity.ps1` is in the same new CI job,
  having also been documented as enforced while running only by hand.
- `tests/Unit/Identity.Tests.ps1`. `Get-RmaImdsToken`, `Test-RmaPrerequisite`,
  `Connect-RmaGraph` and `Connect-RmaExchange` were all at 0% line coverage — the identity
  path, which is the constraint the whole design turns on, was the one part with no tests,
  and the coverage floor was met on the back of the queue logic. Covers the `client_id`
  that stops IMDS returning the VM's system-assigned identity, the Automation sandbox
  branch, token cache isolation between tenants, the context contract between
  `Test-RmaPrerequisite` and the two Connect functions, and that Graph is handed a
  `SecureString` rather than a raw token. Line coverage is 92.9%, from 73.2%.
- `-ExpectedSha256` on `scripts/Initialize-RmaWorker.ps1`.
- `-MaxConsecutiveSkips` on `Invoke-RmaQueueLoop`.
- `tests/Unit/RmaRules.Tests.ps1`. The five custom analyzer rules are the gate's teeth and
  had no tests of their own; a rule that quietly matches nothing lets the build go green
  while the defect it exists to stop walks through. The CI test job now installs
  PSScriptAnalyzer so it can run them.
- `RMA.Runbooks` shared module replacing the per-runbook preamble.
- Atomic job claim (`Request-RmaJobClaim`) so a queued job can only be executed once.
- Guaranteed terminal state via `Invoke-RmaQueueLoop`, closing the stranded-job defect.
- Bounded queue loop with iteration and wall-clock limits.
- Structured logging with a correlation id per job.
- CI pipeline: PSScriptAnalyzer with custom rules, Pester and a coverage floor.
- Watchdog runbook that requeues jobs stranded in Work in Progress.
- `tests/Unit/PinnedModuleVersions.Tests.ps1`, asserting that every `RequiredVersion` a
  runbook declares matches what `Initialize-RmaWorker.ps1` installs, that the provisioner
  installs every third-party module the runbooks require, and that the Graph submodules stay
  on one version. The first two lists moved independently during the 7.6 upgrade, which
  would have failed every job at parse time.
- `scripts/Initialize-RmaWorkerHost.ps1`, which installs PowerShell 7.6 and sets the machine
  environment variable the Hybrid Worker extension uses to locate `pwsh.exe`. Without that
  variable a worker registers and reports healthy but starts no PowerShell 7 job, and
  `Initialize-RmaWorker.ps1` cannot set it because it requires PowerShell 7 to run at all.
  Older runtime version names are registered as aliases by default so runbooks can move to
  7.6 one at a time; `-SkipLegacyPaths` turns that off once they all have.

### Changed
- Modules are declared with `#Requires` and pinned versions instead of installed at run time.
- Runbooks are published on **PowerShell 7.6** instead of 7.2. 7.6 is the current PowerShell
  LTS, supported until 14 November 2028; 7.2 is already out of support in PowerShell and
  retires in Azure Automation on 30 September 2026, and 7.4 leaves support on 10 November 2026.
- `Publish-RmaContent.ps1` selects the interpreter through a **Runtime environment** rather
  than the `PowerShell72` runbook type, because 7.4 and 7.6 exist only in that experience:
  `Import-AzAutomationRunbook` stops at `PowerShell72` and the API rejects a
  `runtimeEnvironment` on a `PowerShell72` runbook. The `-RunbookType` parameter is replaced
  by `-RuntimeEnvironmentName` and `-RuntimeVersion`, and the named Runtime environment is
  verified to exist and be the expected version before anything is published. Runbooks
  published earlier as `PowerShell72` are migrated in place, since runbook type is immutable
  through PUT but can be changed by PATCH in the same call that sets the Runtime environment.
- Secrets move from Automation credential assets to Key Vault, read via managed identity.
- Pinned module set moved to `Microsoft.Graph.* 2.39.0` and `ExchangeOnlineManagement 3.10.1`,
  with the matching `#Requires` in the runbooks and the floor in `Set-RmaAppRegistration.ps1`.
  Graph submodules must share a version: they share `Microsoft.Graph.Core` and the
  Authentication module's assemblies, and a mixed set fails as missing cmdlets.
- `Microsoft.Graph.Beta.Users` is no longer installed. Nothing calls a `Get-MgBeta*` cmdlet,
  so no Beta submodule is needed at all; the docs and the production checklist no longer ask
  for one.

### Documentation
- `docs/INSTALLATION.md`: complete first-time setup guide for the customer, with the roles
  required at each step, the values to carry between steps, and a troubleshooting section
  organised by symptom.
- `docs/DEPLOYMENT.md` narrowed to updating an existing installation, so the two documents
  do not drift.
- `docs/INSTALLATION.md` step 4 split into host provisioning and module provisioning, and
  documents Azure Run Command as the way to reach a worker with no public IP. Run Command
  executes as local SYSTEM, the account the jobs use, so it cannot install to the wrong
  profile. Added a troubleshooting entry for a PowerShell 7 job that never starts.

### Fixed
- Responses are read through `Get-RmaProperty` everywhere, not almost everywhere. The
  helper exists because ServiceNow, IMDS and Graph are all shape-variable and an unguarded
  read throws under `Set-StrictMode -Version Latest`, but nine call sites still read
  directly. The worst was `$job.sys_id` in `Invoke-RmaQueueLoop`, outside the try/finally:
  one malformed row threw out of the loop and abandoned every remaining job. A row without
  a `sys_id` is now skipped and logged, and a row without an `input` payload fails that one
  job with a message naming the field.
- Two context shapes travelled through the module under one parameter name and one type,
  so passing the wrong one surfaced as a property-not-found far from the call.
  `Connect-RmaServiceNow` now returns an `Rma.ServiceNowContext` and `Test-RmaPrerequisite`
  an `Rma.Context` that also answers to the former, and each function declares which it
  takes with `[PSTypeName(...)]`. Handing `Connect-RmaGraph` a ServiceNow context now fails
  at parameter binding.
- `CustomRulePath` in `build/PSScriptAnalyzerSettings.psd1` never loaded the custom rules.
  A relative path in a settings file resolves against the current directory, so from
  anywhere but the repository root the run failed outright with "Cannot find path
  .../build/rules", and from the repository root the rules did not load at all — verified
  both ways. Removed; `build/Invoke-Analysis.ps1` passes `-CustomRulePath` explicitly,
  which is the mechanism that works. The `ExcludeRules` comment also described two rules
  other than the two excluded.
- `$env:COMPUTERNAME` is `[Environment]::MachineName`. The former is null off Windows, so
  the worker id in the log and in the claim read-back was `/local` on a Linux runner.
- `Join-Path $modulesRoot "RMA.Runbooks\$version"` had a literal backslash three lines
  below an explicit non-Windows branch. PowerShell normalises it, so this was style rather
  than a break, but the house rule says no literal separators and the file argued both
  ways at once.
- `[CmdletBinding()]` and validated parameters on `Add-Check`, `Invoke-AutomationApi` and
  `Invoke-RmaRequeue`, and `-ErrorAction Stop` on the `Invoke-RestMethod` inside
  `Get-RmaImdsToken`'s try.
- `Get-RmaAccessToken` could hand one tenant a token minted for another. The cache key was
  parameter set, resource and managed identity client id; `ApplicationId` and `TenantId`
  were missing, so two federated calls for the same scope through the same managed
  identity but a different app registration shared one entry. Multi-domain is the normal
  case here, which is what made this reachable.
- `Set-RmaAppRegistration.ps1` could not run with `-WhatIf` on a tenant where the
  application did not exist yet. The create was skipped, `$app` stayed `$null`, and the
  next line threw under `Set-StrictMode -Version Latest` — so the switch was unusable on a
  first run, which is exactly when you want to see what it would do. The reads that need a
  real object id are now skipped under `-WhatIf` and every planned operation is printed.
- OData string literals are escaped. `Set-RmaAppRegistration.ps1` interpolated
  `-DisplayName` and `Create-EntraUser.ps1` the payload's `username` straight into a
  `$filter`; a single quote — legitimate in a name like O'Brien — changed what the filter
  matched, which silently turned the idempotency check into no check. `username` is also
  validated against the local part Entra accepts, so a value carrying spaces or brackets
  is refused before it reaches Graph.
- `Initialize-RmaWorker.ps1` installs an unverified package no longer. `-ExpectedSha256`
  is checked before the archive is expanded; without it the script warns instead of going
  quiet. This is the one point where code from off the machine is written into
  `Program Files` as administrator, and the release already published a SHA256 that
  nothing compared. The release notes now show the verified form.
- `Get-RmaWorkerId` lived in `Public/Request-RmaJobClaim.ps1` and was never listed in
  `FunctionsToExport`, so it looked exported and was unreachable from a runbook. It is in
  `Private/` now. `Test-ModuleManifestIntegrity.ps1` could not see it because it compared
  file names; it now reads functions from the AST and checks `.SYNOPSIS` and
  `[CmdletBinding()]` per function rather than once per file.
- `build/Invoke-Tests.ps1` caps Pester with `-MaximumVersion 5.99.99` and prints the
  version it loaded. `#Requires -Modules @{ ModuleVersion = '5.5.0' }` is a floor, not a
  pin, so a machine with Pester 6 installed ran the suite on a different major version
  than CI's 5.8.0. The house rules said the version was pinned; it was not.
- `Invoke-RmaQueueLoop` polled without bound when it could not claim a job. A lost claim
  leaves the row Pending, so the next poll returns the same job; nothing incremented, so
  `MaxJobs` never applied, the empty-poll exit never triggered, and there was no sleep on
  that path. Measured at 90,637 polls in 60 seconds against a claim that always failed —
  and `Request-RmaJobClaim` returns `$false` precisely when ServiceNow is failing the
  PATCH, so the flood arrived when the instance was already struggling. Lost claims are
  now backed off, and `-MaxConsecutiveSkips` (default 25) stops the loop with
  `StopReason = 'claim-contention'`.
- `Write-RmaLog -Level Debug` discarded every record. It called
  `Write-Verbose $line -Verbose:$false`, which forces the preference off for that call, so
  no Debug record was reachable by any caller under any preference. Among them was
  'Job claim lost to another worker' — the one line that would have made the loop above
  visible in the job log. Debug now goes to the verbose stream and honours the caller.
- `build/Invoke-Analysis.ps1` reported success while Error findings were on screen.
  `-FailOn` took an unvalidated `[string[]]`, so under `pwsh -File` the literal string
  `Error,Warning` bound as one value that matched no severity. Verified against four Error
  findings, which the gate passed. `-FailOn` is now a `ValidateSet`, turning the silent
  pass into a binding failure.
- `RmaAvoidUnredactedObjectLogging` did not cover the variable names this repository uses.
  It matched `$ParameterObject` and `$Payload` from the previous library, but
  `Invoke-RmaQueueLoop` decodes the payload into `$parameters` and hands it to the body as
  `$p` — the name every runbook copies from `Create-EntraUser.ps1`. `Write-Output $p` with
  a password in it passed the gate. The name list now covers `$parameters`, `$p`, `$job`,
  `$response`, `$token` and `$assertion`.
- `Initialize-RmaWorker.ps1` could not run with `-WhatIf`, and silently skipped
  RSAT-AD-PowerShell without it. `ServerManager` has no PowerShell 7 build, so PowerShell 7
  loads it through the Windows PowerShell compatibility shim, which stages a proxy module
  with `Copy-Item`; under `-WhatIf` those copies are simulated, the module never loads, and
  `Get-WindowsFeature` fails. With `-ErrorAction SilentlyContinue` it returned `$null` and
  the script reported the feature already present while installing nothing. It now tests for
  the `ActiveDirectory` module, which is what the runbooks actually require, and verifies the
  module is discoverable after installing the feature.
- `.gitignore` coverage patterns were lowercase and would not have matched `Coverage.xml`
  on a case-sensitive filesystem, so CI on Linux could have committed test output.
- Corrected the scheduling guidance throughout. Azure Automation schedules cannot run more
  often than hourly; a 15 minute cadence needs four offset hourly schedules. The previous
  text asked for an interval the platform does not offer.
- `RMA.Runbooks` is installed on the Hybrid Worker by `Initialize-RmaWorker.ps1`, not
  imported into the Automation Account. An Automation Account module is available to Azure
  sandbox jobs only; a Hybrid Worker resolves modules from its own `PSModulePath`, so the
  earlier approach would have looked correct while every runbook failed at `#Requires`.
- `Publish-RmaContent.ps1` now refuses to publish a runbook whose pinned `RMA.Runbooks`
  version disagrees with the module in the repository.

### Removed
- `MSAL.PS` dependency.
- Runtime `Install-Module` calls.
- Module import into the Automation Account, and the staging storage account that served it.
