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
// Claim contention. Sustained non-zero with an empty queue means the schedule is
// too aggressive, not that more workers are needed.
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
In order of preference: increase schedule frequency, raise `MaxJobs`, add a worker.

### `job-claim-contention`
Workers competing for an empty queue. Reduce frequency or worker count. Harmless but wasteful.

### `module-install-attempted`
An unreviewed runbook reached production, or a rollback restored an old one. Find it, remove
it, and check how it bypassed the analyzer gate.

## Common tasks

**Reprocess a failed job.** Set its ServiceNow status back to `1` (Pending). The next
scheduled run picks it up. Do not edit `worker_id` or `claimed_at`.

**Stop everything.** Disable the schedules. Jobs queue and are processed when re-enabled.
Nothing is lost — the queue is durable.

**Change how often a runbook runs.** Azure Automation schedules have a one hour minimum.
For a finer cadence, add offset hourly schedules (`:00`, `:15`, `:30`, `:45`) rather than
looking for a setting that does not exist. Overlapping runs are safe because jobs are
claimed atomically.

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
