Closes #

<!-- Every pull request closes an issue; see "Tracking work" in docs/CONTRIBUTING.md.
     Use "Part of #<n>" instead if it does only part of the issue. -->

## What and why

## How it was checked

- [ ] The gate in `CLAUDE.md` passes locally
- [ ] Docs that describe this behaviour are updated, and `CHANGELOG.md` under *Unreleased*
- [ ] `ModuleVersion` bumped, if anything under `src/RMA.Runbooks` changed
- [ ] Tried on a test Hybrid Worker, if it changes what a runbook does against a real system
- [ ] No customer-identifying values: names, instances, tenant ids, hostnames, real `sys_id`s
