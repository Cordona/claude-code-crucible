---
name: build-report-standards
description: Defines the inline narrative report a developer subagent gives the primary agent after building or fixing review findings. Bind alongside build-core (HOW to build) — this owns HOW to report it. Does not define the reviewer's finding schema (review-report-standards).
---

# Build Report Standards

## Overview

This skill defines HOW every developer subagent reports back to the primary agent after implementing or refactoring code. It exists so developer reports are uniform across languages and easy for the primary agent to expose to the user and to hand to the review swarm.

It is the constructive twin of `review-report-standards` — but deliberately **lighter**. A reviewer emits machine-mergeable findings (stable IDs, status lifecycle, verdict arithmetic, JSON) because many reviewers' outputs are merged and tracked across rounds. A developer emits ONE narrative report, consumed once — so this contract is a concise prose envelope, NOT a finding schema. Bind this from any developer alongside `build-core`.

## Absolute Mandates

- **INLINE ONLY.** Emit the report in your response text. NEVER write a report file to disk (no `.md`/`.json` artifact) — documentation is the docs-writer's job, not this contract.
- **TOKEN-DISCIPLINED.** Be concise: one line per file, a few sentences of summary, no restating large code blocks. The primary agent skims this to brief reviewers.

## The Implementation Report (canonical shape)

Report these fields, in this order:

| Field | Content |
|-------|---------|
| **Technology** | Language/framework + version (e.g. Rust 2021, Tokio). |
| **Files created/modified** | One line per file: `path` — purpose. |
| **What was implemented** | 2–3 sentences: what and why. |
| **Key decisions** | Notable choices + a one-line rationale each (architecture, trade-offs, patterns followed). **If `build-core`'s comment-economy self-check deferred a rationale to the commit/PR message instead of the file** (Implementation Workflow, step 4), name it here explicitly (`"kept in-file: X; deferred to the commit/PR message: Y"`) — the primary agent carries `Y` forward into whichever `git-operator` brief actually lands it: the commit brief (`flow-git-operations` G2) or the PR/MR brief (the Pull-Request/Merge-Request Path), whichever destination still exists. |
| **Validation** | Which gates ran and their result — format · lint · type-check · test · build — plus any remaining warnings. State honestly if a gate did not run or failed. **If your own change broke an EXISTING test's compilation** (`build-core`'s Implementation Workflow, step 5), report it here as an open blocker, not a failed-but-complete gate: name each broken call site and mechanically why, and state that fixing it needs a `tests-developer` dispatch with repair scope. The primary agent MUST carry this forward into its own executive summary — it is not resolved by this report alone. |
| **Handoff to reviewer** | What the review swarm should focus on: areas of concern, trade-offs you made, and any contract/convention conflict you surfaced (per `build-core`). This is the dev→review contract. |

## Rendering (default)

**Emit this as LIVE MARKDOWN — never inside a code fence.** The `>` marks below delimit the spec *here*; they are not part of what you emit. A fence turns a report a human is meant to read into a grey copy-box, and any table inside one renders as raw pipes.

> ## Implementation Report — {tech}
>
> **Files**
> - `src/order/service.rs` — order-placement service + validation
> - `src/order/mod.rs` — module wiring
>
> **What & why**
> Added an idempotent order-placement path so retried requests don't double-charge.
> Validation happens at the handler boundary; the service stays pure.
>
> **Key decisions**
> - Newtype `OrderId(Uuid)` for type-safe IDs — prevents mixing with `UserId`.
> - `thiserror` domain errors surfaced as `Result` — no panics on the library path.
>
> **Validation**
> - fmt ✅ · clippy ✅ (0 warnings) · test ✅ (14 passed) · build ✅ (release)
>
> **Handoff to reviewer**
> - Focus: the retry/idempotency logic in `place_order` (concurrency).
> - Trade-off: chose an in-memory dedup cache; flagged as a follow-up for a durable store.
> - Surfaced: existing `PaymentRepo` bypasses the service layer — did NOT change it (out of scope); noted for consistency review.


## Reporting a Fix Round (re-review loop)

When the primary agent hands you review findings to fix, close the loop so the re-review can track them (see `review-report-standards`):

- Reference each finding by its **reviewer-assigned ID** and say what you changed:
  `RUST-003 (HIGH) — fixed: replaced unwrap() with ? and a thiserror variant in parse_config.`
- If you deliberately did NOT fix one, say so and why (the reviewer will mark it `ACK`).
- Then give the normal **Validation** line for the changed files.

Do NOT invent your own finding IDs — reuse the reviewer's so IDs stay stable across the loop.

## What This Skill Does NOT Cover

- It does not define HOW to build (that is `build-core` + the concern skills).
- It does not define the reviewer's finding schema (that is `review-report-standards`) — in a fix round you *consume* those IDs; you do not *emit* findings.

## Constraints (NEVER Violate)

- Do NOT write the report to a file — inline only.
- Do NOT pad with restated code or boilerplate — one line per file, terse summary.
- Do NOT omit the Validation line, or claim gates passed that you did not run.
- Do NOT drop the Handoff-to-reviewer block — it is the dev→review contract.
- Do NOT renumber or invent finding IDs in a fix round — reuse the reviewer's.

---
*Skill Version: 1.3 — a round-4 consistency-lens sweep found this row still named only the `git-operator` commit brief as the deferred rationale's destination, after `flow-git-operations` 1.8 gave it a second one (a PR/MR body, when the commits it was meant for are already landed) — widened to name both.*
*Skill Version: 1.2 — a consistency-lens finding on the comment-volume fix found `build-core` v1.4 promised a developer's deferred-to-commit rationale would reach the `git-operator` commit brief via the Key decisions field, without this skill (the field's owner) or `flow-git-operations` actually being amended to receive it — the identical shape of gap the v1.1 entry below already fixed once for the Validation field. Added the receiving clause to the Key decisions row, mirroring that precedent; `flow-git-operations` G2's brief list is amended in the same round.*
*Skill Version: 1.1 — added a required disclosure to the Validation field for when a developer's own change breaks an existing test's compilation (`build-core`'s Implementation Workflow, step 5): report it as an open blocker with the repair-scope route named, since `build-core` promises this report is what surfaces it — a promise this version makes true by requiring the field and requiring `flow-implementation` §7 to carry it forward.*
*Pair with: build-core (conduct/workflow). Constructive twin of: review-report-standards (the reviewer's finding schema).*
