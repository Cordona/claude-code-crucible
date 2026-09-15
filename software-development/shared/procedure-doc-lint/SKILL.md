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

`standard-documentation`'s Redaction discipline section and `flow-documentation` both used to say a
"genuinely independent, orchestrator-run mechanical gate — one `tech-writer` itself cannot skip or
misjudge — remains an open TODO." Two things drove that TODO, and this skill closes both at once,
because they are the same kind of problem — deterministic pattern/structure checks against a markdown
file:

1. **No script enforced documentation structure or format at all.** Only an LLM self-check checklist
   existed (`standard-documentation`'s Excellence checklist, run by `tech-writer` on itself) — freeform,
   not checkable, and not run by anything outside the authoring agent.
2. **Redaction enforcement had a real, named gap.** `tech-writer`'s own `Grep` pattern scan (ticket IDs,
   local paths) is real, but it is self-administered — the same agent that might paraphrase a leaking
   source document is the one deciding whether its own draft still leaks. An agent can skip a step under
   pressure or misjudge a borderline case; a script run by a different party cannot.

## Why this runs outside the agent (not as another `tech-writer` self-check step)

The whole point of a mechanical gate is that it does not trust the agent it is checking. If `tech-writer`
ran `doc-lint.sh` on its own draft, a skipped or misjudged run would look identical to a clean one — the
exact failure mode the TODO existed to close. The **orchestrator** invokes this script, on the file path
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
| `SINGLE_ITEM_LIST` | A bulleted or numbered list with exactly one item | Block-boundary tracking: a run of list-marker lines, closed only by a hard break (plain column-0 text), not by a blank line or an indented continuation |

Fenced code-block content is excluded from list-structure detection (a `- like this` line inside an
example code block is not a real list). The `TICKET_ID` and `LOCAL_PATH` checks deliberately **never
echo the matched text back into the report** — only the location — so the report itself never re-leaks
what it flags.

**The `TICKET_ID` allowlist (root cause + fix for a real false-positive defect).** The bare pattern
`[A-Z]{2,}-[0-9]+` matches a real ticket ID (`COTE-1543`) but also matches ordinary, correct technical
vocabulary that shares its shape — `UTF-8`, `SHA-256`, `RFC-2119`, `ISO-8601`, `AES-256`, an `ES256`-style
algorithm name, and more. Confirmed by direct execution: a one-line file reading "The API uses UTF-8
encoding and SHA-256 hashes, per RFC-2119 and ISO-8601 timestamps." used to get flagged as a ticket-ID
violation — on a MANDATORY gating check, that made the gate actively harmful, since a doc that correctly
mentions a standard could never pass without lying about content. The script now extracts each match's
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
proving a real ticket ID still triggers even alongside a standard mention — plus ad-hoc cases for
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

---
*Procedure Version: 1.3 — fixed a confirmed logic bug in the `SINGLE_ITEM_LIST` check's block-boundary
detection in `doc-lint.sh`. **Root cause:** the awk pass tracked only whether a trimmed line was
list-item-shaped, never whether consecutive list-item lines actually belonged to the SAME CommonMark
list — so two adjacent, genuinely distinct single-item lists with no blank line between them (a bullet
marker change, e.g. `- item A` immediately followed by `* item B`; or a bullet-to-ordered transition,
e.g. `- item A` immediately followed by `1. item B`) merged into one two-item block and neither was ever
flagged, even though each is independently a single-item list under CommonMark (a marker-character
change or an ordered/unordered transition starts a new list). **Fix:** the pass now also tracks the
marker KIND per list-item line (the bullet character `-`/`*`/`+`, or a fixed `ORDERED` tag for `N.`
items) and treats a kind change between two consecutive list-item lines as the prior block closing and a
new one opening, not a continuation — closing (and flagging, if it was single-item) the outgoing block
before starting the new one. A first implementation attempt read the marker via awk's `RSTART`/`RLENGTH`
after the `is_indented` line's own `match()` call had already silently overwritten them for a non-indented
line — the marker extraction now happens immediately after the `is_item` match, before any other `match()`
call can clobber those built-ins. Added a new fixture (`adjacent-single-item-lists.md`, covering both the
marker-change and bullet-to-ordered cases with no blank line between pairs) plus new `run-tests.sh` cases
proving both example inputs from the bug report are now correctly flagged (exactly right violation
count/lines), and a should-NOT-regress case confirming a genuine multi-item list with a consistent marker
(`- a` / `- b` / `- c`) still reports zero violations. All 66 pre-existing checks plus 16 new ones (82
total) pass under both `sh` and `dash`; `shellcheck -s sh` stays clean on both `doc-lint.sh` and
`run-tests.sh`.*
*Procedure Version: 1.2 — a final comprehensive review found this file's own body described the gate as
running "before any fact-check or PR step," reading as if `flow-documentation` has a PR step of its own
— it doesn't (D1–D8 has no PR step; that lifecycle belongs to `flow-git-operations`, a separate flow).
Reworded to cite `flow-documentation`'s actual Step D6 by name, and to state plainly that a downstream
PR/MR (if the effort ever reaches one) is a different flow's mechanics, not this procedure's.*
*Procedure Version: 1.1 — two fixes from a third, deeper independent review round. (1) **Root cause: the
`TICKET_ID` check's bare pattern `[A-Z]{2,}-[0-9]+` false-positived on ordinary, correct technical
vocabulary** — `UTF-8`, `SHA-256`, `RFC-2119`, `ISO-8601`, `AES-256`, and similar standard/algorithm
names all share the ticket-ID shape, so a MANDATORY gating check was actively harmful: a document that
correctly mentioned a standard could never lint clean without lying about content. Confirmed by direct
execution against a one-line fixture. Fixed in `doc-lint.sh` by extracting each match's prefix and
flagging a line only when a match's prefix is not on a new allowlist — a living list (mirroring this
repo's own `deploy/hub/lib/hub-discovery.sh` `HUB_COLOR_KNOWN_LIST` shape), documented above, plus a new
`--allow-ticket-prefixes` flag for a per-invocation domain-specific extension. Added two new fixtures
(`ticket-id-allowlist-clean.md`, `ticket-id-not-allowlisted.md`) and new `run-tests.sh` cases proving both
the false-positive fix and that a real ticket-ID-shaped string with an unlisted prefix (`COTE-1543`,
`PROJ-99`) — including one mixed on the same line as an allowlisted mention — still correctly triggers,
plus a case for the new flag. (2) **Corrected two stale step-number citations** — "Step D5's fact-check"
(How the orchestrator uses this section) and "proceed to Step D5's fact-check" (Constraints) both
pre-dated `flow-documentation`'s v1.2 renumbering: Step D5 IS this gate itself, and the fact-check/
reviewer dispatch is Step D6. Both now correctly cite Step D6, with the surrounding prose clarified that
D5 and D6 are two distinct, sequential steps — and this section now states explicitly that `flow-
documentation`'s Step D8 fix loop re-runs this gate (Step D5) against every revised draft, not only the
first pass.*
*Procedure Version: 1.0 — closes two related findings against the tech-writer pipeline at once, since
they are the same kind of problem (deterministic pattern/structure checks against a markdown file):
(1) no script enforced documentation structure/format — only an LLM self-check checklist existed; (2)
the still-open half of an older redaction finding — `standard-documentation`'s Redaction discipline
section and `flow-documentation` both named a genuinely independent, orchestrator-run mechanical gate as
an open TODO. `doc-lint.sh` is that gate: bare-fence, ticket-ID, local-path, and single-item-list checks,
run by the orchestrator against `tech-writer`'s draft, before the fact-check/reviewer step, never by
`tech-writer` on itself.*
