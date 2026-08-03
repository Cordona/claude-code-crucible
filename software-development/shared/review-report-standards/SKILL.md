---
name: review-report-standards
description: Uniform structured reporting contract for all reviewer subagents. Applies whenever a reviewer (clean-code, security, test-quality, consistency, observability, or a language-specific reviewer) reports findings to the primary agent, or when a review iterates across rounds. Binds the externalized finding-schema contract (deployed under crucible/contracts/) and owns stable finding IDs, the status lifecycle, severity and verdict rules, and both table and JSON renderings so reports merge across reviewers and track across fix cycles.
---

# Review Report Standards

## Overview

This skill defines HOW every reviewer subagent reports findings back to the primary agent. It exists so reports are uniform across reviewers and trackable across review rounds (report → delegate fix → re-review, until approved). It binds one canonical finding schema (the deployed JSON-Schema contract), and owns stable finding IDs, a status lifecycle, severity and verdict rules, and two renderings of the same data: **compact JSON — the default a reviewer emits, for the primary agent to parse and merge** — and a **compact table — how the primary agent renders it for a human**.

This skill governs reporting ONLY. It does not define WHAT to review — each reviewer supplies its own analysis (its "lens"). Bind this skill from any reviewer and follow it exactly so the primary agent can brief implementers and track fixes across iterations without reformatting.

## Absolute Mandates (Every Reviewer)

Reviewer conduct (report-only, no code changes) is defined by the `review-core` skill. This skill governs the report itself:

- **INLINE ONLY.** Emit the report in your response text. NEVER write a report file to disk (no `.md`, no `.json` artifact). Generated documents waste tokens and are not this contract.
- **TOKEN-DISCIPLINED.** Compact rows, one-line `problem` and `fix`, no restating of large code blocks. A fenced snippet is allowed ONLY when a one-liner genuinely cannot carry the fix, keyed by finding `id`, and kept minimal.

## The Wire Contract (canonical schema)

The machine wire format — the report envelope, the finding schema, and the controlled enums (`status`, `severity`, `verdict`) — is defined ONCE, as a JSON Schema, at the deployed path:

**`$HOME/.claude/crucible/contracts/review-finding-report.schema.json`** *(framework source: `software-development/contracts/review-finding-report.schema.json`)*

Emit **minified JSON conforming to that schema** by default (Rendering 2 below). Read that file for the exact fields, types, and enum value sets, plus a worked example — this skill does not restate them, so the schema is the single source of truth for the *shape*. What this skill owns is everything the schema cannot express: the SEMANTICS that follow — how IDs stay stable, what each status means, how severity is anchored, and how the verdict is computed.

Two field-level notes the schema deliberately leaves to this skill:
- `category` is a controlled vocabulary **defined by each reviewer** (e.g. `dry`, `coupling`), NOT free text — pick from the reviewer's own declared set so findings aggregate cleanly across rounds and reviewers.
- `summary.open` counts UNRESOLVED findings (`NEW`/`OPEN`/`REGRESSED`) by severity; `resolved`/`new`/`ack` are orthogonal status counts.

## Finding IDs (Stable Across Rounds)

- Format: `PREFIX-NNN`, zero-padded sequence (e.g. `CLEAN-001`, `CLEAN-002`).
- The `PREFIX` identifies the reviewer so IDs never collide when the primary agent merges reports from a review swarm. Recommended prefixes — the natural, real-word form of the concept, never an artificial letter-drop: `CLEAN` (clean-code), `SEC` (security), `TEST` (test-quality), `CONS` (consistency), `OBS` (observability), `PERF` (performance), `COMPAT` (compatibility), `PERS` (persistence); language/tech reviewers use their actual full name (e.g. `RUST`, `JAVA`, `KOTLIN`, `PHP`, `REACT`, `SHELL`, `DEVOPS`).
- An `id` is assigned once and **reused unchanged** in every later round for the same finding. Never renumber. Global uniqueness comes from composing the report header (`reviewer` + `target` + `round`) with the local `id` — do NOT bloat the `id` with names or timestamps.

## Status Lifecycle

| Status | Meaning |
|--------|---------|
| `NEW` | First reported this round. |
| `OPEN` | Reported in a prior round, still present (not yet fixed). |
| `RESOLVED` | Reviewer verified the issue is gone. |
| `REGRESSED` | Was `RESOLVED`, has reappeared. |
| `ACK` | The primary agent/user decided not to fix it; reviewer stops re-flagging but keeps it listed for the record. |

In round 1, every finding is `NEW`.

## Severity — ONE scale, anchored to consequence

**Severity is a CROSS-lens scale, not your lens's private sense of importance.** Your report is merged with every other reviewer's, and the arithmetic below gates a shared fix loop — so a `HIGH` from you must mean exactly what a `HIGH` from any other lens means. Grade by **what happens if this ships**, never by how central the issue is to your domain.

| Severity | The test — if this ships… |
|----------|---------------------------|
| `CRITICAL` | …it causes loss or compromise a later fix cannot undo: data loss/corruption, a breach, an unrecoverable outage. |
| `HIGH` | …it reaches production/users as a defect: wrong results, a silent failure, an exploitable hole, a broken consumer. Recoverable — but it lands. |
| `MEDIUM` | …nothing breaks for users. It raises the cost or risk of the NEXT change: maintainability, a coverage gap, a latent trap. |
| `LOW` | …nothing breaks and the next change is barely affected. Polish. |

**The indirect-finding rule — read this if your lens judges tests, docs, tooling, or process.** Those findings describe a **latent** risk, not a present defect: the code works today. That is `MEDIUM` by construction — *"raises the risk of the next change."* A weak test is not `HIGH` because the behavior it fails to guard is important. It becomes `HIGH` only when the gap is **currently hiding a real defect** — and then the finding IS that defect, reported at the defect's severity, not the gap's.

**Your lens's own severity table maps YOUR issue types onto this scale — it never redefines the scale.** If your table would grade something `HIGH` that fails the "reaches production/users" test, your table is wrong.

## Verdict Arithmetic

Compute the report-level `verdict` mechanically from OPEN/NEW/REGRESSED findings (i.e. anything not `RESOLVED` or `ACK`):

- Any `CRITICAL` or `HIGH` present → **`CHANGES_REQUIRED`** (blocks the fix loop).
- Only `MEDIUM` / `LOW` present → **`APPROVED_WITH_FOLLOWUPS`** (does NOT block the loop; fixes are optional follow-ups).
- Nothing unresolved → **`APPROVED`**.

This lets the primary agent gate the review→fix loop from a single line, and merge across a reviewer swarm by taking the strictest verdict.

## Rendering 1: Grouped Report (the primary agent's human rendering)

The **primary agent** renders this for the human, from the reviewers' JSON (Rendering 2) — merging the swarm into one view. A reviewer emits it directly ONLY if a delegation explicitly asks for a human-readable report.

**Emit this as LIVE MARKDOWN — never inside a code fence.** The `>` marks below delimit the spec *here*; they are not part of what you emit. A fence turns a report a human is meant to read into a grey copy-box, and any table inside one renders as raw pipes.

**Structure — this ordering is the contract:**
1. **A header line** — reviewers, file count, merged verdict.
2. **Open findings, grouped by reviewer → then by severity.** The reviewer is the top-level group; within it, `HIGH` before `MEDIUM` before `LOW`. Reviewer names in **Title Case**, never the kebab agent id — **lens seats drop the `-reviewer` suffix** (`lens-consistency-reviewer` → `Lens Consistency`); **`{tech}` seats keep it** (`kotlin-reviewer` → `Kotlin Reviewer`).
3. **Handoffs / Pre-existing / Conflict** — the non-gating `## Notes` prose (all three kinds).
4. **`✓ Resolved this round`** — a SEPARATE group at the very bottom. It is a receipt, not a to-do; it must never sit among the open findings the human is triaging. Omit the whole block when nothing resolved.
5. **`Acknowledged (won't-fix, for the record)`** — a final block below Resolved, for `ACK` findings the human chose not to fix. Like Resolved it is non-gating and must never sit among the open findings; unlike Resolved it persists across rounds (the reviewer keeps it listed but stops re-flagging). Omit when empty.

**Two hard rules for the human view:**
- **NO finding ids.** The `id` is a machine key for cross-round tracking (Rendering 2); it is noise to a human and must not appear here. The **`file:line` is the anchor** — refer to a finding by its location, not a code.
- **Render `status` as a word, not the enum.** Map: `NEW`→**New** · `OPEN`→**Tracking** · `RESOLVED`→**Resolved** · `REGRESSED`→**Regressed** · `ACK`→**Acknowledged**. *(The enum stays machine-side in Rendering 2; only the friendly word reaches the human.)*

Each finding is one line: **Status** · `file:line` — the problem → the fix.

> ## Code Review Report (Swarm) — Round 2
>
> **Reviewers:** Lens Consistency · Kotlin Reviewer · **Files:** 3 · **Verdict:** CHANGES_REQUIRED
>
> ### Kotlin Reviewer
>
> **HIGH**
> - **Tracking** · `order/service.rs:88` — OrderService reaches into PaymentRepo internals. → inject a PaymentGateway abstraction; depend on the trait.
>
> ### Lens Consistency
>
> **MEDIUM**
> - **New** · `order/mapper.rs:40-71` (+ `order/api.rs:88`, `order/batch.rs:22`) — dto→entity mapping duplicated across 3 sites. → extract `map_order()`; call from all three.
>
> ### Handoffs / Pre-existing (non-gating)
> - `order/legacy.rs:12` — pre-existing `TODO`, not from this change.
>
> ### ✓ Resolved this round
> - **Kotlin Reviewer** · `order/place.rs:30` — param `d` renamed to `deadline`.

- A finding spanning multiple sites leads with its primary `file:line` and lists the rest in parentheses.
- One defect found by **two** reviewers (same `file:line` + same mechanism) is ONE line, placed under the section of the reviewer whose severity is higher (ties → either), and tagged **(found by both: Lens X + Y Reviewer)** — never two rows under two sections. This is where the mechanical `id` merge would have hidden convergence; the human view surfaces it, and two blind reviewers agreeing is the swarm's strongest signal.

## Rendering 2: the JSON wire format (DEFAULT)

**This is what a reviewer emits by default** — minified JSON conforming to the canonical schema (see *The Wire Contract* above): `$HOME/.claude/crucible/contracts/review-finding-report.schema.json`. The primary agent parses it to merge the swarm, compute the merged verdict, and track fixes across rounds — parsing JSON is more reliable than re-parsing prose tables. Keep it **COMPACT — one line per finding, minified**, to stay token-lean. The schema file carries a worked example; do not paste it back into the report.

## Post-Report Notes (the ONLY allowed prose)

The findings table/JSON **is** the report. The single exception: a short, clearly-delimited **`## Notes` block AFTER the findings** may carry non-scored prose that `review-core` mandates but that has no finding row:
- **Handoff** — out-of-scope observations routed to other reviewers.
- **Pre-existing (not from this change)** — issues in untouched code (non-gating).
- **Conflict** — a "surface the tension once" note when the project deliberately does it differently.

Each is a line or two, carries NO `id`, and is never scored. Everything else stays in the schema.

## Re-Review Contract (Round > 1)

When the primary agent provides the prior round's findings, you MUST:

1. **Reuse prior `id`s** for findings that still exist — never renumber.
2. **Update `status`**: fixed → `RESOLVED`; still present → `OPEN`; previously `RESOLVED` but back → `REGRESSED`; deferred by decision → `ACK`.
3. **Add genuinely new findings** with fresh sequential `id`s under your prefix.
4. **Recompute** `first_seen` only for new findings; keep it frozen for existing ones.
5. **Recompute the `verdict`** from the current unresolved set.

If the prior findings are not provided, state that you are reviewing without prior context and treat all findings as `NEW`.

**Reusable review context.** If a reviewer emits a reusable artifact in its report (e.g. the consistency reviewer's `## Conventions Profile`), the primary agent passes it back on re-review alongside the prior findings, and the reviewer **reuses it rather than re-deriving it** — this avoids paying an expensive per-round re-computation (e.g. re-profiling the project's conventions every fix cycle).

## Timestamp Rule

`first_seen` and `generated` are **date-only** (ISO 8601, e.g. `2026-07-12`) and taken from the date provided to you in context. Do NOT invent a wall-clock time (hours/minutes/seconds) — sub-day precision is not reliable and is not needed for tracking.

## What This Skill Does NOT Cover

- It does not define review scope, checks, or severity *criteria* — each reviewer owns its lens and its `category` vocabulary.
- It does not set tool policy — each reviewer enforces read-only by declaring only read tools (no Write/Edit/Bash) in its own frontmatter.

## Constraints (NEVER Violate)

- Do NOT write the report to disk — inline only.
- Do NOT renumber or reassign a finding's `id` across rounds.
- Do NOT invent sub-day timestamps.
- Emit **compact (minified) JSON by default**; the primary agent renders the human table from it. Emit a table directly only if a delegation asks for a human-readable report.
- Do NOT pad with prose beyond the delimited `## Notes` block (Handoff / Pre-existing / Conflict) — otherwise the schema is the report.

---
*Skill Version: 1.0*
*Pair with: review-core (reviewer conduct). Constructive twin of: build-report-standards.*
