# Azure resources

What to build in Azure for the runbooks to run, and how each part must be configured. This
is the specification. [`INSTALLATION.md`](INSTALLATION.md) is the procedure that follows it,
with the commands and scripts for each step.

There is no infrastructure-as-code in this repository, so everything here is created by
hand, in the portal or with `az`. Where a setting is marked **required**, the runbooks
depend on it and fail without it. The names are the recommended ones; if you change them,
change them everywhere.

Every name ends in the environment it belongs to. This document uses `prod` throughout;
for another environment, replace it, for example `aa-rma-test`. Each environment is a
complete, separate copy of everything below, including its own app registration.

Nothing here is for monitoring. The ServiceNow application already tracks the status of
every runbook job and flags the ones that fail, so the platform needs no Log Analytics
workspace, diagnostic settings, action groups or alert rules to run.

---

## Overview

```
Subscription
│
├── rg-rma-automation-prod
│   └── aa-rma-prod ──────────── Automation Account, identity: None
│         │                      └── hwg-rma-prod  Hybrid Worker Group
│         │ runbook job, RunOn hwg-rma-prod
│         ▼
├── rg-rma-workloads-prod
│   └── vm-rma-hw1-prod ──────── Windows Server VM, the Hybrid Worker
│         │                      system-assigned identity: on (no roles)
│         │ attached
│         ▼
├── rg-rma-shared-prod
│   └── id-rma-prod ──────────── User-assigned managed identity
│         │
│         ├── Key Vault Secrets User ──▶ kv-rma-<suffix>-prod
│         │                              ├── servicenow-api-password
│         │                              └── ad-service-account-password
│         │
│         └── federated credential ──────┐
│                                        │
Microsoft Entra ID                       ▼
├── App registration, runbooks ───▶ Microsoft Graph · Exchange Online
└── App registration, ServiceNow ─▶ Automation Contributor on aa-rma-prod
```

One identity does everything the runbooks do. `id-rma-prod` reads the two passwords from Key
Vault and, through the federated credential, acts as the runbooks' app registration towards
Graph and Exchange Online. The runbooks use no client secret and no certificate anywhere.

The ServiceNow application has an app registration of its own, used to publish runbooks into
the Automation Account and start jobs. It is the one credential in the design that lives
outside Azure; see *App registration for ServiceNow*.

---

## Resource groups

| Resource group | Holds | Why it is separate |
|---|---|---|
| `rg-rma-automation-prod` | `aa-rma-prod` | The Automation Account is where the ServiceNow application publishes runbooks and starts jobs. |
| `rg-rma-shared-prod` | `id-rma-prod`, `kv-rma-<suffix>-prod` | The identity and the secrets outlive any one VM. Replacing or adding a worker never touches them. |
| `rg-rma-workloads-prod` | `vm-rma-hw1-prod` and everything created with it | The VM brings a disk, a network interface and, unless you use an existing one, a virtual network. They stay together and can be deleted together. |

All three go in the same subscription.

---

## Automation Account — `aa-rma-prod`

**Resource group:** `rg-rma-automation-prod`

| Setting | Value |
|---|---|
| System-assigned managed identity | **Off. Required.** |
| User-assigned managed identity | **None. Required.** |
| Hybrid Worker Group | `hwg-rma-prod`, with `vm-rma-hw1-prod` as its worker |
| Runtime environment | `Powershell_7-6`: language PowerShell, version 7.6. The ServiceNow application links the runbooks to it. |

> **The Automation Account must have no managed identity of its own, neither system- nor
> user-assigned.** An identity on the Automation Account overrides the Hybrid Worker VM's
> identity, and every runbook stops authenticating. The portal enables the system-assigned
> identity by default when you create the account, so turn it off on the *Advanced* tab.
> Nothing checks this afterwards. If authentication that worked yesterday fails today,
> check this first.

Do not import `RMA.Runbooks` or any other module into the Automation Account. Modules
imported there are available only to jobs that run in Azure's own sandbox. A Hybrid Worker
loads modules from its own disk, where `scripts/Initialize-RmaWorker.ps1` installs them.

Do not create schedules. Every job is started by the ServiceNow application.

---

## Virtual machine — `vm-rma-hw1-prod`

**Resource group:** `rg-rma-workloads-prod`

| Setting | Value |
|---|---|
| Name | At most 15 characters. Windows uses the VM name as the computer name, and a computer name cannot be longer; this is why the worker is `vm-rma-hw1-prod`. |
| Operating system | Windows Server |
| Size | At least 2 vCPU and 4 GB RAM |
| System-assigned managed identity | **On. Required.** The Hybrid Worker extension needs it. Give it no role assignments. |
| User-assigned managed identity | **`id-rma-prod`. Required.** |
| Public IP | None needed. Provisioning uses Azure Run Command, which goes through the Azure control plane. |
| Hybrid Worker | Registered in `hwg-rma-prod` in `aa-rma-prod`, which installs the Hybrid Worker extension. PowerShell 7 runbooks need extension version 1.3.63 or above. |

**Network.** The VM must reach:

| Destination | Why |
|---|---|
| Your domain controllers | Active Directory runbooks. The `ActiveDirectory` module talks to Active Directory Web Services on TCP 9389. |
| Your ServiceNow instance, HTTPS | The command queue, and writing results back |
| Azure Automation, Microsoft Entra ID, Microsoft Graph, Exchange Online and Key Vault, HTTPS | Jobs, tokens and secrets |

Reaching the domain controllers usually means a virtual network with a connection to the
on-premises network, or domain controllers in Azure. That network belongs to your
environment rather than to this solution, so it is not specified here.

> **The VM has two identities, and that is correct.** The system-assigned one exists for the
> Hybrid Worker extension and has no permissions. Every token request in this solution names
> `id-rma-prod` by its client ID, because a request that does not gets the system-assigned
> identity instead and fails.

For more throughput, add `vm-rma-hw2-prod` and onwards: same configuration, same identity,
same Hybrid Worker Group. The job claim makes more than one worker safe.

---

## User-assigned managed identity — `id-rma-prod`

**Resource group:** `rg-rma-shared-prod`

The only identity the solution uses. It is attached to every Hybrid Worker VM, it is the
only assignee on the Key Vault apart from your operators, and it is the subject of the
app registration's federated credential.

Record two values when you create it. They are different GUIDs and are **not
interchangeable**:

| Value | Where it is used |
|---|---|
| **Client** ID | Runbook parameter `ManagedIdentityClientId`, for token requests |
| **Principal** (object) ID | The federated credential's subject |

Swapping them produces a federated credential that saves without error and fails only at
token exchange, with a message that does not point at the cause.

---

## Key Vault — `kv-rma-<suffix>-prod`

**Resource group:** `rg-rma-shared-prod`

Key Vault names are globally unique across Azure, so `kv-rma-prod` alone will almost
certainly be taken. Add a short suffix before the environment, for example
`kv-rma-contoso-prod`. The whole name must be 3–24 characters of letters, digits and
hyphens and start with a letter, which leaves at most 12 characters for the suffix.

| Setting | Value |
|---|---|
| Pricing tier | Standard |
| Permission model | **Azure role-based access control. Required.** Not vault access policies. |
| Soft delete | On, 90 days |
| Purge protection | On in production |
| Public network access | In production: disabled, with the worker VM's subnet allowed. The subnet needs the `Microsoft.KeyVault` service endpoint. A private endpoint also works. |

**Role assignments**, at the scope of the vault:

| Assignee | Role | Role ID |
|---|---|---|
| `id-rma-prod` | Key Vault Secrets User | `4633458b-17de-408a-b874-0445c86b69e6` |
| Your operations group | Key Vault Secrets Officer | `b86a8fe4-44ce-4948-aee5-eccb2c155cd7` |

`id-rma-prod` gets read access and nothing else. It must not hold Secrets Officer. Creating the
vault does not give you permission to write secrets in it, so someone needs Secrets Officer
before the next step.

**Secrets.** Two, with these exact names:

| Secret name | Value | Used by |
|---|---|---|
| `servicenow-api-password` | Password of the ServiceNow integration account | Every runbook, to read and update the command queue |
| `ad-service-account-password` | Password of the Active Directory service account | The Active Directory runbooks |

Give both an expiry date matching the password's own lifetime, so a lapsing password is
visible in the vault. The usernames are not secrets and are not stored here.

---

## App registration for the runbooks

**Where:** Microsoft Entra ID. It is not an Azure resource and has no resource group.

`scripts/Set-RmaAppRegistration.ps1` creates the registration, its API permissions and the
federated credential. It grants no consent and assigns no role, which are left to an
administrator deliberately.

| Setting | Value |
|---|---|
| Supported account types | Single tenant |
| Client secrets | **None. Required.** |
| Certificates | **None. Required.** |

**Federated credential.** This is what lets `id-rma-prod` act as the app registration.

| Field | Value |
|---|---|
| Issuer | `https://login.microsoftonline.com/<tenant-id>/v2.0` |
| Subject | The **principal** ID of `id-rma-prod`, not its client ID |
| Audience | `api://AzureADTokenExchange` |

**API permissions.** All **Application** permissions, all with admin consent granted. This is
the set `scripts/Set-RmaAppRegistration.ps1` requests; if the two ever disagree, the script
is what gets created, so change both together.

| API | Permission | Allows |
|---|---|---|
| Microsoft Graph | `AdministrativeUnit.ReadWrite.All` | Reading and writing administrative units and their members |
| Microsoft Graph | `Directory.Read.All` | Reading directory data |
| Microsoft Graph | `Domain.Read.All` | Reading the tenant's domains |
| Microsoft Graph | `Group.ReadWrite.All` | Reading and writing all groups and their membership |
| Microsoft Graph | `GroupMember.ReadWrite.All` | Reading and writing group memberships |
| Microsoft Graph | `Organization.Read.All` | Reading organization information |
| Microsoft Graph | `User-PasswordProfile.ReadWrite.All` | Reading and writing password profiles, and resetting passwords |
| Microsoft Graph | `User.Invite.All` | Inviting guest users |
| Microsoft Graph | `User.ReadWrite.All` | Reading and writing all users' full profiles |
| Microsoft Graph | `User.RevokeSessions.All` | Revoking a user's sign-in sessions |
| Microsoft Graph | `UserAuthenticationMethod.ReadWrite.All` | Reading and writing users' authentication methods |
| Office 365 Exchange Online | `Exchange.ManageAsApp` | Connecting to Exchange Online as the application |

The delegated Microsoft Graph `User.Read` that the portal adds to every new registration is
not used by the runbooks.

An ungranted permission produces a token that is rejected when used rather than refused when
issued, so check that every row shows **Granted** before testing.

**Directory role.** `Exchange.ManageAsApp` only lets the application connect; what it may do
in Exchange comes from a directory role. Assign **Exchange Recipient Administrator** to the
application's service principal. Exchange Administrator and Global Administrator also work,
and grant far more than the runbooks need.

---

## App registration for ServiceNow

**Where:** Microsoft Entra ID, with a role assignment on `aa-rma-prod`.

A second app registration, separate from the runbooks' one. The ServiceNow application
signs in as it to import and publish runbooks, link them to the Runtime environment, start
jobs and read their status. The runbooks never use it.

| Setting | Value |
|---|---|
| Supported account types | Single tenant |
| Credential | A client secret or a certificate, held by the ServiceNow application |
| API permissions | None. It needs nothing in Microsoft Graph or Exchange Online. |
| Federated credential | None |

**Role assignment:**

| Scope | Role | Role ID |
|---|---|---|
| `aa-rma-prod` | Automation Contributor | `f353d9bd-d4a6-484e-a77a-8050b599b867` |

Assign it on the Automation Account itself, not on the resource group or the subscription.
Automation Contributor grants every action on the account, so a wider scope would hand
ServiceNow every other Automation Account in that scope too.

> **Automation Contributor can also turn on a managed identity on the Automation Account.**
> Doing so breaks every runbook, as described under *Automation Account* above. The
> ServiceNow application must never change the account's identity settings.

**Its credential expires.** A client secret created in the portal lasts at most two years; when it lapses,
ServiceNow can no longer start jobs. Queue rows then accumulate at `status = 1` and nothing
in Azure reports it. Record the expiry date and renew it before then, or use a certificate
with a longer lifetime.

---

## Build order

Each step needs something the one before it created.

1. **Create the three resource groups** in the same subscription.
2. **Create `aa-rma-prod`** in `rg-rma-automation-prod`, with the system-assigned identity turned
   off. Create the `Powershell_7-6` Runtime environment and the `hwg-rma-prod` Hybrid Worker
   Group in it.
3. **Create `vm-rma-hw1-prod`** in `rg-rma-workloads-prod`, with the system-assigned identity
   turned on and network access to the domain controllers.
4. **Create `id-rma-prod`** in `rg-rma-shared-prod`. Record its client ID and principal ID. Attach
   it to `vm-rma-hw1-prod`, then register the VM in `hwg-rma-prod`.
5. **Create `kv-rma-<suffix>-prod`** in `rg-rma-shared-prod` with the RBAC permission model, and
   assign the two roles.
6. **Add the two secrets** to the Key Vault.
7. **Create the runbooks' app registration** with the federated credential and the
   permissions above, then grant admin consent and assign Exchange Recipient Administrator.
8. **Create ServiceNow's app registration**, assign it Automation Contributor on
   `aa-rma-prod`, and hand its credential to whoever configures the ServiceNow application.

After that, the worker itself is provisioned with `scripts/Initialize-RmaWorkerHost.ps1`
and `scripts/Initialize-RmaWorker.ps1`. That step is software on the VM rather than an
Azure resource, and is covered in [`INSTALLATION.md`](INSTALLATION.md) step 3.

## Values the runbooks need

The ServiceNow application passes these to the runbooks as parameters, so whoever
configures it needs them. These are the ones the resources above produce; the full list,
including the ServiceNow and Active Directory values, is under *Runbook parameters* in
[`ARCHITECTURE.md`](ARCHITECTURE.md).

| Runbook parameter | Value |
|---|---|
| `VaultName` | `kv-rma-<suffix>-prod` |
| `ManagedIdentityClientId` | The **client** ID of `id-rma-prod` |
| `TenantId` | The ID of the Entra tenant the app registration is in |
| `ApplicationId` | The application (client) ID of the app registration |
| `AdSecretName` | `ad-service-account-password`, unless there is more than one AD domain |
