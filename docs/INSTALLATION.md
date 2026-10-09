# Installation guide

**Scope: the Azure side only** — the runbooks, the worker, the identity and the secrets.

Setting up the ServiceNow application itself is the **ServiceNow team's responsibility**,
not this repository's: installing the scoped application, populating the domain record and
creating the integration account. There is no written guide for it yet; until there is,
those steps are done by, or with, the ServiceNow team. Nothing in this repository asks you
to change anything in ServiceNow.

The two halves interleave rather than run one after the other, because each needs values
the other produces. In order:

1. **ServiceNow first, in part:** the scoped application installed, the integration
   account and the domain record created. That yields the three values this guide
   consumes, listed under *Values to record* below.
2. **This guide**, steps 1 to 7.
3. **ServiceNow again:** enter the Azure values this guide produced into the domain record
   and the application's configuration. Step 8 cannot pass before that, because it is the
   application that starts the health check with those values.

Once the ServiceNow team has written its guide, the two can be merged into one end-to-end
document.

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
| 1 | Contributor on the subscription, or rights to create the three resource groups, **plus** Owner, User Access Administrator or Role Based Access Control Administrator to create the role assignments | Azure |
| 1 | Application Administrator or Cloud Application Administrator, for ServiceNow's app registration | Microsoft Entra |
| 2 | Contributor on the VM and the Automation Account, plus Managed Identity Operator on `id-rma-prod` (or Contributor on `rg-rma-shared-prod`) to attach it | Azure |
| 3 | Contributor on the VM (for Run Command), or local administrator on it | Azure or Windows |
| 4 | Application Administrator or Cloud Application Administrator | Microsoft Entra |
| 5 | Privileged Role Administrator or Global Administrator | Microsoft Entra |
| 6 | Key Vault Secrets Officer, plus the actual passwords | Azure |
| 7 | Contributor on the Automation Account | Azure |

Contributor alone is not enough for step 1. It cannot create role assignments, and step 1
creates three: Key Vault Secrets User and Key Vault Secrets Officer on the vault, and
Automation Contributor for ServiceNow's app registration on the Automation Account.

Steps 4 and 5 are separate deliberately. Step 4 can be delegated; step 5 grants admin
consent for application permissions and a directory role, and should not be.

The ServiceNow administrator is not listed, because none of their work happens here — see
the scope note above.

### What you need

- An Azure subscription.
- A network the worker VM can be placed in that reaches your domain controllers and your
  ServiceNow instance. The VM itself is created in step 1.
- **The first part of the ServiceNow setup done** by the ServiceNow team, which leaves you
  with the scoped application installed, a domain record and an integration account. You need the three
  values it produces, not access to change any of it.
- An **Active Directory service account** that can create, modify and disable users and
  groups in the target OUs.
- Tooling on your workstation: [Azure CLI](https://aka.ms/azure-cli),
  [PowerShell 7.2+](https://aka.ms/powershell), and the `Microsoft.Graph.Applications`
  module at 2.39.0 or later for step 4, which `Set-RmaAppRegistration.ps1` asserts with
  `#Requires`. Nothing here publishes runbooks, so `Az.Automation` is needed only to start
  the health check by hand (*Running it by hand* in step 8), after `Connect-AzAccount`.

### How long

Roughly half a day of work, spread across whatever approval waits your organisation
imposes. The Azure parts take minutes; the Entra consent is the one that queues.

### Values to record as you go

Three come from the ServiceNow team. The rest are produced by one step here and consumed
by another.

| Value | Produced in | Used in |
|---|---|---|
| Domain record sys_id | **ServiceNow team** | Step 8 |
| ServiceNow instance name | **ServiceNow team** | Step 8 |
| Integration account username | **ServiceNow team** | Steps 6, 8 |
| Managed identity **client** ID | Step 1 | Step 8 |
| Managed identity **principal** ID | Step 1 | Step 4 |
| Key Vault name | Step 1 | Steps 6, 8 |
| Tenant ID | Your Entra tenant | Steps 4, 8 |
| Application (client) ID | Step 4 | Step 8 |
| AD service account username and a domain controller | Your AD | Steps 6, 8 |
| Subscription ID | Your Azure subscription | ServiceNow application |
| Automation Account name and its resource group | Step 1 | ServiceNow application |
| Hybrid Worker Group name | Step 1 | ServiceNow application |
| ServiceNow's app registration: client ID, tenant ID and its secret or certificate | Step 1 | ServiceNow application |

If you do not have the first three, stop and get them from the ServiceNow team. Step 6 puts
the integration account's password into Key Vault, and step 8 cannot verify anything
without the other two.

**Every value in this table except the principal ID ends up in the ServiceNow
application.** The first rows it passes to the runbooks as parameters when it starts a job;
the runbooks read no configuration from ServiceNow. The last four are how the application
reaches Azure at all: it signs in as its own app registration and starts each job in that
Automation Account with `RunOn` set to that Hybrid Worker Group. Hand them all to whoever
configures the application, which is the ServiceNow team. The full list of
runbook parameters is under *Runbook parameters* in [`ARCHITECTURE.md`](ARCHITECTURE.md).

`Connect-RmaExchange` also takes the tenant's `*.onmicrosoft.com` name as a mandatory
`-Organization`. No runbook in this repository connects to Exchange Online yet, so nothing
passes it today, and which parameter will carry it is not decided. Record the name anyway.

> **The two managed identity GUIDs are different and are not interchangeable.** The client
> ID is what a runbook uses to request a token. The principal ID is what the federated
> credential trusts. Swapping them creates a credential that saves without any error and
> fails only later, at token exchange, with a message that does not point at the cause.
> This is the single most common installation mistake.

---

## Step 1 — Create the Azure resources

**Who:** Contributor on the subscription, plus a role that can create role assignments, and
an Entra application administrator for ServiceNow's app registration. See *Who you need*.

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

The secrets and the runbooks' app registration come later, in steps 4 to 6. That document is
the requirement, not a suggestion: the runbooks assume every setting in it.

It also specifies a second app registration, **ServiceNow's**, which the application uses to
publish runbooks and start jobs. Create it now or alongside step 4: it needs Automation
Contributor on the Automation Account and nothing else, and its credential goes into the
ServiceNow application rather than into Key Vault.

**Record the Key Vault name, the managed identity client ID, and the managed identity
principal ID**, and for the ServiceNow application the subscription ID, the Automation
Account and Hybrid Worker Group names, and ServiceNow's app registration client ID, tenant
ID and credential.

> **The Automation Account must have no managed identity of its own, neither system- nor
> user-assigned.** The portal enables a system-assigned one by default, so turn it off when
> you create the account. Nothing checks this afterwards. If one is enabled, at creation or
> later, the Hybrid Worker's identity is overridden and every runbook stops authenticating.
> It is the first thing to check if authentication that worked yesterday stops working.

---

## Step 2 — Attach the identity and register the worker

**Who:** Contributor on the VM and the Automation Account, plus Managed Identity Operator
on `id-rma-prod` (or Contributor on `rg-rma-shared-prod`). Attaching a user-assigned
identity to a VM is an action on the identity as well as on the VM.

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

Provisioning is two scripts, in order, and they run under **different interpreters**. The
first, `Initialize-RmaWorkerHost.ps1`, runs under the Windows PowerShell 5.1 that ships with
the operating system and makes the machine capable of running PowerShell 7 runbooks at all.
The second, `Initialize-RmaWorker.ps1`, installs the modules and declares
`#Requires -Version 7.2`, so it runs only under the PowerShell 7 the first one installs.
That is why they are separate.

### How to run them without a console on the VM

The worker usually has no public IP. Azure Run Command reads a script from your workstation
and executes it on the VM through the Azure control plane, so you need no inbound network
access and no credentials on the VM. Run Command executes as local **SYSTEM**, which is the
account Hybrid Worker jobs run under. That matters: it makes it structurally impossible to
install into the wrong profile, which is the mistake the `AllUsers` note below exists to
prevent.

`RunPowerShellScript` runs the script under **Windows PowerShell 5.1**, not PowerShell 7.
That suits 3a as it is. For 3b it means Run Command cannot be pointed at
`Initialize-RmaWorker.ps1` directly: the script has to be started with PowerShell 7's own
`pwsh.exe`, and taken from a release rather than from a checkout, since there is none on
the VM. Both are shown below.

> **The Run Command routes have not been tested end to end.** They follow from the scripts
> and the release workflow. Read the output of the first run on a new worker rather than
> assuming it succeeded.

If you would rather work on the VM directly, open an elevated Windows PowerShell for 3a and
an elevated PowerShell 7 (`pwsh`) for 3b, over Bastion or RDP.

### 3a. Make the machine a PowerShell 7 host

From a checkout on your workstation:

```bash
az vm run-command invoke \
  --resource-group rg-rma-workloads-prod --name vm-rma-hw1-prod \
  --command-id RunPowerShellScript \
  --scripts @scripts/Initialize-RmaWorkerHost.ps1
```

`--parameters name=value` maps to the script's named parameters, and the output comes back
to your terminal. On the VM directly, from an elevated Windows PowerShell:

```powershell
./scripts/Initialize-RmaWorkerHost.ps1 -WhatIf
./scripts/Initialize-RmaWorkerHost.ps1
```

It runs under the Windows PowerShell 5.1 that ships with the operating system, and it:

- installs PowerShell 7.6 (the current LTS, supported to 14 November 2028), verified
  against the release's published SHA-256;
- sets the machine environment variable that tells the Hybrid Worker extension where
  `pwsh.exe` is;
- bootstraps the NuGet package provider inside PowerShell 7, so 3b does not stop to fetch
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

Install from a **published release**, at the version the runbooks pin in their
`#Requires -Modules @{ ModuleName = 'RMA.Runbooks'; RequiredVersion = ... }`. The release
attaches two assets, `RMA.Runbooks-<version>.zip` and `Initialize-RmaWorker.ps1`, and its
notes carry both SHA256 hashes and a command block that downloads the script, checks its
hash, and runs it against the module package with `-ExpectedSha256`. That block is the
source of truth; [`DEPLOYMENT.md`](DEPLOYMENT.md) describes it. Without `-ExpectedSha256`
the script installs the package anyway and only warns that it was not verified.

**On the VM directly**, paste the release notes' block into an elevated PowerShell 7
session. It is written for `pwsh`, not for Windows PowerShell.

**Through Run Command**, which runs Windows PowerShell 5.1, the same steps need a wrapper
that hands over to `pwsh.exe`. Save this on your workstation as, say, `rma-provision.ps1`.
It is the release notes' block, rewritten for 5.1:

```powershell
param(
    [Parameter(Mandatory)] [string] $Version,       # the release tag, e.g. 'v<version>'
    [Parameter(Mandatory)] [string] $ScriptSha256,  # Initialize-RmaWorker.ps1, from the notes
    [Parameter(Mandatory)] [string] $ModuleSha256   # RMA.Runbooks-<version>.zip, from the notes
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 may still offer TLS 1.0, which GitHub refuses.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$base = "https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/releases/download/$Version"
$dir  = New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP "rma-$Version")
$file = Join-Path $dir 'Initialize-RmaWorker.ps1'

Invoke-WebRequest "$base/Initialize-RmaWorker.ps1" -OutFile $file -UseBasicParsing
if ((Get-FileHash $file -Algorithm SHA256).Hash -ne $ScriptSha256) {
    throw 'Provisioning script hash mismatch. Nothing has run.'
}

# -File, so #Requires is honoured and the parameters bind. Add -WhatIf to preview.
& "$env:ProgramFiles\PowerShell\7\pwsh.exe" -NoProfile -NonInteractive -File $file `
    -ModuleSource "$base/RMA.Runbooks-$($Version.TrimStart('v')).zip" `
    -ExpectedSha256 $ModuleSha256
if ($LASTEXITCODE -ne 0) { throw "Initialize-RmaWorker.ps1 exited with $LASTEXITCODE." }
```

```bash
az vm run-command invoke \
  --resource-group rg-rma-workloads-prod --name vm-rma-hw1-prod \
  --command-id RunPowerShellScript \
  --scripts @rma-provision.ps1 \
  --parameters 'Version=v<version>' 'ScriptSha256=<hash>' 'ModuleSha256=<hash>'
```

With a repository checkout **on the VM**, `./scripts/Initialize-RmaWorker.ps1` with no
`-ModuleSource` installs `RMA.Runbooks` from that checkout instead. That is for a test
worker; a production worker should run exactly the package a release published.

### Verify

In PowerShell 7 on the worker. Windows PowerShell does not search
`C:\Program Files\PowerShell\Modules`, so run there it reports `RMA.Runbooks` as missing
when it is not. Through Run Command, save it to a file and start it with `pwsh.exe -File`,
as in the wrapper above.

```powershell
Get-Module -ListAvailable RMA.Runbooks, Microsoft.Graph.Authentication, ExchangeOnlineManagement |
    Select-Object Name, Version, ModuleBase

[Environment]::GetEnvironmentVariable('powershell_7_6_path', 'Machine')
```

Three things to confirm:

- `powershell_7_6_path` returns a path to a `pwsh.exe` that exists, and `pwsh -v` reports
  7.6.x.
- `RMA.Runbooks` resolves from `C:\Program Files\PowerShell\Modules`, at the version the
  runbooks pin. Hybrid Worker jobs run as local **SYSTEM**, so a per-user install is
  invisible to them.
- The pinned version of each module is present. Older versions alongside it are harmless,
  because every runbook pins an exact `RequiredVersion`; `-PruneUnpinned` removes them when
  you want the disk back. What matters for disk is that no `Microsoft.Graph.Beta*` module is
  present — see *The worker's disk fills up* below.

**If you have more than one worker in the group, run both scripts on every one of them.** A
worker missing a module or the environment variable fails every job routed to it, which
presents as intermittent failures rather than an obvious outage.

---

## Step 4 — Create the app registration

**Who:** Application Administrator or Cloud Application Administrator.

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

   Recipient Administrator covers every Exchange operation the Exchange runbooks perform.
   None of them has been migrated into this repository yet, so nothing exercises this role
   today; it is assigned now so that the installation does not change when they arrive.
   Exchange Administrator and Global Administrator both work and both grant far more than is
   needed.

---

## Step 6 — Add the secrets

**Who:** Key Vault Secrets Officer.

Two secrets, and only two. Everything else authenticates with the managed identity.

```bash
read -rs -p 'ServiceNow integration account password: ' pw; echo
az keyvault secret set --vault-name <kv-name> \
  --name servicenow-api-password --value "$pw" \
  --expires "$(date -u -d '+1 year' '+%Y-%m-%dT%H:%M:%SZ')"

read -rs -p 'AD service account password: ' pw; echo
az keyvault secret set --vault-name <kv-name> \
  --name ad-service-account-password --value "$pw" \
  --expires "$(date -u -d '+1 year' '+%Y-%m-%dT%H:%M:%SZ')"
unset pw
```

The password is read from a prompt rather than typed into the command, so it does not land
in your shell history. `date -d` is GNU; on macOS use `date -u -v+1y '+%Y-%m-%dT%H:%M:%SZ'`.

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

How and when the application pulls from `main`, and how to hold it back while workers are
being upgraded, belongs to the ServiceNow application and is not documented here; it is an
open point in [`HANDOVER.md`](../HANDOVER.md). The constraint it has to meet is fixed:
**every worker must carry the `RMA.Runbooks` version a runbook pins before that runbook
reaches the Automation Account.** A runbook that arrives first fails at `#Requires` on
every run until the workers catch up — loudly and without claiming anything, but without
processing anything either. See *Updating the shared module* in
[`DEPLOYMENT.md`](DEPLOYMENT.md).

**One prerequisite you do have to create:** a PowerShell **7.6** Runtime environment in the
Automation account, for the application to link the runbooks to. Create it under Automation
account > **Runtime Environments** (Language PowerShell, Runtime version 7.6, named
`Powershell_7-6`), or with the API:

```bash
az rest --method put \
  --url "https://management.azure.com/subscriptions/<subId>/resourceGroups/rg-rma-automation-prod/providers/Microsoft.Automation/automationAccounts/aa-rma-prod/runtimeEnvironments/Powershell_7-6?api-version=2024-10-23" \
  --body '{"properties":{"runtime":{"language":"PowerShell","version":"7.6"}}}'
```

After the application has published them, confirm in the Automation Account that each
runbook is of type **PowerShell** and linked to the `Powershell_7-6` Runtime environment. A
runbook linked to no Runtime environment, or to one whose version has no matching
`powershell_7_X_path` variable on the worker, never starts, and the job output is empty —
see *A PowerShell 7 runbook never starts* in Troubleshooting. By default
`Initialize-RmaWorkerHost.ps1` also registers 7.6 under the 7.4 and 7.2 names, so a runbook
still linked to a 7.4 or 7.2 Runtime environment *does* start, quietly on 7.6. Pass
`-SkipLegacyPaths` once every runbook is linked to `Powershell_7-6` to make that fail
instead.

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
`Test-RmaHealth`, and the runbook sends its result back to the domain's health endpoint,
where the status of each check is visible without leaving the platform. That is the
intended way to read it, during installation and afterwards. The shape of the result is in
[Architecture › The health result](ARCHITECTURE.md#the-health-result).

**Do not continue until every check passes.** A green deployment with a broken identity
looks exactly like a working one until the first real job fails.

Two limits on what a pass means:

- **Exchange Online is not checked.** The Graph check proves the federated token exchange
  and nothing about Exchange, so admin consent for `Exchange.ManageAsApp` and the Exchange
  Recipient Administrator role from step 5 are unverified until an Exchange runbook runs —
  and none has been migrated yet. Confirm both by eye in Entra.
- **The report to ServiceNow currently fails.** The health endpoint returns HTTP 500 from
  its own resource script
  ([#23](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/23)),
  so the job ends with `Not reported to ServiceNow` and fails **even when every check
  passes**, and the domain shows no result. Until that is fixed, read the checks from the
  job output in the Automation Account instead: each line starts with `Pass` or `FAIL`.

Then work through the [production checklist](PRODUCTION-CHECKLIST.md), which covers the
verification this guide does not: the duplicate-execution test, the stranding test, and
confirming secrets never reach the logs.

### Running it by hand

Only needed when the application cannot reach Azure at all, or when you are diagnosing why
the automatic run is failing — at which point the ServiceNow-side view is exactly what is
unavailable. Its one write is its own result, sent to ServiceNow as an automatic run's
would be, so it is safe to run at any time. It needs the `Az.Automation` module and a
signed-in session (`Connect-AzAccount`, then `Set-AzContext` to the subscription), as an
identity with at least Automation Operator on the Automation Account:

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

Pass the values of every directory the domain uses. `TenantId` and `ApplicationId` add the
Microsoft Graph check. `DomainController` and `AdUserName` add the Active Directory check,
which reads the AD password from Key Vault and signs in with it. Leave out the pair for a
directory the domain does not use; at least one pair is required. With more than one AD
domain, pass `AdSecretName` as well.

Expected output:

```
RMA health check
================
Pass  Managed identity token (120 ms)
      acquired
Pass  Key Vault + ServiceNow (840 ms)
      authenticated as <username>
Pass  Microsoft Graph token exchange (310 ms)
      federated token acquired for tenant <guid>
Pass  ServiceNow command queue readable (260 ms)
      queue reachable (0 pending for this command)
Pass  Active Directory reachable (90 ms)
      contacted 10.0.0.4 as <username> (contoso.local)

Reported to ServiceNow.

All checks passed.
```

`Not reported to ServiceNow` in place of the line above it means the domain still shows
an older result. The reason follows on the same line, and the job fails.

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
(500) and `MaxMinutes` (45) bound the run; `EmptyPollsBeforeExit` (1) ends it once the queue
is empty. These, `BatchSize` (20) and `HeartbeatMinutes` (5) are parameters of
`Invoke-RmaQueueLoop`, not of the runbooks: no runbook exposes them, so changing one is a
code change that ships as a module or runbook release, not a setting.

Two requests close together can start two runbook jobs that poll the same queue at the same
time. That is meant to be safe because of the claim, and `BatchSize` is what keeps them from
fighting over the same rows. See *Scaling* in [ARCHITECTURE.md](ARCHITECTURE.md).

> **The claim is not yet atomic.** `Request-RmaJobClaim` sends a `PATCH` filtered on
> `status=1` and then checks that the `worker_id` it reads back is its own. On 30 September
> 2026, on a ServiceNow test instance, the Table API was found to **ignore**
> `sysparm_query` on a single-record `PATCH`: the update succeeds on any row, and the
> read-back proves only that this worker wrote last. Two runs that read the same Pending row
> can both run it. The fix is a server-side compare-and-set in the ServiceNow application;
> see *The same job appears to run twice* below. Until then, overlapping runs can execute a
> job twice, and the runbooks' idempotency — `Create-EntraUser` treats an existing user as
> success — is what limits the damage.

### The watchdog

`Invoke-RmaQueueWatchdog` is also started by the ServiceNow application, but on a cadence
rather than in response to a request. It cannot be request-driven: it requeues jobs whose
worker died before finishing, and **there is no event for "a worker died"** — it is a sweep,
and something has to run it periodically.

It is started **once per domain**: `DomainId` is mandatory, alongside the same `Instance`,
`VaultName`, `ManagedIdentityClientId` and `ServiceNowUserName` every runbook takes, and it
sweeps every command for that domain. Two parameters of its own:

| Parameter | Range | Default | Meaning |
|---|---|---|---|
| `StaleAfterMinutes` | 5–1440 | 30 | How long a claim may go unrenewed before the job is presumed stranded |
| `MaxRequeue` | 1–500 | 50 | Ceiling per run. Above it, the watchdog requeues nothing and fails, because mass stranding is systemic |

A running job renews its claim every `HeartbeatMinutes` (5 by default, a parameter of
`Invoke-RmaQueueLoop`), so `StaleAfterMinutes` is measured against that interval, not
against how long a job takes. A full directory import that runs for hours is not requeued
while it is still running. The rule is **`StaleAfterMinutes` ≥ 3 × `HeartbeatMinutes`**, so
two failed renewals in a row do not requeue a live job; the default of 30 leaves six.

A stranded job is recovered at most `StaleAfterMinutes` plus the watchdog's cadence after its
last renewal: it has to go stale, and then a sweep has to run. **The cadence is not agreed
yet**; it is an open point in [`HANDOVER.md`](../HANDOVER.md). The heartbeat renewal and the
watchdog's requeue are table `PATCH`es like the claim and share its limitation.

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
```

Two different faults, fixed in two different places:

- **The runbook's `runtimeEnvironment` is empty, or names the wrong environment.** That is
  in Automation, not on the worker. Link the runbook to `Powershell_7-6`, and tell whoever
  maintains the ServiceNow application, since it is what links runbooks when it publishes
  them.
- **The variable for that version is empty on the worker, or points at a missing file.**
  Re-run `./scripts/Initialize-RmaWorkerHost.ps1`, which sets it and restarts the service.
  The variable is read only when the service starts, so setting it by hand and not
  restarting changes nothing.

Then check the extension version, because PowerShell 7.x runbooks need 1.3.63 or above:

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
still triggering it for that domain, and check its own job history. If more than
`MaxRequeue` jobs are stranded at once, the watchdog deliberately refuses to act and fails
instead, because mass stranding means something systemic and requeueing hundreds of jobs
into a broken system makes it worse.

### The same job appears to run twice

Expected, for now, whenever two runs overlap. The conditional `PATCH` behind the job claim
is not an atomic compare-and-set: the Table API ignores `sysparm_query` on a single-record
`PATCH` (see *The claim is not yet atomic* in step 9). That is a ServiceNow-side fix, for
whoever maintains the scoped application. It needs a **Scripted REST endpoint**: a custom
REST API in the application that, in one server-side operation, moves the row from Pending
to Work in Progress only if it is still Pending, and reports whether it did.
`Request-RmaJobClaim` would then call that endpoint instead of the table; its signature does
not change, so no runbook changes either.

### The worker's disk fills up

Historic module versions. Run:

```powershell
./scripts/Initialize-RmaWorker.ps1 -PruneUnpinned
```

Check specifically that no `Microsoft.Graph.Beta*` module is installed. None is needed: the
runbooks call no `Get-MgBeta*` cmdlet. The `Microsoft.Graph.Beta` meta-module in particular
pulls forty submodules and over a gigabyte. `Initialize-RmaWorker.ps1` removes the
meta-module itself, but **not** the `Microsoft.Graph.Beta.*` submodules it brought with it,
and `-PruneUnpinned` does not touch them either, because it prunes only the pinned modules.
Remove those by hand.

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
