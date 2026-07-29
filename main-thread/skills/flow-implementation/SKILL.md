---
name: flow-implementation
description: The orchestrator's procedure for BUILDING code — developer + `{tech}-reviewer` only, never a lens. Bind this on an explicit build/implement/refactor/fix request, or a bare "review this" for correctness only. Covers briefing, deriving the tech-pair roster (never lenses — those are `flow-review`'s job, on-demand only), the mandatory approval gate, delegation to a `{tech}-developer`, the `{tech}-reviewer`'s bounded 3-round fix loop, direct implementation when no subagent fits, and the executive summary. Also the re-entry point when addressing `flow-review` findings or `flow-spec` conformance fixes — same procedure, briefed with the specific findings instead of a fresh request. It does NOT run the lens swarm (`flow-review`), author a cross-repo contract (`flow-spec`), write tests (`flow-testing`), or define review conduct/report schemas (review-core, review-report-standards) or builder conduct (build-core).
---

# Flow: Implementation

The procedure the primary agent follows to build code and hold it to a correctness floor. **Bound, not memorized.**

This is the narrowed half of what used to be one skill (`flow-orchestration`, now retired). The other half — the lens swarm — is `flow-review`, and it is **never** part of this procedure. **This skill never seats a `lens-*` reviewer.** If a lens seat looks warranted, say so and point at `flow-review`; do not seat it here.

---

## 0. When this applies — an explicit trigger, not repository state

**Bind this skill when:**

1. The request will change files (build, implement, refactor, fix, migrate, "clean up", "make it X").
2. The request is an explicit review of existing code **for correctness** ("review this" with no lens named) — the review-only variant, §6.
3. You are **re-entering** to address `flow-review` findings, or to fix a `flow-spec` conformance gap — brief the developer with the specific findings/gap instead of a fresh request; everything else in this procedure runs unchanged.

**This skill does NOT auto-fire from repository state.** That was the previous design's failure mode: an automatic, unbounded lens swarm firing on every build regardless of size or cost. The safety property it existed to protect — nothing ships uncommitted-and-unreviewed — now lives in `flow-git-operations`'s commit gate (a cheap check, not a full re-run of this procedure) and in build-core's own validation discipline. If you made file changes outside this procedure (a direct-mode framework-prose edit, most commonly) and haven't run the review-only variant, `flow-git-operations` will ask before it lets you commit — it does not silently let unreviewed work ship, it just doesn't cost anything until a commit is actually attempted.

**The trivial hatch still applies.** A genuinely trivial change (typo, comment, formatting — no behavior change) needs no swarm: take the one-line gate (§3) and stop. **Trivial edits accumulate** — the hatch closes once THE PREDICATE (files you changed this session, not yet through this procedure) reaches 5 files, touches a contract (an invariant, a gate, a schema, a public interface, a security/authorization rule), or alters behavior rather than wording. Judge the accumulation, not the keystroke.

---

## 1. Brief yourself (dispatch NOTHING yet)

Read the request AND the code it touches. Establish:

1. **Is it trivial?** (the hatch above). Ask this first.
2. The **primary stack** → the matching `{tech}-developer` and `{tech}-reviewer`. If none exists → §6 (direct implementation). **Naming exception:** DevOps uses `devops-engineer`.
3. **What** is built/reviewed · the **scope** · the **consequence** (what it costs the user if this is wrong).
4. **Does a `flow-spec` artifact govern this work?** If the task is cross-repo, multi-tech-pair, or you were handed a spec path — bind it as the acceptance criterion for both the developer and the reviewer (path + a short navigational hint pointing at the relevant section, never the full text pasted into the dispatch — see `flow-spec`'s token-efficiency note). If no spec exists and the task doesn't call for one, proceed without it. **Exception (mandatory ask):** before dispatching 2+ parallel pairs on an unspecced effort, ask the human first — see `flow-spec` §0 for the full rule and rationale.

**The consequence is your guess, and it is the weakest claim in the plan.** You can measure scope; you cannot know consequence. Put your guess where the user can correct it.

**Ground truth before you build on it.** When the work rests on a contract the code cannot confirm — an external API's shape, a data/file format, a runtime behavior — establish it against reality FIRST: probe it and fold the result into the developer's brief, or verify immediately after the first build. This orchestrator-run probe is reconnaissance, not a dispatch — it may precede the gate.

---

## 2. Roster — the tech pair, and NOTHING else

There is no derivation here in the sense `flow-review` has one — the roster is fixed by construction: **the matching `{tech}-developer` implements, the matching `{tech}-reviewer` reviews.** That is the entire roster. No lens is ever seated as part of this procedure, regardless of how substantive the change is — a substantive change earns a full `flow-review` pass later (on request), not a bigger roster here.

**Correctness floor (hard).** Code correctness — wrong or inverted conditions, dropped errors, arithmetic, exhaustiveness, boundary and error paths, contract adherence — is owned ONLY by the `{tech}-reviewer`. This procedure without it ships with ZERO correctness coverage. There is no variant of this skill that omits the reviewer for a real (non-trivial) build.

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
>
> ### Seats
> - `{tech}-developer` — implements
> - `{tech}-reviewer` — correctness floor: [the specific logic at risk here]
>
> ### Loop
> - round 1 fix (gating findings) → round 2 verify (reviews the whole fix diff) → stop · round 3 ONLY on an open CRITICAL/HIGH
> - unfixed MEDIUM/LOW → follow-ups
>
> ### Next step available on request
> - a full lens review (`flow-review`) is NOT part of this plan and will not run unless you separately ask for it

**Then gate via `AskUserQuestion`** — Header "Implementation" · Question *"Is the consequence right? Approve this plan?"* · Options: **"Approve & run"** (the loop policy is now binding) · **"Consequence is wrong"** → re-derive, re-present · **"Adjust"** or free text → apply, re-present, ask again.

**Ask about CONSEQUENCE — never cost.** Never surface token or time estimates.

---

## 4. Build → expose → review

### 4a. Delegate to the developer.

Subagents have NO conversation history — provide ALL of it: what to implement, tech version, project structure and conventions, existing patterns, integration points, and the spec (path + hint) if one governs this work. One technology per delegation. Wait for completion.

### 4b. Expose the developer's report

immediately, as received, per `build-report-standards`.

### 4c. Dispatch the `{tech}-reviewer` — one Task call.

Binds `review-core` + `review-report-standards`, is read-only, returns a structured report.

**The reviewer has NO shell — it cannot run `git diff`.** In DIFF/PR mode you must materialize the diff to a file and pass its absolute path. `git diff` **omits untracked files** — enumerate new files explicitly.

Give it: **exact file paths** · diff/PR or full audit, **with the diff artifact path** · **tech version + language** · the developer's **Handoff-to-Reviewer note** · the spec (path + hint), if one governs this work — conformance to it is an acceptance criterion, not just generic code quality · **prior-round findings on a re-review**, so IDs stay stable.

### 4d. Expose the report.

Render per `review-report-standards` **Rendering 1**. That skill owns the format, the grouping, the verdict arithmetic.

---

## 5. The fix loop — guaranteed, bounded

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

**Review only, correctness scope (no developer).** Triggered by *"review this"* with no lens named, or when re-entering to check a diff that was made outside this procedure (a direct-mode edit, most commonly). §1 + §3 (gate) → skip 4a/4b → 4c → 4d. This is a `{tech}-reviewer` pass, not a lens pass — if the human wants lens scrutiny, that's `flow-review`, a separate ask.

**Direct implementation (no matching subagent).** §1 + §3 first — the gate is NOT optional; it is MORE load-bearing, because this mode has no developer and no `{tech}-reviewer`. Present the plan with the Seats block replaced by *"no subagent exists for [stack] — I implement, and I self-check correctness myself."* Then:

1. Tell the user no specialized subagent exists for this stack.
2. Implement it, building to the shared standards — `build-core` + `standard-clean-code`, `standard-observability`, `standard-performance`, `standard-security`, `standard-testing`, `standard-persistence` (durable stores), `standard-{lang}` if one exists. **`standard-testing` here means its non-authoring guidance only — what makes the surrounding code testable (boundaries, dependency injection, avoiding hidden state), never writing the test file itself** (`build-core`'s no-test-authoring rule binds you here exactly as it binds any developer).
3. **Review it — NOT optional, NOT self-performed.** Where no `{tech}-reviewer` exists, satisfy the correctness floor with the **execution test** (§2) — a cold `general-purpose` agent running the artifact against real scenarios. A lens pass is NOT part of this step by default — that's `flow-review`, on request.
4. Summarize per `build-report-standards`.

**Cross-repo / multi-tech-pair work.** When `flow-spec` governs the effort, each repo's `{tech}-developer`/`{tech}-reviewer` pair runs this ENTIRE procedure independently and in parallel, each briefed with the same approved spec (path + hint) as its acceptance criterion. There is no cross-pair coordination beyond that shared document — each pair's own gate, loop, and executive summary are its own.

---

## 7. Executive summary

Present: the stack · the developer · the `{tech}-reviewer` · the cycle count · what was achieved · the files delivered · the final verdict with issues found vs resolved · any seat still unsatisfied at the cap · notable decisions and rationale · **whether a lens review or test-authoring pass is available and not yet run** (so the human knows those exist as next steps, without either having auto-fired).

---

## Invariants (NEVER break)

- **Never dispatch anything without approval of the plan** (§3).
- **The roster is the tech pair, full stop — never a lens.** A lens seat, however warranted-looking, is `flow-review`'s call, made separately (§2).
- **Correctness floor** — the `{tech}-reviewer` is the sole owner of code correctness; no variant of this skill ships without it for a real change (§2).
- **Ground truth before building on it** — verify a code-unverifiable contract against reality early (§1).
- **One batched fix round; every fix is reviewed** (§5).
- **Round 1 is guaranteed; the cap is 3.** Hitting the cap unsatisfied is an escalation, never an approval (§5).
- **The reviewer keeps its seat until ITS gating findings close** — you never declare them resolved (§5).
- **Never price the review** — the gate asks about consequence, never tokens or time (§3).
- **Reviewers are read-only** and have no shell; materialize the diff for them (§4c).
- **Expose every subagent report** as it completes.
- **Direct-mode review is independent, never self-performed** (§6).
- **A spec, when one governs the work, is handed by path + hint — never pasted verbatim** into a dispatch prompt (§1).
- **2+ parallel pairs without a governing spec requires an explicit human ask, never a unilateral decision** (`flow-spec` §0 / §1).

---
*Procedure Version: 1.0 — the narrowed build-only half of the retired `flow-orchestration`. The lens swarm lives in `flow-review`, on-demand only. The cross-repo contract lives in `flow-spec`. Test-authoring lives in `flow-testing`. Review conduct in review-core / review-report-standards; builder conduct in build-core; the quality rubrics in standard-*.*
