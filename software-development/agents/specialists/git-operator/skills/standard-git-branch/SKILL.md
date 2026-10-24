---
name: standard-git-branch
description: The single rubric for a good git BRANCH — workflow, naming, one-concern-per-branch, hygiene, and protection — followed by the git-operator whenever a branch is created, named, kept current, or protected. It does NOT define commit format (standard-git-commit) or tags (standard-git-tag).
---

# Standard: Git Branch

The **one** definition of a good branch. A branch is a **short-lived, single-purpose** line of work, named so a human (and tooling) knows what it holds.

## Workflow — Git Flow

This project uses **Git Flow**. Two long-lived branches and three supporting roles — feature work, releases, hotfixes:

| Branch | Lifetime | Branches FROM | Merges INTO |
|--------|----------|---------------|-------------|
| `main` (`master`) | permanent — always production-ready | — | — |
| `develop` | permanent — integration | — | — |
| `feat/*` | short | `develop` | `develop` |
| `release/*` | short | `develop` | `main` **and** `develop` |
| `hotfix/*` | short | `main` | `main` **and** `develop` |

`fix/*`, `refactor/*`, `perf/*`, `docs/*` and `chore/*` branch from and merge into `develop` exactly like `feat/*`.

> **Deliberate-choice note:** Git Flow suits software that ships **versioned releases with multiple supported versions** (SDKs, i.e. Software Development Kits; installed/on-prem, mobile store cadence). For a continuously-delivered single-version app, a simpler trunk-based / GitHub-Flow model is often better — Git Flow's own author now advises CD (Continuous Delivery) teams toward it. This standard commits to Git Flow by project choice; if the delivery model is pure CD, revisit that choice rather than shoehorning it.

## Naming

`<type>/<ticket>-<kebab-description>` — e.g. `feat/1-token-refresh`, `fix/PROJ-42-null-session`, `hotfix/OPS-7-urgent-cert-rotation`.

- **`type/` prefix** is a deliberate, coarser-grained subset of `standard-git-commit`'s own type vocabulary (`feat` · `fix` · `refactor` · `perf` · `docs` · `chore`) — a branch rarely exists solely for a `style`/`test`/`build`/`ci`/`revert` commit, so those fold under the closest type above (when none is closer, `chore`) — plus two Git-Flow-specific categories with no commit-type equivalent: `hotfix` · `release`.
- **Ticket id required** — every branch traces to the issue it serves, and a tracker such as Jira links a branch to its issue only through the key in the branch name. No ticket yet? Ask for one rather than inventing an id or leaving it out. Enforced by `procedure-git-ops`' `create-branch.sh`, which refuses a branch without `--ticket`. Place it right after the prefix. **Do NOT use `#`** (`feat/#1-…` breaks: `#` truncates in shells and must be percent-encoded in URLs). Use the bare number or key: `feat/1-…`, `feat/PROJ-1-…`.
- **The ticket is lowercase, except a tracker key, which is uppercase.** A *tracker key* is an id issued by a key-based tracker (e.g. Jira) whose issued form, uppercased, matches `^[A-Z][A-Z0-9]+-[0-9]+$` — e.g. `PSWS-1313`, `AB2-7`. If you don't know which tracker issued an id, ask: its case cannot be decided without that. Write it uppercase even when it was supplied lowercase (`feat/PSWS-1313-…`, never `feat/psws-1313-…`): Jira links a branch to an issue only when the key in the branch name is uppercase, with no case-insensitive option. Every other id — a numeric id, a lowercase slug such as `ops-incident-7`, a mixed-case id such as `Ops-Incident-7` — is written in lowercase. Build the ticket segment in this order: (1) decide whether the id is a tracker key, on its form **as issued**; (2) drop a leading `#`; (3) replace every other character that is not a letter or digit with a hyphen, then collapse repeated hyphens and trim them from both ends; (4) apply the case rule. So a key whose issued form falls outside the pattern (e.g. a custom Jira key format that allows `_` in the project part, such as `MY_PROJ-42`) is not a tracker key: it becomes `my-proj-42`, and Jira will not link it.
- **Type and description: lowercase, kebab-case, alphanumerics + hyphens only** — no spaces, underscores, or punctuation; replace any special char with a hyphen, then collapse repeated hyphens and trim them from both ends. Avoid `..` and a trailing `.lock` (git-reserved). The ticket's case follows its own rule (above).
- Short and descriptive.

## One concern per branch

- A branch holds **one concrete concern** — one feature, one fix, one refactor — not a mixed bag.
- **Exception:** a genuine cross-module **refactoring effort** may span many modules on one branch; prefer focused branches otherwise, and if a "feature" is really several concerns, split it into multiple branches (or a stack of PRs).

## Hygiene

- **Short-lived** — hours to a few days. Branches older than ~2–3 days make conflicts inevitable.
- **Keep current with the base** — rebase the branch onto its base branch regularly (rebase, not merge-in, to keep history linear).
- **Delete after merge** — enable auto-delete on merge; don't accumulate stale branches.
- **Pushing / staying current** — set the upstream on first push (`git push -u <remote> <branch>`; don't assume `origin` in a multi-remote repo). A rejected **non-fast-forward** push means fetch + rebase onto the base then re-push — never blind `--force`; use **`--force-with-lease`** only to overwrite your OWN un-shared branch after a rebase (never a shared/protected branch). Verify the tree is clean (`git status`) before switching branches or rebasing — stash or refuse rather than clobber uncommitted work.

## Protection (the server-side backstop)

`main` and `develop` are **protected** — on GitHub via a **repository ruleset**, on GitLab via **protected branches + push rules** (same intent, different mechanism):
- Require a **pull/merge request** before merging (no direct pushes).
- Require **signed commits** and **linear history**.
- Require **passing status checks** (commitlint + build/test) and **≥ 1 review**.
- **Block force-pushes** and branch deletion.

Client-side branch discipline is advisory; the platform's protection setting is what makes it an invariant. **`release/*` is a different case** — per the workflow table above it is short-lived and merges into `main` **and** `develop` only, so it is typically NOT configured as a platform-protected branch the way `main`/`develop` are (a ruleset on an ephemeral branch is unusual). Its "no direct push" rule is this agent's own client-side discipline, enforced by `push.sh` refusing a direct push to it — never platform-enforced the way `main`/`develop`'s protection is, unless the project has separately chosen to protect it too.

- Never push directly to `main`, `develop`, or `release/*` — client-side, `push.sh` refuses all three; only `main`/`develop` additionally have platform-side protection.

## Constraints (NEVER violate)
- Never commit directly to a protected branch (`main`/`develop`) — always via a branch + PR/MR (pull request / merge request).
- Never force-push a shared/published branch.
- Never put `#` or spaces in a branch name; write a tracker key in the ticket segment uppercase and everything else lowercase; use only the types listed under Naming; never create a branch without a ticket id, and never invent one; never mix multiple concerns on one branch (bar the refactor exception).
