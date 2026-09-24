---
name: test-on-hybrid-worker
description: Use when a runbook or RMA.Runbooks change should be tried against real Azure, ServiceNow and Active Directory before it is pushed - running a runbook or a module function on a test Hybrid Worker from the working tree with scripts/Invoke-RmaWorkerRun.ps1, over an Azure Bastion tunnel. Also use when that connection fails - Bastion native client or tunnel errors, a busy local port, SSH remoting that hangs or is refused.
---

# Testing on a test Hybrid Worker

The unit tests mock Azure, ServiceNow and Active Directory. This skill covers the step
after them: running the working tree on a real test worker, with nothing pushed and no
release built. The script that does it is `scripts/Invoke-RmaWorkerRun.ps1`. The human
setup guide is *Trying a change on a test Hybrid Worker* in `docs/CONTRIBUTING.md`. Read
that for the setup commands; this file does not repeat them.

Run the unit tests first. A worker run is for what mocks cannot show. It does not replace
the gate in `CLAUDE.md`.

## Rules

1. **Test environments only.** Never point this at a worker that serves a customer. The
   SSH key it uses has administrator rights on the worker.
2. **Never guess a runbook parameter value, least of all a ServiceNow one.** The health
   check sends the ServiceNow password from Key Vault to whatever instance `Instance`
   names. If a value is missing from `rma-worker.local.json`, ask the user for it.
3. **Never commit `rma-worker.local.json`,** and never copy its values into a committed
   file, a commit message or a pull request. The repository is public. `*.local.json` is
   gitignored; check with `git check-ignore` if the file was renamed.
4. **Ask before changing shared infrastructure.** Switching on Bastion native client
   support, changing a Bastion SKU, editing `sshd_config` or installing a key on the
   worker all change the user's Azure environment. Say what the change is and wait for a
   yes.
5. **Report what the run was.** It ran as the SSH user, not as SYSTEM like a real job, and
   with the working tree's module loaded next to the installed one. Say both when you
   report a result, and say that a real Automation job is still the final check.

## Prerequisites, in the order they fail

Check each one before the first run in a session. A failure further down the chain
often looks like a failure further up.

### 1. Azure Bastion is configured for native client connections

This is the prerequisite that fails most quietly. `az network bastion tunnel` needs:

- **SKU Standard or Premium.** Basic and Developer do not support native client
  connections. Changing the SKU changes the bill, so that is the user's decision.
- **Native client support switched on.** The resource property is `enableTunneling`.
  Switching it on takes 5 to 10 minutes.
- **Reader on the VM, on the VM's NIC and on the Bastion resource** for whoever runs the
  tunnel.
- **Port 22 on the VM reachable from `AzureBastionSubnet`.** The default NSG rule
  `AllowVnetInBound` covers it unless a custom rule denies it. So does the Windows
  firewall rule `OpenSSH-Server-In-TCP`, which the OpenSSH Server install creates.
- **Azure CLI 2.32 or later with the `bastion` extension** on the local machine.

Check the first two from the `Worker` values in the config:

```bash
az network bastion show -g <ResourceGroup> -n <BastionName> --query "{sku:sku.name, tunneling:enableTunneling}" -o json
```

`sku` must be `Standard` or `Premium` and `tunneling` must be `true`. If tunneling is
`false`, the fix is `az network bastion update ... --enable-tunneling true`. Rule 4
applies.

### 2. The worker accepts PowerShell over SSH

sshd must be running, and `sshd_config` must register the `powershell` subsystem before
any `Match` block. `az vm run-command invoke --command-id RunPowerShellScript` can check
both without a console, for example:

```powershell
Get-Service sshd | Select-Object Status, StartType
Select-String -Path "$env:ProgramData/ssh/sshd_config" -Pattern '^\s*Subsystem\s+powershell'
```

Running this through `az vm run-command` needs `Microsoft.Compute/virtualMachines/runCommand/action`
on the VM, for example through Virtual Machine Contributor. Reader is not enough.

### 3. The local side is in place

- `rma-worker.local.json` at the repository root has a complete `Worker` object.
  `rma-worker.example.json` shows the shape.
- The file named by `Worker.KeyFilePath` exists, and its public half is in the worker's
  `C:\ProgramData\ssh\administrators_authorized_keys`, which only Administrators and
  SYSTEM may access.
- The file named by `Worker.KnownHostsFile` holds the worker's host key. The script
  connects with `StrictHostKeyChecking=yes` and will not add a host key itself.
- `az account show` names the subscription that holds the worker.

## Running it

```powershell
./scripts/Invoke-RmaWorkerRun.ps1 Test-RmaHealth
./scripts/Invoke-RmaWorkerRun.ps1 Test-RmaHealth -Parameters @{ AdSecretName = 'other-secret' }
./scripts/Invoke-RmaWorkerRun.ps1 -ScriptBlock { Get-Module RMA.Runbooks | Select-Object Version, ModuleBase }
./scripts/Invoke-RmaWorkerRun.ps1 Test-RmaHealth -WhatIf
./scripts/Invoke-RmaWorkerRun.ps1 -StopTunnel
```

From a shell, call it as `pwsh -NoProfile -File scripts/Invoke-RmaWorkerRun.ps1 ...`, or
use `-Command` when you pass `-Parameters` or `-ScriptBlock`.

- The first call starts the tunnel, and later calls reuse it. When you are finished, run
  `-StopTunnel`. A tunnel you leave behind blocks that port for the next session.
- To test a variant, such as one directory only, write a trimmed copy of the config to a
  scratch directory and pass `-ConfigPath`. Do not edit the user's file for it.
- The run copies the working tree as it is on disk, committed or not.

### Reading the result

- **The exit code is the verdict.** 0 means the runbook returned normally, and 1 means it
  threw or the script could not run it.
- **A failure ends in one line,** `ERROR: <message>`, on stderr. The script prints it in
  plain text, because the host would otherwise wrap it in ANSI colour codes.
- **Lines that start with `{"timestamp"`** are `Write-RmaLog` records. `correlationId` is
  empty outside `Invoke-RmaQueueLoop`, and that is expected.
- **Check the module location.** The first line names the module version. To prove the
  working tree's copy was loaded, `-ScriptBlock { (Get-Module RMA.Runbooks).ModuleBase }`
  should answer a path under `C:\RmaDev`.

## Traps

| Symptom | Cause | Do this |
|---|---|---|
| `Defined port is currently unavailable` | Something already listens on the local port, usually a tunnel left over from before | `-StopTunnel`, or find the listener with `lsof -nP -iTCP:<port> -sTCP:LISTEN`. Stopping the `az` process is not enough, because its Python child keeps the port. |
| The tunnel never opens, or closes straight away | Bastion is not on Standard or Premium, native client support is off, or the Reader roles are missing | Prerequisite 1 |
| `Permission denied (publickey)` | The key is not in `administrators_authorized_keys`, or that file's ACL lets someone other than Administrators and SYSTEM read it | Prerequisite 3. With a wrong ACL, sshd skips the file and tells the client nothing. |
| `Host key verification failed` | The known_hosts file has no entry for `[localhost]:<port>`, or the VM was rebuilt | Connect once with `ssh` as `docs/CONTRIBUTING.md` shows, compare the fingerprint with the user, then retry. |
| `ssh-keyscan` returns nothing through the tunnel | It does not work through a Bastion tunnel | Collect the host key with a real `ssh` connection instead. |
| `pwsh -Command "Enter-PSSession ..."` hangs after the password | `Enter-PSSession` needs an interactive prompt | Start `pwsh` first and run `Enter-PSSession` at its prompt, or use `Invoke-Command`, as the script does. |
| An AD cmdlet fails with access denied, but works in a real job | Key-based SSH logons on Windows carry no network credentials, so implicit Kerberos to the DC fails | Pass `-Credential`, as the runbooks do with the AD service account from Key Vault. |
| `#Requires` says `RMA.Runbooks` is missing | The runbook pins a version that differs from the manifest in the working tree | Bump the manifest and every runbook's `#Requires` together. That is the rule in `docs/CONTRIBUTING.md`. |
| It passes here and fails as a job | The run went as the SSH user and the job runs as SYSTEM, which has different module scope, certificate store and profile | Check the module's install scope and the certificate location. Then run a real job. |
