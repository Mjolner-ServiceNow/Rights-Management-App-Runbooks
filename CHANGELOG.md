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

### Fixed
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
