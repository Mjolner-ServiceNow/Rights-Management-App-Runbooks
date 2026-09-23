# Production deployment checklist

Work top to bottom. Anything marked **BLOCKER** stops the release.

## 1. Code and pipeline

- [ ] CI green on the release commit: analyzer (0 findings at Error and Warning), 43+ Pester tests passing, coverage above the floor, manifest integrity passes (run it locally; it is not in CI)
- [ ] `ModuleVersion` in `RMA.Runbooks.psd1` bumped, and `CHANGELOG.md` updated **BLOCKER**
- [ ] Every analyzer suppression in the diff carries a `Justification` that a reviewer accepted
- [ ] Branch protection on `main`: no direct pushes, one approving review, CI required
- [ ] Release tagged, so a rollback target exists by name
- [ ] Repository reviewed for anything customer-identifying before it is made public: instance names, tenant or subscription IDs, internal hostnames, record sys_ids **BLOCKER**
- [x] `LICENSE` present (MIT) and the copyright line names the correct legal entity

## 2. Identity

- [ ] Resources built as [`AZURE-RESOURCES.md`](AZURE-RESOURCES.md) specifies: names, resource groups and every setting marked required
- [ ] Automation Account identity is **None** — `az automation account show --query identity.type`. Nothing automated asserts this; confirm by hand on every environment **BLOCKER**
- [ ] User-assigned managed identity attached to the Hybrid Worker VM
- [ ] Federated credential subject equals the identity's **principal** ID, not its client ID **BLOCKER**
- [ ] Federated credential issuer is `https://login.microsoftonline.com/{tenant}/v2.0`, audience `api://AzureADTokenExchange`
- [ ] App registration has exactly the API permissions listed in [`AZURE-RESOURCES.md`](AZURE-RESOURCES.md), **admin consent granted** **BLOCKER**
- [ ] Directory role assigned is **Exchange Recipient Administrator**, not Exchange Administrator or Global Administrator
- [ ] App registration has **no client secret and no certificate**. If one exists, delete it — a live secret is a live bypass of everything above
- [ ] Managed identity has `Key Vault Secrets User` and nothing more. Confirm it does **not** hold Secrets Officer

## 3. Key Vault

- [ ] `servicenow-api-password` and `ad-service-account-password` present, values verified against a real login
- [ ] Expiry dates set on both secrets, matching the passwords' own lifetimes, and someone owns renewing them
- [ ] Purge protection and 90-day soft delete on **BLOCKER**
- [ ] Public network access disabled, worker subnet allowed. Confirm from the worker: `Invoke-RestMethod https://<vault>.vault.azure.net/...` succeeds; confirm from elsewhere that it fails

## 4. Worker

- [ ] `Initialize-RmaWorker.ps1` run on **each** worker; module list matches the pinned set exactly
- [ ] If more than one worker: all of them provisioned identically. A worker missing the module fails every job routed to it, intermittently
- [ ] `Get-Module -ListAvailable Microsoft.Graph* | Group-Object Name` shows **one version per module** **BLOCKER**
- [ ] No `Microsoft.Graph.Beta*` module present; none is required
- [ ] `MSAL.PS` absent
- [ ] Free disk above 20 GB
- [ ] `RSAT-AD-PowerShell` installed and `Get-ADRootDSE` succeeds against the domain controller
- [ ] Worker registered in the Hybrid Worker Group and showing healthy
- [ ] Two workers if the queue justifies it. One is a single point of failure; the claim makes two safe

## 5. ServiceNow

Covered by the ServiceNow application's own guide, maintained outside this repository.
Complete it before working through this list.

Nothing on the ServiceNow side is verified here. The Azure-side consequences still are: the
**duplicate-execution test** in section 6 proves the job claim works end to end, which is
the behaviour that depends on the queue columns and on the conditional `PATCH` being atomic.
If that test fails, the cause is usually on the ServiceNow side rather than in anything this
repository ships.

## 6. Verification

- [ ] `RMA.Runbooks` installed on **every** worker in the group, at the version the runbooks pin — `Get-Module -ListAvailable RMA.Runbooks` **BLOCKER**
- [ ] It resolves from an AllUsers PowerShell 7 path (`C:\Program Files\PowerShell\Modules`), not a per-user one. Hybrid Worker jobs run as local SYSTEM **BLOCKER**
- [ ] Confirmed that `RMA.Runbooks` was **not** imported into the Automation Account, which would give a false impression that the dependency is met
- [ ] Every runbook shows as Published, not Draft
- [ ] `Test-RmaHealth` passes on the real worker for every domain, with the parameters of each directory that domain uses **BLOCKER**
- [ ] One real job end to end in each direction: an Entra create and an AD create
- [ ] **Duplicate-execution test:** queue one job, start the runbook twice concurrently. One must complete it; the other must log `Job claim lost to another worker`. **This is the defect the customer reported. Prove it is fixed.** **BLOCKER**
- [ ] **Stranding test:** claim a job, kill the worker process, confirm the watchdog requeues it within `StaleAfterMinutes`
- [ ] **Failure path:** queue a job that must fail; confirm ServiceNow shows Failed with the reason in `exception`
- [ ] Job output in the Automation Account parses as JSON and carries a correlation id
- [ ] **Secret redaction:** create a user with a password in the payload and grep the job output. Nothing. **BLOCKER**

## 7. Operational readiness

- [ ] **No** Azure Automation schedules exist. Work is event-driven; a schedule competing with the application doubles claim contention for no gain
- [ ] ServiceNow application confirmed to trigger `Invoke-RmaQueueWatchdog` on a cadence **BLOCKER** — nothing else recovers a job whose worker died, and there is no event for it
- [ ] `StaleAfterMinutes` comfortably above the longest observed job, and above `MaxMinutes`
- [ ] On-call knows where ServiceNow flags failed runbook jobs and what the first response is
- [ ] `docs/RUNBOOK-OPERATIONS.md` reviewed by whoever will be woken up
- [ ] Rollback rehearsed at least once in `test`, not just documented
- [ ] Customer informed of the go-live window

## 8. Post go-live

- [ ] Watch for one full business cycle before enabling the next tenant
- [ ] Confirm worker disk is flat, not growing
- [ ] Review claim contention; raise `BatchSize` before adding workers
- [ ] Re-run the analyzer against production content and confirm it still reports zero

---

## Sign-off

| Area | Name | Date |
|---|---|---|
| Engineering | | |
| Security / identity | | |
| Operations | | |
| Customer | | |
