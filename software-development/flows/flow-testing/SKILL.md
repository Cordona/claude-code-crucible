---
name: flow-testing
description: The orchestrator's procedure for authoring tests — ONLY on the human's explicit confirmation that a `flow-implementation` result is what they expected. Bind this when the human says the implementation is right and it's time to write tests ("write tests now", "this is right, add tests", "test this"). Never fires automatically after a build or a review — tests are the last step, not a parallel one. Briefs the new `tests-developer` agent — never the `{tech}-developer`, which is structurally restricted from writing tests (build-core). Does NOT build production code (flow-implementation), review it beyond correctness (flow-review), or define test conduct/standards (standard-testing, owned by tests-developer's own binding).
---

# Flow: Testing (last, on explicit confirmation only)

The procedure the primary agent follows to get tests written. **Bound only after the human confirms the implementation is right.**

**Why tests are last, not parallel.** Writing tests against an implementation the human hasn't yet confirmed is right means testing something that might get thrown away — the exact failure this redesign exists to prevent. Deferring tests until confirmation, and handing them to an agent that never wrote the code under test, closes two problems at once: no wasted test-authoring against a wrong direction, and no test suite graded by the same party motivated to make it pass.

---

## 0. When this applies

**Bind this skill ONLY when the human has explicitly confirmed the implementation matches their intent.** This may be immediately after `flow-implementation`'s tech-pair loop, or only after one or more `flow-review` passes and their fixes — whenever the human actually says so. It does not fire because a build finished, because a review approved, or because it "seems like the natural next step."

---

## 1. Brief `tests-developer`

`tests-developer` has no conversation history — give it:
- The final, approved implementation (file paths, not pasted content).
- The tech stack in use (framework/language) so it can apply the right test-framework idioms — it is tech-agnostic and reads the relevant `standard-{tech}` file itself on this cue, rather than the orchestrator binding every `standard-{tech}` skill up front.
- The `flow-spec` artifact (path + hint), if one governs this work — its Interface contract sections become acceptance criteria the tests should actually assert, not just structural coverage.
- Any explicit test-scope guidance the human gave ("just the new code path", "the whole module").

---

## 2. The gate

For a small, single-file test addition this is a one-line confirmation, not a plan: *"writing tests for [X] against [stack] — go?"* For a larger effort, present scope (what gets covered) before dispatching, same proportionality rule as every other gate in this framework — match ceremony to stakes, not to habit.

---

## 3. Dispatch → expose

`tests-developer` writes the tests, runs them, and reports back per the same report envelope shape developers use (`build-report-standards`) — what it wrote, what it ran, pass/fail state. Expose this immediately, as received.

**This procedure does not itself review the tests.** If the human wants that — a `{tech}-reviewer` correctness pass, or `lens-test-quality-reviewer` specifically — that's a separate, explicit ask: either `flow-implementation`'s review-only variant (correctness) or `flow-review` (seating `lens-test-quality-reviewer`). Neither runs automatically here.

---

## Invariants (NEVER break)

- **Never fires before the human explicitly confirms the implementation is right** — not after a build, not after a review, regardless of how confident either looked (§0).
- **`tests-developer` writes tests. The `{tech}-developer` never does** — enforced structurally in `build-core`, backstopped in `review-core` (a test file in the developer's diff is itself a gating violation, independent of the test's content).
- **No automatic review of the tests once written** — a follow-on review is a separate, explicit ask (§3).
- **A spec, when one governs the work, is handed by path + hint — never pasted verbatim** (§1).

---
*Procedure Version: 1.0 — the last stage of the split that used to be `flow-orchestration`. Test conduct/standards live in `standard-testing`, bound by `tests-developer` itself. The restriction on `{tech}-developer` lives in `build-core`; its backstop in `review-core`.*
