---
name: procedure-gh-issues
description: The procedure the project-manager runs to create, query, comment on, edit, and close GitHub issues without ever hand-authoring shell. It wraps seven highly-portable, deterministic scripts — scripts/create-issue.sh (OUTWARD WRITE: creates an issue, body ALWAYS via --body-file, optional --project), scripts/find-duplicate.sh (READ-ONLY: idempotency check via gh issue list), scripts/link-children.sh (OUTWARD WRITE: wires child issues under an epic by appending a task-list), scripts/ensure-labels.sh (OUTWARD WRITE: opt-in, idempotent creation of missing PERSISTENT repo labels), scripts/comment.sh (OUTWARD WRITE: adds a comment, body ALWAYS via --body-file), scripts/update-issue.sh (OUTWARD WRITE: edits title/body/labels/assignees/milestone — the body is changed ONLY if --body-file is given, never clobbered otherwise), and scripts/close-issue.sh (OUTWARD WRITE: closes an issue with an optional --comment-file). The whole point of these scripts is eliminating the command-injection sink of `gh issue create --body "$(cat <<'EOF' … EOF)"` — an agent-authored artifact body pulls in real repo content, and a lone line matching the heredoc delimiter terminates it early and executes what follows as shell. Every script here takes any body/comment only as a file path and never builds it in a string/heredoc/$(), and never eval's anything. It does NOT define the artifact's craft/content (standard-backlog-artifacts) or the GitHub-account confirmation gate (procedure-git-auth — a separate, MANDATORY precondition run by the caller before any of these scripts write).
---

# Procedure: GitHub Issues (`gh` wrapper scripts)

The **one** way the `project-manager` talks to `gh` for issue creation, duplicate-checking, epic/child linking, label management, commenting, editing, and closing. This is a **procedure, not a rubric**: call the right script with the right flags; never hand-author a `gh issue create`/`edit`/`comment`/`close` invocation, and never build an issue/comment body in shell.

## Why these scripts exist (read this before calling anything)

The artifacts this agent authors are agent-audience-capable and pull in real repo content (file paths, code snippets, existing issue text). A body built via `--body "$(cat <<'EOF' … EOF)"` is a **command-injection sink**: if any line in that body happens to equal the heredoc's closing delimiter, the heredoc ends early and every line after it is executed as shell — not written into the issue. Renaming the delimiter, quoting it, or switching to `--body-file -` on stdin does **not** fix this; it is inherent to constructing the body in shell at all.

The fix is structural: **any issue/comment body is ALWAYS a file, passed via `--body-file <path>` (or `--comment-file` for close-issue.sh).** The agent `Write`s the drafted content to a file first, then hands the path to these scripts. None of the seven scripts here ever read a body/comment into a shell variable and re-emit it through a heredoc, `eval`, or string interpolation:

- `create-issue.sh` and `comment.sh` refuse a `--body`/`--comment` flag entirely (there isn't one).
- `update-issue.sh` passes `--body-file` **only when the caller explicitly gave one** — omitting it emits NO body-related flag at all, so `gh issue edit` leaves the existing body untouched. There is no code path that reads the current body to "preserve" it; non-clobber is structural, not a preservation step.
- `link-children.sh`, which must *modify* an existing (untrusted) epic body, reads it straight to a temp file and only ever appends caller-validated, non-repo-content lines to that file.
- `close-issue.sh`'s optional closing comment is posted via a **separate `gh issue comment --body-file` call before the close** — never a `gh issue close --comment` string flag — because the rule is "body/comment content is always a file," full stop, regardless of whether a particular string-flag sink would technically be injection-safe.

## The seven scripts (`$HOME/.claude/skills/procedure-gh-issues/scripts/` — all portable & deterministic)

**Invoke each by its deployed absolute path — `$HOME/.claude/skills/procedure-gh-issues/scripts/<name>`.** Never a bare `scripts/<name>` (that resolves against the repo cwd, where the script does not exist), and never `${CLAUDE_SKILL_DIR}/…` from an agent's Bash — that placeholder is substituted only inside a skill's own `SKILL.md` content at invocation, NOT in the shell the calling agent runs, so it will not resolve there. All seven are POSIX `sh`, run on any machine (macOS BSD / Bash 3.2 + Linux), `shellcheck`-clean, self-contained (no external library sourcing), and deterministic.

### `create-issue.sh` — OUTWARD WRITE

```
$HOME/.claude/skills/procedure-gh-issues/scripts/create-issue.sh \
  --repo OWNER/REPO --title "STR" --body-file /path/to/body.md \
  [--label NAME]... [--milestone STR] [--assignee LOGIN]... \
  [--project NAME]... [-h|--help]
```

- **`--body-file` is required; there is no `--body` flag.** The path must exist and be readable, or the script fails with exit `2` before touching `gh` at all.
- **Preconditions checked BEFORE creating anything:** `gh issue create` does not auto-create labels or milestones — an unknown one makes the whole create fail after everything else validated, wasting the round-trip. This script queries the repo's actual labels (`gh api repos/OWNER/REPO/labels`) and milestones (`gh api repos/OWNER/REPO/milestones?state=all`) first and fails with a precise "label(s) not found: X, Y" / "milestone not found: Z" error naming exactly what's missing — **it never auto-creates a label or milestone**; run `ensure-labels.sh` (below) first, or create the milestone manually, or drop the flag.
- **`--project NAME` (repeatable) has NO pre-check** — project lookup is GraphQL (projects-v2), out of scope for this script. An unknown project surfaces as a plain `gh issue create` failure, same as any other gh error.
- On success, prints machine-parseable `PM_ISSUE_NUMBER=<n>` and `PM_ISSUE_URL=<url>` on stdout; all diagnostics go to stderr.
- Exit `0` created · `1` gh absent/unauthenticated/unknown label-or-milestone/gh itself failed · `2` usage error.

### `find-duplicate.sh` — READ-ONLY (the only ungated script)

```
$HOME/.claude/skills/procedure-gh-issues/scripts/find-duplicate.sh --repo OWNER/REPO (--title "STR" | --search "QUERY") [-h|--help]
```

- Runs `gh issue list --search "<title/query> in:title" --state all` and never writes anything — safe to call speculatively before drafting, to steer the "is this really new work" judgment call. **Matches issues whose title CONTAINS the given text — a GitHub search is tokenized/fuzzy, never an exact-string match** — so treat a hit as "worth a human look," not proof of an identical title.
- Prints `PM_DUPLICATE_COUNT=<n>` and `PM_DUPLICATE_URLS=<url[,url...]>` (empty when count is 0).
- Exit `0` on any clean query — **a count of 0 is success, not failure** · `1` gh absent/unauthenticated/the query itself failed · `2` usage error.

### `link-children.sh` — OUTWARD WRITE (kept thin)

```
$HOME/.claude/skills/procedure-gh-issues/scripts/link-children.sh --repo OWNER/REPO --epic N --child N [--child N ...] [-h|--help]
```

- **Mechanism (v1, a deliberate choice):** appends `- [ ] #<child>` lines under a `## Linked children` heading to the epic's body, rather than the GitHub sub-issues REST API. The sub-issue API needs each child's *internal database id* (an extra `gh api` round-trip per child to resolve number → id) and its exact contract could not be exercised against a real repo in this build/test environment (no live `gh`, no real network — see Constraints). The task-list form reuses the same well-understood `gh issue edit --body-file` path this skill already depends on. **This is a documented limitation, not an oversight** — a future version can swap in the sub-issues API behind the same `PM_LINKED` contract without the caller changing.
- **Injection safety, same rule as above:** the epic's *existing* body is untrusted repo content, so it is read straight to a temp file (`gh issue view --json body --jq '.body // ""'` → file) and never assigned to a shell variable. The new checklist lines appended are built *only* from `--child` values already validated as plain positive integers — never from the body just read.
- **Idempotent, regardless of checkbox state, and safe against duplicate arguments:** a child already present — as `- [ ] #N` OR a checked `- [x]`/`- [X] #N` — is detected and skipped, never re-appended or recounted; a child requested more than once in a single run (e.g. `--child 11 --child 11`) is linked at most once. New lines are inserted right after the heading's own last checklist item (not blindly at end-of-file), so a `## Linked children` heading that isn't the last section in the body never gets orphaned new lines below whatever follows it.
- Prints `PM_LINKED=<n>` — the count of **new** links actually appended this run (0 is a valid, successful no-op when every requested child is already linked).
- Exit `0` updated (or already fully linked) · `1` gh/awk absent/unauthenticated/epic not found/the edit itself failed · `2` usage error.

### `ensure-labels.sh` — OUTWARD WRITE, PERSISTENT — extra caution

```
$HOME/.claude/skills/procedure-gh-issues/scripts/ensure-labels.sh \
  --repo OWNER/REPO --label NAME [--label NAME]... \
  [--color HEX] [--description STR] [-h|--help]
```

- **This is THE opt-in "create missing labels" step** — `create-issue.sh`/`update-issue.sh` deliberately never auto-create a label. Run this FIRST, only when the user has explicitly opted in, before a create/update that needs a not-yet-existing label.
- **Creates PERSISTENT, repo-wide, visible state** — a label isn't scoped to one issue; it appears in the repo's label picker for everyone. Treat this with the same caution as any other outward write, not as a harmless side-step of the label pre-check.
- **Idempotent:** every requested label is checked against the repo's actual labels first; an already-existing one is skipped — never re-created, never an error. A label requested more than once (repeated `--label`, a comma-list, or both) is created at most once.
- **Best-effort, not all-or-nothing:** if one `gh label create` call fails (e.g. a bad `--color`), the labels that succeeded before or after it are still created and reported; the script still exits `1` so the caller knows something needs attention.
- Prints `PM_LABELS_CREATED=<name[,name...]>` and `PM_LABELS_EXISTING=<name[,name...]>` (either may be empty).
- Exit `0` every requested label exists · `1` gh absent/unauthenticated/the lookup failed/at least one create call failed · `2` usage error.

### `comment.sh` — OUTWARD WRITE

```
$HOME/.claude/skills/procedure-gh-issues/scripts/comment.sh \
  --repo OWNER/REPO --issue N --body-file /path/to/comment.md [-h|--help]
```

- Same injection-safety rule as `create-issue.sh`: **`--body-file` is required; there is no `--body` flag.**
- Prints `PM_COMMENT_URL=<url>` **if gh returns one** — unlike `create-issue.sh`'s stricter contract, a successful post that returns no URL still exits `0` with this key empty; the URL is a courtesy, gh's own exit code is the proof of success.
- Exit `0` posted · `1` gh absent/unauthenticated/gh itself failed · `2` usage error.

### `update-issue.sh` — OUTWARD WRITE — the non-clobber contract

```
$HOME/.claude/skills/procedure-gh-issues/scripts/update-issue.sh \
  --repo OWNER/REPO --issue N \
  [--title STR] [--body-file PATH] \
  [--add-label NAME]... [--remove-label NAME]... \
  [--add-assignee LOGIN]... [--remove-assignee LOGIN]... \
  [--milestone STR] [-h|--help]
```

- **CRITICAL: the body is changed ONLY if `--body-file` is given.** When it is omitted, this script passes **nothing** body-related to `gh issue edit` — no `--body`, no `--body-file` — so gh leaves the existing body exactly as it was. This is structural (a single guard in the argv-building code that only appends `--body-file` when the caller's value is non-empty), not a "read the old body and put it back" step — there is no code path here that ever reads an issue's current body at all.
- **At least one field flag is required** — a bare `--repo`/`--issue` with nothing to change is a usage error (exit `2`), not a silent no-op.
- **`--add-label` requires the label to already exist** — gh errors otherwise. This script does NOT auto-create one; run `ensure-labels.sh` first if the caller wants that.
- Prints `PM_ISSUE_URL=<url>` on success.
- Exit `0` updated · `1` gh absent/unauthenticated/gh itself failed/it reported success but returned no URL · `2` usage error.

### `close-issue.sh` — OUTWARD WRITE

```
$HOME/.claude/skills/procedure-gh-issues/scripts/close-issue.sh \
  --repo OWNER/REPO --issue N \
  [--reason completed|not_planned] [--comment-file PATH] [-h|--help]
```

- **Mechanism for `--comment-file` (a deliberate choice):** an optional closing comment is posted via a **separate `gh issue comment --body-file` call BEFORE `gh issue close` runs** — never a `gh issue close --comment` string flag. This skill's rule is that body/comment content is ALWAYS a file; reading a file into a shell variable just to hand it to a `--comment "$VALUE"` string flag would still put untrusted content through a shell variable, which the rule forbids regardless of whether that particular flag is technically injection-safe. It also reuses the already-proven-safe `comment.sh` mechanism rather than depend on an unverifiable `gh issue close` comment-file flag (no live `gh` in this build/test environment — see Constraints).
- **`--reason`, if given, is validated against exactly `completed` or `not_planned`** before anything runs; anything else is a usage error (exit `2`). *(These are the two values this procedure validates against; confirm they match the exact strings the `gh` version in use accepts, since that could not be verified against a real `gh` here.)*
- If the comment post fails, the close is **never attempted** — no partial "commented but didn't close" surprise from a script that silently continued past a failure.
- No `PM_*` output key on success beyond the exit code — `gh issue close` doesn't reliably return a URL the way create/edit do, and inventing one wasn't part of this script's contract.
- Exit `0` closed (and the closing comment, if any, was posted first) · `1` gh absent/unauthenticated/the comment post failed/`gh issue close` itself failed · `2` usage error.

## The gates the CALLER (project-manager) must clear before invoking a WRITE

Six of these seven scripts write to a live, notifying, hard-to-retract tracker — everything except `find-duplicate.sh`. **`find-duplicate.sh` is the only read-only, ungated one.** Before calling `create-issue.sh`, `link-children.sh`, `ensure-labels.sh`, `comment.sh`, `update-issue.sh`, or `close-issue.sh`:

1. **Explicit user creation-consent for THIS write** — per the project-manager's own creation gate (see its agent body): drafting is free, writing is not; a relayed "do it" is never sufficient on its own. This applies just as much to a comment, an edit, a close, or a label creation as it does to creating the issue itself.
2. **The `procedure-git-auth` account gate** — run `gh-auth-status.sh`, present the active account, and get the user's confirmation it's the correct login, **before** calling any write script. This skill does **not** perform that check itself (see each script's header comment) — it is a separate, upstream precondition the calling agent owns.

**`ensure-labels.sh` warrants particular care** — a label is repo-wide and persistent (unlike a single issue's field), so its consent should be as explicit as any other outward write, never inferred from "the user wanted the issue created."

## Constraints (NEVER violate)

- Never pass an issue/comment body as a `--body`/`--comment` string, a heredoc, or a `$(...)` — it is ALWAYS a file via `--body-file`/`--comment-file`, full stop, including for a closing comment.
- Never `eval` anything, and never build a `gh` command by string-concatenating untrusted values — arguments are built as POSIX positional parameters (`set -- ...`), the sh equivalent of an array.
- Never auto-create a missing label or milestone from `create-issue.sh`/`update-issue.sh` — report it and stop; `ensure-labels.sh` is the separate, explicit, opt-in step for labels; a missing milestone is never auto-created at all.
- Never call any OUTWARD-WRITE script without both gates above already cleared.
- Never assume `gh` is installed or authenticated — every script checks and fails fast, cleanly, before any precondition query or write.
- Never let `update-issue.sh` touch the body unless `--body-file` was explicitly given — no code path may read-then-rewrite the current body "to be safe."
- Never create a real GitHub issue, label, comment, or edit while developing/testing this skill — the test suite is fully stubbed (`tests/run-tests.sh`) and must stay that way; no real `gh`, no network.

---
*Procedure Version: 2.0 — the GitHub-issue creation/duplicate-check/linking/labeling/commenting/editing/closing wrapper. Bound by the project-manager. The account-confirmation gate is the separate `procedure-git-auth`; artifact craft/content is `standard-backlog-artifacts`. Wraps `$HOME/.claude/skills/procedure-gh-issues/scripts/`create-issue.sh, find-duplicate.sh, link-children.sh, ensure-labels.sh, comment.sh, update-issue.sh, close-issue.sh — all portable POSIX, shellcheck-clean, self-contained.*
