---
name: procedure-inbox-capture
description: The procedure the `gtd-inbox-writer` agent runs to append ONE entry to the user's GTD inbox log without ever hand-authoring the write. It wraps a single highly-portable, deterministic POSIX-sh script — scripts/capture.sh (APPEND: stamps id/ts, sets is_processed=false and note=null, optionally records the capturing session's session_id when --session-id is given, builds the schema-shaped line via a static jq program, and appends it under a shared on-disk lock). The captured text is ALWAYS supplied as a FILE via --text-file — never a string, heredoc, or $(...) — which is the command-injection boundary (identical in spirit to procedure-gh-issues' --body-file rule): the caller materializes the verbatim bytes to a temp file and hands the script only the path, so untrusted user prose never enters a shell command. It does NOT own triage, listing, processing, or purging the inbox (those are the main thread's flow-inbox skill, which keeps list.sh/process.sh/purge-processed.sh), nor the entry wire-shape (gtd/contracts/inbox-entry.schema.json), nor the agent's own safety conduct (the gtd-inbox-writer agent body). Bound by the gtd-inbox-writer agent.
---

# Procedure: Inbox Capture (`capture.sh` wrapper)

The **one** way the `gtd-inbox-writer` agent appends to the GTD inbox log. This is a **procedure,
not a rubric**: call the script with the right flags; never hand-author a write and never build the
log line in shell.

## The script (`$HOME/.claude/skills/procedure-inbox-capture/scripts/capture.sh`)

**Invoke it by its deployed absolute path — `$HOME/.claude/skills/procedure-inbox-capture/scripts/capture.sh`.**
Never a bare `scripts/capture.sh` (it resolves against the caller's cwd, where the script isn't),
and never `${CLAUDE_SKILL_DIR}/…` from a Bash shell (that placeholder is substituted only inside a
skill's own `SKILL.md`, not in the shell the agent runs). POSIX `sh`, runs on macOS (BSD / Bash 3.2)
and Linux, `shellcheck`-clean, self-contained. `jq` is the sole JSON tool. The log defaults to
`$HOME/.claude/crucible/gtd/inbox.jsonl` (override with `INBOX_FILE` for tests only).

```
$HOME/.claude/skills/procedure-inbox-capture/scripts/capture.sh --text-file /path/to/text [--project NAME] [--session-id ID]
```

- **`--text-file <path>` is REQUIRED; there is no `--text` flag.** The captured prose is always a
  file. The caller (the main thread) `Write`s the verbatim text to a temp file *outside any repo*
  and hands the agent the **path**; the agent passes it straight to `--text-file`. This is the
  injection boundary — untrusted bytes never touch a shell command line, exactly as
  `procedure-gh-issues` keeps a body out of shell via `--body-file`.
- **`--project NAME`** is passed **explicitly by the caller** (derived from the USER's cwd). The
  script has a cwd-basename fallback, but the agent must NOT rely on it — the agent runs in its own
  cwd, never the user's repo — so `--project` is always supplied (or deliberately omitted when the
  caller says there is no project). Pass it single-quoted, as one opaque token.
- **`--session-id ID`** is OPTIONAL, passed **explicitly by the caller** (the capturing Claude Code
  session's UUID, derived from the caller's own session/scratchpad path). When given, the script
  records a `session_id` field (via `--arg`); when absent it OMITS the key entirely (never a null),
  so pre-enrichment records stay shape-identical. Pass it single-quoted; never invent one.
- **What the script does:** stamps `id` (time-prefixed + random suffix) and `ts` from one UTC clock
  read, sets `is_processed=false` and `note=null` (and includes `session_id` only when
  `--session-id` was given), builds the schema-shaped line with a **static jq program** (every value
  via `--arg`/`--argjson`/`--rawfile`, never concatenated — the `session_id` field is added by a
  static conditional merge, not string concatenation), and appends one line **under the shared
  `.inbox.lock`**. It is the SOLE writer of the log for this operation.
- **Output:** prints `INBOX_ID=<id>` on stdout (machine-clean); diagnostics on stderr.
- **Exit codes:** `0` captured · `1` `jq`/`/dev/urandom` missing or the write failed · `2` usage
  (missing/empty `--text-file`, bad argument).

## The shared lock (why this script coordinates with a skill it doesn't live in)

`capture.sh` takes the same `mkdir`-based `.inbox.lock` (in the log's own dir) that `flow-inbox`'s
`process.sh` / `purge-processed.sh` take. The lock is a **runtime on-disk path** derived from
`INBOX_FILE`, independent of which skill dir a script lives in — so a background capture never races
a triage rewrite even though capture and the rewriters now live in **two different skills**.
`capture.sh`'s `acquire_lock` helper is byte-identical to the copies in `flow-inbox`'s `process.sh`
and `purge-processed.sh` (the three writers that take the lock); a change to it must be mirrored
across all three — a duplication that now **spans two skills**, so it is easier to miss.
(`capture.sh` has NO `is_valid_json_object`: that reader-side validator lives only in the log-reading
scripts `list.sh`/`process.sh`/`purge-processed.sh` — the appender never reads existing lines.) This
byte-identical self-containment is the framework norm — `procedure-git-ops` states the same.

## Testing

`tests/run-tests.sh` is a fully-stubbed suite — it runs against an isolated `INBOX_FILE` (its own
`mktemp` dir) and **must never touch the real log** at `$HOME/.claude/crucible/gtd/inbox.jsonl`. It
covers usage/argument errors, `jq`-absent, the schema-shaped line, verbatim/injection preservation,
project derivation, the capture-side lock (held-lock + stale-reclaim), and the `700`/`600` perms.
Keep it stubbed; never add a case that writes to the real inbox.

## Constraints (NEVER violate)
- **Text travels only as a file** — always `--text-file <path>`; never a `--text` string, a heredoc,
  or `$(...)`, and never build the log line in shell. (The script has no `--text` flag by design.)
- **Never write the log line yourself** — always through `capture.sh`; never `echo >>` the log, never
  hand-build the JSON.
- **Always pass `--project` explicitly** (single-quoted); never rely on the script's cwd fallback
  from the agent's cwd. Omit it only when the caller said there is no project.
- **Pass `--session-id` through verbatim** (single-quoted) when the caller supplies one; omit it
  only when none was given, and never invent or derive one in the agent.
- **Report only what the script returned** — the real `INBOX_ID`, never an invented one; on a
  non-zero exit, report the failure rather than pretending success.

---
*Procedure Version: 1.0 — the GTD inbox APPEND wrapper, colocated with its owner the `gtd-inbox-writer` agent. Wraps `$HOME/.claude/skills/procedure-inbox-capture/scripts/capture.sh` (portable POSIX sh, shellcheck-clean, self-contained). The entry wire-shape is `gtd/contracts/inbox-entry.schema.json`; triage/list/process/purge belong to the main thread's `flow-inbox` skill; the agent's safety conduct lives in the `gtd-inbox-writer` agent body.*
