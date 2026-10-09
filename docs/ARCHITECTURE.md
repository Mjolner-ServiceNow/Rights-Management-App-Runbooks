# Architecture

## Overview

```
ServiceNow                Azure                                  Microsoft 365
──────────                ─────                                  ─────────────
                          ┌──────────────────┐
command_queue  ◀────────  │ Automation Acct  │
  1 Pending               │ identity: None   │  ← must stay None
  2 Work in Progress      └────────┬─────────┘
  3 Failed                         │ RunOn: hybrid worker group
  4 Completed                      ▼
                          ┌──────────────────┐
results        ◀────────  │ Hybrid Worker VM │
  (write-back of what     │  + user-assigned │────── IMDS token ──┐
   the job created)       │    managed id    │                    │
                          └────────┬─────────┘                    │
                                   │                              ▼
                                   │ Secrets User        ┌─────────────────┐
                                   ▼                     │ App registration│
                          ┌──────────────────┐           │ + federated     │
                          │    Key Vault     │           │   credential    │
                          │ servicenow-api-  │           └────────┬────────┘
                          │   password       │                    │
                          │ ad-service-      │                    │
                          │   account-       │                    │
                          │   password       │                    │
                          └──────────────────┘                    ▼
                                                         Graph · Exchange Online

                                                        Active Directory
                                                        (AD credential from Key Vault)
```

## Identity

One user-assigned managed identity, attached to the Hybrid Worker VM, is the only identity
in the system. It does two things:

1. **Reads Key Vault** with the `Key Vault Secrets User` role. Read only: it cannot rotate,
   add or delete a secret.
2. **Acts as the app registration** through a federated identity credential, which gives
   Graph and Exchange Online without a client secret or certificate.

Nothing expires and nothing is stored. The two passwords that cannot be federated —
ServiceNow and the AD service account — live in Key Vault, each with an expiry date, and
the managed identity can read them but not change them.

### The constraint that governs the whole design

The Automation Account **must have no managed identity of its own**. Enabling one overrides
the Hybrid Worker VM's identity, and an Automation Account user-assigned identity cannot be
used from a Hybrid Worker at all.

Nothing enforces it automatically. The Automation Account is created by hand, so the
identity must be left at **None** at creation and never enabled afterwards.
`Test-RmaPrerequisite` produces a diagnostic naming this cause when the token call fails,
which is detection, not prevention.

It is also the first item on the production checklist, and the first step in the
authentication troubleshooting order, because it is the most likely explanation for
authentication that worked yesterday and does not today.

A VM running the Hybrid Worker extension also has a **system-assigned** identity, which the
extension requires. IMDS requests must therefore always pass `client_id`, or
they return the wrong identity. `Get-RmaImdsToken` does.

Two GUIDs are involved and they are not interchangeable:

| Value | Used for |
|---|---|
| Managed identity **client** ID | IMDS token requests (`?client_id=`) |
| Managed identity **principal** ID | Federated credential subject, RBAC assignments |

Record both when the identity is created, labelled, and keep them apart. Swapping them
produces a federated credential that saves without error and fails later, at token
exchange.

## Runbook parameters

Every value a runbook needs is a parameter, passed by the ServiceNow application when it
starts the job. The runbooks read nothing else from ServiceNow: the command queue is the
only table they query, and what they send back is job state and the results of the work.

| Parameter | Runbooks | Value | ServiceNow domain record |
|---|---|---|---|
| `Instance` | All | ServiceNow instance name: `contoso` for `contoso.service-now.com` | No field. The application knows its own instance. |
| `DomainId` | All | `sys_id` of the domain record. Filters the command queue; nothing is read from the record itself. | The record's own `sys_id` |
| `ServiceNowUserName` | All | The integration account | Setup › ServiceNow username *(replaces ServiceNow Credentials)* |
| `VaultName` | All | The Key Vault | Setup › Key Vault name *(new)* |
| `ManagedIdentityClientId` | All | The **client** ID of the user-assigned managed identity | Setup › Managed Identity Client ID *(new)* |
| `TenantId` | Entra, Exchange | The Entra tenant ID | Entra ID Setup › Tenant Azure Active Directory |
| `ApplicationId` | Entra, Exchange | The application (client) ID of the app registration | Entra ID Setup › Application ID |
| `DomainController` | Active Directory | Host name or IP address of a domain controller | Active Directory Setup › Domain Controller IP |
| `AdUserName` | Active Directory | The AD service account | Active Directory Setup › AD username *(replaces Active Directory Credentials)* |
| `AdSecretName` | Active Directory | Key Vault secret with that account's password. Defaults to `ad-service-account-password`. | Active Directory Setup › AD secret name *(replaces Active Directory Credentials)* |
| `StaleAfterMinutes` | Watchdog | Minutes a claim may go unrenewed before the job is requeued. Defaults to 30. | No field. Set where the application schedules the watchdog. |
| `MaxRequeue` | Watchdog | Most stranded jobs one run will requeue; above it the run refuses and fails. Defaults to 50. | No field. Set where the application schedules the watchdog. |

The last column is the ServiceNow application's domain record form, as *tab › field*.
Fields marked *new* or *replaces* are changes the application needs for this release. The
application is maintained outside this repository, so check its own guide for the final
field names.

One value has no row yet. `Connect-RmaExchange` takes a mandatory `-Organization`, the
tenant's `*.onmicrosoft.com` name, and Exchange Online will not connect without it. No
runbook declares it and the domain record has no field for it, because no Exchange runbook
has been migrated yet. Which field supplies it is an open point in
[HANDOVER.md](../HANDOVER.md).

Some fields on the form do not become parameters:

- **Setup › Automation account** and **Setup › Hybrid worker group** tell the application
  where to start the job, and become its `RunOn`.
- **Enable Active Directory** and **Enable Azure Active Directory** decide which of the
  directory-specific parameters the application passes at all.
- **Entra ID Setup › Certificate Thumbprint**, **Entra ID Setup › Entra ID Client secret
  Credentials**, **Setup › ServiceNow Credentials** and **Active Directory Setup ›
  Active Directory Credentials** have no counterpart here and go. The workload
  authenticates with the managed identity, and the two passwords live in Key Vault.

> **The Managed Identity field takes the client ID, not the object ID.** The object
> (principal) ID is set once, as the subject of the federated credential in Entra, and is
> never passed to a runbook. The field sits under Setup rather than Entra ID Setup because
> the identity belongs to the Hybrid Worker and reads Key Vault for every domain, including
> one with Entra switched off.

`Test-RmaHealth` takes all of them. A domain can use Entra ID, Active Directory or both, so
both pairs are optional: pass `TenantId` and `ApplicationId` for the Graph check,
`DomainController` and `AdUserName` for the AD check, or all four. At least one pair is
required, and a pair with one half missing fails the job rather than skipping the check.
Every Active Directory command runbook uses the same names.

No runbook may declare parameter sets. Azure Automation refuses to start one that does
(*"Parameter sets in runbooks are not supported in this release"*), so a rule like "this
pair or that one" is checked in the script body instead.
`tests/Unit/RunbookDefinition.Tests.ps1` enforces it.

The ServiceNow application must **leave out** the parameters of a directory the domain
does not use, not pass them as empty strings. An empty value fails validation.

Three rules follow from putting configuration here:

- **Passwords are never parameters.** Azure Automation records every job's input in its
  job history, readable by anyone with read access to the Automation Account. The two
  passwords live in Key Vault and nowhere else.
- **The ServiceNow secret has a fixed name**, `servicenow-api-password`, rather than a
  parameter. An installation serves one ServiceNow instance through one integration
  account, so there is nothing to choose. The AD secret has a parameter because one
  installation can serve several AD domains, each with its own account.
- **Values are fixed when the job starts.** A change in ServiceNow applies to the next job,
  never to one already running.

The domain record used to be fetched at the start of every run. That cost a REST call and
a failure point, needed read access to one more table, and found a malformed tenant ID only
at token exchange. As parameters, the GUIDs are validated when the job binds them, before
any network call.

## The health result

`Test-RmaHealth` sends its result to the ServiceNow application, which displays it on the
domain:

```
PATCH /api/x_autps_active_dir/domain/{DomainId}/health
Content-Type: application/json; charset=utf-8
```

```json
{
  "status": "fail",
  "checked_at": "2026-10-09 08:15:02",
  "worker": "HW-01",
  "passed": 4,
  "total": 5,
  "checks": [
    { "name": "Managed identity token", "status": "pass", "duration_ms": 118, "detail": "acquired" },
    { "name": "Active Directory reachable", "status": "fail", "duration_ms": 2104, "detail": "<the error message>" }
  ]
}
```

- `status` is `pass` only when every check passed. Each check's `status` is `pass` or
  `fail`.
- `checked_at` is UTC in ServiceNow's internal Date/Time format, `yyyy-MM-dd HH:mm:ss`,
  which `GlideDateTime` reads as UTC. ISO 8601 would be stored as midnight of its date.
- `worker` is the machine name of the Hybrid Worker that ran the check.
- `checks` lists only the checks that ran, in the order they ran. The Graph check is
  present only for a domain using Entra ID, the AD check only for one using Active
  Directory. `detail` is capped at 4000 characters.

The result is sent whether the checks passed or failed, with the integration account's
credentials. It cannot be sent when the *Key Vault + ServiceNow* check failed, since
that check is where the connection comes from; the job output is then the only record, and
ServiceNow goes on showing the last result it received. A result that could not be sent
fails the job, as a failed check does, so the Automation job's own status always says
whether the ServiceNow view is current.

**Delivery does not work yet.** On the test instance the endpoint fails with HTTP 500 inside
its own resource script, before anything is stored
([#23](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/23)). The
fault is on the ServiceNow side. Until it is fixed every run fails at the report, even when
all the checks pass, and the job output is the only record.

## Job lifecycle

```
   Pending (1)
       │  Get-RmaPendingJob            oldest first, up to BatchSize (default 20),
       ▼                               walked from a random offset
   ┌────────────────────────────────────────────┐
   │ Request-RmaJobClaim                        │
   │   PATCH ...?sysparm_query=status%3D1       │  meant to touch only a still-Pending row;
   │   { status: 2, worker_id, claimed_at }     │  ServiceNow ignores the filter (see below)
   │   won = (response.worker_id == mine)       │
   └────────────┬───────────────────┬───────────┘
          won   │                   │  lost
                ▼                   └──▶ skip, try the next row
   Work in Progress (2)
                │  try { body } catch { record } finally { set terminal state }
                │  heartbeat renews claimed_at every HeartbeatMinutes while the body runs
                ▼
   Completed (4)  or  Failed (3)

   Worker dies, or the terminal write fails ──▶ stuck at (2), claimed_at stops moving
                                    │  Invoke-RmaQueueWatchdog (ServiceNow, on a cadence):
                                    │  claimed_at older than StaleAfterMinutes
                                    ▼
                                 Pending (1)
```

The claim is the property that is meant to make everything else safe. Without it, running
two workers doubles the duplicate-execution rate; with it, workers could be added without
risking duplicate execution.

Safe is not the same as useful. The claim makes a second worker *correct*; the batched poll
described under **Scaling** is what makes it *faster*.

> **The claim is not atomic today.** It depends on the filtered `PATCH` being a single
> server-side compare-and-set, and it is not one: on 2026-09-30, on a ServiceNow test
> instance, the Table API was found to ignore `sysparm_query` on a single-record `PATCH`.
> The `PATCH` succeeds on any row — it won a Completed row and a row held by another worker
> — and the read-back proves only that this worker wrote last. Two executions that read the
> same Pending row can therefore both run it.
>
> The shape of the claim is still right; the server side has to honour it. The fix is a
> Scripted REST endpoint in the ServiceNow application that does the compare-and-set server
> side, called from inside `Request-RmaJobClaim`. Its signature does not change, and no
> runbook changes. Until then, keep command bodies idempotent, as `Create-EntraUser` is. The
> endpoint is an open point in [HANDOVER.md](../HANDOVER.md).

### The heartbeat

A full directory import runs for hours, longer than the watchdog's threshold. Without
renewal the watchdog would requeue it while it was still running, and a second worker
would start the same import.

`Invoke-RmaQueueLoop` starts one background runspace per run, on the first claim, so a run
that finds the queue empty never pays for it. Every `HeartbeatMinutes` (default 5) it calls
`Update-RmaJobHeartbeat` for the job that is running, which writes a new `claimed_at` with a
`PATCH` filtered on `status=2^worker_id=<mine>` and checks the record that comes back. A
job that ends inside one interval, which is nearly all of them, is never renewed. Runbook
bodies never call it themselves.

What the loop logs when a job ends:

- **Claim lost** (Error): a renewal found the job no longer `status=2` with this worker's
  id. The watchdog requeued it while it ran, so another worker may have run it as well. The
  terminal state is still written.
- **Some renewals failed** (Warning): requests failed and were retried after a minute. The
  claim was not known to be lost.
- **Thread not running** (Error), reported at the *start* of a job: the heartbeat thread
  has died, so a long job will be requeued by the watchdog.

The renewal's filter has the same limitation as the claim's, and the read-back is what
makes it trustworthy. The watchdog keys on `claimed_at` older than `StaleAfterMinutes`
(default 30). Keep **`StaleAfterMinutes` at three times `HeartbeatMinutes` or more**, so
two failed renewals in a row do not requeue a job that is still running.

### The worker id

`worker_id` must be unique per execution, not per machine: the claim's read-back and the
heartbeat's filter both compare against it, and two runs that share an id both believe
they hold the same job. `Get-RmaWorkerId` builds it as `<machine>/<suffix>`, using the
first of these that is available:

1. `<jobId>`, the Automation job id from `$PSPrivateMetadata`. Older sandboxes set it.
2. `sandbox-<AUTOMATION_ASSET_SANDBOX_ID>`. This is the real case: a Hybrid Worker job on a
   PowerShell 7.x runtime environment has no `$PSPrivateMetadata`, and the environment
   variable of that name holds the literal text `System.Collections.Hashtable`. The
   sandbox id is a GUID unique per job.
3. `process-<pid>-<start time>`, anywhere else: a local run, a test, a dev run over SSH.

Before e4e8441 the fallback was `local`, so every real job on a worker shared the id
`<machine>/local`.

### ServiceNow Date/Time values

Any Date/Time written to ServiceNow — `claimed_at`, the health result's `checked_at` — must
be UTC in the internal format, `yyyy-MM-dd HH:mm:ss`. The Table API accepts ISO 8601
without complaint and stores midnight of its date. That was found on a real instance:
every `claimed_at` read as 00:00:00, so the heartbeat renewed nothing and the watchdog saw
every running job as stale. `Get-RmaGlideDateTime` formats it inside the module;
`Test-RmaHealth` inlines the same format, because a runbook cannot call a private function.

## Module distribution

**Azure Automation cannot deliver modules to a Hybrid Runbook Worker.** Modules imported
into an Automation Account are made available to jobs running in an Azure sandbox. A worker
resolves modules from its own `PSModulePath`, and nothing pushes them there.

Everything the runbooks need is therefore installed on the worker by
`scripts/Initialize-RmaWorker.ps1`: the `RSAT-AD-PowerShell` Windows feature for the
`ActiveDirectory` module, the Graph and Exchange modules at pinned versions, and
`RMA.Runbooks` itself.

```
build/New-RmaModulePackage.ps1   →  RMA.Runbooks-<version>.zip
                                          │
                    GitHub release asset  │  (or a repo checkout, or a file share)
                                          ▼
              scripts/Initialize-RmaWorker.ps1  on each worker
                                          │
                                          ▼
        C:\Program Files\PowerShell\Modules\RMA.Runbooks\<version>\
                                          │
                                          ▼
                 #Requires -Modules @{ ...; RequiredVersion = '<version>' }
```

Two consequences worth understanding:

**Version pinning is the coupling.** Each runbook pins an exact `RequiredVersion`. If the
worker has a different one, the job fails at parse time with a precise message rather than
part-way through a directory write. `tests/Unit/PinnedModuleVersions.Tests.ps1` asserts in
CI that every runbook pins the version this repository builds, so a mismatch between the
runbooks and the module is caught on the pull request, before anything reaches Azure. What
CI cannot see is the worker's own disk; that is what the parse-time failure and
`Test-RmaHealth` are for.

**Upgrading is a two-sided change.** Bump `ModuleVersion`, update the `#Requires` in every
affected runbook, and re-run `Initialize-RmaWorker.ps1` on every worker. All three in one
pull request. Rolling a worker forward without the runbooks, or the reverse, produces a
clean refusal rather than a subtle failure, which is the intended behaviour.

The PowerShell 7 module path is used, not the Windows PowerShell one, because runbooks run
on PowerShell 7.6. Hybrid Worker jobs run as local **SYSTEM**, so the module must be in an
AllUsers location; a per-user install is invisible to them. All 7.x versions share
`C:\Program Files\PowerShell\Modules`, so this path does not change with the runtime version.

## Scaling

Work is **event-driven**: ServiceNow writes a queue row and starts the runbook job that
drains it. There are no Azure Automation schedules, so there is no schedule interval to
tune and arrival rate is set by whatever the customer's users are doing. Three levers:

| Lever | When | Cost |
|---|---|---|
| Raise `MaxJobs` / `MaxMinutes` | Runs stop on a safety limit with work left | Longer job duration |
| Raise `BatchSize` | Workers are losing claims to each other | One larger read per poll |
| Add a Hybrid Worker to the group | Single worker is saturated | One VM |

`MaxJobs` (default 500), `MaxMinutes` (default 45) and `BatchSize` (default 20) are
parameters of `Invoke-RmaQueueLoop`, and no runbook exposes them. Raising one is a code
change to the runbook's call to it, deployed like any other runbook change.

Concurrency is therefore not a number anyone configures. A burst of requests starts several
runbook jobs that overlap on the same queue, and a quiet hour starts none.

Adding workers is meant to be safe **because of the claim**, which today it is not; see
*Job lifecycle*. It is *productive* because of the batched poll, which is a separate
mechanism and worth understanding before the fleet grows.

A poll fetches up to `BatchSize` rows and the worker walks that window from a random
offset. Fetching a single row instead makes every worker contend for the same head of the
queue: one wins, the rest lose, and the losers never reach the rows behind it. A worker in
that state stops with `claim-contention` having processed nothing while the queue is full,
so adding workers buys wasted `PATCH` calls rather than throughput.

**Raise `BatchSize` roughly in step with the worker count.** The default of 20 suits a small
fleet. Contention falls as the window widens, because two workers entering a 20-row window
at random offsets rarely start on the same row.

A run that stops with `claim-contention` does not simply mean "too many workers" — see
[RUNBOOK-OPERATIONS.md](RUNBOOK-OPERATIONS.md).

Both safety limits are deliberate. Azure Automation applies a three-hour fair-share limit
to cloud jobs; Hybrid Worker jobs are not capped, so an unbounded loop can run until
something else kills it, potentially mid-write. `MaxMinutes` ends the run cleanly with the
queue intact and the next run continues.

## Failure modes and what covers them

| Failure | Covered by |
|---|---|
| Two runs claim the same job | **Not covered yet.** The conditional claim is unit-tested, but ServiceNow ignores its filter; needs a server-side compare-and-set |
| Worker dies mid-job | `try/finally` pre-set to Failed, then the watchdog |
| Long job outlives the watchdog threshold | Heartbeat thread renews `claimed_at` every `HeartbeatMinutes` |
| Terminal state write fails | Logged as Error, loop continues, watchdog requeues |
| ServiceNow transient 5xx | `Invoke-RmaRestMethod` retry with backoff and jitter. **Broken today:** the retry overwrites the request headers ([#24](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/24)) |
| Token expires mid-run | Partly. `Get-RmaAccessToken` re-mints inside a five-minute margin for any call that asks it for a token, such as a Key Vault read. Graph and Exchange are connected once with a static token (`Connect-MgGraph -AccessToken`, `Connect-ExchangeOnline -AccessToken`) and nothing reconnects, so a run longer than the token lifetime (`MaxMinutes` allows up to 170) can fail part-way |
| Payload action mismatch | Job explicitly Failed, never silently skipped |
| Runaway loop | `MaxJobs` and `MaxMinutes`; the run ends with a Warning naming the limit |
| Mass stranding | Watchdog refuses to act above `MaxRequeue` and raises |
| Secret in a log | `Write-RmaLog` redacts a fixed list of field names; `RmaAvoidUnredactedObjectLogging` blocks the pattern. See [SECURITY.md](../SECURITY.md) for what the list misses |
| Worker disk exhaustion | Pinned modules, no runtime install, analyzer rule, prune sweep |

## Infrastructure

There is no infrastructure-as-code in this repository. The Bicep that used to define it was
removed because it did not meet the bar, and infrastructure-as-code is deferred until the
wider framework is settled. Until then the resources are created by hand;
[`AZURE-RESOURCES.md`](AZURE-RESOURCES.md) specifies what they are, which resource group
each belongs in, and how each must be configured.

There is no monitoring infrastructure either: no Log Analytics workspace and no alert
rules. The ServiceNow application tracks the status of every runbook job and flags the
ones that fail, so failures surface where the request was made.

## Environments

`dev`, `test`, `prod` are the same resources, provisioned separately per environment, each
with the environment as the last part of every name: `aa-rma-test`, `aa-rma-prod`.
Production additionally gets: Key Vault public access disabled with a subnet rule, and
purge protection.
