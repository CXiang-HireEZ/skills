---
name: hireez-git-conventions
description: HireEZ git conventions for commit messages, branch names, and PR targets. Use when committing, creating or naming a branch, or opening a PR in a HireTeamMate repo (TM-Hiretual-Frontend, htm-backend, native-agent-frontend, native-agent-backend).
---

# HireEZ git conventions

Applies to `TM-Hiretual-Frontend`, `htm-backend`, `native-agent-frontend`, `native-agent-backend`. (`TM-Hiretual-Backend-proxy` has no consistent convention.)

## Commit messages

```
<TICKET> <Imperative description> [ez-ai-assisted]
```

- Ticket first, then a space. No colon, no `feat:`/`fix:` prefix. Ticket is a Jira key, almost always `HT5-xxxxx`.
- Imperative, plain-English sentence describing the behavior change, e.g. `HT5-45806 Let the candidate sign with any name they type`.
- Append `[ez-ai-assisted]` when AI helped significantly.
- Test-only commits: `<TICKET> [fix-ut]<description>`, e.g. `HT5-45930 [fix-ut]Check the offer approval is among the personal cards`.
- Merge commits also lead with the ticket: `HT5-45806 Merge erbing/HT5-45806 into the 10/18 hotfix`.

Documented in `native-agent-backend/AGENTS.md` and `native-agent-backend/docs/legacy/claude-guide.md`.

## Long-lived branches

- `master`: default / production.
- `develop`: integration.
- `hotfix/MMDDYYYY`: dated hotfix branch (e.g. `hotfix/10182026`), PR'd into `master`.
- `release/*`, `common/*`: also valid PR targets per CI.
- Releases are tags, not branches: `release/MMDDYYYY`, then `.1`, `.2`, … for follow-ups.

## Workflow for bug fixes and feature changes (Xiang's convention)

Follow this for every bug fix or feature modification.

1. **Branch from the latest release tag.** Fetch tags and cut the work branch from the newest `release/*` tag:
   ```bash
   git fetch origin --tags
   TAG=$(git tag -l 'release/*' --sort=-creatordate | head -1)
   git checkout -b xiangchen/<TICKET>[/<short-description>] "$TAG"
   ```
2. **Name the branch** `xiangchen/<TICKET>/<optional-short-description>`, e.g. `xiangchen/HT5-46102` or `xiangchen/HT5-46102/fix-offer-signature`. This is the "from-release" branch.
3. **Test via `develop`.** Open a PR from the from-release branch into `develop`.
   - If that PR has conflicts, don't resolve them on the from-release branch. Instead cut `xiangchen/from-develop/<TICKET>` from `origin/develop`, cherry-pick the from-release commits onto it, resolve conflicts there, and open the `develop` PR from this branch.
4. **Keep the two branches in sync.** Any follow-up fix goes onto the from-release branch first and is cherry-picked onto the from-develop branch (or vice versa), so both carry the same change.
5. **Ship to production.** Once the change is tested and approved, PR the from-release branch into `master` (the production branch). Never PR the from-develop branch into `master`.
   - **Never do this step on your own.** Don't open or merge the `master` PR as part of finishing a task. Only do it when Xiang explicitly says to.
6. **Subtasks and follow-up bug tickets reuse the original branch.** A ticket may have subtasks for related bugs or tasks. QA may also file a separate bug ticket against a change from an earlier ticket. Either way, the fix usually depends on the earlier ticket's code, which may not be in a release tag or in `develop` yet. Don't cut a new branch from the release tag or from `develop`. Commit on the earlier ticket's from-release branch, cherry-pick onto its from-develop branch as in step 4, and start each commit message with the new ticket's number, e.g. `HT5-46230 Keep the signature field when the offer is re-sent` on `xiangchen/HT5-46102`.

## Other branch names seen in the repos

Documented format: `username/from-branch/TICKET-ID` (e.g. `alice/from-dev/IM-10481`). Teammates also use `username/TICKET`, `username/from-hotfix/TICKET`, `from-hotfix/TICKET`, and `username/develop/TICKET-short-suffix`. Use the workflow above for your own branches.

## Hooks and CI

- `TM-Hiretual-Frontend`, `native-agent-frontend`: pre-commit runs lint-staged + `ts-check`.
- `htm-backend`: pre-commit is off unless `HTM_PRECOMMIT=1` or `git config htm.precommit.enabled true`; pre-push always runs lint-staged + full build.
- No commitlint and no PR templates; the format is not enforced automatically.
- PR CI runs on PRs into `develop`, `master`, `release/*`, `hotfix/*`.
