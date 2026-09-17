---
name: procedure-doc-lint
description: The deterministic pre-publish gate the ORCHESTRATOR runs against a tech-writer draft — never tech-writer itself, so the check is independent of the agent that authored the draft. Wraps `doc-lint.sh`, which scans one markdown file for four pattern-matchable violations — bare code fences, ticket/issue-ID-shaped identifiers, absolute local filesystem paths, and single-item lists — and exits non-zero with an itemized file:line report if any are found. Does NOT judge documentation quality/structure choices (standard-documentation) or tech-writer's own conduct (the agent body); this is a mechanical script, not a rubric.
---

# Procedure: Documentation Lint (`doc-lint.sh` wrapper)

The **one** deterministic, orchestrator-run gate a `tech-writer` draft passes through before any
fact-check step (`flow-documentation`'s Step D6) — and, if the effort later goes up as a pull/merge
request, before that too, though PR/MR mechanics themselves are `flow-git-operations`'s domain, not
this procedure's; `flow-documentation` has no PR step of its own. This is a **procedure, not a rubric**: run the script, read its report, act on
the exit code — never re-derive these four checks by eye, and never let `tech-writer` run this gate on
its own draft (see "Why this runs outside the agent" below).

## Why this exists

A genuinely independent, orchestrator-run mechanical gate matters because two problems otherwise go
unaddressed, and both are the same kind of problem — deterministic pattern/structure checks against a
markdown file that must not be self-administered by the file's own author:

1. **Documentation structure and format need a script, not just self-checking.** An LLM self-check
   checklist alone (`standard-documentation`'s Excellence checklist, run by `tech-writer` on itself) is
   freeform, not checkable, and not run by anything outside the authoring agent.
2. **Redaction enforcement needs a check outside the authoring agent.** `tech-writer`'s own `Grep`
   pattern scan (ticket IDs, local paths) is real, but it is self-administered — the same agent that
   might paraphrase a leaking source document is the one deciding whether its own draft still leaks. An
   agent can skip a step under pressure or misjudge a borderline case; a script run by a different party
   cannot.

## Why this runs outside the agent (not as another `tech-writer` self-check step)

The whole point of a mechanical gate is that it does not trust the agent it is checking. If `tech-writer`
ran `doc-lint.sh` on its own draft, a skipped or misjudged run would look identical to a clean one — the
exact failure mode this design exists to prevent. The **orchestrator** invokes this script, on the file path
`tech-writer` reports back, as a step the agent cannot see, skip, or influence.

## The script (`$HOME/.claude/skills/procedure-doc-lint/scripts/doc-lint.sh`)

**Invoke it by its deployed absolute path — `$HOME/.claude/skills/procedure-doc-lint/scripts/doc-lint.sh`.**
Never a bare `scripts/doc-lint.sh` (resolves against the caller's cwd, where the script does not exist),
and never `${CLAUDE_SKILL_DIR}/…` from the orchestrator's own Bash (that placeholder only resolves inside
a skill's own `SKILL.md` content). POSIX `sh`, runs on macOS (BSD awk/grep/sort) and Linux (GNU), all
`shellcheck`-clean, self-contained (no external library sourcing), deterministic. Its only external
dependencies are `awk`, `grep`, `sort`, and `mktemp` — every one guarded with `command -v` before use.

```
$HOME/.claude/skills/procedure-doc-lint/scripts/doc-lint.sh --file PATH \
    [--allow-ticket-prefixes "FOO BAR"] [-h|--help]
```

**Checks (all four, one pass over the file, report-only — never modifies the file):**

| Code | What it catches | How |
|------|------------------|-----|
| `BARE_FENCE` | A code fence (` ``` `) opened with no language tag | Fence-state tracking: an opening ` ``` ` line with nothing (or only whitespace) after it |
| `TICKET_ID` | A ticket/issue-ID-shaped identifier | Pattern `[A-Z]{2,}-[0-9]+`, **excluding an allowlisted prefix** (below) |
| `LOCAL_PATH` | An absolute local filesystem path | Patterns `/Users/`, `/home/`, `C:\Users\` |
| `SINGLE_ITEM_LIST` | A bulleted or numbered list with exactly one item | Block-boundary tracking: a run of list-marker lines, closed by a hard break (plain column-0 text), a marker-kind change, or EOF — never by a blank line or an indented continuation |

Fenced code-block content is excluded from list-structure detection (a `- like this` line inside an
example code block is not a real list). The `TICKET_ID` and `LOCAL_PATH` checks deliberately **never
echo the matched text back into the report** — only the location — so the report itself never re-leaks
what it flags.

**The `TICKET_ID` allowlist.** The bare pattern
`[A-Z]{2,}-[0-9]+` matches a real ticket ID (`COTE-1543`) but also matches ordinary, correct technical
vocabulary that shares its shape — `UTF-8`, `SHA-256`, `RFC-2119`, `ISO-8601`, `AES-256`, an `ES256`-style
algorithm name, and more. Flagging every such match unconditionally would make a MANDATORY gating check
actively harmful, since a doc that correctly mentions a standard could never pass without lying about
content. The script instead extracts each match's
**prefix** (the letters before the hyphen) and flags a line only when at least one match's prefix is
**not** on an allowlist. A line that mixes a real ticket ID with a standard mention (e.g. `"COTE-1543, per
RFC-2119"`) is still flagged — only the standard mention is excused, never the whole line.

The built-in default allowlist (a **living list, not a closed set** — mirrors this repo's own
`deploy/hub/lib/hub-discovery.sh` `HUB_COLOR_KNOWN_LIST`/`HUB_COLOR_BROKEN_LIST` shape: a space-separated
constant, documented as non-exhaustive, extended as new cases surface rather than patched ad hoc):

```
UTF SHA AES RFC ISO RSA ECDSA HMAC TLS SSL HTTP HTTPS JSON XML IEEE ECMA ANSI
POSIX ASCII UUID MIME CRC MD DES RC PKCS ITU IETF W3C ES
```

For a domain-specific standard this default list won't anticipate, pass `--allow-ticket-prefixes "FOO
BAR"` (space-separated, repeatable — each use appends) to extend the allowlist for that one invocation,
rather than editing the script. This never widens what the script treats as a *violation* — it only
suppresses a known-safe shape; any prefix absent from both the default list and a caller's extra prefixes
is still flagged, exactly as before.

**Output:** a human-readable block (file, total violation count), an itemized `file:line: CODE: message`
list when any exist, then machine-parseable lines:

```
DOCLINT_FILE=<path>
DOCLINT_VIOLATIONS=<n>
DOCLINT_BARE_FENCES=<n>
DOCLINT_TICKET_IDS=<n>
DOCLINT_LOCAL_PATHS=<n>
DOCLINT_SINGLE_ITEM_LISTS=<n>
```

**Exit codes:** `0` clean pass (zero violations) · `1` one or more violations found (see the itemized
report) · `2` usage error (missing/bad `--file`, unreadable/nonexistent file).

## How the orchestrator uses this (see `flow-documentation`)

This script itself IS Step D5 of `flow-documentation` — a distinct, sequential step that runs **before**
Step D6's fact-check/reviewer dispatch, never the same step as D6. Run it against `tech-writer`'s draft
file(s); on any non-zero exit, report the itemized violations back to `tech-writer` for a fix pass — same
fix-loop shape as the rest of the flow (fix → re-lint → repeat) — and do not proceed to Step D6's
fact-check until the run exits `0` clean. This gate is orthogonal to the fact-check: `doc-lint.sh` never
judges whether the content is *true*, only whether it is *structurally clean* — both gates must pass, in
sequence. **`flow-documentation`'s own Step D8 fix loop re-runs this gate (Step D5) against every revised
draft, before the reviewer's re-review** — a fix made mid-loop can reintroduce any of these four
violations just as easily as the first draft could, so the gate is never a one-time-only check.

## What this does NOT do

- Does not judge Diátaxis mode, minimalism, writing style, or any other qualitative call — that stays
  `standard-documentation`'s territory, self-checked by `tech-writer` and judged for accuracy by the
  `{tech}`-reviewer.
- Does not catch person names — no regular shape distinguishes a name from an ordinary technical term, so
  that half of redaction discipline remains the LLM judgment pass `tech-writer` already performs. This
  script closes the pattern-matchable half of the gap (ticket IDs, local paths) plus structure/format,
  independently of the authoring agent; it does not claim to close the whole redaction problem.
- Does not fix anything. Report-only, like every reviewer in this framework — fixes go back to
  `tech-writer`.

## Testing

`tests/run-tests.sh` is a fully self-contained, zero-dependency POSIX harness (mirrors the
`procedure-git-ops` / `procedure-inbox-capture` harnesses' shape: `pass`/`fail`/`expect_rc`/`stdout_has`
helpers). Unlike `procedure-git-ops`, there is no stub-vs-real split here — `doc-lint.sh` is pure text
processing (no git, no network, no mutation), so every test runs the **real** script against a real
fixture file in `tests/fixtures/` (one clean fixture, one per violation type, two more for the
`TICKET_ID` allowlist specifically — one proving known standard prefixes never false-positive, one
proving a real ticket ID still triggers even alongside a standard mention — one for the
adjacent-marker-change edge of `SINGLE_ITEM_LIST`'s block-boundary tracking, plus ad-hoc cases for
fence/list edge conditions and the `--allow-ticket-prefixes` flag) and is a full proof of behavior, not a
stand-in for one.

```
sh tests/run-tests.sh              # run all tests
VERBOSE=1 sh tests/run-tests.sh
dash tests/run-tests.sh            # also runs green under dash
```

## Constraints (NEVER violate)

- **Never let `tech-writer` invoke this script on its own draft.** It runs from the orchestrator, outside
  the authoring agent, or it is not the independent gate it claims to be.
- **Never proceed to Step D6's fact-check/reviewer dispatch while this gate is failing.** A non-zero exit
  is a required fix round, not an advisory note — and this applies on every pass through Step D8's fix
  loop, not only the first.
- **Never echo the matched sensitive text** (the ticket ID, the local path) back into the report —
  location only, per the script's own design.
- **Never treat this as covering person-name redaction** — it does not, and does not claim to.
- **Never modify the linted file** — this script (and this procedure) is report-only.
