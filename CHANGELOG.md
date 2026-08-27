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

### Changed
- Modules are declared with `#Requires` and pinned versions instead of installed at run time.
- Secrets move from Automation credential assets to Key Vault, read via managed identity.

### Documentation
- `docs/INSTALLATION.md`: complete first-time setup guide for the customer, with the roles
  required at each step, the values to carry between steps, and a troubleshooting section
  organised by symptom.
- `docs/DEPLOYMENT.md` narrowed to updating an existing installation, so the two documents
  do not drift.

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
