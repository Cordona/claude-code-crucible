---
name: review-report-standards
description: Uniform structured reporting contract every reviewer subagent uses to report findings to the primary agent. Owns stable finding IDs, the status lifecycle, severity/verdict rules, and the JSON and Grouped-Report renderings. Pair with `review-core` (reviewer conduct) and `review-boundaries` (which lens owns an overlapping finding) — this skill governs reporting only, never what to review or a lens's own scoring criteria.
---

# Review Report Standards

## Overview

Bind this alongside `review-core` (reviewer conduct) and `review-boundaries` (which lens owns an overlapping finding). This skill defines HOW every reviewer subagent reports findings back to the primary agent — it exists so reports are uniform across reviewers and trackable across review rounds (report → delegate fix → re-review, until approved). It binds one canonical finding schema (the deployed JSON-Schema contract), and owns stable finding IDs, a status lifecycle, severity and verdict rules, and two renderings of the same data: **compact JSON — the default a reviewer emits, for the primary agent to parse and merge** — and a **Grouped Report — how the primary agent renders it for a human**.

This skill governs reporting ONLY. It does not define WHAT to review — each reviewer supplies its own analysis (its "lens"). Bind this skill from any reviewer and follow it exactly so the primary agent can brief implementers and track fixes across iterations without reformatting.

## Absolute Mandates (Every Reviewer)

Reviewer conduct (report-only, no code changes, diff-vs-whole-file scope) is defined by the `review-core` skill. This skill governs the report itself:

- **INLINE ONLY.** Emit the report in your response text. NEVER write a report file to disk (no `.md`, no `.json` artifact). Generated documents waste tokens and are not this contract.
- **TOKEN-DISCIPLINED.** Compact rows, one-line `problem` and `fix`, no restating of large code blocks.

## The Wire Contract (canonical schema)

The machine wire format — the report envelope, the finding schema, and the controlled enums (`status`, `severity`, `verdict`) — is defined ONCE, as a JSON Schema, at the deployed path:

**`$HOME/.claude/crucible/contracts/review-finding-report.schema.json`** *(framework source: `software-development/contracts/review-finding-report.schema.json`)*

Emit **minified JSON conforming to that schema** by default (Rendering 2 below). If that path is unreadable, do not improvise a shape — say so in your report and fall back to the field set named here as a legibility aid (the schema stays authoritative wherever it's reachable): the envelope requires `schema_version`, `reviewer`, `target`, `round`, `generated`, `verdict`, `summary`, `findings`; each finding requires `id`, `status`, `severity`, `category`, `locations`, `first_seen`, `problem`, `fix`. Read the schema for exact types and the worked example when you can reach it — this skill does not restate them, so the schema is the single source of truth for the *shape*. What this skill owns is everything the schema cannot express: the SEMANTICS that follow — how IDs stay stable, what each status means, how severity is anchored, and how the verdict is computed.

`category` is a controlled vocabulary **defined by each reviewer's own declared set** (e.g. `dry`, `coupling`) — never free text — so findings aggregate cleanly across rounds and reviewers.

**A fenced code snippet keyed by finding `id` is a Rendering-1 (human view) affordance only** — it cannot travel in the default JSON (see *Post-Report Notes* for why). Use it only when a delegation explicitly asks for the human-readable Grouped Report and a one-liner genuinely cannot carry the fix.

## Finding IDs (Stable Across Rounds)

- Format: `PREFIX-NNN`, zero-padded sequence (e.g. `CLEAN-001`, `CLEAN-002`), matching the schema's `^[A-Z]+-[0-9]{3,}$` pattern — the prefix itself must be pure letters, no hyphen.
- The `PREFIX` identifies the reviewer so IDs never collide when the primary agent merges reports from a review swarm. Rule: a short caps tag — the distinguishing word of the concept, or its conventional abbreviation, never an invented mangling — with no hyphen, since the schema pattern forbids one inside the prefix. For a multi-word tech name, take the distinguishing word (e.g. `shell-script` → `SHELL`, `cloudflare-workers` → `CLOUDFLARE`). **Each reviewer's own body declares its actual prefix — that declaration is authoritative.** The list below is a non-exhaustive index for collision-avoidance at a glance, not the source of truth: `CLEAN` (clean-code), `DOC` (self-documenting-code), `SEC` (security), `TEST` (test-quality), `CONS` (consistency), `OBS` (observability), `PERF` (performance), `COMPAT` (compatibility), `PERS` (persistence); tech reviewers use their distinguishing word (e.g. `RUST`, `JAVA`, `KOTLIN`, `PHP`, `REACT`, `PYTHON`, `SHELL`, `DEVOPS`, `CLOUDFLARE`).
- An `id` is assigned once and **reused unchanged** in every later round for the same finding. Never renumber. Global uniqueness comes from composing the report header (`reviewer` + `target` + `round`) with the local `id` — do NOT bloat the `id` with names or timestamps.

## Status Lifecycle

| Status | Meaning |
|--------|---------|
| `NEW` | First reported this round. |
| `OPEN` | Reported in a prior round, still present (not yet fixed). |
| `RESOLVED` | Reviewer verified the issue is gone. |
| `REGRESSED` | Was `RESOLVED`, has reappeared. |
| `ACK` (acknowledged) | The user decided not to fix it; reviewer stops re-flagging but keeps it listed for the record. |

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

**Your lens's own severity table maps YOUR issue types onto this scale — it never redefines the scale.** If your table would grade something `HIGH` that fails the "reaches production/users" test, your table is wrong. In particular, "it blocks testing", "it breaks an architectural invariant", "it erodes CI (Continuous Integration) trust", and "it is central to my lens" are **not** gating reasons on their own — none of them ships a defect. (`review-core`'s test-authoring tripwire is the one stated, deliberate exception to consequence-anchoring in this framework; it names itself as such. Absent a comparably explicit exception, this rule holds.)

**A spike/prototype that will not ship has genuinely lower ship-consequence** — grade real issues on that basis and say so; do not discount a real defect merely because the code is labelled a prototype.

## Verdict Arithmetic

Compute the report-level `verdict` mechanically from OPEN/NEW/REGRESSED findings (i.e. anything not `RESOLVED` or `ACK`):

- Any `CRITICAL` or `HIGH` present → **`CHANGES_REQUIRED`** (blocks the fix loop).
- Only `MEDIUM` / `LOW` present → **`APPROVED_WITH_FOLLOWUPS`** (does NOT block the loop; fixes are optional follow-ups).
- Nothing unresolved → **`APPROVED`**.

This lets the primary agent gate the review→fix loop from a single line, and merge across a reviewer swarm by taking the strictest verdict.

**`ACK`-ing a finding is a human waiver, not an orchestrator convenience.** Only the user may decide not to fix a finding — the primary agent proposes, it does not decide. Because an `ACK`'d finding drops out of the unresolved set above, `ACK`-ing a `CRITICAL` or `HIGH` silently flips a blocking verdict to a clean one: that is a real waiver of the correctness/security floor, not paperwork, and it must be an explicit in-turn human decision, relayed and recorded — never inferred, never defaulted, and never the primary agent's own call. See the Acknowledged block below for how the waived finding stays visible.

## Rendering 1: Grouped Report (the primary agent's human rendering — NOT the default; see Rendering 2 below for what a reviewer actually emits)

The **primary agent** renders this for the human, from the reviewers' JSON (Rendering 2) — merging the swarm into one view. A reviewer emits it directly ONLY if a delegation explicitly asks for a human-readable report.

**Emit this as LIVE MARKDOWN — never inside a code fence.** The `>` marks below delimit the spec *here*; they are not part of what you emit. A fence turns a report a human is meant to read into a grey copy-box, and any table inside one renders as raw pipes — this rendering is bullet lines grouped under headings, never a markdown table.

**Structure — this ordering is the contract:**
1. **A header line** — reviewers, file count, merged verdict.
2. **Open findings, grouped by reviewer → then by severity.** The reviewer is the top-level group, ordered by that reviewer's own highest open severity (ties → any stable order); within a reviewer's group, `CRITICAL` before `HIGH` before `MEDIUM` before `LOW`. Reviewer names in **Title Case**, never the kebab agent id — **lens seats drop the `-reviewer` suffix** (`lens-consistency-reviewer` → `Lens Consistency`); **`{tech}` seats keep it** (`kotlin-reviewer` → `Kotlin Reviewer`).
3. **Handoffs / Pre-existing / Conflict / Unreviewed territory** — the non-gating `## Notes` prose (all four kinds; see *Post-Report Notes* below for what each carries and why none of it lives in the JSON).
4. **`✓ Resolved this round`** — a SEPARATE group at the very bottom. It is a receipt, not a to-do; it must never sit among the open findings the human is triaging. Omit the whole block when nothing resolved.
5. **`Acknowledged (won't-fix, for the record)`** — a final block below Resolved, for `ACK` findings the human chose not to fix. Like Resolved it is non-gating and must never sit among the open findings; unlike Resolved it persists across rounds (the reviewer keeps it listed but stops re-flagging). Omit when empty.

**Two hard rules for the human view:**
- **NO finding ids.** The `id` is a machine key for cross-round tracking (Rendering 2); it is noise to a human and must not appear here. The **`file:line` is the anchor** — refer to a finding by its location, not a code.
- **Render `status` as a word, not the enum.** Map: `NEW`→**New** · `OPEN`→**Tracking** · `RESOLVED`→**Resolved** · `REGRESSED`→**Regressed** · `ACK`→**Acknowledged**. *(The enum stays machine-side in Rendering 2; only the friendly word reaches the human.)*

Each finding is one line: **Status** · `file:line` — the problem → the fix. **Exception: the Resolved and Acknowledged blocks (items 4-5 above) lead with the reviewer's name instead of the status word** — the section heading already conveys status for the whole block, so the reviewer is the more useful lead: **Reviewer** · `file:line` — the fix (Resolved) or the problem + why it's acknowledged (Acknowledged).

> ## Code Review Report (Swarm) — Round 2
>
> **Reviewers:** Kotlin Reviewer · Lens Clean Code · Lens Consistency · **Files reviewed:** 5 · **Verdict:** CHANGES_REQUIRED
>
> ### Kotlin Reviewer
>
> **HIGH**
> - **Tracking** · `order/PaymentProcessor.kt:52` — a caught payment-failure exception is swallowed; the order is confirmed anyway. → Propagate the error and roll back the order.
>
> ### Lens Clean Code
>
> **MEDIUM**
> - **New** · `order/OrderMapper.kt:40-71` (+ `order/OrderApi.kt:88`) — dto→entity mapping duplicated across 2 sites **(found by both: Lens Clean Code + Lens Consistency)**. → Extract `mapOrder()`; call from both.
>
> ### Handoffs / Pre-existing (non-gating)
> - `order/Legacy.kt:12` — pre-existing `TODO`, not from this change.
>
> ### ✓ Resolved this round
> - **Kotlin Reviewer** · `order/PlaceOrder.kt:30` — an unhandled null `deadline` branch now returns an error instead of silently proceeding.
>
> ### Acknowledged (won't-fix, for the record)
> - **Lens Clean Code** · `order/PaymentProcessor.kt:80` — long parameter list; team decided a builder isn't worth it here.

- A finding spanning multiple sites leads with its primary `file:line` and lists the rest in parentheses.
- One defect found by **two** reviewers (same `file:line` + same mechanism) is ONE line, placed under the section of the reviewer whose severity is higher (ties → either), and tagged **(found by both: Lens X + Y Reviewer)** — never two rows under two sections. This applies to independent convergence on a territory `review-boundaries` assigns to nobody; a territory it DOES assign is still deferred to its one owner, never scored twice under any tag. Convergence is where the mechanical `id` merge would have hidden agreement; the human view surfaces it, and two blind reviewers agreeing is the swarm's strongest signal.

## Rendering 2: the JSON wire format (DEFAULT — this is what a reviewer emits)

**This is what a reviewer emits by default** — minified JSON conforming to the canonical schema (see *The Wire Contract* above). The primary agent parses it to merge the swarm, compute the merged verdict, and track fixes across rounds — parsing JSON is more reliable than re-parsing prose. Keep it **COMPACT — one line per finding, minified**. The schema file carries a worked example; do not paste it back into the report.

## Post-Report Notes (the ONLY allowed prose)

The findings JSON **is** the report. The single exception: a short, clearly-delimited **`## Notes` block AFTER the findings** may carry non-scored prose that `review-core` or `review-boundaries` mandates but that has no finding row:
- **Scope/applicability assessment** — a lens's Phase-0 gate result (whether its territory applies at all to this change). **MANDATORY every round, from every lens that has such a gate** — unlike the four categories below, which are occasional/conditional, this one is expected every time.
- **Handoff** — out-of-scope observations routed to other reviewers.
- **Pre-existing (not from this change)** — issues in untouched code (non-gating).
- **Conflict** — a "surface the tension once" note when the project deliberately does it differently.
- **Unreviewed territory** — a territory `review-boundaries` assigns elsewhere whose owner is not on this roster.

Each is a line or two, carries NO `id`, and is never scored. Everything else stays in the schema. **This prose has no field in the wire schema** (`additionalProperties: false` on both the envelope and the finding object) — it travels beside the JSON, not inside it, so the primary agent must surface it explicitly rather than assume it survives the JSON merge.

The one exception to "everything else stays in the schema" is `conventions_profile` — see the Wire Contract's own field description and the Re-Review Contract below; that reusable artifact travels in its own schema field, never in this `## Notes` block.

## Re-Review Contract (Round > 1)

When the primary agent provides the prior round's findings, you MUST:

1. **Reuse prior `id`s** for findings that still exist — never renumber.
2. **Update `status`**: fixed → `RESOLVED`; still present → `OPEN`; previously `RESOLVED` but back → `REGRESSED`; deferred by the user's decision → `ACK`.
3. **Add genuinely new findings** with fresh sequential `id`s under your prefix.
4. **Set `first_seen` only for new findings**; keep it frozen, unchanged, for existing ones.
5. **Recompute the `verdict`** from the current unresolved set.

If the prior findings are not provided, state that you are reviewing without prior context and treat all findings as `NEW`.

**Reusable review context.** If a reviewer populates the wire schema's OPTIONAL `conventions_profile` field (e.g. `lens-consistency-reviewer`'s own conventions summary), the primary agent passes that string back on re-review alongside the prior findings, and the reviewer reuses it rather than re-deriving it — see `review-core`'s Convention Profiling for the underlying discipline this serves; the mechanics of what a reviewer may attach and how it's passed back live here. This is a real exception to "everything else stays in the schema" only in the sense that it travels IN the schema, in its own dedicated field — never as `## Notes` prose or a separate Markdown block. `lens-performance-reviewer` and `lens-test-quality-reviewer` run their own Phase-1-style profiling too, but deliberately do NOT populate this field — they re-derive fresh every round with no round-to-round reuse claim, which is a design choice, not an oversight.

## Timestamps

`first_seen` and `generated` are **date-only**, taken from the date provided to you in context — never a wall-clock time. The schema's `generated`/`first_seen` field descriptions own the exact format and the freeze-on-create rule; do not invent sub-day precision, it is not reliable and is not needed for tracking.

## What This Skill Does NOT Cover

- It does not define review **scope** — diff-vs-whole-file discipline, understanding intent, or the missing-diff-artifact rule → `review-core`.
- It does not define a lens's own checks or its `category` vocabulary → each reviewer's own body.
- It does not decide **which lens owns** a finding two lenses could both claim → `review-boundaries`.
- It does not set tool policy — each reviewer enforces read-only by declaring only read tools (no Write/Edit/Bash) in its own frontmatter.

## Constraints (NEVER Violate)

- Do NOT write the report to disk — inline only.
- Do NOT renumber or reassign a finding's `id` across rounds.
- Do NOT invent sub-day timestamps.
- Emit **compact (minified) JSON by default**; the primary agent renders the human Grouped Report from it. Emit the Grouped Report directly only if a delegation asks for a human-readable report.
- Do NOT pad with prose beyond the delimited `## Notes` block (Handoff / Pre-existing / Conflict / Unreviewed territory) — otherwise the schema is the report.
- Do NOT let the primary agent treat an `ACK` on a `CRITICAL`/`HIGH` as its own call — that waiver is the user's alone.

---
*Pair with: review-core (reviewer conduct) + review-boundaries (which lens owns an overlapping finding). Constructive twin of: build-report-standards.*
