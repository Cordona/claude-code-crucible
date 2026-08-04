---
name: standard-git-pr
description: The single definition of an EXCELLENT pull-request body — the shared rubric the git-operator BUILDS to. Applies whenever a PR is opened or its body/title is edited. A PR body has a FIXED audience (technical-human reviewers; agents read it fine too), so unlike a backlog artifact it never takes an audience question. Defines the required shape (What / Why / How-to-test / risk / linked issue), the title convention (Conventional-Commit-style), and the anti-pattern list. Sibling to standard-git-commit/-branch/-tag — this is the git-operator's own PR-craft rubric, not the project-manager's. It does NOT define the PR mechanics (procedure-gh-pr) or the GitHub-account confirmation gate (procedure-git-auth).
---

# Standard: Git PR Bodies

The **one** definition of an excellent pull-request body. The `git-operator` builds every PR to it. A PR body's job is to help a reviewer *review* — not to restate the diff, and not to perform the audience-tuning a backlog artifact needs (a PR's audience is fixed).

## Shape (What / Why / How-to-test / risk / link)

- **Lead with What · Why · How-to-test** — what changed (the outcome, not a commit list), why it was needed, and exactly how a reviewer verifies it.
- **Point at the risk** — name the files/areas that most deserve scrutiny, and any decision or trade-off a reviewer should sanity-check.
- **Link the work** — `Closes #<n>` (or `Refs #<n>`), so the PR and its issue connect.
- **Concise and scannable** — a reviewer skims; front-load, short sections, don't restate the diff.

## Title

A **Conventional-Commit-style** one-liner (`type(scope): summary`), matching the commit convention `standard-git-commit` defines.

## Leave out (the anti-pattern catalogue)

A diff-shaped body (a per-file changelog instead of an outcome) · no test/verification instructions · no linked issue when one exists · risk buried or omitted · restating the title in the body with no added information · scope creep the PR itself doesn't actually contain.

## Excellence checklist (self-check before proposing)

- [ ] Title is Conventional-Commit-style and matches what actually changed
- [ ] Body leads with What/Why, not a file list
- [ ] How-to-test is concrete enough for a reviewer to actually run it
- [ ] Risk areas are named, not left for the reviewer to discover
- [ ] The issue is linked (`Closes`/`Refs`) when one exists

## Constraints (NEVER violate)

- Never ship a diff-shaped body (a per-file changelog) in place of an outcome-framed What/Why.
- Never omit How-to-test or the risk callout — a reviewer without either is reviewing blind.
- Never restate the title in the body with no added information.
- Never claim scope the PR itself doesn't actually contain.

---
*Standard Version: 1.0 — split out of `standard-backlog-artifacts`' former "Pull request bodies" section when the PR lifecycle moved from the project-manager to the git-operator (PR work requires reading the diff, which is development work). Sibling to `standard-git-commit` / `standard-git-branch` / `standard-git-tag`. Mechanics live in `procedure-gh-pr`.*
