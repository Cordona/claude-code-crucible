---
name: procedure-gh-pr
description: The procedure the git-operator runs to find, open, and edit GitHub pull requests via deterministic scripts, never a hand-authored `gh pr` command or a shell-built PR body. Before any create/update write, the caller must already hold explicit user write-consent and have cleared the `procedure-github-auth` account gate — not performed here. It does NOT define PR body/title craft or content (`standard-git-pr`); its GitLab merge-request counterpart is `procedure-glab-mr`.
---

# Procedure: GitHub Pull Requests (`gh` wrapper scripts)

The **one** way the `git-operator` talks to `gh` for PR discovery, creation, and editing. This is a **procedure, not a rubric**: call the right script with the right flags; never hand-author a `gh pr create`/`gh pr edit` invocation, and never build a PR body in shell. Sibling to `procedure-gh-issues` — same conventions, same injection-safety rule, same test-harness style (it lives in a different domain now, but the mechanics it mirrors are identical). **`procedure-glab-mr` is this skill's true backend twin** — the same three operations (find/create/update) on GitLab merge requests instead of GitHub pull requests, same injection-safety RULE, a different MECHANISM where `glab` lacks a flag `gh` has (no `--description-file`; see that skill's own header for why).

## Why this exists (read this before calling anything)

A PR body built via `--body "$(cat <<'EOF' … EOF)"` is the same **command-injection sink** `procedure-gh-issues` exists to eliminate: a PR body commonly pulls in real repo content (a diff summary, commit messages, linked issue text), and a lone line matching the heredoc's closing delimiter ends it early and executes what follows as shell. The fix is the same structural one: **the PR body is ALWAYS a file, passed via `--body-file <path>`.** The agent `Write`s the drafted body to a file first, then hands the path to `create-pr.sh`/`update-pr.sh` — neither script has a `--body` flag at all.

**The PR title is different and is NOT subject to this rule** — it travels as a single argv token (`--title "$OPT_TITLE"`), which is safe because it is never built via a heredoc, `eval`, or string interpolation; it is simply one caller-supplied value passed straight into the array-built `gh` command, the same way `create-issue.sh`'s `--title` already works.

## The three scripts (`$HOME/.claude/skills/procedure-gh-pr/scripts/` — all portable & deterministic)

**Invoke each by its deployed absolute path — `$HOME/.claude/skills/procedure-gh-pr/scripts/<name>`.** Never a bare `scripts/<name>` (that resolves against the repo cwd, where the script does not exist), and never `${CLAUDE_SKILL_DIR}/…` from an agent's Bash — that placeholder is substituted only inside a skill's own `SKILL.md` content at invocation, NOT in the shell the calling agent runs, so it will not resolve there. All three are POSIX `sh`, run on any machine (macOS BSD / Bash 3.2 + Linux), `shellcheck`-clean, and deterministic.

### The shared library (`lib/gh-pr-common.sh`)

All three scripts **source one skill-local library**, `lib/gh-pr-common.sh`, resolved from the script's own `$0` by shell parameter expansion (never `dirname`/`readlink`/`realpath`, none of which may be assumed present). It holds what all three genuinely share: the `LC_ALL`/`PROG` pins and `warn`/`error`, `need_arg`, `is_valid_repo_slug`, `is_positive_int`, `split_csv_list`/`accumulate`, the `gh`/`awk`/auth preconditions, `init_tmp_err`, and `emit_captured_stderr`. Each script keeps its own `usage()` and — necessarily — its own `gh` argv builder: a `set --` inside a function rebinds only that function's positional parameters, so building a command's argv cannot be centralized even in principle.

**This is the ONE library, and its scope is exactly this skill.** Nothing here sources `procedure-gh-issues`, and nothing here sources **`procedure-glab-mr`** — even though `warn`/`error`/`need_arg`/`is_positive_int`/`split_csv_list` are byte-identical to that skill's copies. The two skills deploy to the hub **independently**, so a cross-skill source would resolve to a path that may simply not be there, and it would fail at *runtime*, invisibly, on the first real PR operation. Those helpers are **duplicated on purpose**; when you change one, change both. `is_valid_repo_slug` is a different case again — it is deliberately **not** the same validator as `procedure-glab-mr`'s `is_valid_gitlab_project_path` (this one hard-rejects a second `/`; that one must accept arbitrary subgroup depth), so the two must **never** be unified behind one parameterized helper.

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

## The gates the CALLER (the orchestrator — git-operator only plans) must clear before invoking a WRITE

`create-pr.sh` and `update-pr.sh` write to a live, notifying, hard-to-retract tracker. **`find-pr.sh` is the only read-only, ungated script.** Before calling either write script:

1. **Explicit user creation-consent for THIS write** — per the git-operator's own commit-plan-style gate (see its agent body, and `flow-git-operations`): drafting/planning is free, writing is not; a relayed "open it"/"update it" is never sufficient on its own.
2. **The `procedure-github-auth` account gate** — run `gh-auth-status.sh`, present the active account, and get the user's confirmation it's the correct login, **before** calling `create-pr.sh` or `update-pr.sh`. This skill does **not** perform that check itself (see each script's header comment) — it is a separate, upstream precondition the calling agent owns.

## Constraints (NEVER violate)

- Never pass a PR body as a `--body` string, a heredoc, or a `$(...)` — it is ALWAYS a file via `--body-file`, full stop. The title is the one exception (a plain argv token), never the body.
- Never `eval` anything, and never build a `gh` command by string-concatenating untrusted values — arguments are built as POSIX positional parameters (`set -- ...`), the sh equivalent of an array.
- Never let `create-pr.sh` open a PR without first checking for an existing open PR on the same head — the pre-check is not optional and cannot be skipped by a flag.
- Never let `update-pr.sh` touch the body unless `--body-file` was explicitly given — no code path may read-then-rewrite the current body "to be safe."
- Never call `create-pr.sh` or `update-pr.sh` without both gates above already cleared.
- Never assume `gh` is installed or authenticated — every script checks and fails fast, cleanly, before any precondition query or write.
- Never create a real GitHub PR or edit while developing/testing this skill — the test suite is fully stubbed (`tests/run-tests.sh`) and must stay that way; no real `gh`, no network.

---
*Procedure Version: 1.3 — the GitHub-PR discovery/creation/editing wrapper. Bound by the git-operator (moved from the project-manager — PR work requires reading the diff, which is development work, not backlog authoring). The account-confirmation gate is the separate `procedure-github-auth`; artifact craft/content is `standard-git-pr`. Sibling to `procedure-gh-issues` (same conventions, different domain). **GitLab backend twin: `procedure-glab-mr`** (same three operations on merge requests; account gate `procedure-gitlab-auth`). Wraps `$HOME/.claude/skills/procedure-gh-pr/scripts/`find-pr.sh, create-pr.sh, update-pr.sh — all portable POSIX and shellcheck-clean, over one skill-local `lib/gh-pr-common.sh`. **1.2 adds the reciprocal GitLab-twin pointer**, closing a one-directional gap where `procedure-glab-mr` already pointed back here but this file never pointed forward. **1.3 decomposes the three script monoliths onto that shared lib** — behavior-identical, verified by the unchanged test suite plus new repeated-flag / CSV-trim / glob / `--pr 0`-`007` / triple-segment-slug coverage — and corrects this file's former "self-contained (no external library sourcing)" claim, which the split made false.*
