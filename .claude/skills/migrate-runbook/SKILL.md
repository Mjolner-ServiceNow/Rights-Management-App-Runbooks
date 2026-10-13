---
name: migrate-runbook
description: Use when migrating a 1.0 runbook onto the shared module - one of the "Migrate <Runbook> onto the shared module" issues under #36 - from picking an unblocked issue, through the runbook, its tests and the gate, to publishing it in the test Automation Account, an end-to-end test with real queue rows and a real job, and the pull request. Also use when running several such migrations in parallel, each agent in its own git worktree.
---

# Migrating a 1.0 runbook

Each 1.0 runbook has an issue under #36, *Migrate <Runbook> onto the shared module*, with
the queue command, the 1.0 payload fields and cmdlets, and notes. The procedure below is
how ten of them were done; follow it, and record anything new on the issue.

Invoke `track-work` first, as for any task, and `powershell-7-expert` before writing code.
When you test on the worker, `test-on-hybrid-worker` has the prerequisites.

## 0. Pick an issue that is not blocked

```bash
gh api repos/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/<n>/dependencies/blocked_by -q '[.[] | select(.state=="open") | .number]'
```

An empty list means it can be done now. Most runbooks that write back to ServiceNow wait on
#106 (`/insertMultiple`); Exchange ones wait on #108 (`Organization`).

## 1. Your own worktree, when agents run in parallel

Never use the Agent tool's `isolation: "worktree"`: the harness refuses every `pwsh` call in
such a worktree. A worktree added by hand works:

```bash
git -C <repo> fetch -q
git -C <repo> worktree add <repo>/../rma-wt/<n> -b <type>/<n>-<slug> origin/main
cd <repo>/../rma-wt/<n>
cp <repo>/rma-worker.local.json ./rma-worker.local.json   # gitignored; edit Worker.Port below
```

For the test worker, each parallel agent needs its **own tunnel port** and **own remote
folder**, or two runs replace each other's files on the worker:

- In your copy of `rma-worker.local.json`, set `Worker.Port` to `2224 + <slot>` (2225, 2226, ...).
- Add a known_hosts line for that port, copied from the 2224 line:
  `grep '^\[localhost\]:2224 ' <KnownHostsFile> | sed 's/:2224 /:<port> /' >> <KnownHostsFile>`
- Pass `-RemoteRoot C:/RmaDev-<n>` to every script below that takes it.

Remove the worktree when the pull request is open: `git worktree remove <path>`.

## 2. Read the 1.0 runbook

The 1.0 sources are at `LegacyRunbookPath` in `rma-worker.local.json` (their home is the
team's Azure DevOps organization; see `HANDOVER.md`). Read the job body, from
`if ($ParameterObject.action -eq ...)` to its `catch`. Note what it reads from the payload,
what it calls, what it writes back, and what it does when the object is missing or
already in the asked-for state. 1.0 often failed where 2.0 should complete; see D15.

## 3. Write the runbook

Copy the closest migrated runbook in `src/runbooks/`, not the 1.0 one:

| Kind | Copy |
|---|---|
| Entra ID, one object | `Create-EntraUser.ps1` (setup and `Connect-RmaGraph`) |
| AD, one field | `Unlock-ADUser.ps1`, `Enable-ADUser.ps1` |
| AD, several fields | `Remove-ADGroupMember.ps1`, `Move-ADGroupToOrganizationalUnit.ps1` |
| AD, delete | `Remove-ADUser.ps1`, `Remove-ADGroup.ps1` |
| AD, secret in the payload | `Set-ADUserPassword.ps1` |

Rules each of those already follows, and reviewers check:

- **Payload fields** are read as `$p.PSObject.Properties['name']?.Value`. Under
  `Set-StrictMode -Version Latest`, `$p.name` on a payload without the field throws a
  property-not-found that names no ServiceNow field. For several fields, a reader
  scriptblock that takes the payload as a parameter (`& $field $p 'group'`); a nested
  scriptblock that reads `$p` itself leaves `$p` unused to the analyzer.
- **Validate before the directory is touched:** empty or control characters fail with
  *Payload field 'x' ... Correct the ServiceNow record.* Booleans are `true`/`false`, as JSON
  or text, and nothing else.
- **Look up, then act by objectGUID**, so the object changed is the object looked up.
- **Not found** is matched by type name, `$_.Exception.GetType().Name -eq
  'ADIdentityNotFoundException'`; a typed `catch` needs the AD assembly loaded. Every other
  error is rethrown unchanged.
- **Idempotent:** an object already in the asked-for state completes the job with a log
  record. A delete or a removed membership whose object is already gone completes with a
  Warning (`docs/DECISIONS.md` D15). An action on an object that does not exist, other
  than a delete, fails.
- **Never log the payload**, only named fields. A secret goes from the payload into a
  `SecureString` (`AppendChar`, `MakeReadOnly`) and nowhere else.
- **AD:** one `$server = @{ Server; Credential }` splat built before the loop, on every AD
  cmdlet. `#Requires -Modules ActiveDirectory` without a version. Never clear
  *Protect object from accidental deletion*; the service account may not change
  permissions (#123).
- **Entra ID:** `Connect-RmaGraph` before the loop; the loop renews it (#30). Graph modules
  are `#Requires`d at the version `scripts/Initialize-RmaWorker.ps1` pins.
- The help names the delegation scope an AD runbook needs (`docs/INSTALLATION.md` step 6a).

## 4. Tests

`tests/Unit/<Runbook>.Tests.ps1`, built on `tests/Helpers/RunbookBody.ps1`, which takes the
body and `-Command` from the runbook's AST, so no `#Requires` module is needed. Copy the
test of the runbook you copied. Each test file:

- defines stand-ins for the cmdlets as `function global:<Name>` with the parameters the
  mocks bind, and removes them in `AfterAll` with `Remove-Item -Path Function:\<Name>`
  (`function:global:<Name>` silently removes nothing);
- sets the variables the body reads, such as `$script:server`, in `BeforeEach`;
- covers: the command name; the action with its exact arguments; already in the state;
  not found; another error passed through; each invalid payload under
  `Set-StrictMode -Version Latest`, with the control character in the middle of the value
  (`Trim` removes one at the end); the payload, and any secret, absent from every log
  record and error.

## 5. Docs and the gate

README's runbook table, the runbook list in `docs/PRODUCTION-CHECKLIST.md`, and an entry
under *Unreleased → Added* in `CHANGELOG.md` naming the issue. A new decision goes in
`docs/DECISIONS.md`. No module change means no version bump.

Run the whole gate in `CLAUDE.md`. Use `pwsh -NoProfile -NonInteractive`: without it a
missing mandatory parameter waits for input forever.

## 6. End to end on the test environment

Test environments only. The scripts in this skill read every value from
`rma-worker.local.json` and print no secret.

```powershell
$d = './.claude/skills/migrate-runbook/scripts'
& "$d/Publish-RmaTestRunbook.ps1" -Runbook <Runbook> -Confirm:$false     # create, publish, compare
& "$d/Invoke-RmaTestCheck.ps1" -ActiveDirectory -ScriptBlock { ... }     # fixtures and checks; -Graph for Entra ID
$id = & "$d/Add-RmaTestQueueRow.ps1" -Payload @{ action = '<Command>'; ... }
$job = & "$d/Start-RmaTestJob.ps1" -Runbook <Runbook> [-ForbiddenText $secret]
$job.Records | Format-Table Level, Message, SysId
& "$d/Invoke-RmaTestCheck.ps1" -ScriptBlock { Get-TestQueueRow -SysId '<id>' }
```

- **Fixtures** go in `OU=RMA-Test` of the test domain, named `rma-test-*`. The AD service
  account holds the `Users`, `Groups` and `OrganizationalUnits` scopes there. A fixture the
  service account cannot create (a protected OU, for example) is created as SYSTEM on the
  DC with `az vm run-command invoke --command-id RunPowerShellScript`. Leave reusable
  fixtures, such as `rma-test-unlock`, as you found them.
- **Queue several rows and run one job:** the normal case, the repeat (already done or not
  found), and each refusal. One job drains them all, in random order; check each row.
- Check the directory and **every row** afterwards: `status` 4 is Completed, 3 Failed.
- A Bash command longer than ten minutes moves to the background; run a long sequence as a
  script with `run_in_background` and read its log.

## 7. The pull request

Push, then open it with the REST API (`gh api repos/<repo>/pulls -f ...`), body from
`.github/pull_request_template.md`, starting `Closes #<n>`. Say what the end-to-end test
did and showed, without instance names, tenant ids or `sys_id`s. Comment on the issue with
the pull request number. **Do not merge** unless the user said to; when several branches
are merged, the README, CHANGELOG and checklist conflicts are always "keep both".

## Traps already found

| Symptom | Cause |
|---|---|
| Every `pwsh` call refused | The agent runs with `isolation: "worktree"`; use a hand-made worktree |
| A multi-word variable reaches a command as one argument | The Bash tool runs zsh, which does not split `$var`; use PowerShell or arrays |
| `Access is denied` on delete or move, though the scope is granted | A protected OU below denies Delete Child on its parent; the scope's Delete grant (#131) must be applied, run `Grant-RmaAdDelegation.ps1` again |
| `Access is denied` on any write | The service account lacks the scope on that OU (#123) |
| A job's `runbook` log field is a GUID | Automation runs the runbook from a temp file (#124); filter on `Message` |
| GraphQL `API rate limit exceeded` from `gh project` | Use REST for issues, pull requests and comments; leave board fields for later |
| The analyzer flags `$p` as unused | A nested scriptblock reads it; pass it as a parameter |
