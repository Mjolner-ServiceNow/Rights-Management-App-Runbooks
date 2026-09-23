# Architecture

## Overview

```
ServiceNow                Azure                                  Microsoft 365
──────────                ─────                                  ─────────────
                          ┌──────────────────┐
command_queue  ◀────────  │ Automation Acct  │
  status 1 Pending        │ identity: None   │  ← must stay None
  status 2 In Progress    └────────┬─────────┘
  status 3 Failed                  │ RunOn: hybrid worker group
  status 4 Completed               ▼
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
                          │ servicenow-pw    │           └────────┬────────┘
                          │ ad-service-pw    │                    │
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

| Parameter | Runbooks | Value |
|---|---|---|
| `Instance` | All | ServiceNow instance name: `contoso` for `contoso.service-now.com` |
| `DomainId` | All | `sys_id` of the domain record. Filters the command queue; nothing is read from the record itself. |
| `ServiceNowUserName` | All | The integration account |
| `VaultName` | All | The Key Vault |
| `ManagedIdentityClientId` | All | The **client** ID of the user-assigned managed identity |
| `TenantId` | Entra, Exchange | The Entra tenant ID |
| `ApplicationId` | Entra, Exchange | The application (client) ID of the app registration |
| `DomainController` | Active Directory | Host name or IP address of a domain controller |
| `AdUserName` | Active Directory | The AD service account |
| `AdSecretName` | Active Directory | Key Vault secret with that account's password. Defaults to `ad-service-account-password`. |

`Test-RmaHealth` takes all of them; the Active Directory ones switch on its AD check. Every
Active Directory command runbook uses the same names.

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

## Job lifecycle

```
   Pending (1)
       │  Get-RmaPendingJob            oldest first, limit 1
       ▼
   ┌────────────────────────────────────────────┐
   │ Request-RmaJobClaim                        │
   │   PATCH ...?sysparm_query=status%3D1       │  conditional: only a still-Pending row
   │   { status: 2, worker_id, claimed_at }     │
   │   won = (response.worker_id == mine)       │
   └────────────┬───────────────────┬───────────┘
          won   │                   │  lost
                ▼                   └──▶ skip, poll again
   Work in Progress (2)
                │  try { body } catch { record } finally { set terminal state }
                ▼
   Completed (4)  or  Failed (3)

   Worker dies before finally ──▶ stuck at (2)
                                    │  Invoke-RmaQueueWatchdog (ServiceNow, on a cadence)
                                    ▼
                                 Pending (1)
```

The claim is the property that makes everything else safe. Without it, running two workers
doubles the duplicate-execution rate; with it, workers can be added without risking
duplicate execution.

Safe is not the same as useful. The claim makes a second worker *correct*; the batched poll
described under **Scaling** is what makes it *faster*.

> **Verify before relying on this.** Correctness depends on the filtered `PATCH` being a
> single server-side compare-and-set on your ServiceNow instance. Confirm it in the
> technical workshop. If the instance does not honour it, replace the call inside
> `Request-RmaJobClaim` with a Scripted REST endpoint that does the compare-and-set server
> side. No other code changes.

## Module distribution

**Azure Automation cannot deliver modules to a Hybrid Runbook Worker.** Modules imported
into an Automation Account are made available to jobs running in an Azure sandbox. A worker
resolves modules from its own `PSModulePath`, and nothing pushes them there.

Everything the runbooks need is therefore installed on the worker by
`scripts/Initialize-RmaWorker.ps1`: the Graph and Exchange modules at pinned versions, and
`RMA.Runbooks` itself.

```
build/New-RmaModulePackage.ps1   →  RMA.Runbooks-1.0.0.zip
                                          │
                    GitHub release asset  │  (or a repo checkout, or a file share)
                                          ▼
              scripts/Initialize-RmaWorker.ps1  on each worker
                                          │
                                          ▼
        C:\Program Files\PowerShell\Modules\RMA.Runbooks\1.0.0\
                                          │
                                          ▼
                 #Requires -Modules @{ ...; RequiredVersion = '1.0.0' }
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

Concurrency is therefore not a number anyone configures. A burst of requests starts several
runbook jobs that overlap on the same queue, and a quiet hour starts none.

Adding workers is safe **because of the claim**. It is *productive* because of the batched
poll, which is a separate mechanism and worth understanding before the fleet grows.

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
| Two runs claim the same job | Conditional claim; verified by unit test |
| Worker dies mid-job | `try/finally` pre-set to Failed, then the watchdog |
| Terminal state write fails | Logged as Error, loop continues, watchdog requeues |
| ServiceNow transient 5xx | `Invoke-RmaRestMethod` retry with backoff and jitter |
| Token expires mid-run | `Get-RmaAccessToken` re-mints inside a five-minute margin |
| Payload action mismatch | Job explicitly Failed, never silently skipped |
| Runaway loop | `MaxJobs` and `MaxMinutes`; the run ends with a Warning naming the limit |
| Mass stranding | Watchdog refuses to act above `MaxRequeue` and raises |
| Secret in a log | `Write-RmaLog` redacts; `RmaAvoidUnredactedObjectLogging` blocks the pattern |
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
