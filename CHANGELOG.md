# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `RMA.Runbooks` shared module replacing the per-runbook preamble.
- Atomic job claim (`Request-RmaJobClaim`) so a queued job can only be executed once.
- Guaranteed terminal state via `Invoke-RmaQueueLoop`, closing the stranded-job defect.
- Bounded queue loop with iteration and wall-clock limits.
- Structured logging with a correlation id per job.
- Bicep infrastructure for the Automation Account, Key Vault, managed identity and monitoring.
- CI pipeline: PSScriptAnalyzer with custom rules, Pester, Bicep lint and what-if.
- CD pipeline: environment-gated infrastructure and content deployment.
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

### Changed
- `infra/main.bicep` now targets the subscription and creates the resource group, then
  deploys the workload into it. The previous resource-group-scoped template required the
  group to exist first, which a template at that scope cannot create.
- `infra/workload.bicep` holds the resources and is still deployable directly into an
  existing resource group with `-WorkloadOnly`, for environments where Contributor on the
  subscription is not granted.

### Fixed
- The Automation Account could not be created. `identity: { type: 'None' }` is rejected by
  the Automation resource provider, which fails the deployment with the misleading
  `BadRequest: Could not find the account`. No identity is now expressed by omitting the
  property. Isolated by bisecting the request body: every other property is accepted.
- Scheduled query alerts could not be created against a new Log Analytics workspace.
  `AutomationJobLogs` and `AutomationJobStreams` do not exist until Automation sends data,
  and the rules validate their KQL at creation time. Added `skipQueryValidation: true`.
- The what-if delete gate produced a false positive on every plan. It matched a regex
  against the human-readable output, which begins with a legend containing the literal line
  `  - Delete`. It now reads `changeType` from `--no-pretty-print` JSON, and prints a
  grouped per-resource summary instead of the raw text.
- `Deploy-RmaPlatform.ps1` did not check the exit code of `az deployment what-if`. A failed
  what-if printed its error and the script deployed anyway, which defeated the purpose of
  having the gate.
- Added fail-fast checks for not being signed in, an inaccessible subscription, and a
  missing resource group, so those produce one clear line instead of an Azure CLI traceback.
- CI would have failed on the first pull request: the parameter-file check required
  production parameters to be filled in, which is correct for a private repository and
  wrong for a public one. Inverted, so it now fails if a committed template contains a real
  Azure resource id.
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
