---
name: procedure-inbox-capture
description: The procedure the `gtd-inbox-writer` agent runs to append ONE entry to the GTD (Getting Things Done) inbox log, via a deterministic `capture.sh` wrapper that takes the captured text only as a file path (never a string/heredoc) to keep untrusted prose out of the shell. It does NOT own triage, listing, processing, or purging the inbox (the main thread's `flow-inbox` skill), the entry wire-shape (the inbox-entry schema, `gtd/contracts/inbox-entry.schema.json`), or the agent's own safety conduct (`gtd-inbox-writer.md`'s own body).
---

# Procedure: Inbox Capture (`capture.sh` wrapper)

The **one** way the `gtd-inbox-writer` agent appends to the GTD (Getting Things Done) inbox log.
This is a **procedure, not a rubric**: call the script with the right flags; never hand-author a
write and never build the log line in shell. This skill owns the `capture.sh` wrapper only — the
entry wire-shape it writes to is `gtd/contracts/inbox-entry.schema.json`'s own territory, not
restated here, and the agent's own conduct/safety rules (what it may read, when it may act) live in
`gtd-inbox-writer.md`'s own body, not here.

## The script (`$HOME/.claude/skills/procedure-inbox-capture/scripts/capture.sh`)

**Invoke it by its deployed absolute path — `$HOME/.claude/skills/procedure-inbox-capture/scripts/capture.sh`.**
Never a bare `scripts/capture.sh` (it resolves against the caller's cwd, where the script isn't),
and never `${CLAUDE_SKILL_DIR}/…` from a Bash shell (that placeholder is substituted only inside a
skill's own `SKILL.md`, not in the shell the agent runs). POSIX (Portable Operating System Interface) `sh`, runs on macOS (BSD, Berkeley Software Distribution / Bash 3.2)
and Linux, `shellcheck`-clean, self-contained. `jq` is the sole JSON tool. The log defaults to
`$HOME/.claude/crucible/gtd/inbox.jsonl` (override with `INBOX_FILE` for tests only).

```
$HOME/.claude/skills/procedure-inbox-capture/scripts/capture.sh --text-file /path/to/text [--project NAME] [--session-id ID]
```

- **`--text-file <path>` is REQUIRED; there is no `--text` flag.** The captured prose is always a
  file, passed straight to `--text-file`. This is the injection boundary — untrusted bytes never
  touch a shell command line, exactly as `procedure-gh-issues`/`procedure-glab-issues` keep a body
  out of shell via `--body-file`. Who derives this path and hands it to the agent is `flow-inbox`'s
  own CAPTURE-mode procedure, not restated here.
- **`--project NAME`** is passed **explicitly by the caller**. The script has a cwd-basename
  fallback, but the agent must NOT rely on it, so `--project` is always supplied (or deliberately
  omitted when the caller says there is no project). Pass it single-quoted, as one opaque token.
  How the caller derives this value is `flow-inbox`'s own CAPTURE-mode procedure, not restated here.
- **`--session-id ID`** is OPTIONAL, passed **explicitly by the caller**. When given, the script
  records a `session_id` field (via `--arg`); when absent it OMITS the key entirely (never a null),
  so pre-enrichment records stay shape-identical. Pass it single-quoted; never invent one.
- **What the script does:** stamps `id` (time-prefixed + random suffix) and `ts` from one UTC
  (Coordinated Universal Time) clock read, sets `is_processed=false` and `note=null` (and includes
  `session_id` only when `--session-id` was given), builds the schema-shaped line with a **static
  jq program** (every value via `--arg`/`--argjson`/`--rawfile`, never concatenated — the
  `session_id` field is added by a static conditional merge, not string concatenation), and appends
  one line **under the shared `.inbox.lock`**. It is the SOLE writer of the log for this operation.
  (If `/dev/urandom` is unreadable, the random suffix falls back to a weaker `cksum`-derived source
  with a warning — this does NOT exit the script; see Exit codes below for what actually does.)
- **Output:** prints `INBOX_ID=<id>` on stdout (machine-clean); diagnostics on stderr.
- **Exit codes:** `0` captured · `1` `jq` missing, the inbox lock could not be acquired, the inbox
  directory could not be created, the write itself failed, or (near-impossible) the id-suffix
  generator failed to produce an 8-hex-digit string · `2` usage (missing/empty `--text-file`, bad
  argument, unknown option).

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
