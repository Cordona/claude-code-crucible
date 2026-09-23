---
name: flow-testing
description: The orchestrator's procedure for authoring tests. Bind ONLY on the human's explicit confirmation that a `flow-implementation` result is right — a completed tech-pair loop, a review pass, or live validation of a not-yet-reviewed Validate-First result — never automatically after a build or review. Briefs `tests-developer`, never the `{tech}-developer`, then runs a mandatory `lens-test-quality-reviewer` fix loop. Does NOT build production code (`flow-implementation`), run the discretionary lens swarm (`flow-review`), or define test/review conduct or standards (standard-testing, build-core, review-core, review-report-standards).
---

# Flow: Testing (on explicit confirmation only)

The procedure the primary agent follows to get tests written **and verified**. **Bound only after the human confirms the implementation is right.**

**Why tests follow confirmation, never precede it.** Writing tests against an implementation the human hasn't yet confirmed is right means testing something that might get thrown away. Deferring tests until confirmation, and handing them to an agent that never wrote the code under test, closes two problems at once: no wasted test-authoring against a wrong direction, and no test suite graded by the same party motivated to make it pass.

**Why this flow reviews, not just writes.** The party motivated to make tests pass and the party who verifies they actually test anything cannot be the same agent — that's why `tests-developer` exists as a separate dispatch from the `{tech}-developer` in the first place. But the same logic applies one level further: `tests-developer` grading its *own* tests (even sincerely, via self-checks) is the identical failure shape, just moved one step over — a repaired assertion can silently drop a compound-index key, a wired-in collaborator can end up never invoked at all, or a test's real failure condition can drift, none of it caught because nothing independent ever looked. `flow-implementation` never ships a real build without its `{tech}-reviewer`; this flow holds tests to the same bar.

---

## 0. When this applies

**Bind this skill ONLY when the human has explicitly confirmed the implementation matches their intent.** Three shapes of confirmation are equally valid:

1. Immediately after `flow-implementation`'s tech-pair loop (Pair-First there).
2. After one or more `flow-review` passes and their fixes.
3. **After live validation** of a `flow-implementation` Validate-First result whose `{tech}-reviewer` pass hasn't run yet (`flow-implementation` §2/§4c). Here confirmation comes from the human's live-test result, not from a completed correctness review — and `flow-implementation` resumes AFTER this flow to run its deferred `{tech}-reviewer` pass, with the tests just written as its regression net.

It does not fire because a build finished, because a review approved, or because it "seems like the natural next step."

---

## 1. Roster — the test pair, and NOTHING else

Fixed by construction — unlike `flow-implementation` §2's two-path roster: **`tests-developer` writes, `lens-test-quality-reviewer` reviews.** That is the entire roster. No other lens is seated as part of this procedure — a broader audit is `flow-review`'s call, made separately.

**Test-quality floor (hard).** Whether a test verifies real behavior — not implementation, not noise, not a false-confidence assertion that passes regardless of whether the behavior it names holds — is owned ONLY by `lens-test-quality-reviewer`. This procedure without it ships with ZERO verification coverage: a green suite nobody has confirmed is actually testing anything. There is no variant of this skill that omits the reviewer for a test-authoring or test-repair pass.

---

## 2. Brief `tests-developer`

`tests-developer` has no conversation history — give it:
- The final, approved implementation (file paths, not pasted content).
- The tech stack in use (framework/language) so it can apply the right test-framework idioms — it is tech-agnostic and reads the relevant `standard-{tech}` file itself on this cue, rather than the orchestrator binding every `standard-{tech}` skill up front.
- The `flow-spec` artifact (path + hint), if one governs this work — its Interface contract sections become acceptance criteria the tests should actually assert, not just structural coverage.
- Any explicit test-scope guidance the human gave ("just the new code path", "the whole module").
- **Whether this is a repair of existing tests, fresh authoring, or both** — repair carries a specific hazard (an existing assertion can silently weaken while being made to compile/pass again) that this agent's own report is required to answer for the repaired subset (see its own agent body).

---

## 3. The gate (MANDATORY — before ANY dispatch)

**Present the plan and wait for approval before dispatching anything, `tests-developer` or the reviewer.** Proportionate to itself — for a small, single-file test addition this is close to one line.

**This gate ALWAYS fires — including when triggered from `flow-implementation`'s Validate-First path (that skill's §4c).** Approving the Validate-First PLAN at `flow-implementation`'s own §3 gate is NOT itself approval to dispatch `tests-developer` — that plan only discloses that this step exists and roughly what it will do. Every path — Pair-First's tech-pair loop, a `flow-review` pass, or Validate-First's live validation — earns this gate in full, every time, confirmed here when this step is actually reached.

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
> - exception: an open `false-confidence` or `repair-weakening` finding enters round 1 even at `APPROVED_WITH_FOLLOWUPS` (§5) — this flow does not defer that MEDIUM to a follow-up
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

immediately, as received, per `build-report-standards` — including its Mutation Verification field and its repair-vs-authoring answer (see its own agent body). If either is missing, that is itself a problem: send it back before proceeding to review. **If the Validation field reports the implementation itself is wrong or untestable, that is not fixable here** — carry it into the executive summary unresolved (§6) and route it by re-entering `flow-implementation` §0 case 1, briefed exactly per §5's two-precondition requirement (Pair-First recommended explicitly, diff artifact scoped to the whole originally-unreviewed implementation) so that re-entry's own reviewer pass can discharge the deferred obligation — see §5 for why `flow-implementation`'s case 3 doesn't fit here and for the full requirement text. Absent either precondition, the deferred obligation is NOT discharged and §6 must not report it as such. Do not proceed to write tests against code the developer flagged as wrong.

### 4c. Dispatch `lens-test-quality-reviewer` — one Task call.

Binds `review-core` + `review-report-standards` + `review-boundaries`, is read-only, returns a structured report.

**No shell, cannot read a diff itself** — `review-core`'s own Review Scope rule. Materialize a diff artifact (the new/changed test files) to a file and pass its absolute path; `git diff` **omits untracked files** — enumerate new test files explicitly.

Give it: **the test files** (and the production files they cover) · diff/PR mode, **with the diff artifact path** · the language/test framework · the `flow-spec` artifact (path + hint), if one governs this work — the reviewer judges missing-coverage against the same Interface contract `tests-developer` built to · the project's testing guide / conventions doc, if one exists · **explicit confirmation that tests were expected at this review** (this flow just authored or repaired the tests — so, unlike a stray `flow-review` pass before testing, a total absence of coverage for the new behavior IS a live finding here, not the deferred-testing exception) · `tests-developer`'s repair-vs-authoring answer, so the reviewer knows where to look hardest · **prior-round findings on a re-review**, so IDs stay stable.

Note the roster's known gap: comment/docstring/naming discipline in the new test files is `lens-self-documenting-code-reviewer`'s territory per `review-boundaries`, and that lens is not part of this fixed roster — it goes unreviewed unless a separate `flow-review` pass is run (mention this in §6).

### 4d. Expose the report.

Render per `review-report-standards` **Rendering 1** — same format, grouping, and verdict arithmetic `flow-implementation` uses.

---

## 5. The fix loop — guaranteed, bounded

Identical mechanics to `flow-implementation` §5, `tests-developer` in the developer seat — **for test findings.** A HIGH finding that is actually a masked production defect (the reviewer's one conditional path to HIGH — `lens-test-quality-reviewer`'s own Severity Guidance) or a production bug named in the reviewer's Handoff is NOT a `tests-developer` fix-round item — `tests-developer` cannot touch production code at all. Pull it out of this loop immediately: report it, and route it by re-entering `flow-implementation` §0 case 1 (briefed with the specific finding as the fix request, not a fresh task) — `flow-implementation`'s case 3 doesn't fit here because it assumes the `{tech}-reviewer` has already joined, which is false on the Validate-First path (this skill's own §0 case 3 above) that most often produces this blocker. **If this run was triggered via that Validate-First path, brief the case-1 re-entry with two things it would not otherwise get by default:** recommend Pair-First for it explicitly (its §4d must not be deferred a second time — a re-deferral just recreates the same open obligation), and scope its diff artifact to the WHOLE originally-unreviewed implementation, not merely the fix delta — only then does that re-entry's own `{tech}-reviewer` pass (§4d) review the corrected implementation in full and discharge this flow's originally-deferred reviewer obligation (§0 case 3, §6); absent both, a second, separate deferred-reviewer pass is still owed. The remaining test-only findings (if any) still run this loop normally.

**This seat's findings are MEDIUM by construction** (`lens-test-quality-reviewer`'s own severity scale — a test gap ships no defect today). That means `APPROVED_WITH_FOLLOWUPS` is this flow's normal steady state, not a sign the loop is toothless. But a false-confidence test or a repair that silently stopped verifying its original behavior (`repair-weakening`) is exactly the kind of MEDIUM this flow does not leave to a follow-up: **treat an open `false-confidence` or `repair-weakening` finding as a flow-local override of the loop-entry predicate below** — it enters round 1 FIX even when the merged verdict is `APPROVED_WITH_FOLLOWUPS`, because the mechanical hazard it names (§4c) is exactly what this flow exists to catch before calling itself done. Any other MEDIUM/LOW still follows the normal arithmetic.

**The verdict arithmetic** is owned by `review-report-standards` and already restated once, where CLAUDE.md's own Invariants name it as sanctioned, at `flow-implementation` §5 — not copied a third time here.

```
The reviewer pass is guaranteed whenever changes exist; a FIX round is
guaranteed whenever a gating finding exists. The cap is 3. Both bind.

IF merged verdict == CHANGES_REQUIRED
   OR an open false-confidence / repair-weakening finding exists (flow-local override, above):

  round 1 · FIX     Re-dispatch tests-developer with EVERY finding in ONE batch —
                    the gating findings plus any MEDIUM/LOW you elect to fix now.
                    NEVER drip-feed fixes across separate rounds. This round is
                    itself repair-scoped for reporting purposes regardless of why
                    the assertion is being rewritten: fresh Mutation Verification
                    AND the repair-vs-authoring answer for every assertion touched
                    fixing this round — a fix to an assertion is itself a changed
                    assertion. Expose the fix summary.

  round 2 · VERIFY  Re-run lens-test-quality-reviewer — it keeps its seat until
                    ITS gating findings are closed; you do not get to declare
                    them resolved, it does. Pass back its own prior findings
                    (stable IDs), AND restate that round 1 was repair-scoped —
                    so it applies repair-weakening scrutiny to every assertion
                    the fix round touched, not only ones broken by the original
                    implementation change. Expose.

  ═══════════════════ STOP ═══════════════════

  round 3           ONLY if a CRITICAL/HIGH is still open. Then stop regardless.

MEDIUM/LOW you do NOT fix are follow-ups — list them, never their own round.
```

**Every fix is a change, and a change gets re-reviewed.** VERIFY re-reads the ENTIRE fix diff. The one thing that legitimately defers is a MEDIUM/LOW you chose NOT to fix — safe precisely because nothing changed.

**"Satisfied" means its GATING findings are closed — not zero findings.** Every fix round can produce fresh MEDIUM/LOWs; on the zero-findings reading the loop never terminates.

**When the cap is reached with the reviewer still unsatisfied, that is an ESCALATION, not an approval.** Report it plainly. Continuing past round 3 requires a new approval — not a counter you increment.

---

## 6. Executive summary

Present: the stack · `tests-developer` · `lens-test-quality-reviewer` · the cycle count · what was written/repaired · the files delivered · the final verdict with issues found vs. resolved · any seat still unsatisfied at the cap · the mutation-verification and repair-vs-authoring answers · **whether a broader lens review (`flow-review`) is available and not yet run** (so the human knows it exists as a next step, without it having auto-fired) · **any unresolved implementation-wrong/untestable blocker from `tests-developer`'s Validation field, or a masked-defect/production finding from the reviewer** — named explicitly, with the `flow-implementation` re-entry route stated, never silently dropped.

**When triggered via §0 case 3 (Validate-First), lead the summary with an explicit, unambiguous statement — keep this exact lead in every case: "the production code has NOT yet been correctness-reviewed — `flow-implementation`'s deferred `{tech}-reviewer` pass is still outstanding, and this diff is not commit-eligible until it closes."** Never let a green test verdict here read as "the build is done." Then state who runs that pass next, in the branch that applies:
- **Normal case:** `flow-implementation` resumes now to run its deferred pass at its §4d.
- **If this run also exited early via §4b or §5's case-1 re-entry** (an implementation-wrong/untestable blocker or a masked-defect finding), briefed exactly per §5's two-precondition requirement: that re-entry's own `{tech}-reviewer` pass **supersedes** the deferred obligation once it closes (`flow-implementation` §4c's own exception clause names this the same way) — do not also say `flow-implementation` "resumes at its §4d" for this branch, and do not present both as separately outstanding. If either precondition was NOT actually briefed, the obligation is still outstanding exactly as in the normal case — report it that way, not as discharged.

---

## Invariants (NEVER break)

- **Never fires before the human explicitly confirms the implementation is right** — not after a build, not after a review, regardless of how confident either looked (§0).
- **The roster is the test pair, full stop — never a broader lens.** A lens seat beyond `lens-test-quality-reviewer`, however warranted-looking, is `flow-review`'s call, made separately (§1).
- **`tests-developer` writes tests. The `{tech}-developer` never does** — enforced structurally in `build-core`, backstopped in `review-core`'s own Structural Tripwire section.
- **Test-quality floor** — `lens-test-quality-reviewer` is the sole owner of whether a test verifies real behavior; no variant of this skill ships without it for a test-authoring or repair pass (§1). **This is a floor built into this flow, not a discretionary lens seat** — the same relationship `{tech}-reviewer` has to `flow-implementation`, not the relationship an on-demand lens has to `flow-review`.
- **§3's gate ALWAYS fires — no trigger, including Validate-First, ever pre-satisfies or skips it.** Approving `flow-implementation`'s plan is never itself approval to dispatch `tests-developer` (§3).
- **Triggered via §0 case 3, this flow hands control back explicitly** — its own executive summary always states the `{tech}-reviewer` pass is still outstanding, never a bare "tests done" that could be mistaken for "build done"; it names `flow-implementation` resuming at its §4d as the normal case, EXCEPT when this run also exited via §4b/§5's case-1 re-entry, in which case that re-entry's own reviewer pass supersedes the obligation instead — but only under BOTH of §5's preconditions; absent either, it stays outstanding as in the normal case (§6).
- **The reviewer pass is guaranteed whenever changes exist; a FIX round on a gating finding — or on §5's flow-local false-confidence/repair-weakening override. The cap is 3.** Hitting it unsatisfied is an escalation, never an approval (§5).
- **The reviewer keeps its seat until ITS gating findings close** — you never declare them resolved (§5).
- **Never price the review** — the gate asks about scope, never tokens or time (§3).
- **The reviewer is read-only** and has no shell; materialize the diff for it (§4c).
- **A total absence of coverage for the new behavior IS a live finding here** — unlike a `flow-review` pass run before testing, this flow's own reviewer runs *because* testing just happened; tell it so explicitly (§4c).
- **`tests-developer` must report Mutation Verification every dispatch, and the "did it stop verifying" answer whenever the dispatch involved repair** — a report missing either where required is incomplete, send it back before reviewing (§4b).
- **An implementation-wrong/untestable blocker or a masked-defect/production finding is never fixed inside this flow** — it exits to `flow-implementation`, named explicitly in the executive summary (§4b, §5, §6).
- **Expose every subagent report** as it completes.
- **A spec, when one governs the work, is handed by path + hint — never pasted verbatim** (§2).

---
*Test conduct/standards live in `standard-testing` + `tests-developer`'s own Mutation Verification/repair-vs-authoring reporting requirement; review conduct in `review-core` / `review-report-standards`; the restriction on `{tech}-developer` writing tests lives in `build-core`, backstopped in `review-core`.*
