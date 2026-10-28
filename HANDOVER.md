# Handover

What a new maintainer needs to take RMA 2.0 over: what is finished, what is not, what is
waiting on someone else and what is decided but not yet built. The maintainer changes on
2026-10-30, possibly before the rewrite is complete.

This file is the index. Detail lives where it is maintained: open work in
[GitHub issues](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues),
laid out by status and priority on the
[RMA 2.0 project board](https://github.com/orgs/Mjolner-ServiceNow/projects/1), the reasons behind the design in [docs/DECISIONS.md](docs/DECISIONS.md), and how the system
works in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). When something here is done, delete
the line instead of ticking it.

*Last reviewed: 2026-10-28.*

## Where to start

Read in this order:

1. [README.md](README.md): what the repository is and why it replaces 1.0.
2. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): the queue contract, identity, job
   lifecycle and runbook parameters.
3. [docs/DECISIONS.md](docs/DECISIONS.md): why it is built this way, and what testing
   against ServiceNow and Azure established. Read F1 before trusting the job claim.
4. [docs/INSTALLATION.md](docs/INSTALLATION.md) and
   [docs/AZURE-RESOURCES.md](docs/AZURE-RESOURCES.md): building an environment.
5. [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) and [CLAUDE.md](CLAUDE.md): how changes are
   made, tested and released.

The best test of the documentation is to build the test environment from it without help.
Every place that needed help is a gap; record it.

## State of the work

*Written 2026-10-28, two days before the handover.*

- **Done:** the shared module (`RMA.Runbooks` 2.6.0) with the queue loop, claim, heartbeat,
  retry of a job that is not ready yet, watchdog, health check and logging; CI and the
  release pipeline; and 27 command runbooks on it, plus `Invoke-RmaQueueWatchdog` and
  `Test-RmaHealth`. The references are `Create-EntraUser` for Entra ID and `Unlock-ADUser`
  for Active Directory. The last four merged on 2026-10-21 and are the first that write to
  ServiceNow in bulk: `Initial-Import-ADUsers`
  ([#184](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/pull/184)),
  `Initial-Import-EntraUsers`
  ([#194](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/pull/194)),
  `Import-EntraUsers`
  ([#196](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/pull/196))
  and `Import-EntraMFA`
  ([#197](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/pull/197)).
  Each ran as a real Automation job on the test worker against the test instance; the
  pull requests say what was compared. None was run at the 500,000-user scale the rewrite
  is for.
- **Released:** 2.6.0 is the latest release (2026-10-15), installed on the test Hybrid
  Worker, the only worker today. The four import runbooks came after it but changed no
  module code, so they run on 2.6.0 and need no release. 2.6.0 adds
  `Update-EntraUserHideMailbox`, the first Exchange runbook, which has not run end to end
  because the test app registration has no Exchange role
  ([#180](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/180);
  still missing when the environment was read on 2026-10-28,
  [#199](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/199)).
  2.2.1 to 2.4.0 were drafted and deleted unpublished, because 2.5.0 holds them; 2.1.0 was
  never published either. `CHANGELOG.md` still files everything since 2.0.1 under
  *Unreleased*
  ([#202](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/202));
  the release notes on GitHub are the record of what each release holds. Every module
  change bumps the version, so each merge to `main` that touches the module needs its
  release published and installed on every worker before the ServiceNow application takes
  the runbooks from `main`.
- **In progress:** migrating the 1.0 runbooks
  ([#36](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/36)).
  36 are left. 27 wait on the ServiceNow team's
  [#106](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/106)
  alone, four on #106 and
  [#109](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/109),
  and three on #109 alone. Two wait on nothing and can be started now:
  `Add-MailboxPermission`
  ([#41](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/41))
  and `Create-ADDistributionGroup`
  ([#43](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/43)).
  Each issue's *Blocked by* relation is the current answer. The two Initial-Import runbooks
  left, for groups, are rebuilt as
  [DECISIONS.md D12](docs/DECISIONS.md#d12-how-the-four-initial-import-runbooks-are-to-be-rebuilt)
  decides.
- **Never run end to end:** a queue row created by the ServiceNow application itself,
  claimed and completed by a runbook on a worker. Every test so far queued its rows with
  the `migrate-runbook` skill's scripts. The queue columns `worker_id` and `claimed_at`
  exist on the test instance since 2026-09-30.

### Answered by the ServiceNow team, not yet acted on here

The ServiceNow team answered four issues on 2026-10-22, after the last change was merged
here. Start with these:

- **The claim can be made atomic.**
  [#27](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/27)
  now has a compare-and-set endpoint, `POST …/queue/{jobid}/{claim|heartbeat|requeue}`.
  Calling it from `Request-RmaJobClaim`, `Update-RmaJobHeartbeat` and the watchdog's
  requeue is
  [#201](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/201).
  Until that is merged and released, F1 still holds: two executions can run the same job.
- **`Create-EntraUser` can write back to the right table.** Both `/insertMultiple`
  endpoints exist, but the runbook still writes the new user to `/domain/{DomainId}/user`
  ([#40](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/40)).
- **The health endpoint is fixed** on ServiceNow's side
  ([#23](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/23)).
  `Test-RmaHealth` has not been run against it since; close the issue once it has.
- **The watchdog is started per job, not on a cadence**
  ([#110](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/110)):
  about 61 minutes after a claim, and only while that job is still Work in Progress, with
  `StaleAfterMinutes` 60. D10 still says the cadence is not agreed, and D11 assumes the
  runbook's default of 30; both need updating from the issue.

The board showed #23, #40 and #110 as Done while the issues were open. #40 was set back to
Ready on 2026-10-28, since its work is ours.

## Waiting on the ServiceNow team

The ServiceNow application is maintained outside this repository. Each thing it has to do
is an issue owned by the ServiceNow team, with the `servicenow` label, as a sub-issue of
[#35](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/35). Issues here that wait on one have a *Blocked by* relation to it. The board's
**ServiceNow** view shows them all.

| Issue | What | Why it matters |
|---|---|---|
| [#106](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/106) | The `/insertMultiple` contract and the resource names, including fields ServiceNow truncates and a `username` it never updates | 31 of the runbooks left under #36 |
| [#109](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/109) | Which overlapping 1.0 commands are still sent | Decides whether 7 of the runbooks left need migrating |
| [#192](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/192) | `/entraiduser/cleanup`, limited to the domain in its path | Until it exists, a user deleted from Entra ID stays in ServiceNow ([#193](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/193)) |
| [#185](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/185) | `/aduser/cleanup` does not remove a user deleted from AD | The same, for Active Directory |
| [#130](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/130) | Passwords stay readable in the command queue after a password job | A password job leaves the password on the row |
| [#111](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/111) | How the application takes runbooks from `main`, and how an operator stops it | Rolling out a module version, and rollback |
| [#112](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/112) | A written installation guide for the ServiceNow application | [INSTALLATION.md](docs/INSTALLATION.md) covers only Azure |

## Open work in this repository

Tracked as GitHub issues, most urgent first. The
[project board](https://github.com/orgs/Mjolner-ServiceNow/projects/1) shows the same issues
by status (Backlog, Ready, In progress, Done) and priority (P1 blocks production use). Add every new issue to it, and move a card when its state changes:

- [#201](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/201) P1. Claim, heartbeat and requeue do not yet call ServiceNow's compare-and-set endpoint, so the claim is not atomic.
- [#40](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/40) P1. `Create-EntraUser` writes the new user back to the Active Directory user endpoint.
- [#36](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/36) P1. Migrate the remaining 1.0 runbooks.
- [#141](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/141) P2. `Revoke-SignInTokens` cannot disable a user synced from on-premises AD.
- [#180](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/180) P2. Run `Update-EntraUserHideMailbox` end to end; needs the Exchange role first.
- [#193](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/193) P2. `Initial-Import-EntraUsers` calls no cleanup until `/entraiduser/cleanup` exists.
- [#31](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/31) P3. `Test-RmaHealth` does not verify Exchange.
- [#170](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/170) P3. Provisioning has not been tried on a network that allows only the documented hosts.
- [#195](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/195) P3. `Import-EntraUsers` does not import changes to existing users.
- [#198](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/198) P3. `Import-EntraMFA` reads phone methods one user at a time, too slow at 500,000 users.
- [#199](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/199) P3. Where the test environment differs from [AZURE-RESOURCES.md](docs/AZURE-RESOURCES.md), not yet triaged.
- [#202](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/202) P3. `CHANGELOG.md` has no section for any release after 2.0.1.

None of these, and none of the migrations under #36, has an owner. The maintainer who
leaves on 2026-10-30 was removed from them on 2026-10-28, so they stay unassigned until
the next maintainer is named, against the one-owner rule in
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md). Whoever takes over assigns themselves to the
issues they start. The ServiceNow team's issues keep their owner.

## Kept outside this repository

The repository is public, so some of what the next maintainer needs cannot be here. It is
in the private repository
[Mjolner-ServiceNow/Rights-Management-App-Internal](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Internal).
An owner of the `Mjolner-ServiceNow` GitHub organization grants access to it. It holds no
secrets: those stay in Key Vault or with whoever grants the access.

- **The 1.0 runbooks**, the source of every runbook still to migrate, are in the team's
  Azure DevOps organization. `legacy-runbooks.md` there names the repository and who adds
  you to it.
- **The test environment**: subscription, resource groups, VMs, Bastion, Key Vault, the
  test Active Directory domain, the Entra tenant the Graph runbooks are tested in, and the
  ServiceNow test instance with its integration account. `test-environment.md` there.
- **Accounts and access** the maintainer needs, who grants each, and whom to contact at
  ServiceNow and at the customer. `access.md` there.
- **Local test configuration**: a copy of `rma-worker.local.json`, which is gitignored here,
  with the paths to your own SSH key and 1.0 clone left for you to fill in.

## Working with Claude Code here

The repository is set up for Claude Code. [CLAUDE.md](CLAUDE.md) is loaded into every
session, and four skills live in `.claude/skills/`: `track-work` for issues and the board,
`powershell-7-expert` for the house rules, `test-on-hybrid-worker` for trying a change on a
real worker, and `migrate-runbook` for moving a 1.0 runbook onto the shared module, end to
end, which is most of the work left under #36.

Claude Code's memory files live on the machine that ran it, not in the repository.
Everything durable from them has been moved into [docs/DECISIONS.md](docs/DECISIONS.md).
In a worktree-isolated session Claude Code refuses to run `pwsh` at all, which in a
PowerShell repository blocks the analyzer and the tests. A worktree added by hand with
`git worktree add` does not have that problem, which is how `migrate-runbook` runs several
migrations in parallel.

## Keeping the documentation true

The audit that produced this file found the documentation mostly right, and wrong exactly
where the code changed after the text was written. To keep it that way:

- A pull request that changes behaviour updates the doc that describes it and
  `CHANGELOG.md` in the same pull request.
- A decision or a finding about ServiceNow or Azure goes into
  [docs/DECISIONS.md](docs/DECISIONS.md) when it is made, not into someone's notes.
- All work is an issue with one owner, on the
  [RMA 2.0 board](https://github.com/orgs/Mjolner-ServiceNow/projects/1), as *Tracking
  work* in [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) describes. Not this file's prose.
- Before publishing a release, check the docs against the code. Ask Claude Code to audit
  the documentation against the source; that is how this file started.
