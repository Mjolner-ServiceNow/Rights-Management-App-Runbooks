---
name: track-work
description: Use at the start of every task in this repository, and whenever the work changes state - finding or creating the GitHub issue for it, assigning its owner, putting it on the RMA 2.0 project board with Status and Priority, naming the branch, linking the pull request, recording what blocks it (a Blocked by relation, or an issue for the ServiceNow team under #35), recording progress on the issue, and opening a new issue for something found out of scope.
---

# Tracking work through issues and the board

All work on this repository is a GitHub issue with one owner, and all project tracking goes
through the **RMA 2.0** project board. The human version of the process, with what each
column and priority means, is *Tracking work* in `docs/CONTRIBUTING.md`. This file is how to
do it with `gh`.

The issue is also your memory. Your session ends; the next person, or the next Claude,
starts from the issue and the board, not from this conversation. Write down there what
they will need.

## Rules

1. **No work without an issue.** At the start of a task, find the issue. If there is none,
   create it before changing anything, including documentation.
2. **One owner.** Every issue has exactly one assignee. By default that is the user you work
   for, which is the account `gh` is signed in as (`@me`). If the user says someone else
   owns it, assign that person instead.
3. **On the board, with Status and Priority.** Auto-add puts new issues on the board with
   both fields empty. Set them.
4. **Keep the state true.** Move the card when the state changes, not at the end.
5. **One pull request closes one issue,** with `Closes #<n>` in its body.
6. **Out of scope becomes a new issue.** Something you notice that does not belong to the
   current issue gets its own, in Backlog, assigned to the user, and you tell them. It
   does not go into the current pull request.
7. **The repository is public, and so are its issues.** No customer names, instance names,
   tenant or subscription ids, hostnames or real `sys_id` values in an issue, a comment or a
   pull request. Customers are never named.
8. **Never close an issue by hand without a comment saying why.** Merging the pull request
   closes it in the normal case.

## Fixed values

| | |
|---|---|
| Repository | `Mjolner-ServiceNow/Rights-Management-App-Runbooks` |
| Project | number `1`, owner `Mjolner-ServiceNow`, <https://github.com/orgs/Mjolner-ServiceNow/projects/1> |
| Status | `Backlog`, `Ready`, `In progress`, `Done` |
| Priority | `P1`, `P2`, `P3` |
| Labels | `bug`, `enhancement`, `documentation`, `servicenow`, `question` |

The values are case-sensitive and must match exactly.

## Prerequisites

```bash
gh auth status        # the token scopes must include 'project'
```

If `project` is missing, ask the user to run `gh auth refresh -h github.com -s project`. It
opens a browser, so you cannot do it for them.

The commands below select project fields by name with `--field` and `--value`, which
`gh` 2.102 supports. If `gh` rejects those flags, ask the user to upgrade it rather than
falling back to GraphQL node ids.

## 1. Find or create the issue

```bash
gh issue list -R Mjolner-ServiceNow/Rights-Management-App-Runbooks --state all --search "<words>"
gh issue view <n> -R Mjolner-ServiceNow/Rights-Management-App-Runbooks --comments
```

Read the comments before starting. They are where the last person left off.

To create one:

```bash
gh issue create -R Mjolner-ServiceNow/Rights-Management-App-Runbooks \
  --title "<what is wrong or what is wanted, as a statement>" \
  --label <label> --assignee @me \
  --body "<what, why, and what done looks like>"
```

A good body:

- says what is wrong or wanted;
- names the files involved;
- says what *done* means;
- links the relevant entry in `docs/DECISIONS.md` or `HANDOVER.md`.

Someone who has never seen this conversation must be able to act on it.

## 2. Put it on the board

Auto-add can take a few seconds, so add it yourself. Adding an issue that is already on the
board does nothing.

```bash
url=https://github.com/Mjolner-ServiceNow/Rights-Management-App-Runbooks/issues/<n>
gh project item-add 1 --owner Mjolner-ServiceNow --url "$url"
gh project item-edit 1 --owner Mjolner-ServiceNow --url "$url" --field Status --value "In progress"
gh project item-edit 1 --owner Mjolner-ServiceNow --url "$url" --field Priority --value P2
```

`item-edit` sets one field per call.

**Choosing Priority:**

- **P1:** blocks production use, or blocks other work.
- **P2:** needed before go-live.
- **P3:** an improvement that can wait.

If unsure, ask the user. Do not default to P1.

## 3. Start work

1. Assign the owner if the issue has none:
   `gh issue edit <n> -R ... --add-assignee @me`.
2. Set Status to `In progress`.
3. Create the branch from an up-to-date `main`. Name it `<type>/<n>-<short-slug>`, where
   type is `feat`, `fix`, `docs`, `chore` or `test`. For example: `fix/24-retry-headers`.

Commit messages follow the existing history: `fix: ...`, `feat: ...`, `docs: ...`, in the
imperative.

## 4. While working

Comment on the issue when something is learned that the next person would need:

- a finding;
- a dead end;
- a decision the user made;
- what is left when you stop.

```bash
gh issue comment <n> -R Mjolner-ServiceNow/Rights-Management-App-Runbooks --body "..."
```

A decision that outlives the issue also goes into `docs/DECISIONS.md`, with a link from
the comment.

## 5. Blocked by another issue, or by the ServiceNow team

There is no *Blocked* status. A blocked issue keeps its own status (usually `Backlog` or
`Ready`) and gets a **Blocked by** relation to the issue that blocks it. The relation
clears itself when the blocker closes.

```bash
R=Mjolner-ServiceNow/Rights-Management-App-Runbooks
blocker_id=$(gh api repos/$R/issues/<blocker> -q .id)      # the REST id, not the number
gh api -X POST repos/$R/issues/<n>/dependencies/blocked_by -F issue_id=$blocker_id
gh api repos/$R/issues/<n>/dependencies/blocked_by -q '.[].number'   # check
```

**When the blocker is work for the ServiceNow team**, it must be an issue of its own:

1. Find it among the sub-issues of #35, or create it: owned by the ServiceNow team,
   labelled `servicenow`, saying exactly what is asked of them.
2. Make it a sub-issue of #35:
   `gh api -X POST repos/$R/issues/35/sub_issues -F sub_issue_id=$(gh api repos/$R/issues/<new> -q .id)`
3. Put it on the board with Status `Ready` and a Priority.
4. Add the *Blocked by* relation from every issue here that waits on it.

The `servicenow` label goes only on the ServiceNow team's own issues, never on the issues
that wait on them: the board's **ServiceNow** view (`label:servicenow`) is their work list.

A blocker that is not an issue, such as a person or a decision, is named in a comment.

## 6. Open the pull request

Start the body with `Closes #<n>` and fill in `.github/pull_request_template.md`. `gh pr
create` picks the template up when no `--body` is given. With `--body`, keep its headings.
Merging closes the issue, and the board's *Item closed* workflow moves it to Done.

If a pull request only partly addresses an issue, write `Part of #<n>` instead of
`Closes`, and comment on the issue with what is left.

## 7. Stopping without finishing

1. Comment with the state: what is done, what is left, the branch name.
2. Leave the Status as it is, if someone is still on it. Otherwise set it back to `Ready`
   and remove yourself as assignee, only when the user says ownership moves.

## Looking at the board

```bash
gh project item-list 1 --owner Mjolner-ServiceNow --limit 200 --format json \
  -q '.items[] | "\(.status // "-")\t\(.priority // "-")\t#\(.content.number) \(.content.title)\t\(.assignees // ["UNASSIGNED"] | join(","))"' | sort
```

Look for these:

- an item with no Status or Priority;
- an open issue with no assignee;
- an issue that is `In progress` with no activity for a week.

Fix them, or raise them with the user.
