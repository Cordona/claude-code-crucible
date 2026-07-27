---
name: build-report-standards
description: Uniform implementation-report contract for all developer subagents. Applies whenever a developer (rust, java, kotlin, php, react, shell, devops) reports an implementation back to the primary agent, or reports what it changed while fixing review findings. Defines the report envelope — technology, files, summary, key decisions, validation gates, and handoff-to-reviewer — as a light inline narrative (not a finding schema) so every developer reports the same way and the primary agent can brief the review swarm and track fixes across rounds. Pair with build-core (conduct/workflow).
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
| **Key decisions** | Notable choices + a one-line rationale each (architecture, trade-offs, patterns followed). |
| **Validation** | Which gates ran and their result — format · lint · type-check · test · build — plus any remaining warnings. State honestly if a gate did not run or failed. |
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
*Skill Version: 1.0*
*Pair with: build-core (conduct/workflow). Constructive twin of: review-report-standards (the reviewer's finding schema).*
