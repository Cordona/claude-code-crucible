---
name: flow-testing
description: The orchestrator's procedure for authoring tests — ONLY on the human's explicit confirmation that a `flow-implementation` result is what they expected. Bind this when the human says the implementation is right and it's time to write tests ("write tests now", "this is right, add tests", "test this"). Never fires automatically after a build or a review — tests are the last step, not a parallel one. Briefs the new `tests-developer` agent — never the `{tech}-developer`, which is structurally restricted from writing tests (build-core) — then runs a MANDATORY `lens-test-quality-reviewer` correctness pass and a bounded fix loop, the same shape as `flow-implementation`'s tech-pair loop. Does NOT build production code (flow-implementation), run a discretionary lens swarm (flow-review), or define test conduct/standards (standard-testing, owned by tests-developer's own binding) or review conduct (review-core / review-report-standards, owned by the reviewer's own binding).
---

# Flow: Testing (last, on explicit confirmation only)

The procedure the primary agent follows to get tests written **and verified**. **Bound only after the human confirms the implementation is right.**

**Why tests are last, not parallel.** Writing tests against an implementation the human hasn't yet confirmed is right means testing something that might get thrown away — the exact failure this redesign exists to prevent. Deferring tests until confirmation, and handing them to an agent that never wrote the code under test, closes two problems at once: no wasted test-authoring against a wrong direction, and no test suite graded by the same party motivated to make it pass.

**Why this flow reviews, not just writes.** The party motivated to make tests pass and the party who verifies they actually test anything cannot be the same agent — that's why `tests-developer` exists as a separate dispatch from the `{tech}-developer` in the first place. But the same logic applies one level further: `tests-developer` grading its *own* tests (even sincerely, via self-checks) is the identical failure shape, just moved one step over. A real backend session found three defects that self-checking alone missed — a repaired assertion that silently dropped a compound-index key, wired-in collaborators provably never invoked, and a test whose real failure condition drifted — none caught, because nothing independent ever looked. `flow-implementation` never ships a real build without its `{tech}-reviewer`; this flow now holds tests to the same bar.

---

## 0. When this applies

**Bind this skill ONLY when the human has explicitly confirmed the implementation matches their intent.** This may be immediately after `flow-implementation`'s tech-pair loop, or only after one or more `flow-review` passes and their fixes — whenever the human actually says so. It does not fire because a build finished, because a review approved, or because it "seems like the natural next step."

---

## 1. Roster — the test pair, and NOTHING else

Fixed by construction, same shape as `flow-implementation` §2: **`tests-developer` writes, `lens-test-quality-reviewer` reviews.** That is the entire roster. No other lens is seated as part of this procedure — a broader audit is `flow-review`'s call, made separately.

**Test-quality floor (hard).** Whether a test verifies real behavior — not implementation, not noise, not a false-confidence assertion that passes regardless of whether the behavior it names holds — is owned ONLY by `lens-test-quality-reviewer`. This procedure without it ships with ZERO verification coverage: a green suite nobody has confirmed is actually testing anything. There is no variant of this skill that omits the reviewer for a real (non-trivial) test-authoring or test-repair pass.

---

## 2. Brief `tests-developer`

`tests-developer` has no conversation history — give it:
- The final, approved implementation (file paths, not pasted content).
- The tech stack in use (framework/language) so it can apply the right test-framework idioms — it is tech-agnostic and reads the relevant `standard-{tech}` file itself on this cue, rather than the orchestrator binding every `standard-{tech}` skill up front.
- The `flow-spec` artifact (path + hint), if one governs this work — its Interface contract sections become acceptance criteria the tests should actually assert, not just structural coverage.
- Any explicit test-scope guidance the human gave ("just the new code path", "the whole module").
- **Whether this is a repair of existing tests, fresh authoring, or both** — repair carries a specific hazard (an existing assertion can silently weaken while being made to compile again) that this agent's own report is required to answer for the repaired subset (see its own binding).

---

## 3. The gate (MANDATORY — before ANY dispatch)

**Present the plan and wait for approval before dispatching anything, `tests-developer` or the reviewer.** Proportionate to itself — for a small, single-file test addition this is close to one line.

**Emit as LIVE MARKDOWN the terminal renders — never inside a code fence.**

> ## 🎯 Testing Plan
>
> - **Task:** [what gets tests — file paths]
> - **Stack:** [test framework + language]
> - **Scope:** [repair / new authoring / both; what's covered]
> - **Spec:** [path, if one governs this work — otherwise omit]
>
> ### Seats
> - `tests-developer` — writes/repairs the tests
> - `lens-test-quality-reviewer` — test-quality floor: does every assertion verify real behavior, none false-confidence, nothing weakened by repair?
>
> ### Loop
> - round 1 fix (gating findings) → round 2 verify (re-reviews the whole fix diff) → stop · round 3 ONLY on an open CRITICAL/HIGH
> - unfixed MEDIUM/LOW → follow-ups
>
> ### Next step available on request
> - a full lens review (`flow-review`) beyond test quality is NOT part of this plan and will not run unless separately asked for

**Then gate via `AskUserQuestion`** — Header "Testing" · Question *"Approve this plan?"* · Options: **"Approve & run"** (the loop policy is now binding) · **"Adjust"** or free text → apply, re-present, ask again.

**Ask about scope — never cost.** Never surface token or time estimates.

---

## 4. Write → expose → review

### 4a. Delegate to `tests-developer`.

Per §2's brief. One dispatch. Wait for completion.

### 4b. Expose `tests-developer`'s report

immediately, as received, per `build-report-standards` — including its `## Mutation Verification` block and its repair-vs-authoring answer (see the agent's own binding). If either is missing, that is itself a problem: send it back before proceeding to review.

### 4c. Dispatch `lens-test-quality-reviewer` — one Task call.

**It has NO shell — it cannot run `git diff`.** Materialize a diff artifact (the new/changed test files) to a file and pass its absolute path; `git diff` **omits untracked files** — enumerate new test files explicitly.

Give it: **the test files** (and the production files they cover) · diff/PR mode, **with the diff artifact path** · the language/test framework · **explicit confirmation that tests were expected at this review** (this flow just ran `flow-testing` — so, unlike a stray `flow-review` pass before testing, a total absence of coverage for the new behavior IS a live finding here, not the deferred-testing exception) · `tests-developer`'s repair-vs-authoring answer, so the reviewer knows where to look hardest · **prior-round findings on a re-review**, so IDs stay stable.

### 4d. Expose the report.

Render per `review-report-standards` **Rendering 1** — same format, grouping, and verdict arithmetic `flow-implementation` uses.

---

## 5. The fix loop — guaranteed, bounded

Identical mechanics to `flow-implementation` §5, `tests-developer` in the developer seat:

- any open `CRITICAL`/`HIGH` → **`CHANGES_REQUIRED`** → the loop runs
- only `MEDIUM`/`LOW` open → **`APPROVED_WITH_FOLLOWUPS`** → does NOT block; list them and stop
- nothing open → **`APPROVED`** → stop

```
Round 1 is GUARANTEED whenever changes exist. The cap is 3. Both bind.

IF merged verdict == CHANGES_REQUIRED:

  round 1 · FIX     Re-dispatch tests-developer with EVERY finding in ONE batch —
                    the gating findings plus any MEDIUM/LOW you elect to fix now.
                    NEVER drip-feed fixes across separate rounds. It reports fresh
                    Mutation Verification for every assertion it touched fixing
                    this round — a fix to an assertion is itself a changed
                    assertion. Expose the fix summary.

  round 2 · VERIFY  Re-run lens-test-quality-reviewer — it keeps its seat until
                    ITS gating findings are closed; you do not get to declare
                    them resolved, it does. Pass back its own prior findings
                    (stable IDs). Expose.

  ═══════════════════ STOP ═══════════════════

  round 3           ONLY if a CRITICAL/HIGH is still open. Then stop regardless.

MEDIUM/LOW you do NOT fix are follow-ups — list them, never their own round.
```

**Every fix is a change, and a change gets re-reviewed.** VERIFY re-reads the ENTIRE fix diff. The one thing that legitimately defers is a MEDIUM/LOW you chose NOT to fix — safe precisely because nothing changed.

**"Satisfied" means its GATING findings are closed — not zero findings.** Every fix round can produce fresh MEDIUM/LOWs; on the zero-findings reading the loop never terminates.

**When the cap is reached with the reviewer still unsatisfied, that is an ESCALATION, not an approval.** Report it plainly. Continuing past round 3 requires a new approval — not a counter you increment.

---

## 6. Executive summary

Present: the stack · `tests-developer` · `lens-test-quality-reviewer` · the cycle count · what was written/repaired · the files delivered · the final verdict with issues found vs. resolved · any seat still unsatisfied at the cap · the mutation-verification and repair-vs-authoring answers · **whether a broader lens review (`flow-review`) is available and not yet run** (so the human knows it exists as a next step, without it having auto-fired).

---

## Invariants (NEVER break)

- **Never fires before the human explicitly confirms the implementation is right** — not after a build, not after a review, regardless of how confident either looked (§0).
- **The roster is the test pair, full stop — never a broader lens.** A lens seat beyond `lens-test-quality-reviewer`, however warranted-looking, is `flow-review`'s call, made separately (§1).
- **`tests-developer` writes tests. The `{tech}-developer` never does** — enforced structurally in `build-core`, backstopped in `review-core` (a test file in the developer's diff is itself a gating violation, independent of the test's content).
- **Test-quality floor** — `lens-test-quality-reviewer` is the sole owner of whether a test verifies real behavior; no variant of this skill ships without it for a real test-authoring or repair pass (§1). **This is a floor built into this flow, not a discretionary lens seat** — the same relationship `{tech}-reviewer` has to `flow-implementation`, not the relationship an on-demand lens has to `flow-review`.
- **Round 1 is guaranteed; the cap is 3.** Hitting the cap unsatisfied is an escalation, never an approval (§5).
- **The reviewer keeps its seat until ITS gating findings close** — you never declare them resolved (§5).
- **Never price the review** — the gate asks about scope, never tokens or time (§3).
- **The reviewer is read-only** and has no shell; materialize the diff for it (§4c).
- **A total absence of coverage for the new behavior IS a live finding here** — unlike a `flow-review` pass run before testing, this flow's own reviewer runs *because* testing just happened; tell it so explicitly (§4c).
- **`tests-developer` must report Mutation Verification and its repair-vs-authoring answer every dispatch** — a report missing either is incomplete, send it back before reviewing (§4b).
- **Expose every subagent report** as it completes.
- **A spec, when one governs the work, is handed by path + hint — never pasted verbatim** (§2).

---
*Procedure Version: 2.0 — added the mandatory `lens-test-quality-reviewer` correctness pass and bounded fix loop (mirroring `flow-implementation` §4–§5), closing a real gap: this flow previously shipped tests with zero independent verification, relying on `tests-developer`'s own self-check. Prompted by field feedback from a session where self-checked repairs silently weakened three assertions undetected. Test conduct/standards live in `standard-testing` + `tests-developer`'s own Mutation Verification/repair-vs-authoring reporting requirement; review conduct in `review-core` / `review-report-standards`. The restriction on `{tech}-developer` writing tests lives in `build-core`; its backstop in `review-core`.*
