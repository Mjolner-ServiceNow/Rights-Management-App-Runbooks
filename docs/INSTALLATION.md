# Installation guide

**Scope: the Azure side only** — the runbooks, the worker, the identity and the secrets.

Setting up the ServiceNow application itself is a **separate guide, maintained outside this
repository**. That is where the scoped application is installed, the domain record is
populated and the integration account is created. Nothing in this repository asks you to
change anything in ServiceNow.

Do the ServiceNow guide first. It produces three values this one consumes, listed under
*Values to record* below. The two guides will be merged into one end-to-end document once
the solution is settled; until then they are read in that order.

Follow the steps here in order: each one produces a value the next one needs. What the
Azure resources are, and how each must be configured, is specified in
[`AZURE-RESOURCES.md`](AZURE-RESOURCES.md); this guide is the procedure that builds it.

For updating an existing installation, see [`DEPLOYMENT.md`](DEPLOYMENT.md). For day-to-day
running, see [`RUNBOOK-OPERATIONS.md`](RUNBOOK-OPERATIONS.md).

---

## Before you start

### Who you need

This guide touches three systems, and no single person usually has rights to all of them.
Line these people up before you begin, because waiting for an approval mid-install is the
most common reason this takes days instead of hours.

| Step | Role required | Where |
|---|---|---|
| 1 | Contributor on the subscription, or rights to create the three resource groups | Azure |
| 2 | Contributor on `rg-rma-automation-prod` and `rg-rma-workloads-prod` | Azure |
| 3 | Contributor on the VM (for Run Command), or local administrator on it | Azure or Windows |
| 4 | Cloud Application Administrator | Microsoft Entra |
| 5 | Privileged Role Administrator or Global Administrator | Microsoft Entra |
| 6 | Key Vault Secrets Officer, plus the actual passwords | Azure |
| 7 | Contributor on the Automation Account | Azure |

Steps 4 and 5 are separate deliberately. Step 4 can be delegated; step 5 grants a directory
role and should not be.

The ServiceNow administrator is not listed, because none of their work happens here — see
the scope note above.

### What you need

- An Azure subscription.
- A network the worker VM can be placed in that reaches your domain controllers and your
  ServiceNow instance. The VM itself is created in step 1.
- **The ServiceNow guide already completed**, which leaves you with a working scoped
  application, a populated domain record and an integration account. You need the three
  values it produces, not access to change any of it.
- An **Active Directory service account** that can create, modify and disable users and
  groups in the target OUs.
- Tooling on your workstation: [Azure CLI](https://aka.ms/azure-cli),
  [PowerShell 7.4+](https://aka.ms/powershell), and the `Microsoft.Graph.Applications`
  module for step 4. Nothing here publishes runbooks, so `Az.Automation` is not needed.

### How long

Roughly half a day of work, spread across whatever approval waits your organisation
imposes. The Azure parts take minutes; the Entra consent is the one that queues.

### Values to record as you go

Three come from the ServiceNow guide. The rest are produced by one step here and consumed
by another.

| Value | Produced in | Used in |
|---|---|---|
| Domain record sys_id | **ServiceNow guide** | Step 8 |
| ServiceNow instance name | **ServiceNow guide** | Step 8 |
| Integration account username | **ServiceNow guide** | Steps 6, 8 |
| Managed identity **client** ID | Step 1 | Step 8 |
| Managed identity **principal** ID | Step 1 | Step 4 |
| Key Vault name | Step 1 | Steps 6, 8 |
| Tenant ID | Your Entra tenant | Steps 4, 8 |
| Application (client) ID | Step 4 | Step 8 |
| AD service account username and a domain controller | Your AD | Steps 6, 8 |

If you do not have the first three, stop and go back to the ServiceNow guide. Step 6 puts
the integration account's password into Key Vault, and step 8 cannot verify anything
without the other two.

**Every value in this table except the principal ID ends up in the ServiceNow
application**, which passes them to the runbooks as parameters when it starts a job. The
runbooks read no configuration from ServiceNow. Hand them to whoever configures the
application; the ServiceNow guide says where each one goes. The full list is under
*Runbook parameters* in [`ARCHITECTURE.md`](ARCHITECTURE.md).

> **The two managed identity GUIDs are different and are not interchangeable.** The client
> ID is what a runbook uses to request a token. The principal ID is what the federated
> credential trusts. Swapping them creates a credential that saves without any error and
> fails only later, at token exchange, with a message that does not point at the cause.
> This is the single most common installation mistake.

---

## Step 1 — Create the Azure resources

**Who:** Contributor on the subscription.

> **There is no infrastructure-as-code in this repository.** Create the resources by hand,
> in the portal or with `az`.

Build what [`AZURE-RESOURCES.md`](AZURE-RESOURCES.md) specifies, from the resource groups
through the Key Vault and its role assignments:

| Resource | Resource group |
|---|---|
| Automation Account `aa-rma-prod`, with Hybrid Worker Group `hwg-rma-prod` | `rg-rma-automation-prod` |
| Virtual machine `vm-rma-hw1-prod` | `rg-rma-workloads-prod` |
| User-assigned managed identity `id-rma-prod` | `rg-rma-shared-prod` |
| Key Vault `kv-rma-<suffix>-prod` | `rg-rma-shared-prod` |

The secrets and the app registration come later, in steps 4 to 6. That document is the
requirement, not a suggestion: the runbooks assume every setting in it.

**Record the Key Vault name, the managed identity client ID, and the managed identity
principal ID.**

> **The Automation Account must have no managed identity of its own.** The portal enables a
> system-assigned one by default, so turn it off when you create the account. Nothing checks
> this afterwards. If one is enabled, at creation or later, the Hybrid Worker's identity is
> overridden and every runbook stops authenticating. It is the first thing to check if
> authentication that worked yesterday stops working.

---

## Step 2 — Attach the identity and register the worker

**Who:** Contributor on the VM and the Automation Account.

1. **Attach the user-assigned managed identity to the VM.**
   VM → Identity → User assigned → Add → select `id-rma-prod`.

2. **Register the VM into the Hybrid Worker Group.**
   Automation Account → Hybrid worker groups → `hwg-rma-prod` → Hybrid workers → Add →
   select the VM.

The VM also has a **system-assigned** identity, which the Hybrid Worker extension needs. That
is expected and harmless. It is also why every token request in this solution names the
user-assigned identity explicitly: a request that does not would silently get the
system-assigned one, which has no permissions.

Wait for the worker to report healthy before continuing.

---

## Step 3 — Provision the worker

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
  --resource-group rg-rma-workloads-prod --name vm-rma-hw1-prod \
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

### 3a. Make the machine a PowerShell 7 host

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

### 3b. Install the modules

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

## Step 4 — Create the app registration

**Who:** Cloud Application Administrator.

```powershell
./scripts/Set-RmaAppRegistration.ps1 `
    -DisplayName 'RMA Runbooks (prod)' `
    -ManagedIdentityPrincipalId '<managed identity PRINCIPAL id from step 1>' `
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

## Step 5 — Grant consent and the directory role

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

## Step 6 — Add the secrets

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

Set the expiry dates to match the passwords' own lifetimes. Nothing in this solution warns
you before a password lapses, so the expiry date on the secret is where the renewal date is
written down.

If the Key Vault firewall is on, run these from inside the allowed subnet, or temporarily
add your own IP.

---

## Step 7 — Runbook publication

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
  --url "https://management.azure.com/subscriptions/<subId>/resourceGroups/rg-rma-automation-prod/providers/Microsoft.Automation/automationAccounts/aa-rma-prod/runtimeEnvironments/Powershell_7-6?api-version=2024-10-23" \
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

## Step 8 — Verify

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
    -ResourceGroupName rg-rma-automation-prod `
    -AutomationAccountName aa-rma-prod `
    -Name 'Test-RmaHealth' `
    -RunOn 'hwg-rma-prod' `
    -Parameters @{
        DomainId                = '<domain record sys_id>'
        Instance                = '<servicenow instance name>'
        VaultName               = '<key vault name>'
        ManagedIdentityClientId = '<managed identity CLIENT id>'
        ServiceNowUserName      = '<integration account username>'
        TenantId                = '<tenant id>'
        ApplicationId           = '<application client id>'
        DomainController        = '<domain controller host name or IP>'
        AdUserName              = '<AD service account username>'
    }
```

`DomainController` and `AdUserName` add the Active Directory check, which reads the AD
password from Key Vault and signs in with it. Leave both out to check only the Entra side.
With more than one AD domain, pass `AdSecretName` as well.

Expected output:

```
RMA health check
================
Check                                       Status   Ms  Detail
-----                                       ------   --  ------
Managed identity token                      Pass    120  acquired
Key Vault + ServiceNow                      Pass    840  authenticated as <username>
Microsoft Graph token exchange              Pass    310  federated token acquired for tenant <guid>
ServiceNow command queue readable           Pass    260  queue reachable (0 pending for this command)
Active Directory reachable                  Pass     90  contacted 10.0.0.4 as <username> (contoso.local)
All checks passed.
```

---

## Step 9 — How work reaches the worker

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
az automation account show -g rg-rma-automation-prod -n aa-rma-prod --query identity.type
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
az rest --method get --url "https://management.azure.com/subscriptions/<subId>/resourceGroups/rg-rma-automation-prod/providers/Microsoft.Automation/automationAccounts/aa-rma-prod/runbooks/Create-EntraUser?api-version=2024-10-23" \
  --query "properties.runtimeEnvironment"
``` If it is empty, re-run
`./scripts/Initialize-RmaWorkerHost.ps1`, which sets it and restarts the service. The
variable is read only when the service starts, so setting it by hand and not restarting
changes nothing.

Then check the extension version, because PowerShell 7.4 runbooks need 1.3.63 or above:

```bash
az vm extension show -g rg-rma-workloads-prod --vm-name vm-rma-hw1-prod \
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

The conditional `PATCH` behind the job claim is not behaving as an atomic compare-and-set
on your instance. That is a ServiceNow-side problem: raise it with whoever maintains the
scoped application, who will need the Scripted REST endpoint approach. Nothing in this
guide changes.

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
