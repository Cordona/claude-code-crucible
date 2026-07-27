---
name: flow-orchestration
description: The orchestrator's core procedure for BUILDING and REVIEWING code — the complete Mode A/B/C workflow. Bind this whenever work will change files, has changed files, or is an explicit build/implement/refactor/fix/review request. Covers the state-based review trigger (a change is not done until reviewed — bound to `git status`, never to how the request was phrased), briefing, roster derivation from an empty start, the mandatory approval gate and its exact rendering, delegation to a {tech}-developer, dispatching the parallel lens swarm, merging reports, the bounded fix loop (guaranteed first round, hard cap of 3, objecting seats retained until their gating findings close), escalation when the cap is hit unsatisfied, and the executive summary. Also covers review-only runs and direct implementation when no subagent fits, including framework-prose changes where the correctness floor is an execution test. It does NOT define review conduct or report schemas (review-core, review-report-standards), builder conduct (build-core), the quality rubrics (standard-*), costly forked decisions (flow-decision), or external PR review (flow-external-review).
---

# Flow: Orchestration

The procedure the primary agent follows to build and review code. **Bound, not memorized** — CLAUDE.md carries only the trigger that loads this file.

---

## 0. When this applies — the trigger is STATE, not phrasing

**Bind this skill when ANY of these is true:**

1. The request will change files (build, implement, refactor, fix, migrate, "clean up", "make it X").
2. The request is an explicit review of existing code.
3. **You have already changed files** — see THE PREDICATE below.

> **THE PREDICATE (one definition, used everywhere).** *Your unreviewed work* = files **you** created or edited in this
> session that have not since been through a review swarm. Not the user's pre-existing dirty tree, not files a subagent
> changed at someone else's direction, not anything already reviewed. When any rule in this skill or in `CLAUDE.md` refers
> to unreviewed changes — the trigger, the accumulation bound, the commit precondition — it means exactly this set and
> nothing else. **Track it as you go**; `git status` alone cannot tell you who authored a change, so if you genuinely
> cannot reconstruct the set, treat every uncommitted file you might have touched as in it and say so.

**Condition 3 is the one that has been failing.** Every earlier version keyed on the user's wording — *"orchestrate"*, *"review"* — so a change made without those words entered no procedure at all and was never reviewed. Nothing was skipped, because nothing was ever entered.

> **A change you made is not DONE until it has been reviewed.**
> This binds to repository state, not to intent, not to how the request was phrased, and not to whether you *called* it orchestration. If THE PREDICATE above is non-empty, this procedure owes those files a review before you report the work finished or propose a commit.

**Check at three moments:** before reporting work complete · before proposing or performing a commit · when the user asks whether something is done. If unreviewed changes exist, say so and run the review — do not ask permission to *notice*, only to dispatch.

**The trivial hatch, and its bound.** A genuinely trivial change (typo, comment, formatting — no behavior change) needs no swarm: take the one-line gate (§3) and stop. But **trivial edits accumulate.** The hatch CLOSES, and a real review is owed, once any of these is true:

- THE PREDICATE reaches **5 files**, or
- any change touches a **contract**: an invariant, a gate, a schema, a public interface, a security or authorization rule, or
- any change alters **behavior** rather than wording.

Twelve individually-trivial edits are not a trivial change. Judge the accumulation, not the keystroke.

**Precedence when the hatch and direct-mode review both apply.** A small edit you made yourself hits both: the hatch says
you MAY skip review, §6 says direct-mode review is NOT optional. **The hatch wins for a genuinely trivial change; §6 binds
the moment the hatch closes.** §6 governs *how* a direct-mode change is reviewed — independently, never self-performed —
not *whether* a typo needs a swarm. If you are unsure which applies, the hatch does not apply.

---

## 1. Brief yourself (dispatch NOTHING yet)

Read the request AND the code it touches — you cannot size work you have not read. Establish:

1. **Is it trivial?** (see the hatch above). Ask this FIRST — a README typo has no `{tech}`, so routing by stack sends one character through full ceremony.
2. The **primary stack** → the matching `{tech}-developer` and `{tech}-reviewer`. If none exists → §6 (direct implementation). **Naming exception:** DevOps uses `devops-engineer` (not `devops-developer`).
3. **What** is built/reviewed · the **scope** (what changes, what it touches, what depends on it) · the **consequence** (what it costs the user if this is wrong).
4. **The roster, derived starting from EMPTY** (§2).

**The consequence is your guess, and it is the weakest claim in the plan.** You can measure scope; you cannot know consequence. The user delegated the code — they did **not** delegate the stakes. That asymmetry is the whole point of the gate: put your guess where they can correct it.

**Ground truth before you build on it.** When the work rests on a contract the code cannot confirm — an external API's shape, a data or file format, a runtime behavior — establish it against reality FIRST: probe the real thing and fold the result into the developer's brief, or at the latest verify it immediately after the first build. Never leave it to the end. This is the orchestrator's duty because only the main thread holds the live access (credentials, real environment) a sandboxed subagent lacks, and only it controls the sequence. (This orchestrator-run probe is *reconnaissance*, not a subagent dispatch — like the §6 note that the approval invariant is worded around *dispatch*, it may precede the gate; a read-only probe changes nothing and needs no approval.) The cheapest defect is the one caught before anything is stacked on the assumption; a wrong assumption verified late is re-reviewed and re-fixed at every layer that was built on top of it.

---

## 2. Roster selection — start from EMPTY

You already know the available subagents from your Task tool. Select dynamically; never from a hardcoded list.

> review swarm = the one `{tech}-reviewer` for the stack (the correctness floor) + every `lens-*` whose declared applicability the change actually meets

Review is performed by a **swarm of `lens-*` reviewers** — generic, language-agnostic, each judging ONE perspective — **plus** the specialized `{tech}-reviewer`. **Membership is by naming convention: a new lens joins automatically just by being named `lens-*`.** Nothing enumerates them; that is why no list of lenses exists anywhere in this framework.

**Read, don't audition.** For each `lens-*`, read the **Applicability** it declares in its own description (`Applies when…` / `Skip when…`) and reason the change against it. That declaration is free. **Never invoke a lens to ask whether it wants a seat** — a lens asked "is there risk in your domain?" always finds one, because that is what a lens *is*. Where its declaration genuinely doesn't settle it, put it in the plan's **Uncertain** block and let the user resolve it at the gate.

**Those declarations may be stale and nothing will tell you.** Agent definitions load into context ONCE at session start
and never refresh, so a lens edited mid-session still presents its old Applicability to you. You cannot detect this by
reasoning, and you have no session-start timestamp to compare against. What you CAN do: **if anyone has edited an agent
definition during this session — including you — say so plainly and tell the user a restart is needed for the change to
take effect.** You are not required to guess at staleness you have no way to observe; you are required to report the
edits you made.

**Do NOT expect a small roster, and do not sell it as one.** On a substantive change most lenses genuinely apply. **A large roster on a large change is the correct answer, not a failure of derivation.** The filtering bites on *small* changes, where `Skip when` clauses fire honestly.

**What the derivation buys is the EXCLUSIONS, not the inclusions.** "Seat, because [risk]" is unfalsifiable — you can always write a fluent justification. **"No seat — accepting: [what we'd miss]" is a real claim the user can check and reject.** State every seat AND every exclusion; spend your care on the exclusions. If you cannot say what an exclusion accepts, you have not earned it — seat the lens.

**Two-tier gate.** You make the RELEVANCE call; each lens then self-gates its DEPTH internally. **The tiers are not interchangeable** — a lens that self-prunes has still been invoked, still read the diff, still written a report. Depth-gating is cheap; relevance-gating is not. So never seat a lens on the reasoning that it will prune itself anyway.

**Security floor (hard).** Honor any lens marking itself security-critical; include it on ANY doubt.

**Correctness floor (hard).** Code correctness — wrong or inverted conditions, dropped errors, arithmetic, exhaustiveness, boundary and error paths, contract adherence — is owned ONLY by the `{tech}`-reviewer. No generic lens asks "is this code correct?" A roster omitting it ships with ZERO correctness coverage. Never let that happen silently.

**The correctness floor for framework PROSE.** When the change is to markdown that governs behavior — `CLAUDE.md`, a `SKILL.md`, an agent definition — there is no `{tech}`-reviewer, and the lenses are code-shaped. The floor is satisfied instead by an **execution test**: dispatch a `general-purpose` agent, give it the changed file and 3–4 realistic scenarios, and tell it to *execute* the file against them and report where it could not comply. **Reading checks whether the words are right; running checks whether they do anything.** This is not optional garnish — prose defects historically survive every reading review and surface only under execution.

**Trivial-change hatch.** For a genuinely trivial change (per §0's hatch and its accumulation bound) you MAY propose **no review** — or `{tech}` only — with the same reasoning and the same approval. Conversely, **a lens-only roster removes ALL correctness coverage**; call that out per the correctness floor before proposing it.

**Resolving lens names.** The user names a lens in plain words — *"logging"*, *"conventions"*, *"tests"*. Match it against the `lens-*` agents' own descriptions; each declares what it covers. **Never maintain a lens list here** — a list in this file is a list that goes stale the moment a lens is added.

**Command grammar** (the user's explicit override): *"orchestrate"* → developer + roster + loop · *"review"* → roster only · *"skip/don't review for X"* → drop those lenses · *"only review for X"* → just those, plus the `{tech}`-reviewer unless explicitly excluded (warn per the correctness floor).

---

## 3. The gate (MANDATORY — before ANY dispatch)

**Present the plan and wait for approval before dispatching anything, developer or swarm.**

**Proportionate to itself.** For a genuinely trivial change this is ONE LINE, not a plan: *"no review / `{tech}` only — ok?"*

**Emit as LIVE MARKDOWN the terminal renders — never inside a code fence.** The `>` marks below delimit the spec here; they are not part of what you emit.

> ## 🎯 Orchestration Plan
>
> - **Task:** [what is being built / reviewed]
> - **Stack:** [tech + version]
> - **Scope:** [what changes · what it touches · what depends on it]
> - **Consequence:** [what it costs you if this is wrong] ← correct me
>
> ### Seats
> - `{tech}-reviewer` — correctness floor: [the specific logic at risk here]
> - `lens-…` — [the specific risk IN THIS CHANGE it catches]
>
> ### No seat
> - `lens-…` — [why this change doesn't present that risk] → accepting: [what we'd miss]
>
> ### Uncertain
> - `lens-…` — [why its declared applicability doesn't settle it]
>
> ### Loop
> - round 1 fix (ONE batch — gating + any MED/LOW you choose to fix) → round 2 verify (reviews the whole fix diff) → stop · round 3 ONLY on an open CRITICAL/HIGH
> - a seat that raised a gating finding keeps its seat until that finding closes
> - unfixed MEDIUM/LOW → follow-ups

**Rendering rules — part of the format, not style advice:**
- **Every field is a bullet.** Never align labels with padding spaces: markdown collapses whitespace, so alignment survives only inside a fence — and a fence turns the plan into an unreadable grey box.
- **Never join two lines with a single newline** expecting a break. Use separate bullets.
- Omit empty sections rather than emitting empty headings — **except No seat**, which always appears: an exclusion with nothing under it is a claim the user needs to see.

**Then gate via `AskUserQuestion`** — Header "Orchestration" · Question *"Is the consequence right? Approve this plan?"* · Options: **"Approve & run"** (the loop policy is now **binding**) · **"Consequence is wrong"** → re-derive from the corrected consequence, re-present · **"Adjust roster"** or free text → apply, re-present, ask again.

**Ask about CONSEQUENCE — never cost.** Never surface token or time estimates. A visible price buys a penny-wise decision against a pound-foolish risk. **Proportionality is YOUR burden** — this gate verifies you carried it; it does not let the user put it down.

**Why the question is consequence, not scope:** a roster where you justified every seat is unfalsifiable — "yes" is the only rational answer. And the user may no longer know the code well enough to audit your scope; that is what delegating did. But delegation never took the **stakes**. Ask the one question they are still the authority on.

---

## 4. Build → expose → review

### 4a. Delegate to the developer.

Subagents have NO conversation history — provide ALL of it: what to implement, tech version, project structure and conventions, existing patterns, integration points. One technology per delegation; never batch. Wait for completion.

### 4b. Expose the developer's report

immediately, as received, per `build-report-standards`.

### 4c. Dispatch the swarm — in parallel, one Task call each.

Each reviewer binds `review-core` + `review-report-standards` (+ `review-boundaries` where it has contested territory), is read-only, and returns a structured report.

**Reviewers have NO shell — they cannot run `git diff`.** In DIFF/PR mode you must materialize the diff to a file and pass its absolute path. `git diff` **omits untracked files** — enumerate new files explicitly or the reviewer never sees them. Forget this and the reviewer silently audits whole files and bills your change for pre-existing defects.

Give each reviewer: **exact file paths** · diff/PR or full audit, **with the diff artifact path** · **tech version + language** · the developer's **Handoff-to-Reviewer note** · **prior-round findings on a re-review**, so IDs stay stable.

> **Note on the `{tech}`-reviewer:** the merge below is mechanical once it emits the shared schema. **If a not-yet-migrated one returns prose, normalize it — assign a `{TECH}-NNN` prefix, map its severities — BEFORE merging.** Skip this and its findings silently drop out of the merged verdict: a non-schema report contributes nothing to the arithmetic, so a real CRITICAL can vanish into an `APPROVED`.

### 4d. Merge and expose.

Dedup by finding `id` internally (mechanical), then render per `review-report-standards` **Rendering 1** — grouped by reviewer → severity, status as words, **no finding ids** in the human view, **Resolved in its own block at the bottom**. That skill owns the format, the grouping, the strictest-verdict merge, the convergence merge, and the verdict arithmetic. Do not hand-copy any of it.

---

## 5. The fix loop — guaranteed, bounded, and seat-persistent

**The verdict arithmetic that drives it — all three branches.** Owned by `review-report-standards`; restated here because the loop is what consumes it, and because **the middle branch is the one that stops the loop**:

- any open `CRITICAL`/`HIGH` from ANY seat → **`CHANGES_REQUIRED`** → the loop runs
- only `MEDIUM`/`LOW` open → **`APPROVED_WITH_FOLLOWUPS`** → **does NOT block**; list them and stop
- nothing open → **`APPROVED`** → stop

> Historical note, and the reason all three are written out: a previous compression of this procedure silently deleted `APPROVED` and `APPROVED_WITH_FOLLOWUPS`, leaving only `CHANGES_REQUIRED`. No reading review caught it. If you ever find yourself with one branch, you are missing two.

```
Round 1 is GUARANTEED whenever changes exist. The cap is 3. Both bind.

IF merged verdict == CHANGES_REQUIRED:

  round 1 · FIX     Collect EVERY finding FIRST — the full swarm AND any
                    live / ground-truth verification — then delegate in ONE
                    batch: the gating findings (CRITICAL/HIGH) plus any
                    MEDIUM/LOW you elect to fix now (ID, location, problem,
                    fix). NEVER drip-feed fixes across separate rounds — each
                    round re-pays a large fixed cost (the developer re-loads
                    the whole context). Expose the fix summary.

  round 2 · VERIFY  Re-run:
                      (a) EVERY seat that raised a gating finding — it keeps its
                          seat until ITS gating findings are closed. You do not
                          get to declare its finding resolved; it does.
                      (b) EVERY lens whose declared applicability matches the
                          files the FIX touched — not just the ones that
                          complained. A security fix routinely introduces a
                          performance or persistence defect.
                    Pass back each seat's own prior findings (stable IDs).
                    Merge + expose.

  ═══════════════════ STOP ═══════════════════

  round 3           ONLY if a CRITICAL/HIGH is still open. Then stop regardless.

MEDIUM/LOW you do NOT fix are follow-ups — list them; never give them
their OWN round. MEDIUM/LOW you DO fix ride the single FIX batch above.
```

**Every fix is a change, and a change is reviewed (§0).** VERIFY re-reads the ENTIRE fix diff — whoever authored it, the developer OR an orchestrator inline edit for a trivial one — so every change, gating through low, gets an independent eye. Folding a "cheap" low-severity fix and NOT putting it through VERIFY is the same unreviewed-change violation as any other; an inline edit is fine ONLY because VERIFY still sees it in the diff. The one thing that legitimately defers is a MEDIUM/LOW you chose NOT to fix — safe *precisely because nothing changed*. "Defer" means **not touched**, never **touched but unreviewed**. This is also why you batch: one FIX + one VERIFY reviews everything once, instead of a round per finding. **And this holds even when the merged verdict did NOT require a round** (`APPROVED_WITH_FOLLOWUPS` / `APPROVED`, above): if you nonetheless elect to fix a MEDIUM/LOW, that fix is itself a new change, so it re-opens a FIX+VERIFY (per §0's state trigger — your unreviewed work is non-empty again). You never fix-and-ship under "stop": either defer it untouched, or fix it and let VERIFY see it.

**Round 2's roster is pre-authorized by the gate — it is not a new dispatch.** Approving the plan approves the LOOP, and
the loop's round-2 rule (b) is stated in the gate's own Loop block. So re-running a lens the fix newly made applicable does
not breach "never dispatch without approval": the user approved that rule when they approved the plan. **Name the added
seats when you expose the round-2 report**, so the expansion is visible rather than silent. Anything beyond the loop —
a new lens for a new concern, a round past the cap — is a genuinely new dispatch and needs fresh approval.

**"Satisfied" means its GATING findings are closed — not that it has zero findings.** Every fix round produces fresh MEDIUM/LOWs; on the zero-findings reading the loop never terminates.

**When the cap is reached with a seat still unsatisfied, that is an ESCALATION, not an approval.** Report it plainly: which seat, which finding, why it is still open, what you recommend. **The cap must never become a way to run out the clock on an unresolved defect.** Continuing past round 3 requires a new approval from the user — not a counter you increment.

**The loop is where the cost lives, not the swarm.** Rounds past VERIFY are polish, and polish is self-feeding: every fix round produces fresh MEDIUM/LOWs, which invite another round. The gate's policy **binds** you — it is a decision the user already made.

---

## 6. Variants

**Review only (no developer).** Triggered by *"review"* on existing code, or by condition 3 when the changes are already made — including changes **you** made. §1 + §3 (gate) → skip 4a/4b → 4c → 4d. The fix loop runs only if the user asks to fix; otherwise stop after the merged report.

**Direct implementation (no matching subagent).** **§1 + §3 first — the gate is NOT optional here; it is MORE load-bearing**, because this mode has no developer and no `{tech}`-reviewer. **The approval invariant is worded around *dispatch*, and this mode dispatches nothing — do not read that as an exemption.** It is the one mode where the gate is the ONLY check standing between you and the code. Present the plan with the Seats block replaced by *"no subagent exists for [stack] — I implement, and I self-check correctness myself."* Then:

1. Tell the user no specialized subagent exists for this stack.
2. Implement it, **building to the shared standards** — `build-core` + `standard-clean-code`, `standard-observability`, `standard-performance`, `standard-security`, `standard-testing`, `standard-persistence` (durable stores), and `standard-{lang}` **if one exists** — if it doesn't, say so rather than silently dropping it.
3. **Then review it — this is NOT optional and NOT self-performed.** Independent seats still apply: dispatch the `lens-*` reviewers whose applicability the change meets, exactly as in 4c. You wrote the code; you are the worst available judge of it. Where no `{tech}`-reviewer exists, satisfy the correctness floor with the **execution test** (§2) — a cold `general-purpose` agent running the artifact against real scenarios.
4. Summarize per `build-report-standards`.

> Earlier versions said *"offer to self-review… yourself."* That is withdrawn. Optional review is not review, and author-performed review is the weakest check available.

---

## 7. Executive summary

When the review approves OR the loop ends, present: the stack · the developer · the review swarm · the cycle count · what was achieved · the files delivered (path · purpose · created/modified) · the final verdict with issues found vs resolved · **any seat still unsatisfied at the cap** · the notable decisions and their rationale.

---

## Invariants (NEVER break)

- **A change you made is not done until it has been reviewed** — bound to `git status`, not to phrasing (§0).
- **Ground truth before building on it** — verify a code-unverifiable contract (external API shape, data/file format, runtime behavior) against reality EARLY: into the brief, or right after the first build, never at the end (§1).
- **One batched fix round; every fix is reviewed.** Collect ALL findings before dispatching a single FIX (gating + any chosen MED/LOW together); VERIFY re-reads the whole fix diff, so no change of any severity escapes review; only UNfixed items defer (§5).
- **Round 1 is guaranteed; the cap is 3.** Hitting the cap unsatisfied is an escalation, never an approval (§5).
- **A seat that raised a gating finding keeps its seat until that finding closes.** You never mark another seat's finding resolved (§5).
- **Never dispatch anything without approval of the plan** (§3).
- **The roster starts EMPTY**; every seat is earned by a named risk, every exclusion states what it accepts (§2).
- **Never price the review** — the gate asks about consequence, never tokens or time (§3).
- **Reviewers are read-only** and have no shell; materialize the diff for them (§4c).
- **Expose every subagent report** to the user as it completes.
- **Direct-mode review is independent, never self-performed** (§6).

---
*Procedure Version: 1.1 — the orchestration workflow, extracted from CLAUDE.md so the operating contract carries only the trigger that loads it. v1.1 adds two general duties: ground-truth verification of code-unverifiable contracts before building on them (§1), and one batched fix round whose VERIFY reviews the whole diff so no fix — any severity — escapes review (§5). Review conduct lives in review-core / review-report-standards; builder conduct in build-core; the quality rubrics in standard-*.*
