---
name: flow-implementation
description: "The orchestrator's procedure for BUILDING code. Bind on an explicit build/implement/refactor/fix request, or a bare \"review this\" for correctness only; also the re-entry point for addressing `flow-review` findings or `flow-spec` conformance fixes. Never seats a lens reviewer, authors a cross-repo spec, or writes tests — those are `flow-review`, `flow-spec`, and `flow-testing` respectively."
---

# Flow: Implementation

The procedure the primary agent follows to build code and hold it to a correctness floor. **Bound, not memorized.**

This is the narrowed half of what used to be one skill (`flow-orchestration`, now retired). The other half — the lens swarm — is `flow-review`, and it is **never** part of this procedure. **This skill never seats a `lens-*` reviewer.** If a lens seat looks warranted, say so and point at `flow-review`; do not seat it here.

---

## 0. When this applies — an explicit trigger, not repository state

**Bind this skill when:**

1. The request will change files (build, implement, refactor, fix, migrate, "clean up", "make it X").
2. The request is an explicit review of existing code **for correctness** ("review this" with no lens named) — the review-only variant, §6.
3. You are **re-entering** to address `flow-review` findings, or to fix a `flow-spec` conformance gap — brief the developer with the specific findings/gap instead of a fresh request; everything else in this procedure runs unchanged, **except that §1's live-testability assessment and §2's path choice do NOT re-run** — a re-entry only happens after the `{tech}-reviewer` has already joined, so it continues in the same round like any other §5 re-review.

**This skill does NOT auto-fire from repository state.** That was the previous design's failure mode: an automatic, unbounded lens swarm firing on every build regardless of size or cost. The safety property it existed to protect — nothing ships uncommitted-and-unreviewed — now lives in `flow-git-operations`'s commit gate (a cheap check, not a full re-run of this procedure) and in build-core's own validation discipline. If you made file changes outside this procedure (a direct-mode framework-prose edit, most commonly) and haven't run the review-only variant, `flow-git-operations` will ask before it lets you commit — it does not silently let unreviewed work ship, it just doesn't cost anything until a commit is actually attempted.

**The trivial hatch still applies.** A genuinely trivial change (typo, comment, formatting — no behavior change) needs no swarm: take the one-line gate (§3) and stop. **Trivial edits accumulate** — the hatch closes once THE PREDICATE (files you changed this session, not yet through this procedure) reaches 5 files, touches a contract (an invariant, a gate, a schema, a public interface, a security/authorization rule), or alters behavior rather than wording. Judge the accumulation, not the keystroke.

---

## 1. Brief yourself (dispatch NOTHING yet)

Read the request AND the code it touches. Establish:

1. **Is it trivial?** (the hatch above). Ask this first.
2. The **primary stack** → the matching `{tech}-developer` and `{tech}-reviewer`. If none exists → §6 (direct implementation). **Naming exception:** DevOps uses `devops-engineer`.
3. **What** is built/reviewed · the **scope** · the **consequence** (what it costs the user if this is wrong).
4. **Does a `flow-spec` artifact govern this work?** If the task is cross-repo, multi-tech-pair, or you were handed a spec path — bind it as the acceptance criterion for both the developer and the reviewer (path + a short navigational hint pointing at the relevant section, never the full text pasted into the dispatch — see `flow-spec`'s token-efficiency note). If no spec exists and the task doesn't call for one, proceed without it. **Exception (mandatory ask):** before dispatching 2+ parallel pairs on an unspecced effort, ask the human first — see `flow-spec` §0 for the full rule and rationale.
5. **Assess live-testability — reason about it, don't run down a checklist.** The real question: would checking this against actual, running reality tell you something the diff alone can't, and can you find that out cheaply and safely? This is open-ended judgment about THIS specific task, not a fixed test with a pass/fail line. This decides which path (§2) you recommend at the gate.

   Signals that often point toward a genuine live source — illustrative, not required, not sufficient alone; weigh what's actually true of this task:
   - The real risk is behavioral or integration correctness against something you don't fully control — an external API's actual response shape, an undocumented edge case, a version-specific quirk, how a real consumer parses your output — not just internal logic you can trace by reading.
   - You can exercise it cheaply and safely: hit the real endpoint, run the built binary, drive the actual UI, watch a real service respond — and getting it wrong the first time costs little.
   - There's genuine uncertainty about the target's true behavior that re-reading the diff harder won't resolve — you'd be guessing without it.

   Read these the other way and they point at Pair-First instead: pure internal logic with nothing external to observe, a check that would only confirm what reading the diff already told you, or a live check that's destructive, slow, or hard to undo (the "cheap and safe" clause failing is reason enough on its own). **One more standing case, regardless of the above:** if the change touches an authentication/authorization, cryptography/secret-handling, or untrusted-input path, live validation only proves the happy path — it cannot surface a bypass, a fail-open error path, or a leaked credential — so the reviewer's scrutiny is the de-risking step there, not a live check. Recommend Pair-First.

   When you land on Validate-First, **name the concrete source and the specific behavior it will exercise in the plan** — never just assert "yes, live-testable." When you land on Pair-First, state why: no live source exists, or none cheap and safe enough to use here. Either way, this is what lets the human evaluate and override your judgment with real information, not a guess. **On any doubt, recommend Pair-First** — a weak check (a build succeeding, a `--help` run) never counts as live-testability on its own, no matter how the rest of the reasoning goes.

**The consequence is your guess, and it is the weakest claim in the plan.** You can measure scope; you cannot know consequence. Put your guess where the user can correct it.

**Ground truth before you build on it.** When the work rests on a contract the code cannot confirm — an external API's shape, a data/file format, a runtime behavior — establish it against reality FIRST: probe it and fold the result into the developer's brief, or verify immediately after the first build. This orchestrator-run probe is reconnaissance, not a dispatch — it may precede the gate.

---

## 2. Roster — dev-alone-first, or the tech pair together — decided by live-testability

No lens is ever seated as part of this procedure, regardless of how substantive the change is — a substantive change earns a full `flow-review` pass later (on request), not a bigger roster here. Within that constraint, the roster is one of two named paths, chosen from §1's live-testability assessment:

**Validate-First.** A live/manual verification path exists for this task. `{tech}-developer` implements ALONE this round. Dirty, unaudited, unpolished is fine — that's the point: fast iteration and fast human feedback, with no reviewer effort spent on an approach live-testing might still redirect. The `{tech}-reviewer` is **DEFERRED, not cut** — it joins later, at §4d, after §4c's live validation and `flow-testing` have locked in the validated behavior as a regression net.

**Pair-First.** No live source — or none cheap and safe enough to use, or the change touches a security-sensitive path where a live check can't substitute for review (§1). `{tech}-developer` implements, `{tech}-reviewer` reviews, in the SAME round. Without a usable live source there is no cheap way to de-risk the implementation before investing in tests, so the reviewer's scrutiny IS that de-risking step, and it cannot be deferred.

The orchestrator recommends one path at the gate (§3) with its reasoning stated; the human can override in either direction — a trivial or unfamiliar task might warrant Pair-First even with a live source available, and vice versa.

**Correctness floor (hard).** Code correctness — wrong or inverted conditions, dropped errors, arithmetic, exhaustiveness, boundary and error paths, contract adherence — is owned ONLY by the `{tech}-reviewer`. **No real (non-trivial) build is ever DONE without it running.** Validate-First defers WHEN it runs; neither path skips WHETHER it runs.

**The correctness floor for framework PROSE.** When the change is to markdown that governs behavior — `CLAUDE.md`, a `SKILL.md`, an agent definition — there is no `{tech}-reviewer`. The floor is satisfied instead by an **execution test**: dispatch a `general-purpose` agent, give it the changed file and 3–4 realistic scenarios, and tell it to *execute* the file against them and report where it could not comply. Reading checks whether the words are right; running checks whether they do anything.

---

## 3. The gate (MANDATORY — before ANY dispatch)

**Present the plan and wait for approval before dispatching anything, developer or reviewer.**

**Proportionate to itself.** For a genuinely trivial change this is ONE LINE: *"no review / `{tech}` only — ok?"*

**Emit as LIVE MARKDOWN the terminal renders — never inside a code fence.**

> ## 🎯 Implementation Plan
>
> - **Task:** [what is being built / reviewed]
> - **Stack:** [tech + version]
> - **Scope:** [what changes · what it touches · what depends on it]
> - **Consequence:** [what it costs you if this is wrong] ← correct me
> - **Spec:** [path, if one governs this work — otherwise omit]
> - **Recommended path:** [Validate-First — name the live source and the behavior it will exercise / Pair-First — state why: no live source, or none usable here] — *omit for the review-only and Direct-implementation variants (§6), where no path split applies*
> - *Validate-First only:* **Test scope:** [repair / new authoring / both; what's covered — the same field `flow-testing` §2 would otherwise ask for]
>
> ### Seats
> - `{tech}-developer` — implements
> - `{tech}-reviewer` — correctness floor: [the specific logic at risk here] · [Validate-First: **deferred** until after live validation + `flow-testing` / Pair-First: same round]
> - *Validate-First only:* `tests-developer` + `lens-test-quality-reviewer` — bound mid-flow, after live validation, against the Test scope stated above, before the deferred reviewer; **`flow-testing` runs its OWN separate approval gate at that point — approving THIS plan does not authorize that dispatch**
>
> ### Loop
> - round 1 fix (gating findings) → round 2 verify (reviews the whole fix diff) → stop · round 3 ONLY on an open CRITICAL/HIGH
> - unfixed MEDIUM/LOW → follow-ups
> - *Validate-First only:* `flow-testing` runs its own identical bounded loop first, before the `{tech}-reviewer` loop above starts
>
> ### Next step available on request
> - a full lens review (`flow-review`) is NOT part of this plan and will not run unless you separately ask for it

**Then gate via `AskUserQuestion`** — Header "Implementation" · Question *"Is the consequence right? Approve this plan and its recommended path?"* · Options: **"Approve & run"** (the loop policy is now binding) · **"Consequence is wrong"** → re-derive, re-present · **"Switch to Validate-First/Pair-First"** → apply, re-present · **"Adjust"** or free text → apply, re-present, ask again. The Seats-block caveat above binds: this approval does not reach the mid-flow `flow-testing` dispatch (see §4c).

**Ask about CONSEQUENCE — never cost.** Never surface token or time estimates.

---

## 4. Build → expose → [Validate-First: validate → test] → review

### 4a. Delegate to the developer.

Subagents have NO conversation history — provide ALL of it: what to implement, tech version, project structure and conventions, existing patterns, integration points, and the spec (path + hint) if one governs this work. One technology per delegation. Wait for completion.

### 4b. Expose the developer's report

immediately, as received, per `build-report-standards`.

### 4c. Validate-First only — live validation, then `flow-testing`

**Skip this step entirely under Pair-First** — go straight to 4d.

**Live validation.** Check the implementation against the live source identified in §1. The confirmation that the behavior is right must be the HUMAN's own explicit in-turn statement — an orchestrator-run probe may gather evidence and report what it found, but it never supplies the confirmation itself. State plainly at this checkpoint: *"this implementation has NOT yet been correctness-reviewed — the `{tech}-reviewer` pass is still outstanding."* Iterating here — developer fixes, re-validate — is expected and cheap, but **cap it at 3 rounds of iteration before re-presenting the gate (§3)**: past that, the implementation is being redirected, not adjusted, and deserves a fresh look at whether Validate-First is still the right path.

**Then `flow-testing`.** Once the human has live-validated, bind `flow-testing` — `tests-developer` + the mandatory `lens-test-quality-reviewer` pass — to lock in the validated behavior as a regression net. This is `flow-testing`'s third valid trigger (see its §0): confirmation via live validation of a not-yet-reviewed implementation, not only after a completed tech-pair loop or a `flow-review` pass. **Binding it does NOT dispatch it.** `flow-testing` runs its own gate (`flow-testing` §3) — present its plan and get explicit approval before `tests-developer` or the reviewer touch anything. This skill's own §3 disclosure, back at the top of this flow, only told the human this step exists; it is not that step's approval.

When `flow-testing` completes, resume here at 4d — the deferred `{tech}-reviewer` joins now, with the test suite in place to validate anything its findings change. **The obligation to resume does not end when this step does** — carry the "reviewer still outstanding" statement forward into every subsequent report until §4d actually runs (see Invariants).

### 4d. Dispatch the `{tech}-reviewer` — one Task call.

Binds `review-core` + `review-report-standards`, is read-only, returns a structured report.

**The reviewer has NO shell — it cannot run `git diff`.** In DIFF/PR mode you must materialize the diff to a file and pass its absolute path. `git diff` **omits untracked files** — enumerate new files explicitly.

Give it: **exact file paths** · diff/PR or full audit, **with the diff artifact path** · **tech version + language** · the developer's **Handoff-to-Reviewer note** · the spec (path + hint), if one governs this work — conformance to it is an acceptance criterion, not just generic code quality · under Validate-First, that this implementation was already live-validated and is now covered by a `flow-testing`-authored suite (name the test files) · **prior-round findings on a re-review**, so IDs stay stable.

### 4e. Expose the report.

Render per `review-report-standards` **Rendering 1**. That skill owns the format, the grouping, the verdict arithmetic.

---

## 5. The fix loop — guaranteed, bounded

This loop starts whenever the `{tech}-reviewer` is dispatched — immediately after §4b under Pair-First, or after §4c's live-validation + `flow-testing` detour under Validate-First. The mechanics are identical either way.

**The verdict arithmetic — all three branches**, owned by `review-report-standards`:

- any open `CRITICAL`/`HIGH` → **`CHANGES_REQUIRED`** → the loop runs
- only `MEDIUM`/`LOW` open → **`APPROVED_WITH_FOLLOWUPS`** → does NOT block; list them and stop
- nothing open → **`APPROVED`** → stop

```
Round 1 is GUARANTEED whenever changes exist. The cap is 3. Both bind.

IF merged verdict == CHANGES_REQUIRED:

  round 1 · FIX     Collect EVERY finding first, then delegate in ONE batch:
                    the gating findings plus any MEDIUM/LOW you elect to fix
                    now. NEVER drip-feed fixes across separate rounds.
                    Expose the fix summary.

  round 2 · VERIFY  Re-run the {tech}-reviewer — it keeps its seat until ITS
                    gating findings are closed; you do not get to declare
                    them resolved, it does. Pass back its own prior findings
                    (stable IDs). Expose.

  ═══════════════════ STOP ═══════════════════

  round 3           ONLY if a CRITICAL/HIGH is still open. Then stop regardless.

MEDIUM/LOW you do NOT fix are follow-ups — list them, never their own round.
```

**Every fix is a change, and a change gets re-reviewed.** VERIFY re-reads the ENTIRE fix diff, whoever authored it. The one thing that legitimately defers is a MEDIUM/LOW you chose NOT to fix — safe precisely because nothing changed.

**"Satisfied" means its GATING findings are closed — not zero findings.** Every fix round produces fresh MEDIUM/LOWs; on the zero-findings reading the loop never terminates.

**When the cap is reached with the reviewer still unsatisfied, that is an ESCALATION, not an approval.** Report it plainly. Continuing past round 3 requires a new approval — not a counter you increment.

---

## 6. Variants

**Review only, correctness scope (no developer).** Triggered by *"review this"* with no lens named, or when re-entering to check a diff that was made outside this procedure (a direct-mode edit, most commonly). §1 + §3 (gate) → skip 4a/4b/4c (no developer round, so no path split applies) → 4d → 4e. This is a `{tech}-reviewer` pass, not a lens pass — if the human wants lens scrutiny, that's `flow-review`, a separate ask.

**Direct implementation (no matching subagent).** Not to be confused with Validate-First in §2 — Validate-First still has a `{tech}-reviewer`, just deferred; Direct implementation has none, ever, and self-checks instead. §1 + §3 first — the gate is NOT optional; it is MORE load-bearing, because this mode has no developer and no `{tech}-reviewer`. Present the plan with the Seats block replaced by *"no subagent exists for [stack] — I implement, and I self-check correctness myself."* Then:

1. Tell the user no specialized subagent exists for this stack.
2. Implement it, building to the shared standards — `build-core` + `standard-clean-code`, `standard-observability`, `standard-performance`, `standard-security`, `standard-testing`, `standard-persistence` (durable stores), `standard-{lang}` if one exists. **`standard-testing` here means its non-authoring guidance only — what makes the surrounding code testable (boundaries, dependency injection, avoiding hidden state), never writing the test file itself** (`build-core`'s no-test-authoring rule binds you here exactly as it binds any developer).
3. **Review it — NOT optional, NOT self-performed.** Where no `{tech}-reviewer` exists, satisfy the correctness floor with the **execution test** (§2) — a cold `general-purpose` agent running the artifact against real scenarios. A lens pass is NOT part of this step by default — that's `flow-review`, on request.
4. Summarize per `build-report-standards`.

**Cross-repo / multi-tech-pair work.** When `flow-spec` governs the effort, each repo's `{tech}-developer`/`{tech}-reviewer` pair runs this ENTIRE procedure independently and in parallel, each briefed with the same approved spec (path + hint) as its acceptance criterion. There is no cross-pair coordination beyond that shared document — each pair's own gate, loop, and executive summary are its own.

---

## 7. Executive summary

Present: the stack · the developer · the `{tech}-reviewer` · the cycle count · what was achieved · the files delivered · the final verdict with issues found vs resolved · any seat still unsatisfied at the cap · notable decisions and rationale · **whether a lens review is available and not yet run — and, only if `flow-testing` has genuinely not run at all for this effort, that test-authoring is also available.** Never report a pass that already ran mid-flow (Validate-First's `flow-testing` detour) as "not yet run."

**For a Validate-First effort, report both phases distinctly** — the live-validation outcome (what was checked, against what live source, what iteration happened before confirmation) and the subsequent reviewed-hardening cycle count — never one blended narrative that hides which phase caught what.

**If any developer report carried an open test-compilation blocker** (`build-core`'s Implementation Workflow, step 5 — the developer's own change broke an existing test and it stopped rather than touching it), surface it here explicitly, unresolved, with the repair-scope route named. This is not optional detail: `build-core`'s promise that "reporting the blocker is what resolves it" depends on this summary actually carrying it forward — a build is not DONE with a live, unsurfaced test-compilation blocker, whatever the `{tech}-reviewer` verdict says.

---

## Invariants (NEVER break)

- **Never dispatch anything without approval of the plan** (§3).
- **The roster always converges on the tech pair — never a lens.** Dev-alone-first (Validate-First) is a resequencing when a live source exists, never a way to skip the `{tech}-reviewer`; a lens seat, however warranted-looking, is `flow-review`'s call, made separately (§2).
- **Correctness floor** — the `{tech}-reviewer` is the sole owner of code correctness; this flow is not DONE until it has run, for a real change, under either path. Validate-First legitimately defers WHEN it runs (§4c); neither path skips WHETHER it runs (§2).
- **An open test-compilation blocker is never resolved by silence.** If a developer's own change broke an existing test's compilation (`build-core` Implementation Workflow step 5), the executive summary MUST surface it, unresolved, with the repair-scope route named — a `{tech}-reviewer` APPROVED verdict does not close it, and this flow is not DONE while it stands (§7).
- **On any doubt about live-testability, recommend Pair-First** — a weak check does not qualify a task for the deferral, and a security-sensitive path (auth, crypto/secrets, untrusted input) recommends Pair-First regardless of what else is true (§1).
- **Binding `flow-testing` mid-flow is not dispatching it** — that dispatch earns `flow-testing`'s own §3 gate in full; approving THIS plan never authorizes it (§4c).
- **A deferred reviewer is a carried obligation, not a memory.** Once Validate-First is approved, every subsequent report — the live-validation checkpoint, `flow-testing`'s own summary, anything in between — restates that the `{tech}-reviewer` pass is still outstanding, until §4d actually closes it (§4c).
- **Ground truth before building on it** — verify a code-unverifiable contract against reality early (§1).
- **One batched fix round; every fix is reviewed** (§5).
- **Round 1 is guaranteed; the cap is 3.** Hitting the cap unsatisfied is an escalation, never an approval (§5).
- **The reviewer keeps its seat until ITS gating findings close** — you never declare them resolved (§5).
- **Never price the review** — the gate asks about consequence, never tokens or time (§3).
- **Reviewers are read-only** and have no shell; materialize the diff for them (§4d).
- **Expose every subagent report** as it completes.
- **Direct-mode review is independent, never self-performed** (§6).
- **A spec, when one governs the work, is handed by path + hint — never pasted verbatim** into a dispatch prompt (§1).
- **2+ parallel pairs without a governing spec requires an explicit human ask, never a unilateral decision** (`flow-spec` §0 / §1).

---
*Procedure Version: 1.6 — a compatibility review of a `build-core` change found this flow's §7 executive summary had no slot for a developer-reported test-compilation blocker (`build-core` Implementation Workflow step 5), so a Pair-First build could reach DONE with a non-compiling test suite and no surviving record. Added a §7 requirement to surface any such blocker unresolved, with the repair-scope route named, plus a matching Invariants bullet. v1.5 — a third lens round on v1.4 found 4 residual issues, all fixed: §1's live-testability guidance collapsed from two mirrored bulleted lists (which read as a pro/con scorecard, the exact tally-reasoning the open-judgment framing was meant to prevent) down to one list plus a single inverse-and-caveats paragraph, adding an explicit security-sensitive-path case (auth/crypto/secrets/untrusted-input recommends Pair-First regardless, since live validation only proves the happy path); §2's Pair-First definition and §3's template widened to cover "no usable live source" (not just "none exists"), since the enrichment introduced cases — destructive/slow checks, security-sensitive paths — where a live source exists but doesn't qualify; trimmed a same-section restatement in §3 and a two-different-documents "§3" ambiguity in §4c; added an Invariants bullet stating flow-testing's gate is never pre-authorized by this flow's own approval. v1.4 — the human explicitly rejected §3's "approving this plan pre-authorizes the mid-flow `flow-testing` dispatch" design: that dispatch now ALWAYS earns its own separate approval at `flow-testing`'s own §3 gate, no exception, regardless of path. v1.3 fixed a stale §4c/§4d reviewer-join reference and disclosed test scope in the plan — both still stand; its "gate pre-satisfied" terminology work is what v1.4 superseded. v1.2 introduced the Validate-First/Pair-First naming (was "Shape A/B") and closed 6 HIGH findings across gate-disclosure and fail-closed-default mechanics. v1.1 introduced the live-testability-driven roster split itself. v1.0 was the narrowed build-only half of the retired `flow-orchestration`. Full per-version rationale: `git log -p` on this file. The lens swarm lives in `flow-review`; the cross-repo contract in `flow-spec`; test-authoring in `flow-testing`; review conduct in review-core / review-report-standards; builder conduct in build-core.*
