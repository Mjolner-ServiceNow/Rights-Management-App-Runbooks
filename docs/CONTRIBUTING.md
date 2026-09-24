# Contributing

## Before you open a pull request

```powershell
./build/Invoke-Format.ps1
./build/Invoke-Analysis.ps1 -FailOn Error,Warning
./build/Invoke-Tests.ps1
./build/Assert-Coverage.ps1 -Path ./tests/Coverage.xml -MinimumPercent 70
./build/Test-ModuleManifestIntegrity.ps1
```

CI runs all five and will not merge without them, plus a check that `ModuleVersion` was
bumped when the module changed. CI has no Azure access, so it runs on forks and
first-time contributors without exposing anything.

From a shell rather than inside a `pwsh` session, use the `-Command` form for
`Invoke-Analysis.ps1`: `pwsh -File` passes `-FailOn Error,Warning` as one literal string.
`-FailOn` validates its input, so that mistake now fails loudly instead of passing the
build.

## Trying a change on a test Hybrid Worker

The unit tests mock Azure, ServiceNow and Active Directory. Only a worker shows whether a
change works against the real thing. `scripts/Invoke-RmaWorkerRun.ps1` runs a runbook from
your working tree on a test worker, with nothing pushed and no release built:

```powershell
./scripts/Invoke-RmaWorkerRun.ps1 Test-RmaHealth
./scripts/Invoke-RmaWorkerRun.ps1 Test-RmaHealth -Parameters @{ AdSecretName = 'other-secret' }
./scripts/Invoke-RmaWorkerRun.ps1 -ScriptBlock { Get-RmaAccessToken -Resource 'https://vault.azure.net' -ManagedIdentityClientId '<client id>' }
./scripts/Invoke-RmaWorkerRun.ps1 -StopTunnel
```

It copies `src/RMA.Runbooks` to a scratch folder on the worker, under the version in the
manifest, and puts that folder first on `PSModulePath` for its own session only. That way
the runbook's `#Requires` loads your copy, and the module installed on the worker is not
touched. The runbook's parameters come from `rma-worker.local.json` at the repository root,
which is gitignored. Copy `rma-worker.example.json` to create it. Its `Worker` object says
how to reach the worker. Every other key is a runbook parameter, and keys a runbook does not
declare are ignored, so one file serves every runbook.

**Test environments only.** The key below grants administrator access to the worker.

It is not a real job, in two ways:

- The code runs as the SSH user. A real job runs as SYSTEM, which has a different module
  scope, certificate store and profile. Run a real job before you call a change done.
- Key-based SSH logons on Windows carry no network credentials, so implicit Kerberos to a
  domain controller fails. The runbooks never rely on it: they pass the AD service
  account from Key Vault with `-Credential`, exactly as a job does.

### One-time setup

The connection is PowerShell remoting over SSH, through an Azure Bastion tunnel. The VM
needs no public IP and no open port. You need a Standard or Premium Bastion with native
client support switched on:

```bash
az network bastion update -g <rg> -n <bastion> --enable-tunneling true
```

Windows Server 2025 ships OpenSSH Server. On an earlier release, install it first with
`Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`. Register PowerShell 7 as
an SSH subsystem. The line must come before any `Match` block in `sshd_config`, and the 8.3
path avoids the space in `Program Files`:

```
Subsystem powershell c:/progra~1/powershell/7/pwsh.exe -sshs -nologo
```

Then restart `sshd`. Create a key for this alone, and install its public half for an
administrator account:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/rma-worker -N "" -C "rma-worker-dev"
```

On the worker, append the public key to
`C:\ProgramData\ssh\administrators_authorized_keys`. sshd ignores that file unless only
Administrators and SYSTEM can access it:

```powershell
icacls.exe C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'
```

`az vm run-command invoke --command-id RunPowerShellScript` can do all of this without a
console session. Finally, open a tunnel, connect once with `ssh -i ~/.ssh/rma-worker -p 2224
-o UserKnownHostsFile=~/.ssh/known_hosts_rma <user>@localhost`, and check the fingerprint
against the VM before you accept it. The script requires that host key from then on.

Two traps, both found the hard way:

- `pwsh -Command "Enter-PSSession ..."` hangs after the password prompt. Start `pwsh`
  first, then run `Enter-PSSession` at its prompt. `Invoke-Command`, which this script
  uses, has no such problem.
- Stopping `az network bastion tunnel` by its process id can leave its child process
  listening on the port. `-StopTunnel` finds the tunnel by its port for that reason.

## Rules

**Never reimplement queue handling.** Claiming, terminal state, retry, bounds, correlation
and redaction live in `RMA.Runbooks`. A runbook that does its own is rejected in review.
That duplication is exactly what produced the defects this repository exists to fix.

**Bump `ModuleVersion` when you touch the module,** in the manifest and in the
`#Requires` `RequiredVersion` of every runbook. Deployment pins by version, so an unbumped
change cannot be rolled out or rolled back, and a worker that already has that version
will not pick up a different build of it. `build/Assert-ModuleVersionBump.ps1` enforces
this on every pull request.

**Never log a payload object.** Use `Write-RmaLog` with named fields. A payload can carry a
password, and one did.

**Never `Install-Module` in a runbook.** Declare it in `#Requires` and add it to
`scripts/Initialize-RmaWorker.ps1` with a pinned version.

**Suppressions need a justification.** A `SuppressMessageAttribute` without a real
`Justification` will be asked about in review.

## This repository is public

Do not commit anything that identifies a customer: ServiceNow instance names, tenant or
subscription IDs, internal hostnames or IP ranges, or real record sys_ids. Test fixtures use
`contoso` and obviously-synthetic GUIDs; keep it that way.

Keep real subscription ids, resource ids and instance names in a `*.local.json`, which is
gitignored. Nothing in CI checks this now that the infrastructure templates are gone, so it
is a review responsibility.

## Adding a runbook

1. Copy `src/runbooks/Create-EntraUser.ps1`.
2. Change the `#Requires` set to what you actually call, nothing more.
3. Change the `-Command` string to the ServiceNow command name.
4. Write the body. Throw to fail the job; return normally to complete it.
5. Add an idempotency pre-check if a repeat execution would write twice.
6. Add a test if the body has branching logic worth protecting.

## Changing the shared module

Add a test first. The module is the blast radius for all 63 runbooks, and the coverage
floor exists to keep it that way.
