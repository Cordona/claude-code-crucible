---
name: review-boundaries
description: Decides which lens scores a finding two lenses could both claim. Bind alongside review-core and review-report-standards whenever a lens reviewer runs as part of a swarm. Does NOT define reviewer conduct (review-core), report format/severity (review-report-standards), or what good looks like in a domain (the standard-* rubrics).
---

# Review Boundaries — the lens ownership map

## Overview

Bind this alongside `review-core` (conduct) and `review-report-standards` (report format). Those two say *how* to behave and *how* to report. This one says **who owns a finding when two lenses could both claim it**.

**Why this exists as ONE document.** Every lens is dispatched independently and never reads another lens's file, so each boundary has to be legible from inside whichever lens is running. The tempting fix is to write the boundary into both lenses — and that is exactly what fails: a restated boundary drifts, silently, even under careful attention, and then two lenses grade one defect at `HIGH` under two different prefixes. Prefix-keyed dedup cannot merge those. So the boundary is stated **once, here**, and each lens **binds** it rather than paraphrasing it.

## The rule: defer, do not double-flag

When the table below gives a territory to another lens: **do not score it.** Put it in your `## Notes` as a Handoff line (per `review-core`) and move on. Your report should contain the findings you own — no more, no less.

**Why double-flagging is a real defect, not a cosmetic one.** Two findings for one defect inflate the merged gating set, spend a fix round twice, and present the human a report where the same problem appears under two IDs with possibly *different severities and contradictory fixes*. That is worse than the finding being raised once by the lens that reasons about it best.

## Contested territories

| Territory | Owner | Everyone else |
|-----------|-------|---------------|
| **Access patterns against a durable store** — N+1, over-fetch, unbounded reads, unsafe pagination, projection | `lens-persistence` — it judges through the store's **actual guarantees**; the same query is a defect on one engine and correct on another | `lens-performance` defers |
| **Access patterns touching NO store** — N+1 over an HTTP client, in-memory work-in-loop, quadratic algorithms, chatty I/O to a non-store peer | `lens-performance` | `lens-persistence` defers |
| **A migration's DATA/store axis** — backfill correctness, lock/rewrite cost, the destructive-op guard, old+new coexistence for **the application's own code** (incl. its own rolling deploy) | `lens-persistence` | `lens-compatibility` defers |
| **A migration's CONSUMER axis** — a dropped/renamed/retyped column that breaks a reader **outside this change**: a downstream service, another team, a published contract | `lens-compatibility` | `lens-persistence` defers |
| **Code correctness** — wrong or inverted conditions, dropped/unhandled errors, arithmetic and overflow, exhaustiveness, boundary and error-path completeness, contract adherence | **the `{tech}`-reviewer** | **EVERY lens defers.** No lens is the correctness floor, including one whose own domain contains the word "correctness" (`lens-persistence` owns *data*-layer correctness — a different axis, never a substitute) |
| **Comments, docstrings, and naming-as-documentation** — is a specific comment/docstring redundant, disproportionate, duplicated, or a required one missing; OR does a name (a variable, a magic literal with no named constant) fail to carry the meaning that would otherwise force a comment — in ANY file, production or test | `lens-self-documenting-code` — the one lens with jurisdiction over this territory regardless of file type | `lens-clean-code` defers (production files); `lens-test-quality` defers (test files) — neither scores a comment/docstring/naming/magic-literal finding even on a file it otherwise reviews for structure |
| **Whether a test reads as behavioral documentation** — does the test's own structure/naming communicate the behavior under test, independent of any comment | `lens-test-quality` — this is "tests-as-documentation," a test-structure concern, not a comment-proportionality one | `lens-self-documenting-code` defers — it judges individual comments/docstrings, not whether a test's own structure documents behavior |

**The two migration rows are a partition, not an overlap:** "the app's own code" and "a reader outside this change" are disjoint and together total. If you cannot tell which side a reader falls on, it is outside — hand it to `lens-compatibility`.

**The two comment/documentation rows are a partition too, with a stated tie-breaker:** an individual comment or docstring's own content (redundant, disproportionate, duplicated, missing) is row 5's; a test's own identifier or structure communicating behavior, independent of any comment, is row 6's. A test method's NAME is the recurring ambiguous case — it is naming, which row 5 claims, but it is also how a test documents its own behavior, which row 6 claims. **If you cannot tell which side it falls on, it is row 6's** (test-structure, not comment-proportionality) — this mirrors the migration pair's own "if you cannot tell, hand it to the CONSUMER-axis owner" fallback above.

## Rule: not on the roster → disclose, never silently cover

The orchestrator may seat the owning lens or may not. **You never silently absorb a territory you deferred.**

- Owner **is** seated → defer silently. It has it.
- Owner is **NOT** seated → still do not score it. Say so in your `## Notes`: *"`lens-persistence` was not on this roster; the store access patterns in `repo.kt:88` are unreviewed."*

**Why not just cover it yourself?** Because the depth is not equivalent, and a finding filed by the wrong lens carries false authority. `lens-performance` grading a store query without the store's guarantees produces a confident guess. A stated gap is honest and the human can seat the lens. A silently-covered gap looks identical to real coverage — and coverage that only looks real is the defect this framework exists to prevent.

## Rule: your bound `standard-*` is NOT narrowed by this table

Your domain rubric may name territory this table gives to someone else. `standard-performance`, for instance, names SQL N+1 as a scaling rule — and `lens-persistence` owns SQL N+1 in a swarm. **That is not a contradiction, and you must not read it as one.**

- The **`standard-*`** says *what good code looks like*. **Developers bind it too**, and they must build all of it. It is not scoped to the swarm and must never be narrowed to match this table.
- **This table** says *who scores a deviation when a swarm reviews*. It is a routing rule among reviewers, nothing more.

So: judge against your full standard, then **file only what you own**, and hand off the rest.

## What this skill does NOT cover

- Reviewer conduct, diff scope, finding quality, the handoff mechanism → `review-core`.
- Report format, finding schema, stable IDs, the severity scale → `review-report-standards`.
- What good looks like in a domain → the matching `standard-*`.
- Whether a lens gets a **seat** at all → the orchestrator, from each lens's declared Applicability (`flow-review` §3) — it reads **descriptions only** and cannot follow a pointer into this skill. So: **a territory's owner MUST advertise that territory in its own description.** Moving a row in this table is therefore never just a scoring change — if the new owner's description doesn't already cover it, the territory becomes unseatable and nobody reviews it.

## Constraints (NEVER violate)

- Do NOT score a territory this table assigns elsewhere — hand it off.
- Do NOT silently cover a deferred territory when its owner is absent — disclose it in `## Notes`.
- Do NOT paraphrase this table into your own body. Bind it. A copy drifts.
- Do NOT treat a conflict between this table and your `standard-*` as a contradiction — the standard defines the bar, this table routes the finding.

---
*Skill Version: 1.2 — a lens review of v1.1 found two issues in the same round: the two new rows referenced lenses by full agent name (`lens-self-documenting-code-reviewer`, etc.) instead of the short form every other row in this file uses (100% consistent before v1.1) — reworded to match; and the pair carried no partition statement, unlike the migration pair above, so a test method's NAME (simultaneously "naming," row 5's claim, and "how a test documents its behavior," row 6's claim) could be double-flagged — added an explicit tie-breaker sentence, defaulting ambiguous cases to row 6.*
*Skill Version: 1.1 — added the comments/docstrings/naming-as-documentation row (owner: the newly-extracted `lens-self-documenting-code-reviewer`, which — unlike every other lens here — claims jurisdiction regardless of file type, production or test) and its adjacent "tests-as-documentation" row (owner: `lens-test-quality-reviewer`, a test-structure concern distinct from comment proportionality). Extracted alongside `standard-self-documenting-code` out of `standard-clean-code`/`lens-clean-code-reviewer`, closing the gap where test files had zero comment-discipline review. Note: `lens-test-quality-reviewer` does not yet bind this skill as of this version — its own binding + `standard-clean-code` binding for test-file structural review is a planned, disclosed follow-up, not yet wired.*
*Skill Version: 1.0*
*Pair with: review-core (conduct) + review-report-standards (report format). The third of the reviewer-family contracts: how to behave · how to report · what you own.*
