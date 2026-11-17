---
name: flow-implementation
description: "The orchestrator's procedure for BUILDING code. Bind on an explicit build/implement/refactor/fix request, or a bare \"review this\" for correctness only; also the re-entry point for addressing `flow-review` findings or `flow-spec` conformance fixes. Under Validate-First the `{tech}-reviewer` is deferred and `flow-testing` is bound mid-flow, under its own gate. Never seats a lens reviewer (the opt-in background re-check's adversary aside — not a review seat), authors a cross-repo spec, or writes tests itself — those are `flow-review`, `flow-spec`, and `flow-testing` respectively."
---

# Flow: Implementation

The procedure the primary agent follows to build code and hold it to a correctness floor. **Bound, not memorized.**

The lens swarm is a separate procedure, `flow-review`, and it is **never** part of this procedure. **This skill never seats a `lens-*` reviewer** — the one exception is §5's background re-check, whose adversary for a security item is `lens-security-reviewer`; it re-checks set-aside items and is not a review seat. If a lens seat looks warranted, say so and point at `flow-review`; do not seat it here.

---

## 0. When this applies — an explicit trigger, not repository state

**Bind this skill when:**

1. The request will change files (build, implement, refactor, fix, migrate, "clean up", "make it X"). **This also covers a fresh case-1 re-entry from `flow-testing`** — that flow exiting early with a blocker or masked-defect finding it cannot fix itself (`flow-testing` §4b/§5), briefed per that flow's two-precondition requirement (§4c below). Unlike case 3 below, the `{tech}-reviewer` has NOT already joined on this path, so §1's live-testability assessment and §2's path choice DO re-run, same as any other fresh case-1 request.
2. The request is an explicit review of existing code **for correctness** ("review this" with no lens named) — the review-only variant, §6.
3. You are **re-entering** to address `flow-review` findings, or to fix a `flow-spec` conformance gap — brief the developer with the specific findings/gap instead of a fresh request; everything else in this procedure runs unchanged, **except that §1's live-testability assessment and §2's path choice do NOT re-run** — a case-3 re-entry only happens after the `{tech}-reviewer` has already joined, so it does not re-run §1/§2 — a fresh round 1 when the prior loop had already stopped (always true for a `flow-review` re-entry, since that skill requires §4d to have closed before it runs, per `flow-review` §0), or a continuation of the open round's counter when it had not (a `flow-spec` conformance gap caught mid-loop).

**This skill does NOT auto-fire from repository state.** The safety property that matters — nothing ships uncommitted-and-unreviewed — lives in `flow-git-operations`'s commit gate (a cheap check, not a full re-run of this procedure) and in `build-core`'s own validation discipline. If you made file changes outside this procedure (a direct-mode framework-prose edit, most commonly) and their floor has not cleared — the execution test (§2) for prose, the review-only variant (§6) for code — `flow-git-operations` will ask before it lets you commit — it does not silently let unreviewed work ship, it just doesn't cost anything until a commit is actually attempted.

**The trivial hatch still applies.** A genuinely trivial change (typo, comment, formatting — no behavior change) needs no tech-pair dispatch: take the one-line gate (§3) and stop. **Trivial edits accumulate** — the hatch closes once THE PREDICATE (files you changed this session, not yet through this procedure) reaches 5 files, touches a contract (an invariant, a gate, a schema, a public interface, a security/authorization rule), or alters behavior rather than wording. Judge the accumulation, not the keystroke.

---

## 1. Brief yourself (dispatch NOTHING yet)

Read the request AND the code it touches. Establish:

1. **Is it trivial?** (the hatch above). Ask this first.
2. The **primary stack** → the matching `{tech}-developer` and `{tech}-reviewer`. If none exists → §6 (direct implementation). **Naming exception:** DevOps uses `devops-engineer`.
3. **What** is built/reviewed · the **scope** · the **consequence** (what it costs the user if this is wrong).
4. **Does a `flow-spec` artifact govern this work?** If the task is cross-repo, multi-tech-pair, or you were handed a spec path — bind it as the acceptance criterion for both the developer and the reviewer (path + a short navigational hint pointing at the relevant section, never the full text pasted into the dispatch — see `flow-spec` §5, which frames this as a correctness safeguard against drift, not a token-saving shortcut). If no spec exists and the task doesn't call for one, proceed without it. **Exception (mandatory ask):** before dispatching 2+ parallel pairs on an unspecced effort, ask the human first — see `flow-spec` §0 for the full rule and rationale.
5. **Assess live-testability — reason about it, don't run down a checklist.** Skip this step entirely for the review-only and Direct-implementation variants (§6 — no path split applies there) and for a case-3 re-entry (§0 — the path choice does not re-run). The cross-repo variant (§6) does NOT skip this — each pair re-runs this assessment independently. The real question: would checking this against actual, running reality tell you something the diff alone can't, and can you find that out cheaply and safely? This is open-ended judgment about THIS specific task, not a fixed test with a pass/fail line. This decides which path (§2) you recommend at the gate.

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

No lens is ever seated as part of this procedure (§5's background re-check adversary aside — it is not a review seat), regardless of how substantive the change is — a substantive change earns a full `flow-review` pass later (on request), not a bigger roster here. Within that constraint, the roster is one of two named paths, chosen from §1's live-testability assessment:

**Validate-First.** A live/manual verification path exists for this task. `{tech}-developer` implements ALONE this round. Dirty, unaudited, unpolished is fine — that's the point: fast iteration and fast human feedback, with no reviewer effort spent on an approach live-testing might still redirect. The `{tech}-reviewer` is **DEFERRED, not cut** — it joins later, at §4d, after §4c's live validation and `flow-testing` have locked in the validated behavior as a regression net.

**Pair-First.** No live source — or none cheap and safe enough to use, or the change touches a security-sensitive path where a live check can't substitute for review (§1). `{tech}-developer` implements, `{tech}-reviewer` reviews, in the SAME round. Without a usable live source there is no cheap way to de-risk the implementation before investing in tests, so the reviewer's scrutiny IS that de-risking step, and it cannot be deferred.

The orchestrator recommends one path at the gate (§3) with its reasoning stated; the human can override in either direction — a trivial or unfamiliar task might warrant Pair-First even with a live source available, and vice versa.

**Correctness floor (hard).** Code correctness — the itemized boundary lives in `review-boundaries`'s own Code-correctness row, not restated here — is owned ONLY by the `{tech}-reviewer`. **No real (non-trivial) build is ever DONE without it running.** Validate-First defers WHEN it runs; neither path skips WHETHER it runs.

**The correctness floor for framework PROSE.** When the change is to markdown that governs behavior — `CLAUDE.md`, a `SKILL.md`, an agent definition — there is no `{tech}-reviewer`. The floor is satisfied instead by an **execution test**: dispatch a `general-purpose` agent, give it the changed file and 3–4 realistic scenarios, and tell it to *execute* the file against them and report where it could not comply. Reading checks whether the words are right; running checks whether they do anything. **Its gaps go through §5's loop like a reviewer's findings** — the human picks what to fix at the Address question; fix → re-run the test → stop; the cap is 3. The floor is cleared when no gap the human chose to fix is still open — not when the test finds zero gaps.

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
> - **Recommended path:** [Validate-First — name the live source and the behavior it will exercise / Pair-First — state why: no live source, or none usable here] — *omit for the review-only and Direct-implementation variants (§6), where no path split applies, and for a case-3 re-entry (§0), where the prior path choice carries over unchanged*
> - *Validate-First only:* **Test scope:** [repair / new authoring / both; the behaviors to guard — never a case list; `flow-testing` §3 turns it into a reviewed test plan the human approves]
>
> ### Seats
> - `{tech}-developer` — implements — *omit this line entirely for the review-only variant (§6): no developer round runs there*
> - `{tech}-reviewer` — correctness floor: [the specific logic at risk here] · [Validate-First: **deferred** until after live validation + `flow-testing` / Pair-First: same round / review-only: this round, alone]
> - *Validate-First only:* `tests-developer` + `lens-test-quality-reviewer` — bound mid-flow, after live validation, against the Test scope stated above, before the deferred reviewer — no test is written before its own reviewed test plan is approved; **`flow-testing` runs its OWN separate approval gate at that point — approving THIS plan does not authorize that dispatch**
>
> ### Loop
> - round 1 fix (gating findings) → round 2 verify (reviews the whole fix diff) → stop · round 3 ONLY on an open gating CRITICAL/HIGH
> - MEDIUM/LOW the human does not choose at the Address question → follow-ups
> - *Validate-First only:* `flow-testing` runs its own identical bounded loop first, before the `{tech}-reviewer` loop above starts
>
> ### Next step available on request
> - a full lens review (`flow-review`) is NOT part of this plan and will not run unless you separately ask for it — *under Validate-First, `flow-review` will not accept this diff on the lens roster alone until §4d closes; before that, it would have to seat the `{tech}-reviewer` itself (`flow-review` §0/§3)*

**Then gate via `AskUserQuestion`** — Header "Implementation" · Question *"Is the consequence right? Approve this plan and its recommended path?"* · Options: **"Approve & run"** (the loop policy is now binding) · **"Consequence is wrong"** → re-derive, re-present · **"Switch to Validate-First/Pair-First"** → apply, re-present · **"Adjust"** or free text → apply, re-present, ask again. The Seats-block caveat above binds: this approval does not reach the mid-flow `flow-testing` dispatch (see §4c).

**Ask about CONSEQUENCE — never cost.** Never surface token or time estimates.

---

## 4. Build → expose → [Validate-First: validate → test] → review

### 4a. Delegate to the developer.

Subagents have NO conversation history — provide ALL of it: what to implement, tech version, project structure and conventions, existing patterns, integration points, and the spec (path + hint) if one governs this work. One technology per delegation. **Before this dispatch, take the effort's snapshot** (`flow-review` §2, Effort isolation) — every later review and test of this effort runs `--since-snapshot` against it. Wait for completion.

**Brief rules — every brief this flow, `flow-review`, and `flow-testing` write for a developer, reviewer, or tester:**
- **Describe behavior from the code**, never by repeating the developer's claims about it.
- **Never pre-judge an item as acceptable** — no "this is fine", "known limitation", or "low risk" framing; the receiving agent judges.
- **Name the related repos** the agent may read (callers, consumers, producers of the change's data) and **the feature's acceptance goal** in measurable terms ("updates appear within 2 s").

### 4b. Expose the developer's report

immediately, as received, per `build-report-standards`.

### 4c. Validate-First only — live validation, then `flow-testing`

**Skip this step entirely under Pair-First** — go straight to 4d.

**Live validation.** Check the implementation against the live source identified in §1. The confirmation that the behavior is right must be the HUMAN's own explicit in-turn statement — an orchestrator-run probe may gather evidence and report what it found, but it never supplies the confirmation itself. State plainly at this checkpoint: *"this implementation has NOT yet been correctness-reviewed — the `{tech}-reviewer` pass is still outstanding."* Iterating here — developer fixes, re-validate — is expected and cheap, but **cap it at 3 rounds of iteration before re-presenting the gate (§3)**: past that, the implementation is being redirected, not adjusted, and deserves a fresh look at whether Validate-First is still the right path.

**Then `flow-testing`.** Once the human has live-validated, bind `flow-testing` — `tests-developer` + the mandatory `lens-test-quality-reviewer` pass — to lock in the validated behavior as a regression net. This is `flow-testing`'s third valid trigger (see its §0): confirmation via live validation of a not-yet-reviewed implementation, not only after a completed tech-pair loop or a `flow-review` pass. **Binding it does NOT dispatch it.** `flow-testing` runs its own gate (`flow-testing` §3, starting with `flow-testing` §3a's authorization to draft) before `tests-developer` or the reviewer touch anything. This skill's own §3 disclosure, back at the top of this flow, only told the human this step exists; it is not that step's approval.

"Completes normally" means one of two things: `flow-testing` reaches `APPROVED`/`APPROVED_WITH_FOLLOWUPS`, OR it hits its own round cap and ESCALATES with the test-quality reviewer still unsatisfied on an ordinary (non-masked-defect) finding (`flow-testing` §5's generic cap escalation — distinct from the masked-defect exception below). **Either way, resume here at 4d** — the deferred `{tech}-reviewer` joins now, with whatever test suite resulted — but on the ESCALATE branch, carry `flow-testing`'s own escalation forward into every subsequent report alongside the `{tech}-reviewer` finding: two open items, not one, and the human decides whether to proceed to §4d's correctness pass now (accepting the test-quality gap as a disclosed follow-up) or resolve `flow-testing`'s escalation first. **The obligation to resume does not end when this step does** — carry the "reviewer still outstanding" statement forward into every subsequent report until §4d actually runs (see Invariants).

**Exception — `flow-testing` exits early instead of completing** (its §4b or §5: an implementation-wrong/untestable blocker, or a masked-defect finding `tests-developer` cannot fix — NOT the generic cap-escalation case above, which resumes normally). That exit re-enters THIS flow at §0 case 1, briefed per `flow-testing` §5's two-precondition requirement (Pair-First recommended explicitly; the re-entry's diff artifact scoped to the whole originally-unreviewed implementation, not just the fix delta). When both preconditions were actually briefed, that case-1 re-entry's own §4d **supersedes** this suspended invocation's deferred pass — it discharges the obligation instead of resuming it a second time. Absent either precondition, the obligation is NOT discharged and remains outstanding exactly as if `flow-testing` had never run.

### 4d. Dispatch the `{tech}-reviewer` — one Task call.

Binds `review-core` + `review-report-standards`, is read-only, returns a structured report.

**The reviewer has NO shell — it cannot run `git diff`.** The review targets this effort's diff and traces its effects (`review-core`, Review Scope): pick and restrict the effort's diff per `flow-review` §2, into an out-dir in your scratchpad. Pick the files the developer report lists — for the review-only variant, the files named at §3's gate. **When exposing this dispatch, show the human the picked files and any changed file whose effort is unclear — the human corrects the pick there**, and a correction re-runs the restrict step. Pass the absolute paths of the restricted `diff.patch` and `diff-files.txt`, run with `--since-snapshot` against §4a's snapshot — never another effort's changes. **After every fix round, re-run the restrict step with the same paths file plus any file the fix added**, so the reviewer reads the current diff, never a stale snapshot.

Give it, written per §4a's brief rules: **the diff artifact path (`diff.patch`) and its changed-file list (`diff-files.txt`)** — the review target; the reviewer traces what the change uses or affects (`review-core`) · **tech version + language** · **the related repos it may read and the acceptance goal** · the developer's **Handoff to reviewer** block · **every open handoff addressed to it**, for its ruling · the spec (path + hint), if one governs this work — conformance to it is an acceptance criterion, not just generic code quality · under Validate-First, that this implementation was already live-validated and is now covered by a `flow-testing`-authored suite (name the test files) · **prior-round findings on a re-review**, so IDs stay stable.

### 4e. Expose the report.

Render per `review-report-standards` **Rendering 1**. That skill owns the format, the grouping, the verdict arithmetic. Then ask what to address (§5).

---

## 5. The fix loop — guaranteed, bounded

This loop starts whenever the `{tech}-reviewer` is dispatched — immediately after §4b under Pair-First, or after §4c's live-validation + `flow-testing` detour under Validate-First. The mechanics are identical either way. **Exception — the review-only variant (§6):** no developer is seated in that invocation, so a `CHANGES_REQUIRED` verdict there does not enter round 1 · FIX directly; §6 states its own re-entry route instead.

**The verdict arithmetic — all three branches**, owned by `review-report-standards`:

Only findings the verdict counts gate (`review-report-standards`, Verdict Arithmetic) — realistic findings, plus an edge-case `CRITICAL`/`HIGH` until the human confirms it.

- any counted open `CRITICAL`/`HIGH` → **`CHANGES_REQUIRED`** → the loop runs
- only `MEDIUM`/`LOW` open → **`APPROVED_WITH_FOLLOWUPS`** → does NOT block; the loop runs only on what the human chose at the Address question, else list them and stop
- nothing open → **`APPROVED`** → stop

```
The reviewer pass is guaranteed whenever changes exist; a FIX round is
guaranteed whenever a gating finding exists. The cap is 3. Both bind.

IF merged verdict == CHANGES_REQUIRED, or the human chose items to fix:

  round 1 · FIX     Collect EVERY finding first, then delegate in ONE batch:
                    the gating findings plus everything the human chose
                    at the Address question — each chosen item marked
                    mandatory. NEVER drip-feed fixes across separate rounds.
                    Expose the fix summary.

  round 2 · VERIFY  Re-run diff-scope.sh (§4d — same paths file plus any
                    file the fix added), then re-run the {tech}-reviewer on
                    that current diff — it keeps its seat until ITS
                    gating findings are closed; you do not get to declare
                    them resolved, it does. Pass back its own prior findings
                    (stable IDs). A finding it calls partly addressed
                    stays OPEN. When the effort has a review artifact,
                    record the round with review-add-round.sh, each
                    resolved finding per flow-review §5c. Expose.

  ═══════════════════ STOP ═══════════════════

  round 3 · FIX     ONLY if a counted CRITICAL/HIGH is still open. One more fix
                    attempt, same batching rule as round 1; any re-verify
                    runs on a fresh diff-scope.sh run (§4d) — then STOP
                    REGARDLESS, whether or not the reviewer re-verified it.
                    Stopping here is NOT approval: report the finding as
                    still open/unverified and ESCALATE to the human (see
                    below) — never present round 3's own unverified fix
                    claim as resolved.

MEDIUM/LOW the human did NOT choose are follow-ups — list them, never their own round.
A chosen item is never relabelled optional or a follow-up.
```

**After every review, the human chooses what to address.** Render the report per Rendering 1 (§4e) — edge cases, speculative items, Not proven items and open handoffs in their own sections, every class visible. If a reviewer's Notes (or Pre-existing notes) contain a security concern or other problem in code the change touches, relies on, or exposes — not a Handoff line, which stays a handoff — return the report to that reviewer to re-file it as a finding (`review-core`, Review Scope) before asking — never ask about an unnumbered note. Then, when any item is open (a set-aside item alone counts — in `flow-testing`, even when the only open items are the plan's unwaived `not_tested` entries), gate via `AskUserQuestion` — Header "Address" · Question *"What should the fix round address?"*. **Build the options from the report you just showed** — the rule for every decision question these flows ask the human (`flow-testing` §3d applies it to the test plan):
- Each option names its items by their report number, with severity, class, 🔒 when security, and the consequence if left unfixed.
- Offer only choices the report supports — never a label for a kind of item it does not contain. Offer a background re-check when set-aside items exist (below), and "fix nothing" when nothing blocks.
- **The first option is your recommendation, marked "(Recommended)"**, with one line on why and what it leaves unfixed — made in good faith from the report, for a human deciding quickly. It never leaves unfixed any security item (any severity) or any realistic CRITICAL/HIGH (that stays the human's explicit choice), and it names the risk the human accepts by leaving the rest.
- Wording, grouping and the number of options are your judgement. Free text takes item numbers ("1–4, 6"); an answer naming an item overrides an option for that item.
- An option may fold in a handoff ruling by naming the handoff. An open handoff the chosen option does not name stays open and is asked about — filed, waived (its reason per the waiver rule below), or routed to the background re-check — never silently waived.

The human's answer is the human's decision: record it as theirs — a waiver takes its reason as defined below (Every proof). **Each edge-case `CRITICAL`/`HIGH` gets its own question, asked before the Address question and never bundled into it** — its answer changes the Address options. Header "Edge case" · Question *"Item N — keep as an edge case or fix it?"* · two choices, each carrying the facts above, your recommendation first by the same rule: keep it as an edge case (it stops gating; record it with `review-update-status.sh --confirm-edge-case --proof <text> --repo-root <repo>`, or `--unproven` when no proof exists — a security item takes proof only), or fix it (it is elected). You compute the merged verdict from the findings, applying the human's confirmations; a reviewer's own verdict does not see them.

- **Whatever the human chose opens a FIX round** — round 1 if none is open, even when every chosen item is a MEDIUM/LOW under `APPROVED_WITH_FOLLOWUPS`. An elected edge case becomes `realistic`. **An elected speculative item** has no id: it enters the round as a fix request by its location and concern, and the reviewer files it as a finding on re-review.
- **Anything the human chose is mandatory.** The developer may not decline it (`build-report-standards`, Reporting a Fix Round). A decline stops the flow: put it to the human, who either waives it explicitly (`ACK`) or has it re-briefed — never relabel it optional, defer it, or skip it yourself.
- **Any finding or speculative entry** can get a realism check — only when the human asks for one or approves your offer: dispatch `review-arbiter` alone with the item, its trigger, the cited code, the repo root, and that this is an implementation review. **On a blocking finding,** its ruling is a recommendation the human decides on: `realistic` or a missing `realism` → it stays blocking; `edge-case` → offer the human to confirm it; `speculative` → offer the human an `ACK` (a recorded waiver); `verdict: FALSE_POSITIVE` → offer the human an `ACK`; `ESCALATE` → the human decides directly. On a security item (`review-core`, Security is never rare), any ruling below high confidence keeps the finding `realistic`. **On a non-blocking finding or a speculative entry,** the ruling is information for the human — recorded only through the decision the human makes on it.
- **A handoff to a lens this flow does not seat** has no receiver here, so it is an open item shown to the human — who routes it to the background re-check, has it filed, or waives it. **Filing** means the `{tech}-reviewer` files it as a NEW finding on its next review, and you record the ruling `filed` with `--filed-as <that finding's id>` and `--proof <its file:line>` in the round that adds the finding. A waiver is recorded as `waived`, with the waiver's reason (below) as `--reason`. Each outcome is recorded on the handoff's `handoff:<N>` key (`review-core`, Stay in Your Lane; flags: `review-update-status.sh --help`); it is never left open silently.

**Every human decision is recorded.** Whenever one must be recorded — an edge-case confirmation (with or without a chosen re-check), a waiver, a handoff ruling, or a re-check — and no artifact exists yet, persist the reviewer's report first as a review artifact with `review-create.sh` (`flow-review` §5c's location, flags, and which artifact a later lens pass uses); from `flow-testing`, add `--plan-review` so its `plan:<item>` locations are accepted. A re-check of `not_tested` entries alone needs no review artifact — it is recorded in the plan's sidecar (`test-plan-recheck.sh`, `flow-testing` §5).

### Background re-check (the human's option, never automatic)

Runs only when the human's chosen option or answer includes the background re-check. The FIX round (if any) runs on what that option chose to fix and starts at once — a re-check-only choice runs just the re-check — and VERIFY never waits for the re-check; **in parallel**, two fresh agents re-check every set-aside item — edge cases, speculative entries, Not proven items, open handoffs, and in `flow-testing` the plan's `not_tested` entries the human has not waived (a waived entry is a decision, not a set-aside item).

**Every result is recorded.** When the re-check is dispatched, mark each item once with `review-update-status.sh --recheck pending`; when its outcome returns, record it once — `--recheck survived|cleared --recheck-proof <locator> --repo-root <repo>`, or `--recheck escalated --recheck-reason <plain words>` — on the item's key: a finding's `id`, `--speculative-key` for a speculative entry, the `handoff:<N>` key for a handoff (`review-update-status.sh --help`); no round is added. A `not_tested` entry is marked and recorded the same way with `test-plan-recheck.sh` (`flow-testing` §5). A survived speculative entry becomes a NEW realistic finding with `review-update-status.sh --speculative-key <KEY> --promote-to-id <ID> --severity <SEV> --category <CAT> --repo-root <repo> [--trigger <text>] [--fix <text>]` (`--trigger` is required for an escalated entry, which has no proof to take it from) — no round is added for it.

1. **Adversary — tries to prove each item real.** A fresh, cold instance of the flow's reviewer seat — the `{tech}-reviewer` here and for a `flow-review` artifact, `lens-test-quality-reviewer` in `flow-testing`; for a security item (`review-core`, Security is never rare — including a `not_tested` entry in a security or authentication category), `lens-security-reviewer` — in adversary mode, read-only, so it cannot disturb the fix round editing the same tree. **Adversary mode is a reviewer mode with one exception of its own: it does not hand off** — it rules on every item itself, whatever lens would own it. Brief: *"For each item, try to prove it is a real defect in this system. Read across boundaries — callers, consumers, and the related repos named here. Do not hand off; do not soften. Return your normal JSON report with exactly one entry per item — a finding or a speculative entry — each echoing its item key (an existing finding keeps its id; any other entry opens its `problem` or concern with the key) and carrying in `proof` the evidence that the item is real, or `unproven`."* — in adversary mode `proof` is evidence the item IS real, the opposite of a dismissal's proof. Give it the items (each with its key in `review-arbiter`'s `item` format, location, concern, the original reason it was set aside), the diff artifact, the related repos, and the acceptance goal — never the orchestrator's opinion of any item.
2. **Verifier — `review-arbiter`**, dispatched after the adversary returns, alone, in its re-check verifier role: the adversary's entries, each with its item key, plus the cited code and repo root. It rules the batch, one verdict per item keyed by `item`. Map every result — the adversary's entries and the verifier's verdicts — to its item by that key, never by location.

**An item survives only when the verifier confirms it** (`REAL`); every other ruling clears it, except `ESCALATE`, which is recorded `escalated` — with the verifier's `recommended_action` as `--recheck-reason` (longer than 200 characters → return it to `review-arbiter` once for one line; still longer → record `see the verifier's full reason` and show the human the full text with the item) — and shown to the human as needs-your-decision. **A security item is never cleared by doubt:** the verifier rules a `medium`-confidence call on it `REAL` (`review-arbiter`'s fail-secure rule), and it clears only on a high-confidence `FALSE_POSITIVE` whose proof is a locator; any other ruling short of `REAL` is recorded `escalated` and needs your decision — with the reason `security item, not proven harmless`, never the verifier's recommendation to dismiss it. **Each item is re-checked once** — a cleared item is not re-checked again, so this terminates. **Show the survivors to the human next to the fix round's results**; the human decides whether they join a fix round — an election is a new Address answer, and the items it names are mandatory like any other. An edge case the human confirmed that survives returns to the human as needs-your-decision. **An escalated item closes on the human's decision.** A finding: confirm it (`--confirm-edge-case`), elect it (`--realism realistic`), or waive it (`ACK`). A `not_tested` entry: elect it (a plan amendment, `flow-testing` §3d) or keep it untested (`test-plan-recheck.sh … --recheck dismissed --reason <reason>`). A speculative entry: elected → `--promote-to-id` (as for a survivor); judged harmless → `review-update-status.sh --speculative-key <KEY> --recheck dismissed --reason <reason>` — never on a security entry, which the human can only elect (and then waive the finding with `ACK`).

**Every proof** — on a dismissal, a re-check result, or a resolution — takes one of `review-core`'s proof forms (Proof for every dismissal). **When a script rejects a reviewer's or `review-arbiter`'s proof,** return that item to its author once for a valid proof or `unproven` — a security item cannot take `unproven` and without a valid proof stays realistic (`review-core`, Security is never rare) — never write a proof for it yourself. **A waiver is a decision, not evidence** — an `ACK` is recorded with `--status ACK --reason <reason>`, a handoff waiver with `--ruling waived --reason`, a `not_tested` waiver with `--waive-not-tested … --reason`: its reason is the human's own words or — when the human chose an option — that option's one-line reason as shown; free text, one line of at most 200 characters (write each option so its reason fits), never a proof form — if the human's words are longer, ask them for the one line to record.

In a `flow-review` artifact, these decisions are recorded with `review-update-status.sh` (`flow-review` §5c). On re-review, pass each decided finding's `realism` back as binding, and tell the reviewer which edge cases the human confirmed. The reviewer keeps its seat for every finding that still blocks.

**Every fix is a change, and a change gets re-reviewed.** VERIFY re-reads the ENTIRE fix diff, whoever authored it. The one thing that legitimately defers is a MEDIUM/LOW the human chose NOT to fix — safe precisely because nothing changed.

**"Satisfied" means its GATING findings are closed — not zero findings.** Every fix round produces fresh MEDIUM/LOWs; on the zero-findings reading the loop never terminates.

**When the cap is reached with the reviewer still unsatisfied, that is an ESCALATION, not an approval.** Report it plainly. Continuing past round 3 requires a new approval — not a counter you increment.

---

## 6. Variants

**Review only, correctness scope (no developer).** Triggered by *"review this"* with no lens named, or when re-entering to check a diff that was made outside this procedure (a direct-mode edit, most commonly). §1 + §3 (gate, with the Seats block's developer line omitted per its own note, and the Scope line naming the files picked — plus any changed file whose effort is unclear) → skip 4a/4b/4c (no developer round, so no path split applies) → 4d → 4e. Pick and restrict the effort's diff per `flow-review` §2 before the gate — with no developer dispatched there is no snapshot, so it is the default diff (the uncommitted work), or `--whole-branch` when the change under review is already committed — never let a committed change read as an empty diff; its stops (an empty diff, a named file that is unchanged) end this variant there. This is a `{tech}-reviewer` pass, not a lens pass — if the human wants lens scrutiny, that's `flow-review`, a separate ask. **If the reviewer returns `CHANGES_REQUIRED`,** there is no developer seated in THIS invocation to fix it — route the findings by re-entering §0 case 1 (a fresh build/fix request briefed with the specific findings), which seats the developer normally; §5's loop does not run standalone against an empty developer seat.

**Direct implementation (no matching subagent).** Not to be confused with Validate-First in §2 — Validate-First still has a `{tech}-reviewer`, just deferred; Direct implementation has none, ever; a cold agent's execution test (§2) checks it instead. §1 + §3 first — the gate is NOT optional; it is MORE load-bearing, because this mode has no developer and no `{tech}-reviewer`. Present the plan with the Seats block replaced by *"no subagent exists for [stack] — I implement, and a cold agent's execution test (§2) checks correctness."* Then:

1. Tell the user no specialized subagent exists for this stack.
2. Implement it, building to the shared standards — `build-core` + `standard-clean-code`, `standard-self-documenting-code`, `standard-observability`, `standard-performance`, `standard-security`, `standard-persistence` (durable stores), `standard-{lang}` if one exists. Design for testability per `build-core`'s own Implementation Workflow (clear boundaries, dependency injection, no hidden state) — never write the test file itself (`build-core`'s no-test-authoring rule binds you here exactly as it binds any developer). `standard-testing` is not among these: it is a pure test-authoring rubric with nothing for a non-test-author to act on, and does not apply here any more than it applies to any `{tech}-developer`.
3. **Review it — NOT optional, NOT self-performed.** Where no `{tech}-reviewer` exists, satisfy the correctness floor with the **execution test** (§2) — a cold `general-purpose` agent running the artifact against real scenarios. A lens pass is NOT part of this step by default — that's `flow-review`, on request.
4. Summarize per `build-report-standards`.

**Cross-repo / multi-tech-pair work.** When `flow-spec` governs the effort, each repo's `{tech}-developer`/`{tech}-reviewer` pair runs this ENTIRE procedure independently and in parallel, each briefed with the same approved spec (path + hint) as its acceptance criterion. There is no cross-pair coordination beyond that shared document — each pair's own gate, loop, and executive summary are its own.

---

## 7. Executive summary

Present: the stack · the developer · the `{tech}-reviewer` · the cycle count · what was achieved · the files delivered · the final verdict with issues found vs resolved · any seat still unsatisfied at the cap · notable decisions and rationale · **whether a lens review is available and not yet run — and, only if `flow-testing` has genuinely not run at all for this effort, that test-authoring is also available.** Never report a pass that already ran mid-flow (Validate-First's `flow-testing` detour) as "not yet run." **If §4d has not yet closed (a Validate-First effort still mid-flow), state that a lens-only review is not yet available — not merely "not yet run" — until it does; `flow-review` would otherwise have to seat the `{tech}-reviewer` itself (`flow-review` §0).**

**For a Validate-First effort, report both phases distinctly** — the live-validation outcome (what was checked, against what live source, what iteration happened before confirmation) and the subsequent reviewed-hardening cycle count — never one blended narrative that hides which phase caught what.

**If any developer report carried an open test-compilation blocker** (`build-core`'s Implementation Workflow, step 5 — the developer's own change broke an existing test and it stopped rather than touching it), surface it here explicitly, unresolved, with the repair-scope route named. This is not optional detail: `build-core`'s promise that "reporting the blocker is what resolves it" depends on this summary actually carrying it forward — a build is not DONE with a live, unsurfaced test-compilation blocker, whatever the `{tech}-reviewer` verdict says.

---

## Invariants (NEVER break)

- **Never auto-fires from repository state** — an explicit trigger only; the safety net for unreviewed changes lives in `flow-git-operations`'s commit gate instead (§0).
- **The trivial hatch closes on accumulation, not the keystroke** — 5 files changed this session and not yet through this procedure, any contract touched (an invariant, a gate, a schema, a public interface, a security/authorization rule), or any behavior change (§0).
- **Never dispatch anything without approval of the plan** (§3).
- **The roster always converges on the tech pair — never a lens** (§5's background re-check adversary is not a review seat). Dev-alone-first (Validate-First) is a resequencing when a live source exists, never a way to skip the `{tech}-reviewer`; a lens seat, however warranted-looking, is `flow-review`'s call, made separately (§2).
- **Correctness floor** — the `{tech}-reviewer` is the sole owner of code correctness; this flow is not DONE until it has run, for a real change, under either path — or, where no `{tech}-reviewer` exists (framework prose §2, direct implementation §6), until the execution test has run and no gap the human chose to fix is still open (§2). Validate-First legitimately defers WHEN it runs (§4c); neither path skips WHETHER it runs (§2).
- **An open test-compilation blocker is never resolved by silence.** If a developer's own change broke an existing test's compilation (`build-core` Implementation Workflow step 5), the executive summary MUST surface it, unresolved, with the repair-scope route named — a `{tech}-reviewer` APPROVED verdict does not close it, and this flow is not DONE while it stands (§7).
- **On any doubt about live-testability, recommend Pair-First** — a weak check does not qualify a task for the deferral, and a security-sensitive path (auth, crypto/secrets, untrusted input) recommends Pair-First regardless of what else is true (§1).
- **Binding `flow-testing` mid-flow is not dispatching it** — that dispatch earns `flow-testing`'s own §3 gate in full; approving THIS plan never authorizes it (§4c).
- **A deferred reviewer is a carried obligation, not a memory.** Once Validate-First is approved, every subsequent report — the live-validation checkpoint, `flow-testing`'s own summary, anything in between — restates that the `{tech}-reviewer` pass is still outstanding, until §4d actually closes it, OR a `flow-testing`-originated case-1 re-entry's own §4d supersedes it under both stated preconditions (§4c).
- **Ground truth before building on it** — verify a code-unverifiable contract against reality early (§1).
- **One batched fix round; every fix is reviewed** (§5).
- **The Address question is built from the report and leads with a good-faith recommendation** — facts on every option, no option for a kind of item the report lacks, never a recommendation to leave a security or realistic CRITICAL/HIGH unfixed; each edge-case CRITICAL/HIGH is asked about on its own (§5).
- **Anything the human chose is mandatory** — a developer decline stops the flow for an explicit human waiver; a partly addressed finding stays OPEN (§5).
- **The background re-check is the human's option, never automatic** — adversary + `review-arbiter` verifier, each item re-checked once and recorded (in a review artifact, or the plan's sidecar for `not_tested` entries), survivors shown to the human; VERIFY never waits for it (§5).
- **No handoff is left open silently** — one to a lens this flow does not seat is shown to the human, who routes, files, or waives it in their own words (§5).
- **Every brief describes behavior from the code, never pre-judges an item, and names related repos and the acceptance goal** (§4a).
- **The reviewer pass is guaranteed whenever changes exist; a FIX round on a gating finding or on items the human chose at the Address question. The cap is 3.** Hitting it unsatisfied is an escalation, never an approval (§5).
- **The reviewer keeps its seat until ITS gating findings close** — you never declare them resolved (§5).
- **Never price the review** — the gate asks about consequence, never tokens or time (§3).
- **Reviewers are read-only** and have no shell; hand them this effort's restricted `diff.patch` and `diff-files.txt` from `diff-scope.sh`, isolated by the effort's snapshot (§4a/§4d).
- **Expose every subagent report** as it completes.
- **Direct-mode review is independent, never self-performed** (§6).
- **A spec, when one governs the work, is handed by path + hint — never pasted verbatim** into a dispatch prompt (§1).
- **2+ parallel pairs without a governing spec requires an explicit human ask, never a unilateral decision** (`flow-spec` §0).

---
*The lens swarm lives in `flow-review`; the cross-repo contract in `flow-spec`; test-authoring in `flow-testing`; review conduct in review-core / review-report-standards; builder conduct in build-core.*
