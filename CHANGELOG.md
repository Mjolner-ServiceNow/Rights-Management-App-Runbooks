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

### Removed
- `MSAL.PS` dependency.
- Runtime `Install-Module` calls.
