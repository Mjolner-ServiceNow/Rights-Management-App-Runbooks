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
| 2 | Contributor on the resource group, and rights to create it | Azure |
| 3 | Contributor on the resource group | Azure |
| 4 | Contributor on the VM (for Run Command), or local administrator on it | Azure or Windows |
| 5 | Cloud Application Administrator | Microsoft Entra |
| 6 | Privileged Role Administrator or Global Administrator | Microsoft Entra |
| 7 | Key Vault Secrets Officer, plus the actual passwords | Azure |
| 8, 9 | Contributor on the Automation Account | Azure |

Steps 5 and 6 are separate deliberately. Step 5 can be delegated; step 6 grants a directory
role and should not be.

### What you need

- An Azure subscription, and a resource group to put the platform in.
- A **Windows Server VM in Azure** that will run the jobs. Two cores and 4 GB RAM minimum.
  It must reach your domain controllers and `service-now.com`.
- A ServiceNow instance with the Rights Management App scoped application installed.
- An **Active Directory service account** that can create, modify and disable users and
  groups in the target OUs.
- A **ServiceNow integration account** with read access to the domain table and read/write
  on the command queue table.
- Tooling on your workstation: [Azure CLI](https://aka.ms/azure-cli),
  [PowerShell 7.4+](https://aka.ms/powershell), and the `Microsoft.Graph.Applications`
  module for step 5. Nothing here publishes runbooks, so `Az.Automation` is not needed.

### How long

Roughly half a day of work, spread across whatever approval waits your organisation
imposes. The Azure parts take minutes; the Entra consent is the one that queues.

### Values to record as you go

Keep these somewhere as you work. Four of them are produced by one step and consumed by
another.

| Value | Produced in | Used in |
|---|---|---|
| Domain record sys_id | Step 1 | Step 9, and the ServiceNow application |
| ServiceNow instance name | Step 1 | Step 9, and the ServiceNow application |
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

## Step 1 — Confirm the ServiceNow application

**Who:** ServiceNow administrator.

**You do not add anything to the command queue table.** `worker_id` and `claimed_at`, and
the behaviour that depends on them, ship with the scoped application: they arrive when the
customer updates it. Earlier versions of this guide had you add the columns by hand — if you
are following those instructions, stop.

What remains here is the configuration only the customer can supply.

### 1a. Confirm the application version

The queue claim needs `worker_id` and `claimed_at` on
`x_autps_active_dir_command_queue`. Confirm the installed application version includes
them before going further.

**Without them nothing runs at all.** The Table API ignores unknown fields silently, so the
claim `PATCH` appears to succeed and moves the row to Work in Progress — then the read-back
in `Request-RmaJobClaim` finds no `worker_id`, every claim is lost, and rows strand in Work
in Progress with no terminal state. It does not fail loudly; it fails as silence.

### 1b. Populate the domain record

The domain record on `x_autps_active_dir_domain` holds **configuration only**, and its
values are specific to this customer, so they cannot ship with the application:

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

### 1c. Integration account

Confirm the account the runbooks will use has read on `x_autps_active_dir_domain` and
read/write on `x_autps_active_dir_command_queue`. Record the username; the password goes
into Key Vault in step 7.

---

## Step 2 — Create the Azure resources

**Who:** Contributor on the resource group.

> **There is no infrastructure-as-code in this repository.** The Bicep templates were
> removed because they did not meet the bar, and are deferred until the wider framework is
> in place. Create these resources by hand, in the portal or with `az`. What follows is a
> requirement, not a suggestion: the runbooks assume it.

All of it goes in one resource group, per environment.

| Resource | Required configuration |
|---|---|
| User-assigned managed identity | The only identity the platform uses. Record both its **client** ID and its **principal** ID. |
| Automation Account | **No managed identity** — see the warning below. Create a Hybrid Worker Group in it for the worker VM. |
| Key Vault | RBAC authorisation, not access policies. Soft delete on. In production also: purge protection, public access disabled, and a network rule for the worker VM's subnet only. |
| Log Analytics workspace | Diagnostic settings on both the Automation Account and the Key Vault point at it. |
| Action group and alert rules | Optional in dev and test. Production notifies on job failure and on the queue loop hitting its bounds. |

Role assignments on the Key Vault, by built-in role ID:

| Assignee | Role | Role ID |
|---|---|---|
| The user-assigned managed identity | Key Vault Secrets User | `4633458b-17de-408a-b874-0445c86b69e6` |
| Your operations group | Key Vault Secrets Officer | `b86a8fe4-44ce-4948-aee5-eccb2c155cd7` |

The subnet in the production Key Vault firewall rule is the one the Hybrid Worker VM sits
in, and it needs the `Microsoft.KeyVault` service endpoint, or a private endpoint.

Scheduled query rules over the Automation tables fail validation until Automation has sent
data to the workspace, because the tables do not exist yet. Create them with query
validation skipped, or wait until after the first job has run.

**Record the Key Vault name, the managed identity client ID, and the managed identity
principal ID.**

> **The Automation Account must have no managed identity of its own.** Nothing enforces
> this any more: no template sets it and no script checks it. If one is enabled at creation,
> or by anyone later in the portal, the Hybrid Worker's identity is overridden and every
> runbook stops authenticating. It is the first thing to check if authentication that worked
> yesterday stops working.

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

**Who:** Contributor on the VM, or local administrator on it.

Provisioning is two scripts, in order. The first makes the machine capable of running
PowerShell 7 runbooks at all; the second installs the modules. They are separate because
`Initialize-RmaWorker.ps1` declares `#Requires -Version 7.2`, so it cannot be the thing that
installs PowerShell 7.

### How to run them without a console on the VM

The worker usually has no public IP. Azure Run Command reads the script from your
workstation and executes it on the VM through the Azure control plane, so you need no
inbound network access, no repository checkout on the VM, and no credentials on it:

```bash
az vm run-command invoke \
  --resource-group rg-rma-prod --name vm-rma-01 \
  --command-id RunPowerShellScript \
  --scripts @scripts/Initialize-RmaWorkerHost.ps1
```

`--parameters name=value` maps to the script's named parameters, and the output comes back
to your terminal.

Run Command also executes as local **SYSTEM**, which is the account Hybrid Worker jobs run
under. That matters: it makes it structurally impossible to install into the wrong profile,
which is the mistake the `AllUsers` note below exists to prevent.

If you would rather work on the VM directly, both scripts run the same way from an elevated
prompt over Bastion or RDP.

### 4a. Make the machine a PowerShell 7 host

```powershell
./scripts/Initialize-RmaWorkerHost.ps1 -WhatIf
./scripts/Initialize-RmaWorkerHost.ps1
```

It runs under the Windows PowerShell 5.1 that ships with the operating system, and it:

- installs PowerShell 7.6 (the current LTS, supported to 14 November 2028), verified
  against the release's published SHA-256;
- sets the machine environment variable that tells the Hybrid Worker extension where
  `pwsh.exe` is;
- bootstraps the NuGet package provider inside PowerShell 7, so 4b does not stop to fetch
  it from a host your firewall may not allow;
- restarts `HybridWorkerService`, which is when the environment variable takes effect.

> **The environment variable is the part that is easy to miss and hard to diagnose.** An
> extension-based Windows worker locates the interpreter through a machine variable named
> after the runbook's runtime version: `powershell_7_6_path`, `powershell_7_4_path`,
> `powershell_7_2_path`. Not `PATH`. If it is absent the worker still registers and still
> reports healthy, and every PowerShell 7 job fails to start with nothing in the job output
> that points at the cause.
>
> The script also registers the same interpreter under the older names by default, so a
> runbook not yet moved to a 7.6 Runtime environment keeps working. Pass `-SkipLegacyPaths`
> once every runbook is on 7.6, so that one left behind fails loudly instead of quietly
> running on an interpreter it did not declare.
>
> Microsoft documents the 7.4 and 7.2 variable names. The 7.6 name follows the same pattern,
> but the Hybrid Worker article has not been updated for 7.6 at the time of writing, so
> confirm it on a new worker: run any runbook linked to a 7.6 Runtime environment on the
> hybrid group. A job that sits in **Queued** and produces nothing means the name is wrong.

PowerShell 7.x runbooks also need Hybrid Worker extension **1.3.63 or above**. The script
prints the installed version and warns if it is older.

### 4b. Install the modules

Every module the runbooks need must be installed **on this machine**. Modules imported into
an Azure Automation Account are only available to jobs running in Azure's own sandbox; a
Hybrid Worker loads modules from its own `PSModulePath`.

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

### Verify

```powershell
Get-Module -ListAvailable RMA.Runbooks, Microsoft.Graph.Authentication, ExchangeOnlineManagement |
    Select-Object Name, Version, ModuleBase

[Environment]::GetEnvironmentVariable('powershell_7_6_path', 'Machine')
```

Three things to confirm:

- `powershell_7_6_path` returns a path to a `pwsh.exe` that exists, and `pwsh -v` reports
  7.6.x.
- `RMA.Runbooks` resolves from `C:\Program Files\PowerShell\Modules`. Hybrid Worker jobs run
  as local **SYSTEM**, so a per-user install is invisible to them.
- **One version per module.** More than one means an older installation is still present.
  Run `./scripts/Initialize-RmaWorker.ps1 -PruneUnpinned` to remove superseded versions and
  reclaim the disk.

**If you have more than one worker in the group, run both scripts on every one of them.** A
worker missing a module or the environment variable fails every job routed to it, which
presents as intermittent failures rather than an obvious outage.

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

## Step 8 — Runbook publication

**Who:** nobody, for the publication itself. Contributor on the Automation Account for the
one prerequisite below.

**The customer does not publish the runbooks.** The ServiceNow application pulls them from
this repository and adds them to the Automation Account. This repository publishes nothing;
what it guarantees is that `main` is always internally consistent, which is what the
application copies. `tests/Unit/PinnedModuleVersions.Tests.ps1` and
`build/Assert-ModuleVersionBump.ps1` enforce that on every pull request.

**One prerequisite you do have to create:** a PowerShell **7.6** Runtime environment in the
Automation account, for the application to link the runbooks to. Create it under Automation account > **Runtime Environments**
(Language PowerShell, Runtime version 7.4 or 7.6), or with the API:

```bash
az rest --method put \
  --url "https://management.azure.com/subscriptions/<subId>/resourceGroups/rg-rma-prod/providers/Microsoft.Automation/automationAccounts/aa-rma-prod/runtimeEnvironments/Powershell_7-6?api-version=2024-10-23" \
  --body '{"properties":{"runtime":{"language":"PowerShell","version":"7.6"}}}'
```

After the application has published them, confirm in the Automation Account that each
runbook is of type **PowerShell** and linked to the `Powershell_7-6` Runtime environment. A runbook
linked to no Runtime environment, or to the wrong one, never starts on a worker that has
only PowerShell 7.6 registered, and the job output is empty — see *A PowerShell 7 runbook
never starts* in Troubleshooting.

The shared module is **not** published to the Automation Account. It lives on the worker.

> **Why the runtime version is a Runtime environment and not a runbook type.** This is the
> non-obvious part, and anything that imports these runbooks has to get it right.
>
> PowerShell 7.4 and 7.6 exist only in the Runtime environment experience.
> `Import-AzAutomationRunbook`'s `-Type` stops at `PowerShell72`, and the API rejects a
> `runtimeEnvironment` on a `PowerShell72` runbook with *"The property runtimeEnvironment
> cannot be configured for runbookType PowerShell72"*. So a runbook must be imported as
> type `PowerShell` and then **linked** to a Runtime environment; that link, not the type,
> decides the interpreter.
>
> Runbook type is immutable through the API's PUT, which is what an import uses, so
> importing over a runbook previously created as `PowerShell72` fails with *"Runbook Type
> cannot be modified"*. A PATCH *can* change the type and set the Runtime environment in
> one call, so a migration is a PATCH first, then the import — no deletion needed.
>
> Importing as a Draft and publishing afterwards is worth keeping too: the live version
> keeps serving until the draft is published, so a failed import cannot take a working
> runbook offline.

---

## Step 9 — Verify

**Who:** nobody, in the normal case.

**The customer does not trigger the health check.** The ServiceNow application runs
`Test-RmaHealth` and surfaces the result in ServiceNow, where the status of each check is
visible without leaving the platform. That is the intended way to read it, during
installation and afterwards.

**Do not continue until every check passes.** A green deployment with a broken identity
looks exactly like a working one until the first real job fails.

Then work through the [production checklist](PRODUCTION-CHECKLIST.md), which covers the
verification this guide does not: the duplicate-execution test, the stranding test, and
confirming secrets never reach the logs.

### Running it by hand

Only needed when the application cannot reach Azure at all, or when you are diagnosing why
the automatic run is failing — at which point the ServiceNow-side view is exactly what is
unavailable. It performs no writes, so it is safe to run at any time:

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

Expected output:

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

---

## Step 10 — How work reaches the worker

**Who:** nobody. There is nothing to create here.

**There are no Azure Automation schedules in this design.** Every job is event-driven:

1. Something happens in ServiceNow — a user requests a password reset, an account is
   onboarded, a group membership changes.
2. The application writes a row to `x_autps_active_dir_command_queue` with `status = 1`.
3. The application starts the matching runbook job in Azure Automation, on the Hybrid
   Worker group.
4. `Invoke-RmaQueueLoop` claims and drains what is queued for that command and domain,
   then exits.

A triggered run **drains the queue** rather than handling the single row that caused it, so
a burst of requests does not produce a burst of runbook jobs each doing one row. `MaxJobs`
and `MaxMinutes` bound the run; `EmptyPollsBeforeExit` ends it once the queue is empty.

Overlapping runs are safe and expected. Two requests close together can start two runbook
jobs that poll the same queue at the same time. The atomic claim is what makes that
correct; `BatchSize` is what keeps them from fighting over the same rows. See *Scaling* in
[ARCHITECTURE.md](ARCHITECTURE.md).

### The watchdog

`Invoke-RmaQueueWatchdog` is also started by the ServiceNow application, but on a cadence
rather than in response to a request. It cannot be request-driven: it requeues jobs whose
worker died before finishing, and **there is no event for "a worker died"** — it is a sweep,
and something has to run it periodically.

`StaleAfterMinutes` must be comfortably above the longest expected job, or the watchdog will
requeue work that is still running. With `MaxMinutes` at its default of 45, a
`StaleAfterMinutes` of 60 is a sensible floor.

### If you find schedules in an existing installation

Earlier versions of this guide had you create Azure Automation schedules for each runbook,
plus four offset hourly schedules for the watchdog. Those are obsolete. Remove them: two
things starting the same runbook doubles claim contention and buys nothing, and a scheduled
run competing with an event-driven one makes queue latency harder to reason about, not
easier.

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

### A PowerShell 7 runbook never starts, and the job output is empty

The worker cannot find the interpreter. On the worker:

```powershell
[Environment]::GetEnvironmentVariable('powershell_7_6_path', 'Machine')
[Environment]::GetEnvironmentVariable('powershell_7_4_path', 'Machine')
[Environment]::GetEnvironmentVariable('powershell_7_2_path', 'Machine')
```

The one matching the runbook's runtime version must return a path to an existing `pwsh.exe`.
`PATH` is not consulted for 7.2, 7.4 or 7.6. Check which Runtime environment the runbook is
actually linked to, since that is what decides which variable is read:

```bash
az rest --method get --url "https://management.azure.com/subscriptions/<subId>/resourceGroups/rg-rma-prod/providers/Microsoft.Automation/automationAccounts/aa-rma-prod/runbooks/Create-EntraUser?api-version=2024-10-23" \
  --query "properties.runtimeEnvironment"
``` If it is empty, re-run
`./scripts/Initialize-RmaWorkerHost.ps1`, which sets it and restarts the service. The
variable is read only when the service starts, so setting it by hand and not restarting
changes nothing.

Then check the extension version, because PowerShell 7.4 runbooks need 1.3.63 or above:

```bash
az vm extension show -g rg-rma-prod --vm-name vm-rma-01 \
  --name HybridWorkerExtension --query typeHandlerVersion
```

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

The worker died mid-job. The watchdog requeues them; confirm the ServiceNow application is
still triggering it on its cadence, and check its own job history. If many jobs are stranded at once, the watchdog deliberately refuses to act
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

Check specifically that no `Microsoft.Graph.Beta*` module is installed. None is needed: the
runbooks call no `Get-MgBeta*` cmdlet. The `Microsoft.Graph.Beta` meta-module in particular
pulls forty submodules and over a gigabyte, and `Initialize-RmaWorker.ps1` removes it.

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
