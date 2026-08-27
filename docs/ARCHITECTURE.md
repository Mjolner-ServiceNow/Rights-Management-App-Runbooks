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
domain record  ◀────────  │ Hybrid Worker VM │
  (config only,           │  + user-assigned │────── IMDS token ──┐
   no credentials)        │    managed id    │                    │
                          └────────┬─────────┘                    │
                                   │                              ▼
                                   │ Secrets User        ┌─────────────────┐
                                   ▼                     │ App registration│
                          ┌──────────────────┐           │ + federated     │
                          │    Key Vault     │           │   credential    │
                          │ servicenow-pw    │           └────────┬────────┘
                          │ ad-service-pw    │                    │
                          └──────────────────┘                    ▼
                                   │                     Graph · Exchange Online
                                   ▼
                          ┌──────────────────┐
                          │ Log Analytics    │  ← job logs, job streams, KV audit
                          │ + alert rules    │
                          └──────────────────┘
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
ServiceNow and the AD service account — live in Key Vault with expiry tracking and an audit
trail.

### The constraint that governs the whole design

The Automation Account **must have no managed identity of its own**. Enabling one overrides
the Hybrid Worker VM's identity, and an Automation Account user-assigned identity cannot be
used from a Hybrid Worker at all. This is enforced in three places:

- `infra/modules/automation.bicep` sets `identity: { type: 'None' }`, with the reason in a comment
- `scripts/Deploy-RmaPlatform.ps1` asserts it after deploying and fails if it changed
- `Test-RmaPrerequisite` produces a diagnostic naming this cause when the token call fails

It is also the first item on the production checklist, and the first step in the
authentication troubleshooting order, because it is the most likely explanation for
authentication that worked yesterday and does not today.

A VM running the Hybrid Worker extension also has a **system-assigned** identity, which the
extension enables automatically. IMDS requests must therefore always pass `client_id`, or
they return the wrong identity. `Get-RmaImdsToken` does.

Two GUIDs are involved and they are not interchangeable:

| Value | Used for |
|---|---|
| Managed identity **client** ID | IMDS token requests (`?client_id=`) |
| Managed identity **principal** ID | Federated credential subject, RBAC assignments |

Both are Bicep outputs, named explicitly.

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
                                    │  Invoke-RmaQueueWatchdog, every 15 min
                                    ▼
                                 Pending (1)
```

The claim is the property that makes everything else safe. Without it, running two workers
doubles the duplicate-execution rate; with it, workers can be added freely.

> **Verify before relying on this.** Correctness depends on the filtered `PATCH` being a
> single server-side compare-and-set on your ServiceNow instance. Confirm it in the
> technical workshop. If the instance does not honour it, replace the call inside
> `Request-RmaJobClaim` with a Scripted REST endpoint that does the compare-and-set server
> side. No other code changes.

## Scaling

Throughput is `workers × jobs-per-run ÷ schedule-interval`. Three levers:

| Lever | When | Cost |
|---|---|---|
| Increase schedule frequency | Queue drains but latency is too high | None |
| Raise `MaxJobs` / `MaxMinutes` | Runs stop on a safety limit with work left | Longer job duration |
| Add a Hybrid Worker to the group | Single worker is saturated | One VM |

Adding workers is safe **because of the claim** and for no other reason. The
`job-claim-contention` alert shows when workers are fighting over an empty queue, which
means the schedule is too aggressive rather than the workers too few.

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
| Runaway loop | `MaxJobs` and `MaxMinutes`, with an alert when hit |
| Mass stranding | Watchdog refuses to act above `MaxRequeue` and raises |
| Secret in a log | `Write-RmaLog` redacts; `RmaAvoidUnredactedObjectLogging` blocks the pattern |
| Worker disk exhaustion | Pinned modules, no runtime install, analyzer rule, prune sweep |

## Environments

`dev`, `test`, `prod` are the same template with different parameters, deployed manually
per environment. Production
additionally gets: Key Vault public access disabled with a subnet rule, purge protection,
90-day soft delete, 90-day log retention, and alert action groups wired up. Lower
environments record alerts but do not notify.
