# Operations

Failed runbook jobs are flagged in ServiceNow, which tracks the status of every job it
starts. There is no Log Analytics workspace and there are no Azure alert rules; everything
below is read from the job output in the Automation Account.

## Reading the logs

Automation Account → **Jobs** → select the job → **All logs**. Every log line is one JSON
object:

| Field | Meaning |
|---|---|
| `timestamp` | UTC, ISO 8601 |
| `level` | `Debug`, `Information`, `Warning` or `Error` |
| `message` | What happened |
| `runbook` | Which runbook logged it |
| `correlationId` | The ServiceNow job `sys_id` the line belongs to. Empty outside a job. |
| `worker` | Which Hybrid Worker ran it |
| `data` | Named fields, already redacted |

Debug lines, including `Job claim lost to another worker`, are written to the Verbose
stream, which a job keeps only when **Log verbose records** is on in the runbook's logging
settings. Leave it off normally and turn it on while diagnosing contention.

To follow one ServiceNow ticket, find the runbook job that ran at the time and search its
output for the ticket's `sys_id`.

Every run ends with one summary line, `Queue loop finished (<stopReason>)`, carrying
`processed`, `succeeded`, `failed`, `skipped` and `durationSeconds`. It is logged at
Information when the queue drained and at Warning otherwise.

## When something goes wrong

### Jobs flagged as failed in ServiceNow
Group the failures by `exception` in ServiceNow. A single repeated message is usually one
bad payload or one missing directory object. Many different messages point at the platform:
check identity first with `Test-RmaHealth`.

### Jobs stuck in Work in Progress
Jobs claimed but never finished. The watchdog requeues a job once its `claimed_at` is older
than `StaleAfterMinutes` (default 30), logging `Stranded job requeued` for each, so recovery
takes up to `StaleAfterMinutes` plus the interval at which the application starts the
watchdog. A requeued job runs again from the start.

The watchdog filters on its `DomainId`, so it only sees one domain's queue. **Every domain
needs its own watchdog run**; a domain without one has no recovery at all.

If they keep coming back the watchdog itself is failing — check its own job history first.
`Could not requeue stranded job` (Error) means the requeue `PATCH` failed for that row; the
run carries on with the others and the row is tried again on the next run. If the count is
large, do **not** requeue manually: the watchdog refuses above `MaxRequeue` (default 50),
logging `Stranded job count exceeds MaxRequeue; refusing to requeue` and failing the run,
precisely because mass stranding means something systemic.

### Heartbeat messages
A running job's claim is renewed every `HeartbeatMinutes` (default 5) by a background
thread, so the watchdog leaves long jobs alone. The loop reports on it in the job output:

- **`Claim was lost while the job ran; another worker may have run it as well`** (Error).
  A renewal found the row no longer at Work in Progress under this worker's id. Either the
  watchdog requeued it while it ran — `StaleAfterMinutes` under three times
  `HeartbeatMinutes`, or renewals failing — or, because the claim is not atomic, another
  worker claimed the same row. Check the target directory for a duplicate write.
- **`Some claim renewals failed`** (Warning), with `failures` and `lastError`. Renewal
  requests failed and were retried after a minute; the claim was never seen to be lost.
  Repeated, it is the warning before the one above.
- **`Heartbeat thread is not running; a long job will be requeued by the watchdog`**
  (Error), logged at the *start* of a job. The thread died, for example because it could
  not import the module; `error` says why. Short jobs are unaffected, and anything longer
  than `StaleAfterMinutes` will be requeued and run again.
- **`Heartbeat thread did not stop cleanly`** (Warning), at the end of a run. Harmless: the
  job it renewed had already reached its terminal state.

### Queue loop errors
- **`Queue row has no sys_id; skipping it`** (Error). The row cannot be claimed or reported
  on, so it is left untouched and counted as skipped. Fix the row in ServiceNow.
- **`Queue row has no 'input' payload`** and **`Action mismatch: the queue returned '…' for
  a '…' runbook`**. The job is set to Failed with that message. The first points at the
  ServiceNow business rule that populates `input`, the second at the application's mapping
  from command to runbook.
- **`Could not write terminal state; job will be requeued by the watchdog`** (Error). The
  body finished but the status could not be written, so the job stays at Work in Progress
  and the watchdog will requeue it, *after which it runs again*. `intendedState` says how
  the first run ended. If it completed and a repeat would write twice, set the row to
  Completed (`4`) by hand before the watchdog reaches it.

### A health check fails
`Test-RmaHealth` fails before running any check when its directory parameters are
incomplete: `The <directory> check needs … as well as …` for half of a pair, `Pass TenantId
and ApplicationId for the Entra ID check, DomainController and AdUserName for the Active
Directory check, or all four` for neither. That is the ServiceNow application passing the
wrong set for the domain.

Otherwise the output ends with `Reported to ServiceNow.` or `Not reported to ServiceNow:
<reason>`. A run whose checks all passed but whose result could not be sent fails with
`All checks passed, but the result could not be reported to ServiceNow`, so the job never
claims a ServiceNow view is current when it is not.

**At present every run fails at the report.** The application's health endpoint answers
HTTP 500 from its own resource script
([#23](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/23)).
Because of the retry bug below, the reason shows as the `System.Object[]` conversion error
rather than as the 500. Read the per-check lines above it for the actual health.

### `Cannot convert "System.Object[]" … to type "System.Collections.Hashtable"`
A known bug, not a fault in the call that failed
([#24](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/24)).
On a transient failure, `Invoke-RmaRestMethod` overwrites the request's `$Headers` with the
response's headers before retrying. An HTTP 408, 429 or 5xx therefore surfaces as this
conversion error instead of being retried, with the status code and the service's message
lost. A transport failure is retried without the `Authorization` header and comes back as
a 401. Every ServiceNow call, Key Vault read and federated token exchange goes through this
function, so until #24 is fixed treat this message as "a request failed transiently".

### A run stops at a safety limit: `max-jobs` or `max-minutes`
Runs are ending with work still queued. Not urgent once, a capacity problem if sustained.
In order of preference: raise `MaxJobs`, raise `BatchSize`, add a worker. The first two are
`Invoke-RmaQueueLoop` parameters that no runbook exposes, so raising either is a change to
the runbook, not a setting. There is no schedule frequency to increase — runs are started
by the ServiceNow application per request, so the queue is refilled by user demand rather
than drained on a clock.

The run itself completes normally, so ServiceNow does not flag it. Check the stop reason
before treating it as a fault. `max-minutes` means jobs are slow;
`max-jobs` means there were simply more of them than the cap allows. `MaxJobs` defaults to
500, which was chosen against a low-volume test instance — on a busy queue `max-jobs` is the
*expected* outcome of a healthy run, not a runaway. Tune the default to the installation
rather than leaving every busy run to end on a Warning, because a warning that is always
there is one nobody reads.

### A run stops with `claim-contention`
The loop gave up after `MaxConsecutiveSkips` consecutive batches in which it attempted
claims and won none. It counts batches, not individual lost claims.

Three causes, in order of likelihood:

1. **The queue holds only rows other workers are winning.** Normal near the end of a drain,
   and harmless. Constant rather than occasional means runs are overlapping more than the
   arrival rate justifies; reduce the worker count.
2. **`BatchSize` is too small for the fleet.** Workers are colliding on the same few rows
   instead of spreading across a window. Raise it before adding workers — see the scaling
   section in [ARCHITECTURE.md](ARCHITECTURE.md).
3. **ServiceNow is failing every `PATCH`.** Check for claim failures in the logs:
   `Job claim request failed` is logged at Warning by `Request-RmaJobClaim`. This one is
   not harmless, and it looks identical to contention from the summary line alone.

A run that reports `claim-contention` with `Processed = 0` on a queue that is not empty is
cause 2 or 3, never cause 1.

## Common tasks

**Reprocess a failed job.** Set its ServiceNow status back to `1` (Pending). It is picked
up by the next run that drains that command and domain. Do not edit `worker_id` or
`claimed_at`.

**Stop everything.** Runs are started by the ServiceNow application, not by an Azure
schedule, so the stop is a ServiceNow-side control — confirm with the application team
which one it is before you need it in anger. Nothing is lost either way: the queue is
durable and rows accumulate at `status = 1`.

As an Azure-side fallback, stopping the Hybrid Worker service on the VM leaves triggered
jobs queued in Automation rather than running them. Use it when the ServiceNow control is
unavailable, not as the first choice — it makes Azure look broken to anyone reading job
history.

**Change how often runbooks run.** You cannot, from Azure. Arrival rate is set by what the
customer's users are doing, and the application starts a run per request. Overlapping runs
are meant to be safe because each job is claimed, but the claim is **not atomic** today:
ServiceNow ignores the condition on the claim's `PATCH`, so two overlapping runs can
execute the same job (see the job lifecycle in [ARCHITECTURE.md](ARCHITECTURE.md)). If
runs are overlapping wastefully, raise `BatchSize` rather than looking for a cadence
setting that does not exist.

**Add a worker.** Attach the same user-assigned identity to the new VM, run
`Initialize-RmaWorker.ps1`, register it into the Hybrid Worker Group. No code change. Until
the claim is made atomic on the ServiceNow side, more workers also means more chance of a
job running twice; that fix is tracked in [HANDOVER.md](../HANDOVER.md).

**Rotate the ServiceNow or AD password.** Update the Key Vault secret. Runbooks read it at
start of run, so the next run uses the new value. No redeployment.

**Upgrade a module version.** Edit the pinned version in `Initialize-RmaWorker.ps1` *and*
the `#Requires` in the affected runbooks, in one pull request. Both must move together or
the runbook refuses to start — which is the intended behaviour.

## Diagnosing an authentication failure

In order, because each rules out the layer below:

1. **Automation Account identity.** `az automation account show --query identity.type`. If
   it is anything but `None`, that is the cause: it overrides the VM's identity. This is the
   single most likely explanation for authentication working yesterday and not today.
2. **IMDS from the worker.** Sign in and request a token with the identity's **client** ID.
   No client ID returns the system-assigned identity, which has no permissions.
3. **Key Vault.** Confirm the role assignment and, if the firewall is on, the subnet rule.
4. **Federated credential.** Subject must equal the identity's **principal** ID. Different
   GUID from the client ID; this is the most common misconfiguration.
5. **Admin consent.** An unconsented permission produces a token that is rejected on use
   rather than at issue, so the failure appears one layer later than the cause.

`Test-RmaHealth` covers part of this, and names the check that failed: the managed identity
token (step 2), Key Vault (step 3), and, for a domain using Entra ID, the federated token
exchange (step 4). It does not
check step 1 directly; a failure there shows as a failed token check, and the *Key Vault +
ServiceNow* check's message names the Automation Account identity as the usual cause. It
does not tell a Key Vault firewall apart from a missing role, and it does not check step 5:
the Graph check stops at the token exchange, which succeeds without admin consent.
