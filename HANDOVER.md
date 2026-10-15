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

*Last reviewed: 2026-10-09.*

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

*To be written in the last week before the handover. Until then this is a snapshot.*

- **Done:** the shared module (`RMA.Runbooks` 2.5.0) with the queue loop, claim, heartbeat,
  retry of a job that is not ready yet, watchdog, health check and logging; CI and the
  release pipeline; and 22 command runbooks on it, among them the references
  `Create-EntraUser` for Entra ID and `Unlock-ADUser` for Active Directory.
- **Released:** 2.5.0 is the latest release (2026-10-15), installed on the test Hybrid
  Worker, the only worker today. Since 2.2.0 it adds the `command` log field
  ([#124](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/124)),
  the `Retry-After` cap
  ([#117](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/117))
  and the retry of objects Graph has not replicated yet (D18, D19,
  [#146](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/146),
  [#173](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/173)).
  2.2.1 to 2.4.0 were drafted and deleted unpublished, because 2.5.0 holds them; 2.1.0 was
  never published either. Every module change bumps the version, so each merge to `main`
  that touches the module needs its release published and installed on every worker
  before the ServiceNow application takes the runbooks from `main`.
- **In progress:** migrating the 1.0 runbooks
  ([#36](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/36)).
  41 are left, and all but one wait on the ServiceNow team (#106, #108, #109), among them
  the live Import-Entra* commands and the four Initial-Import runbooks, whose rebuild is
  decided in
  [DECISIONS.md D12](docs/DECISIONS.md#d12-how-the-four-initial-import-runbooks-are-to-be-rebuilt).
- **Never run end to end:** a job created by the ServiceNow application, claimed and
  completed by a runbook on a worker. The queue columns `worker_id` and `claimed_at` exist
  on the test instance since 2026-09-30.

## Waiting on the ServiceNow team

The ServiceNow application is maintained outside this repository. Each thing it has to do
is an issue owned by the ServiceNow team, with the `servicenow` label, as a sub-issue of
[#35](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/35). Issues here that wait on one have a *Blocked by* relation to it. The board's
**ServiceNow** view shows them all.

| Issue | What | Why it matters |
|---|---|---|
| [#106](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/106) | The `/insertMultiple` contract and the resource names | Every runbook that writes to ServiceNow, including the Initial-Import runbooks ([D12](docs/DECISIONS.md#d12-how-the-four-initial-import-runbooks-are-to-be-rebuilt)) |
| [#108](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/108) | Domain record fields and job parameters, including Exchange `Organization` | ServiceNow cannot supply the runbook parameters ([D9](docs/DECISIONS.md#d9-changes-to-the-servicenow-domain-record)); no Exchange runbook can connect |
| [#27](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/27) | A server-side compare-and-set for the job claim (Scripted REST) | Without it two executions can run the same job ([F1](docs/DECISIONS.md#f1-the-job-claim-is-not-atomic-on-the-instance-it-was-tested-on)) |
| [#23](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/23) | Fix the health endpoint's resource script | Every `Test-RmaHealth` job fails |
| [#107](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/107) | Run `/cleanup` on their side, skipped after a failed import | Until then the runbook has to do it |
| [#109](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/109) | Which overlapping 1.0 commands are still sent | Decides which runbooks need migrating |
| [#110](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/110) | How often the watchdog is started | A stranded job waits `StaleAfterMinutes` plus that interval |
| [#111](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/111) | How the application takes runbooks from `main`, and how an operator stops it | Rolling out a module version, and rollback |
| [#112](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/112) | A written installation guide for the ServiceNow application | [INSTALLATION.md](docs/INSTALLATION.md) covers only Azure |

## Open work in this repository

Tracked as GitHub issues, most urgent first. The
[project board](https://github.com/orgs/Mjolner-ServiceNow/projects/1) shows the same issues
by status (Backlog, Ready, In progress, Done) and priority (P1 blocks production use). Add every new issue to it, and move a card when its state changes:

- [#27](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/27) The job claim is not atomic; the call into the ServiceNow endpoint is ours.
- [#36](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/36) Migrate the remaining 1.0 runbooks.
- [#31](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/31) `Test-RmaHealth` does not verify Exchange.
- [#170](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/170) Provisioning has not been tried on a network that allows only the documented hosts.

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
