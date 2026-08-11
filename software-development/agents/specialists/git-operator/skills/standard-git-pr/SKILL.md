---
name: standard-git-pr
description: The single rubric for an excellent pull-request (GitHub) or merge-request (GitLab) body/title. Bind whenever a PR/MR is opened or its body/title is edited, to write or judge that content. Does NOT define PR mechanics (procedure-gh-pr), MR mechanics (procedure-glab-mr), either account gate (procedure-github-auth / procedure-gitlab-auth), or backlog-artifact craft (that's the project-manager's standard-backlog-artifacts, not this).
---

# Standard: Git PR/MR Bodies

The **one** definition of an excellent pull-request (GitHub) or merge-request (GitLab) body. The `git-operator` builds every PR and every MR to it — the same rubric, no backend-specific variant. A PR/MR body's job is to help a reviewer *review* — not to restate the diff, and not to perform the audience-tuning a backlog artifact needs (a PR/MR's audience is fixed).

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
*Standard Version: 1.1 — split out of `standard-backlog-artifacts`' former "Pull request bodies" section when the PR lifecycle moved from the project-manager to the git-operator (PR work requires reading the diff, which is development work). Sibling to `standard-git-commit` / `standard-git-branch` / `standard-git-tag`. Mechanics live in `procedure-gh-pr` (GitHub) / `procedure-glab-mr` (GitLab). **1.1 makes the backend-agnostic scope explicit** — this rubric already applied unchanged to the GitLab MR work built alongside it; the frontmatter and body now say so rather than reading as GitHub-only by omission.*
