---
name: standard-git-pr
description: The single definition of a good PULL REQUEST — the shared rubric the project-manager follows when opening or updating a PR. Applies whenever a PR is created, described, reviewed, or merged. Covers PR-only landing (no direct pushes), one-concern/small PRs, the PR description template, a Conventional-Commit PR title, issue linking, self-review, required approvals, the merge strategy (rebase-merge to preserve atomic signed commits), draft PRs, stacked PRs, and CODEOWNERS/templates. It does NOT define commit format (standard-git-commit), branch naming (standard-git-branch), or tags (standard-git-tag).
---

# Standard: Git Pull Request

The **one** definition of a good PR. A PR is the **review gate** — every change to a protected branch lands through one.

## Core rules

- **Never push unless the user explicitly requested and authorized THIS push.** A push is public and hard to retract; branch protection governs *where* a push may land, never *whether* you may push. No explicit request → no push.
- **Land via PR.** No direct pushes to `main`/`develop` (enforced by branch protection — see `standard-git-branch`).
- **One concern, small.** A PR mirrors its branch: one feature/fix/refactor, small enough to review in one sitting. A 3-file/100-line PR gets a real review; a 15-file/800-line PR gets a rubber stamp. Decompose large work into a **stack** of small, dependent PRs rather than one mega-PR.
- **PR title is a valid Conventional Commit** — `feat(auth): add token refresh`. With rebase-merge the individual commits keep their own messages; the title still sets the PR's intent and feeds any changelog tooling.

## Description — use the template

Commit `.github/PULL_REQUEST_TEMPLATE.md` so every PR is prompted for:
- **What** — the change in one or two lines.
- **Why** — motivation / context / the issue it addresses.
- **How to test** — concrete steps a reviewer runs.
- **Screenshots** — for any UI change.
- **Linked issue** — `Closes #<ticket>` (auto-closes on merge; ties to the ticket already in the branch name).

## Author discipline

- **Self-review first** — read your own diff, and confirm the build + tests pass, *before* requesting review. Catch the embarrassing stuff yourself.
- **Draft PRs for work-in-progress** — open a draft for early CI/visibility; mark **ready for review** only once self-reviewed.
- **Keep it rebased** — rebase onto the base branch to stay current and conflict-free.

## Review & merge

- **Required approvals** — ≥ 1 review + green CI before merge (a solo repo may set 0 approvals but still self-reviews). **CODEOWNERS** (`.github/CODEOWNERS`) routes the right reviewers and can *require* code-owner approval.
- **Merge strategy: rebase-merge (this project's choice).** It **preserves the curated, individually-signed atomic commits** and their messages onto the base — consistent with the commit standard's atomicity + signing discipline. Each commit must therefore be a valid Conventional Commit.
  - *Why not squash:* squash collapses the atomic commits into one re-created commit, discarding the per-commit history **and** their signatures — throwing away exactly the work `standard-git-commit` invests in.
  - *Why not a merge commit:* it preserves history but adds non-linear merge nodes; rebase keeps history linear (pairs with the "require linear history" protection rule).

## GitHub execution (the `gh` mechanics)

- **Correct base — always explicit.** `gh pr create` defaults the base to the repo's default branch (`main`), which is **wrong under Git Flow**. Always pass `--base` derived from the branch type: `feature/*` → `develop`; `release/*`, `hotfix/*` → `main` (then a second PR into `develop`).
- **Update, don't duplicate.** Before creating, check `gh pr list --head <branch>`; if a PR already exists for the branch, push to update it (or `gh pr edit`) — `gh pr create` errors on an existing PR.
- **Auth first.** Confirm the correct GitHub account before any `gh` operation (see `procedure-git-auth`); `gh auth status` fails fast if unauthenticated.
- **Handle a protected-branch rejection** — recognize it and route via a branch + PR; never retry or force.

## Constraints (NEVER violate)
- Never merge without the required approval(s) + passing checks.
- Never request review before self-reviewing and confirming the build.
- Never open a mixed-bag PR that should be split; never a PR title that isn't a valid Conventional Commit.
- Never squash away signed atomic commits (this project rebase-merges).

---
*Standard Version: 1.0 — the shared PR rubric. Followed by the project-manager. Merge policy: rebase-merge (preserves atomic signed commits). Commit format lives in standard-git-commit; branches in standard-git-branch; tags in standard-git-tag.*
