# Handover

What a new maintainer needs to take RMA 2.0 over: what is finished, what is not, what is
waiting on someone else and what is decided but not yet built. The maintainer changes on
2026-10-30, possibly before the rewrite is complete.

This file is the index. Detail lives where it is maintained: open work in
[GitHub issues](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues),
the reasons behind the design in [docs/DECISIONS.md](docs/DECISIONS.md), and how the system
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

- **Done:** the shared module (`RMA.Runbooks` 2.1.0) with the queue loop, claim, heartbeat,
  watchdog, health check and logging; CI and the release pipeline; the reference runbook
  `Create-EntraUser`.
- **Released:** 2.0.1 is the latest published release. 2.1.0 is a **draft**. The runbooks
  on `main` already require 2.1.0, so publish it and install it on every worker before the
  ServiceNow application next takes the runbooks from `main` ([#34](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/34)).
- **Not started:** migrating the remaining 1.0 runbooks, including the live Import-Entra*
  commands and the four Initial-Import runbooks, whose rebuild is decided in
  [DECISIONS.md D12](docs/DECISIONS.md#d12-how-the-four-initial-import-runbooks-are-to-be-rebuilt)
  ([#36](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/36)).
- **Never run end to end:** a job created by the ServiceNow application, claimed and
  completed by a runbook on a worker. The queue columns `worker_id` and `claimed_at` exist
  on the test instance since 2026-09-30.

## Waiting on the ServiceNow team

The ServiceNow application is maintained outside this repository. These items stop work
here until they are done.
[#35](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/35) tracks them, with the open questions below, as one
checklist for the ServiceNow team.

| What | Why it matters | Reference |
|---|---|---|
| A server-side compare-and-set for the job claim (Scripted REST) | Without it two executions can run the same job | [#27](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/27), [DECISIONS.md F1](docs/DECISIONS.md#f1-the-job-claim-is-not-atomic-on-the-instance-it-was-tested-on) |
| Fix the health endpoint's resource script | Every `Test-RmaHealth` job fails | [#23](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/23) |
| The domain record field changes | ServiceNow cannot supply the runbook parameters | [DECISIONS.md D9](docs/DECISIONS.md#d9-changes-to-the-servicenow-domain-record) |
| The `/insertMultiple` contract: URL, body, upsert semantics, response | The Initial-Import runbooks cannot be written | [DECISIONS.md D12](docs/DECISIONS.md#d12-how-the-four-initial-import-runbooks-are-to-be-rebuilt) |
| Running `/cleanup` on their side, skipped after a failed import | Until then the runbook has to do it | D12 |
| A written installation guide for the ServiceNow application | [INSTALLATION.md](docs/INSTALLATION.md) covers only Azure; the ServiceNow half has no written procedure | |

## Open work in this repository

Tracked as GitHub issues, most urgent first:

- [#27](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/27) The job claim is not atomic; the call into the ServiceNow endpoint is ours.
- [#24](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/24) Retry in `Invoke-RmaRestMethod` has never worked.
- [#28](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/28) `RmaAvoidUnredactedObjectLogging` does not match `$ParameterObject`.
- [#29](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/29) Log redaction misses common secret names and never redacts `-Message`.
- [#30](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/30) Graph and Exchange sessions are never refreshed during a run.
- [#34](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/34) Publish 2.1.0 and install it on every worker before the runbooks move.
- [#36](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/36) Migrate the remaining 1.0 runbooks.
- [#31](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/31) `Test-RmaHealth` does not verify Exchange.
- [#33](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/33) Run the Run Command provisioning route and the outbound hosts on a real worker.
- [#32](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/32) Require CI to pass before merging to `main`.

## Open questions

Each needs an answer from the ServiceNow team, not more code. All are on
[#35](https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/35):

- How and when does the ServiceNow application take the runbooks from `main`, and how is
  it held back while a new module version is installed on the workers?
- How often should the ServiceNow application start the watchdog? A stranded job waits
  `StaleAfterMinutes` plus that interval.
- How does an operator stop the ServiceNow application from starting runs, for a
  rollback?
- Which ServiceNow field and runbook parameter will carry Exchange's `Organization`
  (`*.onmicrosoft.com`)? See
  [DECISIONS.md D9](docs/DECISIONS.md#d9-changes-to-the-servicenow-domain-record).
- Does the ServiceNow application need the Automation Account's resource group as a
  separate value? The ARM path to start a job contains it, so
  [INSTALLATION.md](docs/INSTALLATION.md) lists it among the values to record.

## Kept outside this repository

The repository is public, so some of what the next maintainer needs cannot be here. Before
the handover each of these must be somewhere they can reach, and this section must say
where:

- **The 1.0 runbooks**, the source of every runbook still to migrate. *Location: to be
  decided.*
- **The test environment**: subscription, resource groups, VMs, Bastion, Key Vault, the
  ServiceNow test instance and its integration account. *Location: to be decided.*
- **Accounts and access** the maintainer needs: GitHub repository admin, the Azure test
  subscription, the ServiceNow test instance, and who at ServiceNow and at the customer to
  contact. *Location: to be decided.*
- Local test configuration: `rma-worker.local.json`, which is gitignored.

## Working with Claude Code here

The repository is set up for Claude Code. [CLAUDE.md](CLAUDE.md) is loaded into every
session, and two skills live in `.claude/skills/`: `powershell-7-expert` for the house
rules and `test-on-hybrid-worker` for trying a change on a real worker.

Claude Code's memory files live on the machine that ran it, not in the repository.
Everything durable from them has been moved into [docs/DECISIONS.md](docs/DECISIONS.md).
In a worktree-isolated session Claude Code refuses to run `pwsh` at all, which in a
PowerShell repository blocks the analyzer and the tests, so work on an ordinary feature
branch.

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
