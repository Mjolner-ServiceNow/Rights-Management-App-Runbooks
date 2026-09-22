# Operations

## Reading the logs

Every log line is one JSON object. In Log Analytics:

```kusto
// All structured output for one ServiceNow ticket, end to end.
AutomationJobStreams
| where TimeGenerated > ago(24h)
| extend L = parse_json(ResultDescription)
| where tostring(L.correlationId) == "<job sys_id>"
| project TimeGenerated, level = L.level, message = L.message, data = L.data, worker = L.worker
| order by TimeGenerated asc
```

```kusto
// Throughput and success rate per runbook, hourly.
AutomationJobStreams
| where TimeGenerated > ago(7d)
| extend L = parse_json(ResultDescription)
| where tostring(L.message) startswith "Queue loop finished"
| extend d = L.data
| summarize processed = sum(toint(d.processed)),
            succeeded = sum(toint(d.succeeded)),
            failed    = sum(toint(d.failed))
          by bin(TimeGenerated, 1h), runbook = tostring(L.runbook)
| extend successRate = round(100.0 * succeeded / iff(processed == 0, 1, processed), 1)
```

```kusto
// Claim contention. Sustained non-zero with an empty queue means runs are overlapping
// more than the queue justifies, not that more workers are needed.
AutomationJobStreams
| where TimeGenerated > ago(24h)
| extend L = parse_json(ResultDescription)
| where tostring(L.message) == "Job claim lost to another worker"
| summarize lost = count() by bin(TimeGenerated, 15m), worker = tostring(L.worker)
```

## Alert response

### `jobs-stranded-in-progress`
Jobs claimed but never finished. The watchdog should clear them within
`StaleAfterMinutes`. If it fires repeatedly the watchdog itself is failing — check its own
job history first. If the count is large, do **not** requeue manually: the watchdog refuses
above `MaxRequeue` precisely because mass stranding means something systemic.

### `runbook-failure-rate`
Group the failures by `exception` in ServiceNow. A single repeated message is usually one
bad payload or one missing directory object. Many different messages point at the platform:
check identity first with `Test-RmaHealth`.

### `queue-loop-hit-safety-limit`
Runs are ending with work still queued. Not urgent once, a capacity problem if sustained.
In order of preference: raise `MaxJobs`, raise `BatchSize`, add a worker. There is no
schedule frequency to increase — runs are started by the ServiceNow application per
request, so the queue is refilled by user demand rather than drained on a clock.

Check `stopReason` before treating it as a fault. `max-minutes` means jobs are slow;
`max-jobs` means there were simply more of them than the cap allows. `MaxJobs` defaults to
500, which was chosen against a low-volume test instance — on a busy queue `max-jobs` is the
*expected* outcome of a healthy run, not a runaway. Tune the default to the installation
rather than leaving this alert to fire on normal operation, because an alert that always
fires is one nobody reads.

### `job-claim-contention`
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
   not harmless, and it looks identical to contention from the summary alone.

A run that reports `claim-contention` with `Processed = 0` on a queue that is not empty is
cause 2 or 3, never cause 1.

### `module-install-attempted`
An unreviewed runbook reached production, or a rollback restored an old one. Find it, remove
it, and check how it bypassed the analyzer gate.

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
are safe because jobs are claimed atomically; if they are overlapping wastefully, raise
`BatchSize` rather than looking for a cadence setting that does not exist.

**Add a worker.** Attach the same user-assigned identity to the new VM, run
`Initialize-RmaWorker.ps1`, register it into the Hybrid Worker Group. No code change. Safe
because of the atomic claim.

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

`Test-RmaHealth` walks these in the same order and names the failing step.
