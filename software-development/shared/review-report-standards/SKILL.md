---
name: review-report-standards
description: Uniform structured reporting contract every reviewer subagent uses to report findings to the primary agent. Owns stable finding IDs, the status lifecycle, severity/verdict rules, and the JSON and Grouped-Report renderings. Pair with `review-core` (reviewer conduct) and `review-boundaries` (which lens owns an overlapping finding) — this skill governs reporting only, never what to review or a lens's own scoring criteria.
---

# Review Report Standards

## Overview

Bind this alongside `review-core` (reviewer conduct) and `review-boundaries` (which lens owns an overlapping finding). This skill defines HOW every reviewer subagent reports findings back to the primary agent — it exists so reports are uniform across reviewers and trackable across review rounds (report → delegate fix → re-review, until approved). It binds one canonical finding schema (the deployed JSON-Schema contract), and owns stable finding IDs, a status lifecycle, severity and verdict rules, and two renderings of the same data: **compact JSON — the default a reviewer emits, for the primary agent to parse and merge** — and a **Grouped Report — how the primary agent renders it for a human**.

This skill governs reporting ONLY. It does not define WHAT to review — each reviewer supplies its own analysis (its "lens"). Bind this skill from any reviewer and follow it exactly so the primary agent can brief implementers and track fixes across iterations without reformatting.

## Absolute Mandates (Every Reviewer)

Reviewer conduct (report-only, no code changes, review scope — the change and its effects) is defined by the `review-core` skill. This skill governs the report itself:

- **INLINE ONLY.** Emit the report in your response text. NEVER write a report file to disk (no `.md`, no `.json` artifact). Generated documents waste tokens and are not this contract.
- **TOKEN-DISCIPLINED.** Compact rows, one-line `problem` and `fix`, no restating of large code blocks.

## The Wire Contract (canonical schema)

The machine wire format — the report envelope, the finding schema, and the controlled enums (`status`, `severity`, `verdict`) — is defined ONCE, as a JSON Schema, at the deployed path:

**`$HOME/.claude/crucible/contracts/review-finding-report.schema.json`** *(framework source: `software-development/contracts/review-finding-report.schema.json`)*

Emit **minified JSON conforming to that schema** by default (Rendering 2 below). If that path is unreadable, do not improvise a shape — say so in your report and fall back to the field set named here as a legibility aid (the schema stays authoritative wherever it's reachable): the envelope requires `schema_version`, `reviewer`, `target`, `round`, `generated`, `verdict`, `summary`, `findings`, `speculative`; each finding requires `id`, `status`, `severity`, `realism`, `trigger`, `category`, `locations`, `first_seen`, `problem`, `fix`; an edge-case finding and every `speculative` entry also carry `proof` or `unproven: true`, every `speculative` entry requires a `category` from your vocabulary — and a security entry (`review-core`, Security is never rare) requires `proof`, never `unproven` — a finding you mark `RESOLVED` carries `resolution_proof`, and a finding located outside the diff carries `relates_to` (`review-core`). Every proof takes one of `review-core`'s proof forms (Proof for every dismissal) — never a `ran …` proof: you have no shell, and only the orchestrator records one. Read the schema for exact types and the worked example when you can reach it — this skill does not restate them, so the schema is the single source of truth for the *shape*. What this skill owns is everything the schema cannot express: the SEMANTICS that follow — how IDs stay stable, what each status means, how severity is anchored, and how the verdict is computed.

`category` is a controlled vocabulary **defined by each reviewer's own declared set** (e.g. `dry`, `coupling`) — never free text — so findings aggregate cleanly across rounds and reviewers. The declared vocabulary under `contracts/` mirrors every set and flags the security categories (`review-core`, Security is never rare); the artifact writers reject a category outside it.

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

**Severity grades consequence; realism grades likelihood — they are separate fields.** Severity always assumes the trigger fired; likelihood lives only in `realism`. Every finding carries `realism` (`realistic` | `edge-case`) and the `trigger` that justifies it — an edge case also its `realism_reason` and `proof` (or `unproven`), and a `speculative` entry its `real_if` and `proof` (or `unproven`), each at most 100 characters — decided by `review-core`'s Realism test before you grade. Grade an edge case on the same consequence scale — its class (human-confirmed for a `CRITICAL`/`HIGH`), never a lowered severity, is what keeps it from gating.

**A spike/prototype that will not ship has genuinely lower ship-consequence** — grade real issues on that basis and say so; do not discount a real defect merely because the code is labelled a prototype.

## Verdict Arithmetic

Compute the report-level `verdict` mechanically from OPEN/NEW/REGRESSED findings (i.e. anything not `RESOLVED` or `ACK`) that are `realistic`, plus any `edge-case` `CRITICAL`/`HIGH` the human has not confirmed as an edge case — a MEDIUM/LOW or human-confirmed edge case never counts, and speculative concerns are not findings at all:

- Any `CRITICAL` or `HIGH` present → **`CHANGES_REQUIRED`** (blocks the fix loop).
- Only `MEDIUM` / `LOW` present → **`APPROVED_WITH_FOLLOWUPS`** (does NOT block the loop; what the human does not choose at the Address question is a follow-up, and what the human chooses is mandatory — `flow-implementation` §5).
- Nothing unresolved → **`APPROVED`**.

**Confirming an edge-case `CRITICAL`/`HIGH` is a human decision, like `ACK`:** the primary agent shows it by location and trigger and records the human's in-turn answer; it never confirms one itself. A confirmation covers the severity it was given at — a severity change returns the finding to the human. This lets the primary agent gate the review→fix loop from a single line, and merge across a reviewer swarm by taking the strictest verdict.

**`ACK`-ing a finding is a human waiver, not an orchestrator convenience** — a reviewer report never sets `ACK` (the writers refuse it unless the finding is already `ACK`); only `review-update-status.sh --status ACK --reason <reason>` records it (the reason per `flow-implementation` §5). Only the user may decide not to fix a finding — the primary agent proposes, it does not decide. Because an `ACK`'d finding drops out of the unresolved set above, `ACK`-ing a `CRITICAL` or `HIGH` silently flips a blocking verdict to a clean one: that is a real waiver of the correctness/security floor, not paperwork, and it must be an explicit in-turn human decision, relayed and recorded — never inferred, never defaulted, and never the primary agent's own call. See the Acknowledged block below for how the waived finding stays visible.

## Rendering 1: Grouped Report (the primary agent's human rendering — NOT the default; see Rendering 2 below for what a reviewer actually emits)

The **primary agent** renders this for the human, from the reviewers' JSON (Rendering 2) — merging the swarm into one view. A reviewer emits it directly ONLY if a delegation explicitly asks for a human-readable report. `flow-review`'s durable artifact renders the same layout from its script.

**Emit this as LIVE MARKDOWN — never inside a code fence.** The `>` marks below delimit the spec *here*; they are not part of what you emit. No tables and no colored status dots — bullet and numbered lines under headings only.

**Structure — this ordering is the contract:**
1. **Title, verdict, summary** — `## 🔍 Code Review · round N`, then `**Verdict:**` with the merged verdict in words, then a `**Summary:**` list of open counts, in this order: `Realistic`, `Edge cases` (each with its severity split, `CRITICAL` → `LOW`, zero severities omitted), `Speculative`, `Open handoffs`, `Re-check` (background re-check results), `Needs your decision` (always shown, even 0 — every unconfirmed edge-case `CRITICAL`/`HIGH`, every item whose re-check is `escalated`, and every confirmed edge case whose re-check `survived`), and `Resolved this round` on a re-review. A zero class row is omitted.
2. **Reviewers** and **Files** — each a bold label over a bulleted list.
3. **`Realistic (n)`** — open realistic findings.
4. **`Edge cases (n)`** — open edge-case findings, each with a `Why edge case:` line from its `realism_reason` (else its `Trigger:`) and a `Proof:` line — or, without proof, one `Not proven: <its realism_reason>` line in place of both; an unconfirmed `CRITICAL`/`HIGH` is marked **needs your decision** on its line and shows its `Trigger:` too — it gates until confirmed.
5. **`Speculative (n)`** — every reviewer's `speculative` entries. Non-gating, never a finding — but always shown.
6. **`Open handoffs (n)`** — every handoff in the artifact's `handoffs[]` whose ruling is still `open` (`review-core`, Stay in Your Lane), naming its sender and receiver.
7. **`For your decision (n)`** — reviewer conflicts the human resolves (`## Notes` Conflict), and a defect two reviewers graded at different severities (below).
8. **`Resolved (n)`** — a receipt, never among the open findings, each with its `Proof:` (`resolution_proof`).
9. **`Handoffs ruled (n)`** — every handoff whose ruling is `filed`, `rejected`, `out-of-scope` or `waived`.
10. **`Acknowledged (n)`** — `ACK` findings the human chose not to fix, each with the human's reason; persists across rounds.
11. **`Round history`** — the durable artifact only (below).
12. **`Not reviewed`** — only Pre-existing and Unreviewed territory from `## Notes`, one bullet each; the durable artifact has no field for it, so it appears only in a rendering from live reports.

Omit an empty section, except the verdict, the summary, Reviewers and Files.

**The durable artifact** (`flow-review` §5c) renders this same layout, plus: the title names the repo (`## 🔍 Code Review · <repo> · round <N>`), a `Spec:` line under the verdict when the artifact has a `spec_ref`, a finding whose `tracked_status` is not `PENDING` carries it as a short suffix on its line (`· in progress`), and the closing `Round history` list. `id`, `category`, `first_seen` and `addressed_in_round` stay in the JSON and are not rendered.

**Inside sections 3–5, group by reviewer** — a bold reviewer line, reviewers ordered by their highest open severity, findings `CRITICAL` → `LOW` within a reviewer. Reviewer names in **Title Case**, never the kebab agent id — **lens seats drop the `-reviewer` suffix** (`lens-consistency-reviewer` → `Lens Consistency`); **`{tech}` seats keep it** (`kotlin-reviewer` → `Kotlin Reviewer`).

**Numbering:** ONE continuous count from 1 across sections 3–7, so the human can answer "fix 1–4, 6". Count in the order items appear, top to bottom — never by severity; markdown renumbers a list whose numbers skip, so the number the human sees would differ from the one the question names. Sections 8 onward use plain bullets.

**A Not proven item is never shown as settled** — any set-aside item without proof shows `Not proven`, no section or summary line presents it as cleared, and a proven-harmless security item keeps its own line. **An item with a background re-check result** carries a `Re-check:` sub-line with the result and its proof. **A security item** (`review-core`, Security is never rare) carries a **Security** marker — right after the severity on a finding, first on a speculative entry.

**Hard rules for the human view:**
- **NO finding ids.** The `id` is a machine key for cross-round tracking (Rendering 2). The **`file:line` is the anchor**.
- **File names only.** Show each location by its file name in a code span (`OrderApi.kt:88`) — never a `/` inside the span, never a full or absolute path. When two files in the report share a name, add the shortest distinguishing folder as plain text after it: `OrderApi.kt:88` · order. A `file:line` inside a proof follows the same rule.
- **Every multi-item field is a bulleted list** — never items joined on one line.
- **One short line per reason** — a finding's line plus its reason sub-lines (`Trigger:`, `Why edge case:`, `Real if:` / `Why speculative:`, `Proof:` / `Not proven`, `Re-check:`, `Relates to:`), each one line, then `Also at:` with a nested list when the finding has more locations.
- **Render `status` as a word, not the enum.** Map: `NEW`→**New** · `OPEN`→**Tracking** · `RESOLVED`→**Resolved** · `REGRESSED`→**Regressed** · `ACK`→**Acknowledged**.

Line shapes (`**Security** · ` appears only on a security item):
- Realistic: `n. **SEVERITY** · **Security** · Status · `file:line`: problem → fix`, then `- Trigger: …` (and `- Relates to: `file:line`` when the defect sits outside the diff)
- Edge case: `n. **SEVERITY** · **Security** · `file:line`: problem`, then `- Why edge case: …` and `- Proof: …` — or, without proof, the single line `- Not proven: <why edge case>` (and `- Trigger: …` when it needs your decision)
- Speculative: `n. **Security** · `file:line`: concern`, then `- Real if: …` (else `- Why speculative: …`), then exactly one of `- Proof: …` or `- Not proven`
- Open handoff: `n. **From Reviewer** → **To Reviewer** · `file:line`: concern`
- Resolved: `- **Reviewer** · `file:line`: the fix`, then `- Proof: …`
- Handoff ruled: `- **From Reviewer** → **To Reviewer** · `file:line`: concern`, then `- <Ruling>: <proof>` (`Filed`, `Rejected` or `Out of scope`), or `- Waived — <the human's reason>`
- Acknowledged: `- **Reviewer** · `file:line`: the problem; why it is acknowledged`

> ## 🔍 Code Review · round 1
>
> **Verdict:** Changes required
>
> **Summary:**
> - Realistic: 2 (1 HIGH · 1 MEDIUM)
> - Edge cases: 1 (1 MEDIUM)
> - Speculative: 1
> - Needs your decision: 0
>
> **Reviewers:**
> - Kotlin Reviewer
> - Lens Clean Code
>
> **Files:**
> - `PaymentProcessor.kt`
> - `OrderMapper.kt`
> - `OrderApi.kt`
>
> ### Realistic (2)
>
> **Kotlin Reviewer**
>
> 1. **HIGH** · Tracking · `PaymentProcessor.kt:52`: a payment failure is swallowed and the order confirmed → propagate the error and roll back
>    - Trigger: any declined card at checkout
>
> **Lens Clean Code**
>
> 2. **MEDIUM** · New · `OrderMapper.kt:40`: DTO-to-entity mapping duplicated **(found by both: Lens Clean Code + Lens Consistency)** → extract `mapOrder()`
>    - Trigger: the next field added to the order DTO
>    - Also at:
>      - `OrderApi.kt:88`
>
> ### Edge cases (1)
>
> **Kotlin Reviewer**
>
> 3. **MEDIUM** · `OrderApi.kt:120`: two retries in the same millisecond could both pass the uniqueness check
>    - Why edge case: needs two retries within one millisecond
>    - Proof: `RetryPolicy.kt:22` waits 200 ms between attempts
>
> ### Speculative (1)
>
> **Kotlin Reviewer**
>
> 4. **Security** · `PaymentProcessor.kt:15`: gateway credentials could leak through a heap dump
>    - Real if: someone without host access can trigger a heap dump
>    - Proof: `ActuatorConfig.kt:18` exposes no heap-dump endpoint
>
> ### For your decision (1)
>
> 5. Where order validation belongs:
>    - Kotlin Reviewer: in `OrderApi.kt`
>    - Lens Clean Code: in its own validator
>
> ### Resolved (1)
>
> - **Kotlin Reviewer** · `PlaceOrder.kt:30`: a null `deadline` now returns an error
>   - Proof: `PlaceOrder.kt:31` returns `MissingDeadline` for a null deadline
>
> ### Acknowledged (1)
>
> - **Lens Clean Code** · `PaymentProcessor.kt:80`: long parameter list; a builder is not worth it here
>
> ### Not reviewed
>
> - `Legacy.kt:12`: pre-existing `TODO`, not from this change

- A finding spanning multiple sites leads with its primary `file:line` and lists the rest under an `Also at:` sub-line.
- One defect found by **two** reviewers (same `file:line` + same mechanism) is ONE line, placed under the reviewer whose severity is higher (ties → either), and tagged **(found by both: Lens X + Y Reviewer)** — never two lines under two reviewers. **When their severities differ, the primary agent surfaces both** — the tag names each grade (**(found by both: Lens X HIGH · Y Reviewer MEDIUM)**), the higher one counts, and the disagreement is also a `For your decision` item — never silently resolved to one. This applies to independent convergence on a territory `review-boundaries` assigns to nobody; a territory it DOES assign is still deferred to its one owner, never scored twice under any tag. Convergence is where the mechanical `id` merge would have hidden agreement; the human view surfaces it, and two blind reviewers agreeing is the swarm's strongest signal.

## Rendering 2: the JSON wire format (DEFAULT — this is what a reviewer emits)

**This is what a reviewer emits by default** — minified JSON conforming to the canonical schema (see *The Wire Contract* above). The primary agent parses it to merge the swarm, compute the merged verdict, and track fixes across rounds — parsing JSON is more reliable than re-parsing prose. Keep it **COMPACT — one line per finding, minified**. The schema file carries a worked example; do not paste it back into the report.

The persisted review artifact (`review-artifact.schema.json`, written only by the orchestrator's scripts — `flow-review` §5c) adds what the orchestrator records after the report: `handoffs[]` with each ruling and its proof, `resolution_proof` on a `RESOLVED` finding, and a re-check result on a set-aside item — `pending`, `survived`, `cleared`, or `escalated`, with its locator proof, or for `escalated` its reason in plain words; or `dismissed`, the human's closing of an escalated speculative or `not_tested` entry, with their reason (`flow-implementation` §5, Background re-check).

## Post-Report Notes (the ONLY allowed prose)

The findings JSON **is** the report. The single exception: a short, clearly-delimited **`## Notes` block AFTER the findings** may carry non-scored prose that `review-core` or `review-boundaries` mandates but that has no finding row:
- **Scope/applicability assessment** — a lens's Phase-0 gate result (whether its territory applies at all to this change). **MANDATORY every round, from every lens that has such a gate** — unlike the four categories below, which are occasional/conditional, this one is expected every time.
- **Handoff** — out-of-scope observations routed to other reviewers, each naming its receiver and location; and, on a brief that passed you handoffs, your ruling on each (`review-core`, Stay in Your Lane).
- **Pre-existing (not from this change)** — issues in code the change neither touched, relies on, nor exposes (non-gating).
- **Conflict** — a "surface the tension once" note when the project deliberately does it differently.
- **Unreviewed territory** — a territory `review-boundaries` assigns elsewhere whose owner is not on this roster.

Each is a line or two, carries NO `id`, and is never scored. Everything else stays in the schema. **This prose has no field in the wire schema** (`additionalProperties: false` on both the envelope and the finding object) — it travels beside the JSON, not inside it, so the primary agent must surface it explicitly rather than assume it survives the JSON merge.

An exception to "everything else stays in the schema" is `conventions_profile` — see the Wire Contract's own field description and the Re-Review Contract below; that reusable artifact travels in its own schema field, never in this `## Notes` block. `lens-test-quality-reviewer` has two more, on a `flow-testing` dispatch only: `plan_revision` (the revised test plan, which that flow's scripts validate) and `volume` (its one-line volume verdict); on that dispatch a finding's `locations` may also use `plan:<item>` locators (`flow-testing` §3c, §5). They too travel in their own schema fields, never in `## Notes`.

## Re-Review Contract (Round > 1)

When the primary agent provides the prior round's findings, you MUST:

1. **Reuse prior `id`s** for findings that still exist — never renumber.
2. **Update `status`**: fixed → `RESOLVED`, with `resolution_proof`; still present → `OPEN`; previously `RESOLVED` but back → `REGRESSED`; deferred by the user's decision → `ACK`.
3. **Add genuinely new findings** with fresh sequential `id`s under your prefix.
4. **Set `first_seen` only for new findings**; keep it frozen, unchanged, for existing ones.
5. **Keep the `realism` the primary agent passes back** for a finding the human elected or confirmed — that class is the human's decision, not yours to change; leave an edge case the primary agent says the human confirmed out of your verdict.
6. **Rule on every handoff passed to you** — filed, with `proof` at the new finding's `file:line`; rejected with `proof`; or out of scope with `proof` (`review-core`, Stay in Your Lane); the orchestrator records it in the artifact's `handoffs[]` — `{from, to, concern, location, relates_to?, ruling (open | filed | rejected | out-of-scope | waived), proof, filed_as?, reason?}` — `waived` is the human's decision, recorded by the orchestrator with the human's words as `reason`, never a reviewer ruling.
7. **A finding the fix only partly addresses stays `OPEN`** — never `RESOLVED`.
8. **Recompute the `verdict`** per Verdict Arithmetic.

If the prior findings are not provided, state that you are reviewing without prior context and treat all findings as `NEW`.

**Reusable review context.** If a reviewer populates the wire schema's OPTIONAL `conventions_profile` field (e.g. `lens-consistency-reviewer`'s own conventions summary), the primary agent passes that string back on re-review alongside the prior findings, and the reviewer reuses it rather than re-deriving it — see `review-core`'s Convention Profiling for the underlying discipline this serves; the mechanics of what a reviewer may attach and how it's passed back live here. This is a real exception to "everything else stays in the schema" only in the sense that it travels IN the schema, in its own dedicated field — never as `## Notes` prose or a separate Markdown block. `lens-performance-reviewer` and `lens-test-quality-reviewer` run their own Phase-1-style profiling too, but deliberately do NOT populate this field — they re-derive fresh every round with no round-to-round reuse claim, which is a design choice, not an oversight.

## Timestamps

`first_seen` and `generated` are **date-only**, taken from the date provided to you in context — never a wall-clock time. The schema's `generated`/`first_seen` field descriptions own the exact format and the freeze-on-create rule; do not invent sub-day precision, it is not reliable and is not needed for tracking.

## What This Skill Does NOT Cover

- It does not define review **scope** — the change and its effects (`review-core`'s Review Scope), understanding intent, or the missing-diff-artifact rule → `review-core`.
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
