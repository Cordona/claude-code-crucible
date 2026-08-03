---
name: standard-git-branch
description: The single definition of a good git BRANCH and the branching workflow — the shared rubric the git-operator follows when creating or managing branches. Applies whenever a branch is created, named, kept current, or protected. Covers the Git Flow workflow (main/develop/feature/release/hotfix), branch naming (type/ticket-desc, lowercase-kebab, shell/URL-safe), one-concern-per-branch, branch hygiene (short-lived, rebased onto base, deleted after merge), and branch protection. It does NOT define commit format (standard-git-commit) or tags (standard-git-tag).
---

# Standard: Git Branch

The **one** definition of a good branch. A branch is a **short-lived, single-purpose** line of work, named so a human (and tooling) knows what it holds.

## Workflow — Git Flow

This project uses **Git Flow**. Two long-lived branches, three supporting types:

| Branch | Lifetime | Branches FROM | Merges INTO |
|--------|----------|---------------|-------------|
| `main` (`master`) | permanent — always production-ready | — | — |
| `develop` | permanent — integration | — | — |
| `feature/*` | short | `develop` | `develop` |
| `release/*` | short | `develop` | `main` **and** `develop` |
| `hotfix/*` | short | `main` | `main` **and** `develop` |

> **Deliberate-choice note:** Git Flow suits software that ships **versioned releases with multiple supported versions** (SDKs, installed/on-prem, mobile store cadence). For a continuously-delivered single-version app, a simpler trunk-based / GitHub-Flow model is often better — Git Flow's own author now advises CD teams toward it. This standard commits to Git Flow by project choice; if the delivery model is pure CD, revisit that choice rather than shoehorning it.

## Naming

`<type>/<ticket>-<kebab-description>` — e.g. `feat/1-token-refresh`, `fix/PROJ-42-null-session`, `hotfix/urgent-cert-rotation`.

- **`type/` prefix** mirrors the commit types: `feat` · `fix` · `refactor` · `perf` · `docs` · `chore` · `hotfix` · `release`.
- **Ticket id recommended** — place it right after the prefix. **Do NOT use `#`** (`feat/#1-…` breaks: `#` truncates in shells and must be percent-encoded in URLs). Use the bare number or key: `feat/1-…`, `feat/PROJ-1-…`.
- **lowercase, kebab-case, alphanumerics + hyphens only** — no spaces, underscores, or punctuation; replace any special char with a hyphen. Avoid `..` and a trailing `.lock` (git-reserved).
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

`main` and `develop` are **protected** via a repository ruleset:
- Require a **pull request** before merging (no direct pushes).
- Require **signed commits** and **linear history**.
- Require **passing status checks** (commitlint + build/test) and **≥ 1 review**.
- **Block force-pushes** and branch deletion.

Client-side branch discipline is advisory; the ruleset is what makes it an invariant.

## Constraints (NEVER violate)
- Never commit directly to a protected branch (`main`/`develop`) — always via a branch + PR.
- Never force-push a shared/published branch.
- Never put `#`, spaces, or uppercase in a branch name; never mix multiple concerns on one branch (bar the refactor exception).

---
*Standard Version: 1.0 — the shared branch rubric. Followed by the git-operator. Workflow: Git Flow (by project choice). Commit format lives in standard-git-commit; tags in standard-git-tag.*
