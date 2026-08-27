# Installation guide

Complete setup from nothing to a working, verified installation. Follow the steps in order:
each one produces a value the next one needs.

For updating an existing installation, see [`DEPLOYMENT.md`](DEPLOYMENT.md). For day-to-day
running, see [`RUNBOOK-OPERATIONS.md`](RUNBOOK-OPERATIONS.md).

---

## Before you start

### Who you need

Installation touches four systems, and no single person usually has rights to all of them.
Line these people up before you begin, because waiting for an approval mid-install is the
most common reason this takes days instead of hours.

| Step | Role required | Where |
|---|---|---|
| 1 | ServiceNow administrator | ServiceNow |
| 2, 3 | Contributor on the resource group | Azure |
| 4 | Local administrator on the VM | Windows |
| 5 | Cloud Application Administrator | Microsoft Entra |
| 6 | Privileged Role Administrator or Global Administrator | Microsoft Entra |
| 7 | Key Vault Secrets Officer, plus the actual passwords | Azure |
| 8, 9 | Contributor on the Automation Account | Azure |

Steps 5 and 6 are separate deliberately. Step 5 can be delegated; step 6 grants a directory
role and should not be.

### What you need

- An Azure subscription and an empty resource group.
- A **Windows Server VM in Azure** that will run the jobs. Two cores and 4 GB RAM minimum.
  It must reach your domain controllers and `service-now.com`.
- A ServiceNow instance with the Rights Management App scoped application installed.
- An **Active Directory service account** that can create, modify and disable users and
  groups in the target OUs.
- A **ServiceNow integration account** with read access to the domain table and read/write
  on the command queue table.
- Tooling on your workstation: [Azure CLI](https://aka.ms/azure-cli),
  [PowerShell 7.2+](https://aka.ms/powershell), and the `Az.Automation` module.

### How long

Roughly half a day of work, spread across whatever approval waits your organisation
imposes. The Azure parts take minutes; the Entra consent and the ServiceNow table change
are the ones that queue.

### Values to record as you go

Keep these somewhere as you work. Four of them are produced by one step and consumed by
another.

| Value | Produced in | Used in |
|---|---|---|
| Domain record sys_id | Step 1 | Steps 9, 10 |
| ServiceNow instance name | Step 1 | Steps 9, 10 |
| Managed identity **client** ID | Step 2 | Steps 9, 10 |
| Managed identity **principal** ID | Step 2 | Step 5 |
| Key Vault name | Step 2 | Steps 7, 9, 10 |
| Application (client) ID | Step 5 | Steps 9, 10 |

> **The two managed identity GUIDs are different and are not interchangeable.** The client
> ID is what a runbook uses to request a token. The principal ID is what the federated
> credential trusts. Swapping them creates a credential that saves without any error and
> fails only later, at token exchange, with a message that does not point at the cause.
> This is the single most common installation mistake.

---

## Step 1 — Prepare ServiceNow

**Who:** ServiceNow administrator.

### 1a. Add two columns to the command queue table

On `x_autps_active_dir_command_queue`, add:

| Column | Type | Purpose |
|---|---|---|
| `worker_id` | String (255) | Which worker claimed the job |
| `claimed_at` | String (64) | UTC timestamp of the claim, ISO 8601 |

These are what make it impossible for two workers to execute the same job. Without them
the installation will run, but the duplicate-execution protection does not work.

### 1b. Verify the conditional update behaves correctly

This is the one genuine unknown in the installation, and it is worth ten minutes now rather
than an incident later.

The job claim is a `PATCH` filtered on `status=1`, which must behave as a single
server-side compare-and-set. Test it:

1. Create a test row in the queue with `status = 1`.
2. Issue two `PATCH` requests to
   `/api/now/table/x_autps_active_dir_command_queue/<sys_id>?sysparm_query=status%3D1`
   as close to simultaneously as you can, each with a different `worker_id`.
3. Read the row back.

**Exactly one `worker_id` must be recorded.** If both requests report success and the second
overwrote the first, your instance does not honour the filter as an atomic operation. In
that case, implement a small Scripted REST endpoint that performs the compare-and-set server
side and point `Request-RmaJobClaim` at it. Nothing else in the codebase changes.

### 1c. Confirm the domain record

The domain record on `x_autps_active_dir_domain` holds **configuration only**. Populate:

| Field | Example |
|---|---|
| `tenant_azure_active_directory` | your Entra tenant ID |
| `forest_name` | `contoso.local` |
| `domain_controller_ip` | `10.0.0.4` |

Record the record's **sys_id**; it is the `DomainId` parameter throughout.

If you are migrating from an earlier version, the fields `thumbprint`,
`entra_id_client_secret_credentials` and `automation_credentials` are no longer read.
Remove them once the new installation is verified. They point at credentials, and a domain
record that points at credentials puts ServiceNow inside your secrets boundary.

### 1d. Integration account

Confirm the account you will use has read on `x_autps_active_dir_domain` and read/write on
`x_autps_active_dir_command_queue`. Record the username; the password goes into Key Vault in
step 7.

---

## Step 2 — Deploy the Azure infrastructure

**Who:** Contributor on the resource group.

Clone the repository. **Do not edit the committed parameter file.** This repository is
public, and a filled-in file publishes your subscription id, resource group, VM name and
subnet. Copy it first:

```bash
cp infra/main.parameters.prod.json infra/main.parameters.prod.local.json
```

`*.local.json` is gitignored, CI rejects real values in the committed templates, and
`Deploy-RmaPlatform.ps1` uses the local copy automatically when it exists.

```jsonc
// infra/main.parameters.prod.local.json
{
  "workload":                   { "value": "rma" },
  "environment":                { "value": "prod" },
  "hybridWorkerVmResourceId":   { "value": "/subscriptions/.../virtualMachines/vm-rma-01" },
  "allowedSubnetResourceId":    { "value": "/subscriptions/.../subnets/snet-automation" },
  "secretsOfficerPrincipalIds": { "value": ["<object id of your operations group>"] },
  "alertEmailAddresses":        { "value": ["operations@example.com"] },
  "logRetentionDays":           { "value": 90 }
}
```

`allowedSubnetResourceId` is the subnet your Hybrid Worker VM sits in. In production the
Key Vault firewall is enabled and only that subnet may reach it. The subnet needs the
`Microsoft.KeyVault` service endpoint, or a private endpoint.

Preview, then deploy:

```powershell
./scripts/Deploy-RmaPlatform.ps1 -ResourceGroup rg-rma-prod -Environment prod -WhatIfOnly
./scripts/Deploy-RmaPlatform.ps1 -ResourceGroup rg-rma-prod -Environment prod
```

The script refuses to proceed if the plan would delete anything, checks afterwards that the
Automation Account has no managed identity, and prints the outputs clearly labelled.

**Record the Key Vault name, the managed identity client ID, and the managed identity
principal ID.**

> **The Automation Account must have no managed identity of its own.** The template sets
> this and the script verifies it. If anyone later enables one in the portal, the Hybrid
> Worker's identity is overridden and every runbook stops authenticating. It is the first
> thing to check if authentication that worked yesterday stops working.

---

## Step 3 — Attach the identity and register the worker

**Who:** Contributor on the VM and the Automation Account.

1. **Attach the user-assigned managed identity to the VM.**
   VM → Identity → User assigned → Add → select `id-rma-prod`.

2. **Register the VM into the Hybrid Worker Group.**
   Automation Account → Hybrid worker groups → `hwg-rma-prod` → Hybrid workers → Add →
   select the VM.

The extension installs and enables a **system-assigned** identity on the VM as well. That is
expected and harmless. It is also why every token request in this solution names the
user-assigned identity explicitly: a request that does not would silently get the
system-assigned one, which has no permissions.

Wait for the worker to report healthy before continuing.

---

## Step 4 — Provision the worker

**Who:** Local administrator on the VM.

Every module the runbooks need must be installed **on this machine**. Modules imported into
an Azure Automation Account are only available to jobs running in Azure's own sandbox; a
Hybrid Worker loads modules from its own `PSModulePath`.

Install PowerShell 7.2+ on the VM if it is not already present, then, from an elevated
`pwsh` prompt:

```powershell
# Review what will change first.
./scripts/Initialize-RmaWorker.ps1 -WhatIf

# Install the pinned module set and the shared RMA.Runbooks module.
./scripts/Initialize-RmaWorker.ps1
```

If the repository is not checked out on the VM, install from a release asset instead:

```powershell
./scripts/Initialize-RmaWorker.ps1 `
    -ModuleSource 'https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/releases/download/v1.0.0/RMA.Runbooks-1.0.0.zip'
```

Verify:

```powershell
Get-Module -ListAvailable RMA.Runbooks, Microsoft.Graph.Authentication, ExchangeOnlineManagement |
    Select-Object Name, Version, ModuleBase
```

Two things to confirm:

- `RMA.Runbooks` resolves from `C:\Program Files\PowerShell\Modules`. Hybrid Worker jobs run
  as local **SYSTEM**, so a per-user install is invisible to them.
- **One version per module.** More than one means an older installation is still present.
  Run `./scripts/Initialize-RmaWorker.ps1 -PruneUnpinned` to remove superseded versions and
  reclaim the disk.

**If you have more than one worker in the group, repeat this step on every one of them.** A
worker missing the module fails every job routed to it, which presents as intermittent
failures rather than an obvious outage.

---

## Step 5 — Create the app registration

**Who:** Cloud Application Administrator.

```powershell
./scripts/Set-RmaAppRegistration.ps1 `
    -DisplayName 'RMA Runbooks (prod)' `
    -ManagedIdentityPrincipalId '<managed identity PRINCIPAL id from step 2>' `
    -TenantId '<your tenant id>'
```

The script is idempotent. It creates the application, requests the API permissions, and
creates the federated identity credential that lets the managed identity act as the
application. It creates no secret and no certificate; there is nothing here to expire or
rotate.

**Record the Application (client) ID** that it prints.

Double-check the subject on the federated credential is the **principal** ID, not the client
ID. Entra accepts either without complaint.

---

## Step 6 — Grant consent and the directory role

**Who:** Privileged Role Administrator or Global Administrator.

Two manual actions, deliberately left to a person.

1. **Grant admin consent.**
   Entra → App registrations → your app → API permissions → *Grant admin consent*.
   All permissions must show **Granted**. An ungranted permission produces a token that is
   rejected when used rather than refused when issued, so the failure appears one layer away
   from its cause.

2. **Assign the directory role.**
   Entra → Roles and administrators → **Exchange Recipient Administrator** → Add assignment
   → select the application's service principal.

   Recipient Administrator covers every Exchange operation these runbooks perform. Exchange
   Administrator and Global Administrator both work and both grant far more than is needed.

---

## Step 7 — Add the secrets

**Who:** Key Vault Secrets Officer.

Two secrets, and only two. Everything else authenticates with the managed identity.

```bash
az keyvault secret set --vault-name <kv-name> \
  --name servicenow-api-password --value '<password>' \
  --expires "$(date -u -d '+1 year' '+%Y-%m-%dT%H:%M:%SZ')"

az keyvault secret set --vault-name <kv-name> \
  --name ad-service-account-password --value '<password>' \
  --expires "$(date -u -d '+1 year' '+%Y-%m-%dT%H:%M:%SZ')"
```

Set the expiry dates. They are what makes the near-expiry notification fire, which is the
only thing standing between you and a password lapsing unnoticed.

If the Key Vault firewall is on, run these from inside the allowed subnet, or temporarily
add your own IP.

---

## Step 8 — Publish the runbooks

**Who:** Contributor on the Automation Account.

```powershell
Connect-AzAccount
./scripts/Publish-RmaContent.ps1 `
    -ResourceGroup rg-rma-prod `
    -AutomationAccountName aa-rma-prod
```

Each runbook is imported as a Draft and then published, so a failed import cannot take a
working runbook offline. The script also refuses to publish a runbook that pins a different
`RMA.Runbooks` version than the one you installed in step 4.

The shared module is **not** published to the Automation Account. It lives on the worker.

---

## Step 9 — Verify

**Who:** anyone who can start a runbook.

Run the health check on the real worker, with every value you recorded:

```powershell
Start-AzAutomationRunbook `
    -ResourceGroupName rg-rma-prod `
    -AutomationAccountName aa-rma-prod `
    -Name 'Test-RmaHealth' `
    -RunOn 'hwg-rma-prod' `
    -Parameters @{
        DomainId                = '<domain record sys_id>'
        Instance                = '<servicenow instance name>'
        VaultName               = '<key vault name>'
        ManagedIdentityClientId = '<managed identity CLIENT id>'
        ServiceNowUserName      = '<integration account username>'
        ApplicationId           = '<application client id>'
        IncludeActiveDirectory  = $true
    }
```

It performs no writes. Expected output:

```
RMA health check
================
Check                                       Status   Ms  Detail
-----                                       ------   --  ------
Managed identity token                      Pass    120  acquired
Key Vault + ServiceNow + domain record      Pass    840  tenant <guid>
Microsoft Graph token exchange              Pass    310  federated token acquired
ServiceNow command queue readable           Pass    260  queue reachable (0 pending)
Active Directory reachable                  Pass     90  contacted 10.0.0.4
All checks passed.
```

**Do not continue until every check passes.** A green deployment with a broken identity
looks exactly like a working one until the first real job fails.

Then work through the [production checklist](PRODUCTION-CHECKLIST.md), which covers the
verification this guide does not: the duplicate-execution test, the stranding test, and
confirming secrets never reach the logs.

---

## Step 10 — Create the schedules

**Who:** Contributor on the Automation Account.

Only once step 9 passes and the checklist is complete.

Each runbook needs a schedule, with the same parameters used in step 9.

> **Azure Automation schedules cannot run more often than once an hour.** That is a platform
> limit, not a setting. For a 15 minute cadence the documented approach is four hourly
> schedules offset by 15 minutes each. The alternative is a Logic App calling a runbook
> webhook, which gives finer control at the cost of another moving part.

### The watchdog

**This one is not optional.** `Invoke-RmaQueueWatchdog` requeues jobs whose worker died
before finishing. Without it those jobs stay in Work in Progress forever, invisible, and are
never retried.

Four offset hourly schedules give an effective 15 minute cadence:

```powershell
$rg     = 'rg-rma-prod'
$aa     = 'aa-rma-prod'
$group  = 'hwg-rma-prod'
$params = @{
    DomainId                = '<domain record sys_id>'
    Instance                = '<servicenow instance name>'
    VaultName               = '<key vault name>'
    ManagedIdentityClientId = '<managed identity CLIENT id>'
    ServiceNowUserName      = '<integration account username>'
    StaleAfterMinutes       = 60      # must exceed your longest expected job
}

# Start on the next whole hour so the four offsets land on :00, :15, :30, :45.
$base = (Get-Date).Date.AddHours((Get-Date).Hour + 2)

foreach ($offset in 0, 15, 30, 45) {
    $name = "watchdog-hourly-$offset"

    New-AzAutomationSchedule -ResourceGroupName $rg -AutomationAccountName $aa `
        -Name $name -StartTime $base.AddMinutes($offset) -HourInterval 1 | Out-Null

    Register-AzAutomationScheduledRunbook -ResourceGroupName $rg -AutomationAccountName $aa `
        -RunbookName 'Invoke-RmaQueueWatchdog' -ScheduleName $name `
        -RunOn $group -Parameters $params | Out-Null

    Write-Host "scheduled watchdog at :$('{0:d2}' -f $offset)"
}
```

### The command runbooks

One schedule each, hourly to begin with. Start conservative: it is easier to add offsets
later than to explain a thundering herd. Use the queue depth after a week to decide whether
you need a finer cadence.

```powershell
New-AzAutomationSchedule -ResourceGroupName $rg -AutomationAccountName $aa `
    -Name 'commands-hourly' -StartTime $base -HourInterval 1

Register-AzAutomationScheduledRunbook -ResourceGroupName $rg -AutomationAccountName $aa `
    -RunbookName 'Create-EntraUser' -ScheduleName 'commands-hourly' `
    -RunOn $group -Parameters $commandParams
```

Because every job is claimed atomically, overlapping runs are safe. That is what lets you
add offsets or workers later without redesigning anything.

`StaleAfterMinutes` must be comfortably above your longest expected job, or the watchdog
will requeue work that is still running. With `MaxMinutes` at its default of 45, a
`StaleAfterMinutes` of 60 is a sensible floor.

---

## Troubleshooting

Symptoms in the order you are likely to meet them.

### The health check fails on "Managed identity token"

Almost always the Automation Account identity:

```bash
az automation account show -g rg-rma-prod -n aa-rma-prod --query identity.type
```

It must return `None`. Anything else overrides the VM's identity. Disable it under
Automation Account → Identity.

If it is already `None`, confirm the user-assigned identity is attached to the VM and that
you passed its **client** ID, not its principal ID.

### The health check fails on "Key Vault"

The role assignment or the firewall. Confirm the managed identity has **Key Vault Secrets
User** on the vault, and that the worker's subnet is in the vault's network rules. Test from
the VM itself, not from your workstation.

### The health check fails on "Microsoft Graph token exchange"

In order:

1. Is the federated credential's **subject** the managed identity's principal ID? This is
   the most common cause. It saves without error when wrong.
2. Is the issuer `https://login.microsoftonline.com/<tenant-id>/v2.0`, with no trailing
   whitespace?
3. Is the audience `api://AzureADTokenExchange`?
4. Has admin consent been granted?

### A runbook fails immediately with "module not found" or a #Requires error

`RMA.Runbooks` is missing from that worker, or is a different version than the runbook pins.
On the worker:

```powershell
Get-Module -ListAvailable RMA.Runbooks | Select-Object Version, ModuleBase
```

Re-run `Initialize-RmaWorker.ps1`. If you have several workers, check all of them: a single
unprovisioned worker produces failures that look intermittent because only the jobs routed
to it fail.

Importing the module into the Automation Account will not fix this. Azure does not deliver
Automation Account modules to Hybrid Workers.

### Jobs sit in "Work in Progress" and never finish

The worker died mid-job. The watchdog requeues them; confirm it is scheduled and check its
own job history. If many jobs are stranded at once, the watchdog deliberately refuses to act
and raises instead, because mass stranding means something systemic and requeueing hundreds
of jobs into a broken system makes it worse.

### The same job appears to run twice

Return to step 1b. The conditional `PATCH` is not behaving as an atomic compare-and-set on
your instance, and you need the Scripted REST endpoint approach.

### The worker's disk fills up

Historic module versions. Run:

```powershell
./scripts/Initialize-RmaWorker.ps1 -PruneUnpinned
```

Check specifically that the `Microsoft.Graph.Beta` **meta-module** is not installed. Only
`Microsoft.Graph.Beta.Users` is needed; the meta-module pulls forty submodules and over a
gigabyte.

### Everything works, then stops after some weeks

Check the Key Vault secret expiry dates and whether the ServiceNow or AD account password
was rotated outside this process. Nothing else in this design expires.

---

## Getting help

Include when reporting a problem:

- The full `Test-RmaHealth` output.
- The failing job's output from the Automation Account.
- `Get-Module -ListAvailable RMA.Runbooks` from the worker.
- `az automation account show ... --query identity.type`.

Those four answer most questions immediately. Never include secret values, and note that
job output is deliberately redacted, so pasting it is safe.
