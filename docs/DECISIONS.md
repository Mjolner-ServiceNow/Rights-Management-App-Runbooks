# Decisions and findings

Why the design is the way it is, and what was learned by testing against real systems.
Most of this was agreed in conversation or found on a test instance, and none of it can be
read back out of the code. Before changing anything listed here, read the entry: several
look arbitrary and are not.

Two kinds of entry:

- **Decision**: a choice that was made, with the reason. Reverse it deliberately or not
  at all.
- **Finding**: a fact about ServiceNow or Azure established by testing. The code depends
  on it, and it was not documented anywhere it could be looked up.

Add a new entry at the end of its section with a date. When one is superseded, leave it
and say so on it, rather than deleting it: the history of a wrong turn is what stops the
next person taking it.

Nothing here may identify a customer. Instance names, tenant ids and real `sys_id` values
stay out, as everywhere else in this repository.

## Decisions

### D1. The module owns the queue contract; runbooks own business logic only

*2026-08-27, the start of the rewrite (commit `39ff768`).*

The library this replaces pasted the same 200-line preamble into 63 runbooks, and every
copy drifted. `Invoke-RmaQueueLoop` now claims, bounds, retries, renews and sets the
terminal state; a runbook supplies a body. A runbook that does any of that itself is
rejected in review, because that duplication is the defect the repository exists to
remove. See [ARCHITECTURE.md](ARCHITECTURE.md).

### D2. Many small jobs, not long-running ones

*2026-09-21.*

The rewrite is driven by one large customer, with over 500,000 users, that was not
satisfied with version 1.0. The design target is many small jobs drained by short runs, so
`Invoke-RmaQueueLoop` keeps its shape. Do not reshape it around one long-running job per
command.

The volume-sensitive defaults (`MaxJobs = 500`, `BatchSize`, the backoff counters) were
calibrated against a low-volume internal test instance, not that customer. Expect to tune
them against real traffic. They are `Invoke-RmaQueueLoop` parameters that no runbook
exposes yet, so tuning is a code change and a release.

### D3. One user-assigned managed identity, federated to the app registration

The workload has no client secrets and no certificates. A user-assigned identity on the
Hybrid Worker VM reads Key Vault and acts as the app registration through a federated
credential. The Automation Account must have **no** managed identity of its own: enabling
one overrides the VM's identity and breaks authentication everywhere. IMDS requests always
pass `client_id`, because the Hybrid Worker extension also creates a system-assigned
identity on the VM.

### D4. No infrastructure-as-code for now

*2026-09-21, commit `6b3d13a`.*

The Bicep did not meet the bar, and finishing it was deferred until the wider framework is
settled. A half-trusted template is worse than none, so it was removed and the resources
are created by hand from [AZURE-RESOURCES.md](AZURE-RESOURCES.md). Two automated guards
went with it and are now review duties: rejecting real Azure resource ids in committed
files, and asserting that the Automation Account has no identity. Do not re-add Bicep
without agreeing it first.

### D5. Modules reach the worker as a release package, not through Automation

Azure Automation cannot deliver modules to a Hybrid Runbook Worker. The module is packaged
by `release.yml`, installed on each worker by `scripts/Initialize-RmaWorker.ps1` with a
SHA256 check, and pinned by every runbook's `#Requires`. Dependencies are never installed
at runtime.

### D6. Releases are drafted automatically and published by hand

*2026-09-21, PR #8.*

A release is what somebody installs on every worker by hand, so its cadence follows the
fleet, not the merge tempo. A push to `main` with a new `ModuleVersion` drafts a release;
a human clicks Publish. The zip is written deterministically, because v2.0.0's was rebuilt
at publish time and no longer matched the hash people had copied. See
[CLAUDE.md](../CLAUDE.md), *Releases*.

### D7. ServiceNow passes all configuration as runbook parameters

*2026-09-23, PR #15, module 2.0.0. Breaking on both sides.*

ServiceNow already holds every value when it starts a job, so fetching the domain record
back cost a REST call and a failure point, and needed read access to the domain table.
`Get-RmaDomainConfig` was removed. The only ServiceNow table the runbooks read is the
command queue, `x_autps_active_dir_command_queue`.

- All runbooks take `Instance`, `DomainId` (still the queue filter), `ServiceNowUserName`,
  `VaultName` and `ManagedIdentityClientId`. Entra ID adds `TenantId` and
  `ApplicationId`; Active Directory adds `DomainController`, `AdUserName` and
  `AdSecretName`.
- **Passwords are never parameters.** Automation shows job input in the job history.
- The ServiceNow password has a fixed secret name, `servicenow-api-password`, because
  there is one instance per installation. The AD secret name is a parameter, defaulting to
  `ad-service-account-password`, because one installation can have several AD domains.
- No forest parameter: nothing uses it yet.
- When a directory is disabled on a domain, the application must **omit** that
  directory's parameters, not send empty strings. Validation rejects empty strings.

The full table is in [ARCHITECTURE.md](ARCHITECTURE.md), *Runbook parameters*.

### D8. The managed identity field is the Client ID, on the Setup tab

*2026-09-23.*

The first plan put "Managed Identity Object ID" under Entra ID Setup. The runbooks need
the **client** ID, for IMDS; the object (principal) ID is only the federated credential
subject, set once in Entra. Swapping the two is the most likely installation mistake. The
field belongs on Setup because the identity sits on the worker and reads Key Vault whether
or not the domain uses Entra ID.

### D9. Changes to the ServiceNow domain record

*2026-09-23. Planned on the ServiceNow side; not confirmed as built.*

The domain record form has the tabs Setup, Active Directory Setup, Entra ID Setup and
Password Policy. To supply D7's parameters:

| Tab | Field | Change | Runbook parameter |
|---|---|---|---|
| Setup | Automation account | keep | none: ServiceNow uses it to start the job |
| Setup | Hybrid worker group | keep | none: the job's RunOn |
| Setup | ServiceNow Credentials | **replace** with a plain user name | `ServiceNowUserName` |
| Setup | Key Vault name | **add** | `VaultName` |
| Setup | Managed Identity Client ID | **add** | `ManagedIdentityClientId` |
| AD Setup | Domain Controller IP | keep | `DomainController` |
| AD Setup | Active Directory Credentials | **replace** with user name and secret name | `AdUserName`, `AdSecretName` |
| AD Setup | Domain mode, Forest mode, Forest name, Default user path, PAM enabled | keep | none yet |
| Entra ID Setup | Tenant | keep | `TenantId` |
| Entra ID Setup | Application ID | keep | `ApplicationId` |
| Entra ID Setup | Certificate Thumbprint, Client secret Credentials | **remove** | none |

`Instance` needs no field: ServiceNow knows its own name. Exchange's `Organization`
(`*.onmicrosoft.com`), which `Connect-RmaExchange` requires, has neither a field nor a
parameter yet, because no Exchange runbook has been migrated.

### D10. The watchdog is started by ServiceNow, not by an Automation schedule

There is no event for "a worker died", so the watchdog has to be a periodic sweep, and the
ServiceNow application starts it on a cadence, once per domain. The cadence has not been
agreed; see [HANDOVER.md](../HANDOVER.md).

### D11. Long jobs renew their claim; the watchdog threshold stays low

*2026-09-25, implemented in PR #21.*

A full import at the target scale runs for hours. Raising `StaleAfterMinutes` above the
longest job would leave a genuinely dead job stranded for hours, so instead a background
thread renews `claimed_at` every `HeartbeatMinutes` (5) and the watchdog keeps 30 minutes.
Keep `StaleAfterMinutes` at three heartbeats or more.

### D12. How the four Initial-Import runbooks are to be rebuilt

*2026-09-25. Agreed, not yet implemented.* Applies to Initial-Import-ADUsers,
-ADGroups, -EntraUsers and -EntraGroups.

- **Heartbeat** (D11), not a higher watchdog threshold.
- **`/cleanup`** removes every record not imported since the previous run. ServiceNow has
  been asked to run it on their side. Until they do, the runbook calls it, and **only when
  zero records failed**, since a partial import followed by cleanup deletes good records.
  ServiceNow's own version must skip after a failed job too.
- **`/insertMultiple`** exists on the ServiceNow side (confirmed by the ServiceNow team)
  and replaces one `PUT` per record. Its exact URL, body, upsert semantics and response
  were not known when this was written; groups need `sync_policy` per record.
- **The MFA phone (`mfasms`) is dropped** from Initial-Import-EntraUsers.
  Import-EntraMFA owns it.
- **Group members are restored** in the initial group imports, with the 1.0 monolith's
  field names (`groupguid`, `objectguid`, ...), not the broken `group` / `member` rename.
- API naming in the ServiceNow application: `user` and `group` are Active Directory;
  `aduser` and `adgroup` are Entra ID. In 1.0, Initial-Import-ADGroups called the
  `adgroup` cleanup and Initial-Import-EntraUsers called the `user` cleanup. Both were
  wrong.

### D13. Test-RmaHealth chooses its checks in its body

*2026-09-24, module 2.0.1.*

Azure Automation rejects a runbook that declares parameter sets. The Entra ID pair and the
Active Directory pair are ordinary optional parameters, and the body enforces at least one
whole pair. A test fails any runbook that declares a parameter set.

## Findings

### F1. The job claim is not atomic on the instance it was tested on

*2026-09-30, ServiceNow test instance. Unresolved.*

The Table API **ignores `sysparm_query` on a single-record `PATCH`**.
`Request-RmaJobClaim` won a Completed row, and a row another worker held, and overwrote
both. The read-back cannot tell, because it only shows that this worker wrote last. The
heartbeat's renewal and the watchdog's requeue use the same filter.

The fix is a server-side compare-and-set: a Scripted REST endpoint in the ServiceNow
application that changes the row only if it is still in the expected state, and says
whether it did. `Request-RmaJobClaim`'s signature does not change, so no runbook does.
That endpoint is the ServiceNow team's to build.

### F2. Date/Time fields must be written as UTC `yyyy-MM-dd HH:mm:ss`

*2026-09-30.*

ISO 8601 (`2026-09-30T12:24:25Z`) is accepted for a Date/Time field and stored as midnight
of that date. No error. `yyyy-MM-dd HH:mm:ss` is stored as given and read as UTC. The
private `Get-RmaGlideDateTime` produces it; `Test-RmaHealth` inlines the format because a
runbook cannot call a private function.

### F3. A PowerShell 7 job cannot read its Automation job id

*2026-09-28, real jobs on a Hybrid Worker, runtime environment PowerShell 7.6.*

There is no `$PSPrivateMetadata` variable. An environment variable of that name holds the
literal text `System.Collections.Hashtable`. `AUTOMATION_ASSET_SANDBOX_ID` is a GUID unique
per job, and `Get-RmaWorkerId` uses it. Until this was fixed every real job had the worker
id `<machine>/local`. The script's file name GUID is per runbook version, not per job.
`AUTOMATION_VMRESOURCEID` carries the subscription id: never paste a job's environment
into this repository.

Real jobs run as SYSTEM under `Orchestrator.Sandbox.exe`, with execution policy
RemoteSigned. A remote session for testing runs as the admin you sign in as, so it is not
an exact copy.

### F4. The command queue table

*Observed 2026-09-21 and 2026-09-30.*

`x_autps_active_dir_command_queue` has `command`, `status`, `domain` (a reference),
`exception`, `input`, `worker_id`, `claimed_at` and the system fields. `worker_id` and
`claimed_at` were added on the test instance on 2026-09-30; `worker_id` holds at least 100
characters. The integration account gets 403 on `sys_dictionary`, so field definitions
cannot be read through the API.

`input` is base64 of a small JSON object carrying only `action`, for example
`{"action": "Import-EntraUsers"}`. Rows for Import-EntraManagers come from a different
actor and use single quotes, `{'action' : 'Import-EntraManagers'}`. PowerShell 7's
`ConvertFrom-Json` accepts that; a strict parser would not.

The live traffic on the test instance is all imports, Entra ID into ServiceNow
(Import-EntraUsers, -Groups, -Managers, -AdministrativeUnit), hourly. `Create-EntraUser`,
the reference runbook in this repository, runs the other way and is not in that traffic.

### F5. The health endpoint takes PATCH

*2026-10-09.*

`/api/x_autps_active_dir/domain/{DomainId}/health` answers 405 to `POST`, `PUT` and `GET`.
`PATCH` reaches the resource script, which currently fails with HTTP 500
([#23](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/23)).
