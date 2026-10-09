# Production deployment checklist

Work top to bottom. Anything marked **BLOCKER** stops the release.

## 1. Code and pipeline

- [ ] CI green on the release commit: formatting, analyzer (0 findings at Error and Warning), Pester tests passing, coverage above the floor, manifest integrity, and on the pull request the module version bump check
- [ ] `ModuleVersion` in `RMA.Runbooks.psd1` bumped, and `CHANGELOG.md` updated **BLOCKER**
- [ ] Every analyzer suppression in the diff carries a `Justification` that a reviewer accepted
- [ ] Branch protection on `main`: no direct pushes, one approving review, CI required
- [ ] Release drafted by the workflow and published by hand, so a rollback target exists by name
- [ ] Repository reviewed for anything customer-identifying — it is public, so every commit is published as it lands: instance names, tenant or subscription IDs, internal hostnames, record sys_ids. Nothing automated checks this **BLOCKER**
- [x] `LICENSE` present (MIT) and the copyright line names the correct legal entity

## 2. Identity

- [ ] Resources built as [`AZURE-RESOURCES.md`](AZURE-RESOURCES.md) specifies: names, resource groups and every setting marked required
- [ ] Automation Account identity is **None** — `az automation account show --query identity.type`. Nothing automated asserts this; confirm by hand on every environment **BLOCKER**
- [ ] User-assigned managed identity attached to the Hybrid Worker VM
- [ ] Federated credential subject equals the identity's **principal** ID, not its client ID **BLOCKER**
- [ ] Federated credential issuer is `https://login.microsoftonline.com/{tenant}/v2.0`, audience `api://AzureADTokenExchange`
- [ ] App registration has exactly the API permissions listed in [`AZURE-RESOURCES.md`](AZURE-RESOURCES.md), **admin consent granted** **BLOCKER**
- [ ] Directory role assigned is **Exchange Recipient Administrator**, not Exchange Administrator or Global Administrator
- [ ] The runbooks' app registration has **no client secret and no certificate**. If one exists, delete it — a live secret is a live bypass of everything above. ServiceNow's own app registration is the one that does have a credential; do not confuse the two
- [ ] ServiceNow's app registration holds **Automation Contributor on `aa-rma-prod` only** — not on the resource group or subscription — and no API permissions
- [ ] The expiry date of ServiceNow's credential is recorded, and someone owns renewing it
- [ ] Managed identity has `Key Vault Secrets User` and nothing more. Confirm it does **not** hold Secrets Officer

## 3. Key Vault

- [ ] `servicenow-api-password` and `ad-service-account-password` present, values verified against a real login
- [ ] Expiry dates set on both secrets, matching the passwords' own lifetimes, and someone owns renewing them
- [ ] Purge protection and 90-day soft delete on **BLOCKER**
- [ ] Public network access set to **Enabled from selected virtual networks and IP addresses** with only the worker subnet allowed (it needs the `Microsoft.KeyVault` service endpoint), or Disabled with a private endpoint. Disabled with a subnet rule admits nothing. Confirm from the worker: `Test-RmaHealth`'s *Key Vault + ServiceNow* check passes, which is an authenticated secret read. Confirm from a workstation outside that network, signed in as someone who holds Secrets Officer: `az keyvault secret show --vault-name <vault> --name servicenow-api-password` is refused with a `ForbiddenByFirewall` error rather than returning the secret. An unauthenticated request proves nothing, because it gets 401 either way

## 4. Worker

- [ ] `Initialize-RmaWorkerHost.ps1` run on **each** worker: PowerShell 7.6 installed, and `[Environment]::GetEnvironmentVariable('powershell_7_6_path', 'Machine')` returns a `pwsh.exe` that exists. Without it, PowerShell 7 jobs sit in Queued on a worker that reports healthy **BLOCKER**
- [ ] Hybrid Worker extension at **1.3.63 or above** on each worker — `az vm extension show ... --name HybridWorkerExtension --query typeHandlerVersion` **BLOCKER**
- [ ] `Initialize-RmaWorker.ps1` run on **each** worker, from the published release's hash-checked block; the pinned version of every module present
- [ ] If more than one worker: all of them provisioned identically. A worker missing the module fails every job routed to it, intermittently
- [ ] Superseded module versions may stay: runbooks pin exact versions, so they are never loaded. Prune them only after the release has run cleanly, because `-PruneUnpinned` also removes the previous `RMA.Runbooks`, which is the rollback target
- [ ] No `Microsoft.Graph.Beta*` module present; none is required. `Initialize-RmaWorker.ps1` removes the `Microsoft.Graph.Beta` meta-module but not its `Microsoft.Graph.Beta.*` submodules, which are where the disk goes — remove those by hand
- [ ] `MSAL.PS` absent
- [ ] Free disk above 20 GB
- [ ] `RSAT-AD-PowerShell` installed and `Get-ADRootDSE` succeeds against the domain controller
- [ ] Worker registered in the Hybrid Worker Group and showing healthy
- [ ] Two workers if the queue justifies it. One is a single point of failure. The claim is not yet atomic (see section 5), so overlapping runs can execute a job twice whether they run on one worker or two

## 5. ServiceNow

The ServiceNow application is set up by the ServiceNow team, and there is no written guide
for it yet. Have it done, including entering the Azure values into the domain record, before
working through this list.

Nothing on the ServiceNow side is verified here. The Azure-side consequences still are: the
**duplicate-execution test** in section 6 proves the job claim works end to end, which is
the behaviour that depends on the queue columns and on the conditional `PATCH` being atomic.

**It is not atomic today.** On 30 September 2026, on a ServiceNow test instance, the Table
API was found to ignore `sysparm_query` on a single-record `PATCH`: `Request-RmaJobClaim`'s
claim succeeds on any row, and its read-back proves only that this worker wrote last. Two
executions that read the same Pending row can both run it. The fix is a server-side
compare-and-set — a Scripted REST endpoint in the ServiceNow application — behind the same
`Request-RmaJobClaim` signature. The heartbeat renewal and the watchdog's requeue share the
limitation.

- [ ] Server-side compare-and-set in place in the ServiceNow application, and `Request-RmaJobClaim` calling it **BLOCKER**

## 6. Verification

- [ ] `RMA.Runbooks` installed on **every** worker in the group, at the version the runbooks pin — `Get-Module -ListAvailable RMA.Runbooks` **BLOCKER**
- [ ] It resolves from an AllUsers PowerShell 7 path (`C:\Program Files\PowerShell\Modules`), not a per-user one. Hybrid Worker jobs run as local SYSTEM **BLOCKER**
- [ ] Confirmed that `RMA.Runbooks` was **not** imported into the Automation Account, which would give a false impression that the dependency is met
- [ ] Every runbook shows as Published, not Draft
- [ ] Every runbook is of type PowerShell and linked to the `Powershell_7-6` Runtime environment **BLOCKER**
- [ ] `Test-RmaHealth` passes on the real worker for every domain, with the parameters of each directory that domain uses **BLOCKER**. Until [#23](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/23) is fixed the job itself fails at reporting to ServiceNow even when every check passes, so read the `Pass` lines from the job output. It does not check Exchange Online: confirm `Exchange.ManageAsApp` consent and the Exchange Recipient Administrator role by eye
- [ ] One real job end to end for every runbook in the release. Today that is `Create-EntraUser`; add an AD create once the Active Directory runbooks are migrated
- [ ] **Duplicate-execution test:** queue one job, start the runbook twice concurrently. One must complete it; the other must skip it, logging `Job claim lost to another worker`. That line is written at Debug, which reaches the Verbose stream, so it is in the job only when **Log verbose records** is on for the runbook. The test is timing-dependent: both runs must reach the claim on the same row before either has finished it, so run it several times. **This is the defect the customer reported. Prove it is fixed.** It **cannot pass** on an instance that ignores the claim's `status=1` condition, which is what was found on the test instance; it waits for the compare-and-set in section 5 **BLOCKER**
- [ ] **Stranding test:** claim a job, kill the worker process, confirm the watchdog requeues it within `StaleAfterMinutes` plus the watchdog's cadence
- [ ] **Failure path:** queue a job that must fail; confirm ServiceNow shows Failed with the reason in `exception`
- [ ] Job log records in the Automation Account — the Information, Warning, Error and, when kept, Verbose streams — are one JSON object each and carry a correlation id. The Output stream carries a plain-text summary, not JSON
- [ ] **Secret redaction:** create a user with a password in the payload and grep the job output. Nothing. **BLOCKER**

## 7. Operational readiness

- [ ] **No** Azure Automation schedules exist. Work is event-driven; a schedule competing with the application doubles claim contention for no gain
- [ ] ServiceNow application confirmed to trigger `Invoke-RmaQueueWatchdog` on a cadence, **once per domain** (`DomainId` is mandatory) **BLOCKER** — nothing else recovers a job whose worker died, and there is no event for it. The cadence is not agreed yet; it is an open point in [`HANDOVER.md`](../HANDOVER.md)
- [ ] `StaleAfterMinutes` (5–1440, default 30) at least three times `HeartbeatMinutes` (5 by default), so two missed renewals do not requeue a live job. A running job renews its claim, so this is not measured against the longest job. A stranded job is recovered within `StaleAfterMinutes` plus the cadence
- [ ] `MaxRequeue` (1–500, default 50) agreed: above it the watchdog requeues nothing and fails, by design
- [ ] On-call knows where ServiceNow flags failed runbook jobs and what the first response is
- [ ] `docs/RUNBOOK-OPERATIONS.md` reviewed by whoever will be woken up
- [ ] Rollback rehearsed at least once in `test`, not just documented
- [ ] Customer informed of the go-live window

## 8. Post go-live

- [ ] Watch for one full business cycle before enabling the next tenant
- [ ] Confirm worker disk is flat, not growing
- [ ] Review claim contention. `BatchSize`, like `MaxJobs`, `MaxMinutes` and `EmptyPollsBeforeExit`, is a parameter of `Invoke-RmaQueueLoop` that no runbook exposes, so raising it is a code change shipped as a module or runbook release, not a setting
- [ ] Re-run the analyzer against production content and confirm it still reports zero

---

## Sign-off

| Area | Name | Date |
|---|---|---|
| Engineering | | |
| Security / identity | | |
| Operations | | |
| Customer | | |
