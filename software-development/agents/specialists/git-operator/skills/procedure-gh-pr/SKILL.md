---
name: procedure-gh-pr
description: The procedure the git-operator runs to find, open, and edit GitHub pull requests without ever hand-authoring shell. It wraps three highly-portable, deterministic scripts — scripts/find-pr.sh (READ-ONLY: is there already an open PR for this head branch?), scripts/create-pr.sh (OUTWARD WRITE: opens a PR, body ALWAYS via --body-file, and refuses to create a duplicate — it runs the same open-PR check first and fails rather than opening a second PR for the same head), and scripts/update-pr.sh (OUTWARD WRITE: edits title/body/base/labels/reviewers — the body is changed ONLY if --body-file is given, never clobbered otherwise, mirroring update-issue.sh's non-clobber mechanism exactly). Same injection-safety rule as procedure-gh-issues: any PR body is ALWAYS a file, never built in a string/heredoc/$(), and no script here ever eval's anything — the PR TITLE, by contrast, is safe to pass as a plain `--title "$VALUE"` argv token because it is never shell-constructed either. It does NOT define the artifact's craft/content (standard-git-pr) or the GitHub-account confirmation gate (procedure-git-auth — a separate, MANDATORY precondition run by the caller before any of these scripts write).
---

# Procedure: GitHub Pull Requests (`gh` wrapper scripts)

The **one** way the `git-operator` talks to `gh` for PR discovery, creation, and editing. This is a **procedure, not a rubric**: call the right script with the right flags; never hand-author a `gh pr create`/`gh pr edit` invocation, and never build a PR body in shell. Sibling to `procedure-gh-issues` — same conventions, same injection-safety rule, same test-harness style (it lives in a different domain now, but the mechanics it mirrors are identical).

## Why this exists (read this before calling anything)

A PR body built via `--body "$(cat <<'EOF' … EOF)"` is the same **command-injection sink** `procedure-gh-issues` exists to eliminate: a PR body commonly pulls in real repo content (a diff summary, commit messages, linked issue text), and a lone line matching the heredoc's closing delimiter ends it early and executes what follows as shell. The fix is the same structural one: **the PR body is ALWAYS a file, passed via `--body-file <path>`.** The agent `Write`s the drafted body to a file first, then hands the path to `create-pr.sh`/`update-pr.sh` — neither script has a `--body` flag at all.

**The PR title is different and is NOT subject to this rule** — it travels as a single argv token (`--title "$OPT_TITLE"`), which is safe because it is never built via a heredoc, `eval`, or string interpolation; it is simply one caller-supplied value passed straight into the array-built `gh` command, the same way `create-issue.sh`'s `--title` already works.

## The three scripts (`$HOME/.claude/skills/procedure-gh-pr/scripts/` — all portable & deterministic)

**Invoke each by its deployed absolute path — `$HOME/.claude/skills/procedure-gh-pr/scripts/<name>`.** Never a bare `scripts/<name>` (that resolves against the repo cwd, where the script does not exist), and never `${CLAUDE_SKILL_DIR}/…` from an agent's Bash — that placeholder is substituted only inside a skill's own `SKILL.md` content at invocation, NOT in the shell the calling agent runs, so it will not resolve there. All three are POSIX `sh`, run on any machine (macOS BSD / Bash 3.2 + Linux), `shellcheck`-clean, self-contained (no external library sourcing, no sourcing of `procedure-gh-issues` either — small helpers like `is_valid_repo_slug` are duplicated, not shared), and deterministic.

### `find-pr.sh` — READ-ONLY (the only ungated script)

```
$HOME/.claude/skills/procedure-gh-pr/scripts/find-pr.sh --repo OWNER/REPO --head BRANCH [-h|--help]
```

- Runs `gh pr list --repo OWNER/REPO --head BRANCH --state open --json number,url --jq …` and never writes anything. **`--head` takes a PLAIN branch name — `gh pr list --head` does NOT support `owner:branch` fork syntax.**
- Prints `PM_PR_COUNT=<n>` always; `PM_PR_NUMBER=<n>` and `PM_PR_URL=<url>` **only when the count is exactly 1** — an ambiguous multi-match or a zero-match never fabricates a number/URL.
- Exit `0` on any clean query — **a count of 0 is success, not failure** · `1` gh/awk absent/unauthenticated/the query itself failed · `2` usage error.

### `create-pr.sh` — OUTWARD WRITE, refuses to duplicate

```
$HOME/.claude/skills/procedure-gh-pr/scripts/create-pr.sh \
  --repo OWNER/REPO --head BRANCH --base BRANCH --title "STR" --body-file /path/to/body.md \
  [--draft] [--reviewer LOGIN]... [--label NAME]... [--assignee LOGIN]... [-h|--help]
```

- **`--body-file` is required; there is no `--body` flag.** `--title` is a plain argv token — see "Why this exists" above for why that's safe.
- **Idempotency pre-check, before anything is created:** runs the exact same `gh pr list --head … --state open` query `find-pr.sh` runs. If an open PR already exists for `--head`, this **fails (exit 1)** naming the existing PR's URL and pointing at `update-pr.sh` — it never opens a duplicate. This is the PR analogue of `link-children.sh`'s duplicate-`--child` guard and `create-issue.sh`'s general "don't silently duplicate work" posture.
- **`--label` is NOT pre-checked for existence** (unlike `create-issue.sh`) — an unknown label surfaces as a plain `gh pr create` failure. There is no PR equivalent of `ensure-labels.sh` in this skill; if the caller needs a missing label created, that is still `procedure-gh-issues`' `ensure-labels.sh` (labels are repo-wide, not issue- or PR-scoped).
- On success, prints `PM_PR_NUMBER=<n>` (parsed from the URL; a warn-not-fail if unparseable, same as `create-issue.sh`) and `PM_PR_URL=<url>`.
- Exit `0` created · `1` gh/awk absent/unauthenticated/an open PR already exists for `--head`/the pre-check query itself failed/`gh pr create` itself failed · `2` usage error.

### `update-pr.sh` — OUTWARD WRITE — the non-clobber contract

```
$HOME/.claude/skills/procedure-gh-pr/scripts/update-pr.sh \
  --repo OWNER/REPO --pr N \
  [--title STR] [--body-file PATH] [--base BRANCH] \
  [--add-label NAME]... [--remove-label NAME]... \
  [--add-reviewer LOGIN]... [--remove-reviewer LOGIN]... [-h|--help]
```

- **CRITICAL: the body is changed ONLY if `--body-file` is given** — mirrors `update-issue.sh`'s non-clobber mechanism exactly. When `--body-file` is omitted, this script passes **nothing** body-related to `gh pr edit`; there is no code path here that ever reads a PR's current body at all, so there is nothing to accidentally overwrite. This is structural (one guard in the argv-building code), not a "fetch and put back" step.
- **At least one field flag is required** — a bare `--repo`/`--pr` with nothing to change is a usage error (exit `2`), not a silent no-op.
- **`--add-label` is NOT pre-checked for existence** — gh errors on an unknown one; same posture as `create-pr.sh`.
- Prints `PM_PR_URL=<url>` **if gh returns one** — same soft "courtesy, not proof of success" contract as `comment.sh` in `procedure-gh-issues`: a successful edit that returns no URL still exits `0` with this key empty.
- Exit `0` updated · `1` gh absent/unauthenticated/`gh pr edit` itself failed · `2` usage error.

## The gates the CALLER (git-operator) must clear before invoking a WRITE

`create-pr.sh` and `update-pr.sh` write to a live, notifying, hard-to-retract tracker. **`find-pr.sh` is the only read-only, ungated script.** Before calling either write script:

1. **Explicit user creation-consent for THIS write** — per the git-operator's own commit-plan-style gate (see its agent body, and `flow-git-operations`): drafting/planning is free, writing is not; a relayed "open it"/"update it" is never sufficient on its own.
2. **The `procedure-git-auth` account gate** — run `gh-auth-status.sh`, present the active account, and get the user's confirmation it's the correct login, **before** calling `create-pr.sh` or `update-pr.sh`. This skill does **not** perform that check itself (see each script's header comment) — it is a separate, upstream precondition the calling agent owns.

## Constraints (NEVER violate)

- Never pass a PR body as a `--body` string, a heredoc, or a `$(...)` — it is ALWAYS a file via `--body-file`, full stop. The title is the one exception (a plain argv token), never the body.
- Never `eval` anything, and never build a `gh` command by string-concatenating untrusted values — arguments are built as POSIX positional parameters (`set -- ...`), the sh equivalent of an array.
- Never let `create-pr.sh` open a PR without first checking for an existing open PR on the same head — the pre-check is not optional and cannot be skipped by a flag.
- Never let `update-pr.sh` touch the body unless `--body-file` was explicitly given — no code path may read-then-rewrite the current body "to be safe."
- Never call `create-pr.sh` or `update-pr.sh` without both gates above already cleared.
- Never assume `gh` is installed or authenticated — every script checks and fails fast, cleanly, before any precondition query or write.
- Never create a real GitHub PR or edit while developing/testing this skill — the test suite is fully stubbed (`tests/run-tests.sh`) and must stay that way; no real `gh`, no network.

---
*Procedure Version: 1.1 — the GitHub-PR discovery/creation/editing wrapper. Bound by the git-operator (moved from the project-manager — PR work requires reading the diff, which is development work, not backlog authoring). The account-confirmation gate is the separate `procedure-git-auth`; artifact craft/content is `standard-git-pr`. Sibling to `procedure-gh-issues` (same conventions, different domain). Wraps `$HOME/.claude/skills/procedure-gh-pr/scripts/`find-pr.sh, create-pr.sh, update-pr.sh — all portable POSIX, shellcheck-clean, self-contained.*
