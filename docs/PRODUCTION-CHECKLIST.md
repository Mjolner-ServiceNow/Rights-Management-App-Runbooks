# Production deployment checklist

Work top to bottom. Anything marked **BLOCKER** stops the release.

## 1. Code and pipeline

- [ ] CI green on the release commit: analyzer (0 findings at Error and Warning), 43+ Pester tests passing, coverage above the floor, Bicep compiles with no diagnostics, manifest integrity passes
- [ ] `ModuleVersion` in `RMA.Runbooks.psd1` bumped, and `CHANGELOG.md` updated **BLOCKER**
- [ ] Every analyzer suppression in the diff carries a `Justification` that a reviewer accepted
- [ ] Branch protection on `main`: no direct pushes, one approving review, CI required
- [ ] Release tagged, so a rollback target exists by name
- [ ] Repository reviewed for anything customer-identifying before it is made public: instance names, tenant or subscription IDs, internal hostnames, record sys_ids **BLOCKER**
- [ ] `LICENSE` present and the copyright line names the correct legal entity

## 2. Identity

- [ ] Automation Account identity is **None** — `az automation account show --query identity.type`. `Deploy-RmaPlatform.ps1` asserts this, but confirm by hand if the template was deployed another way **BLOCKER**
- [ ] User-assigned managed identity attached to the Hybrid Worker VM
- [ ] Federated credential subject equals the identity's **principal** ID, not its client ID **BLOCKER**
- [ ] Federated credential issuer is `https://login.microsoftonline.com/{tenant}/v2.0`, audience `api://AzureADTokenExchange`
- [ ] App registration has Graph permissions plus `Exchange.ManageAsApp`, **admin consent granted** **BLOCKER**
- [ ] Directory role assigned is **Exchange Recipient Administrator**, not Exchange Administrator or Global Administrator
- [ ] App registration has **no client secret and no certificate**. If one exists, delete it — a live secret is a live bypass of everything above
- [ ] Managed identity has `Key Vault Secrets User` and nothing more. Confirm it does **not** hold Secrets Officer

## 3. Key Vault

- [ ] `servicenow-api-password` and `ad-service-account-password` present, values verified against a real login
- [ ] Expiry dates set on both secrets, with near-expiry notification configured
- [ ] Purge protection and 90-day soft delete on **BLOCKER**
- [ ] Public network access disabled, worker subnet allowed. Confirm from the worker: `Invoke-RestMethod https://<vault>.vault.azure.net/...` succeeds; confirm from elsewhere that it fails
- [ ] Diagnostic settings sending audit logs to Log Analytics

## 4. Worker

- [ ] `Initialize-RmaWorker.ps1` run on **each** worker; module list matches the pinned set exactly
- [ ] If more than one worker: all of them provisioned identically. A worker missing the module fails every job routed to it, intermittently
- [ ] `Get-Module -ListAvailable Microsoft.Graph* | Group-Object Name` shows **one version per module** **BLOCKER**
- [ ] `Microsoft.Graph.Beta` meta-module absent; only `Microsoft.Graph.Beta.Users` present
- [ ] `MSAL.PS` absent
- [ ] Free disk above 20 GB, with an alert at 10 GB
- [ ] `RSAT-AD-PowerShell` installed and `Get-ADRootDSE` succeeds against the domain controller
- [ ] Worker registered in the Hybrid Worker Group and showing healthy
- [ ] Two workers if the queue justifies it. One is a single point of failure; the claim makes two safe

## 5. ServiceNow

- [ ] `worker_id` and `claimed_at` columns added to `x_autps_active_dir_command_queue` **BLOCKER**
- [ ] **Conditional PATCH verified.** Two concurrent claims on the same row: exactly one must win **BLOCKER**
- [ ] `exception` field confirmed as the correct column for failure text
- [ ] Integration user has read on the queue and domain tables, write on the queue
- [ ] Domain record populated with tenant id, forest name, domain controller IP
- [ ] Domain record contains **no** credential pointers. Remove `thumbprint`, `entra_id_client_secret_credentials` and `automation_credentials` once migration is complete

## 6. Monitoring

- [ ] Diagnostic settings on the Automation Account sending JobLogs and JobStreams
- [ ] All five scheduled query alerts deployed and **tested by deliberately triggering one** — an untested alert is an assumption
- [ ] Action group recipients correct and confirmed receiving mail
- [ ] Log Analytics retention at least 90 days
- [ ] A dashboard or saved query showing queue depth, success rate and job duration

## 7. Verification

- [ ] `RMA.Runbooks` installed on **every** worker in the group, at the version the runbooks pin — `Get-Module -ListAvailable RMA.Runbooks` **BLOCKER**
- [ ] It resolves from an AllUsers PowerShell 7 path (`C:\Program Files\PowerShell\Modules`), not a per-user one. Hybrid Worker jobs run as local SYSTEM **BLOCKER**
- [ ] Confirmed that `RMA.Runbooks` was **not** imported into the Automation Account, which would give a false impression that the dependency is met
- [ ] Every runbook shows as Published, not Draft
- [ ] `Test-RmaHealth` passes on the real worker, with `-IncludeActiveDirectory` **BLOCKER**
- [ ] One real job end to end in each direction: an Entra create and an AD create
- [ ] **Duplicate-execution test:** queue one job, start the runbook twice concurrently. One must complete it; the other must log `Job claim lost to another worker`. **This is the defect the customer reported. Prove it is fixed.** **BLOCKER**
- [ ] **Stranding test:** claim a job, kill the worker process, confirm the watchdog requeues it within `StaleAfterMinutes`
- [ ] **Failure path:** queue a job that must fail; confirm ServiceNow shows Failed with the reason in `exception`
- [ ] Job logs in Log Analytics parse as JSON and carry a correlation id
- [ ] **Secret redaction:** create a user with a password in the payload and grep the job output. Nothing. **BLOCKER**

## 8. Operational readiness

- [ ] Schedules created, with frequency justified by measured queue depth
- [ ] Watchdog scheduled every 15 minutes, `StaleAfterMinutes` comfortably above the longest observed job
- [ ] On-call knows where the alerts land and what the first response is
- [ ] `docs/RUNBOOK-OPERATIONS.md` reviewed by whoever will be woken up
- [ ] Rollback rehearsed at least once in `test`, not just documented
- [ ] Customer informed of the go-live window

## 9. Post go-live

- [ ] Watch for one full business cycle before enabling the next tenant
- [ ] Confirm no `module-install-attempted` alerts
- [ ] Confirm worker disk is flat, not growing
- [ ] Review claim contention; tune schedule or worker count
- [ ] Re-run the analyzer against production content and confirm it still reports zero

---

## Sign-off

| Area | Name | Date |
|---|---|---|
| Engineering | | |
| Security / identity | | |
| Operations | | |
| Customer | | |
