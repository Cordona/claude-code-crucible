---
name: flow-decision
description: >-
  The panel — the reviewers + arbiter pattern for costly, forked decisions of ANY kind (a design
  or architecture call, a refactor-vs-rewrite call, a technical approach — not architecture only).
  Runs 2 (trio) or 3 (quartet) BLIND reviewers seated on ONE disposition-neutral base agent DERIVED
  from the fork (§1a — `software-architect` for a design fork, the matching `{tech}`-reviewer for a
  technical one, and so on), each given an OPPOSITE/orthogonal role briefing, plus a neutral
  `decision-arbiter` agent that resolves disagreement by reasoning, not vote. All seats on Opus.
  Neutralizes orchestrator bias on reversible-but-costly calls with multiple defensible answers. Default is the trio
  (soundness + skeptic); the quartet adds an operability-&-evolution lens for decisions with
  heavy run-it/change-it weight. Invoke on an explicit user request or a user-APPROVED offer
  — NEVER auto-run. This skill holds the role briefings (inject verbatim) and the procedure;
  the arbiter's mandate lives in the `decision-arbiter` agent (which binds the shared `standard-judging` constitution).
---

# Flow: Decision — the panel (sizes: trio / quartet)

A decision harness whose real job is **neutralizing orchestrator bias**. When the
orchestrator has a reflex toward some answer ("this file is too long, let me split it"), a
single reviewer inherits that framing and hands back a confidently wrong verdict. Multiple
reviewers with **different** lenses surface what none sees alone; a neutral arbiter resolves
their disagreement by judging reasoning quality.

**The value is complementary blind spots, not redundancy.** The reviewers share a base
agent — their independence comes entirely from the differing briefings in §3.

**The pattern is the _panel_; *trio* and *quartet* are only its two sizes:**
- **Trio (default): 2 lawyers + 1 arbiter** — Soundness (§3a) + Skeptic (§3b).
- **Quartet (opt-in escalation): 3 lawyers + 1 arbiter** — adds Operability & Evolution (§3c),
  for decisions with heavy run-it / change-it weight (service boundaries, data models,
  anything with deploy or migration consequences).

**3 lawyers is the ceiling.** The evidence is clear that panels peak at 3–4 and *degrade*
past 5, and that what matters is decorrelation, not count — so never add a 4th lawyer;
spend the budget on making each lens genuinely different.

---

## 0. Entry — never auto-runs

Starts only one of two ways, both human-gated. **Either way, the orchestrator FIRST renders the
Panel Plan (below) as live markdown — a panel NEVER runs until the user has seen it.** A panel spawns
3–4 Opus lawyers + an arbiter; the user authorizes *why* it runs and *which seats* run, never a bare
"pressure-test, y/n?".

### The Panel Plan (render as LIVE MARKDOWN — never inside a code fence)

The `>` marks below delimit the spec here; they are not part of what you emit.

> ## ⚖️ Panel Plan
> - **Decision:** *[the fork, framed as a question]*
> - **Candidate answers:** *[the ≥3 defensible options]*
> - **Why a panel:** *[the concrete trigger IN THIS decision — forked with ≥3 defensible answers · costly to undo: (name the real cost) · (orchestrator-bias signal, if any)]*
> - **Seats:** base = `[the §1a-derived agent]` *(why this base fits the fork)* · Soundness (§3a) · Skeptic (§3b) · *[Operability & Evolution (§3c) — quartet only]* · arbiter = `decision-arbiter`

**Why-a-panel and Seats are BOTH required** — a plan that names neither is the thin "pressure-test?"
prompt this gate exists to replace. Derive the base per §1a BEFORE rendering; if no single base fits
the fork, that is the §1a signal the decision is really two decisions — split it, do not average.

1. **Explicit user request** — "run a panel" / "run the trio" / "run the quartet", "add an ops lens",
   "review this decision". Render the Panel Plan as a **one-look confirmation** — the explicit
   request IS the authorization, so this is transparency, not a re-gate: it surfaces the *why* +
   *seats* in the same turn as dispatch, so a surprising roster is visible and the user can
   interrupt before the agents finish. No `AskUserQuestion` modal — do not re-gate a panel the
   user already asked for.
2. **Main-thread offer** — the orchestrator judges the decision worth pressure-testing and OFFERS.
   Render the Panel Plan, then gate via `AskUserQuestion`. Run **only** on approval.

> **Offer heuristic:** offer when the decision is a **complex/costly forked
> call of ANY kind (design, technical, refactor-vs-rewrite, UX…) with multiple defensible answers** — ideally ≥3, and undoing it costs real refactor
> time. Bias is a strong extra signal but not required. Offer the **quartet** (third option)
> only when the decision has a genuine **operational or evolutionary** dimension the two
> default lenses would underweight; otherwise offer the trio.

The offer prompt (via `AskUserQuestion`, rendered directly BELOW the Panel Plan — the Decision, the
why, and the seats live in the plan above, so the question captures only the choice):
- **Header:** "Decision"
- **Question:** "Run the panel above on this decision, or decide normally?"
- **Options:** "Panel — trio (2 lenses)" · *(if a strong 3rd axis)* "Panel — quartet (+operability lens)" · "Decide normally"

When you offer the **quartet** option, the Panel Plan's **Seats** line MUST already show the
bracketed *Operability & Evolution (§3c)* seat — never offer a size whose extra seat the plan did
not render (the "user has seen the seats" invariant applies to every size on offer).

**Do NOT offer** when a contract / type / test dictates the answer · the change is mechanical
· there is one obviously-correct answer · the fix is one line.

---

## 1. The roster (ONE derived base, different lenses — all Opus)

| Seat | Agent | Lens (injected briefing) | Trio | Quartet |
|------|-------|--------------------------|:----:|:-------:|
| Reviewer A | *the derived base* (§1a) | **Soundness** — is it built right? (§3a) | ✅ | ✅ |
| Reviewer B | *the derived base* (§1a) | **Skeptic** — do we even need it? (§3b) | ✅ | ✅ |
| Reviewer C | *the derived base* (§1a) | **Operability & Evolution** — can we run & change it? (§3c) | — | ✅ |
| Arbiter | `decision-arbiter` | Neutral synthesizer (mandate in the agent) | ✅ | ✅ |

### 1a. Deriving the base (NEVER hardcode a profile)

**The panel is not an architecture tool.** It is the machinery for *any* costly, forked decision.
Derive ONE base agent from the fork itself and seat it for every lawyer seat:

| The fork is about… | Base |
|---|---|
| design · boundaries · where a responsibility lives | `software-architect` |
| a technical approach in one stack (*"is this concurrency model sound?"*) | the matching `{tech}`-reviewer |
| refactor vs rewrite · is this worth the churn | the matching `{tech}`-reviewer, or `software-architect` if it is structural |
| a data-model / storage fork | `lens-persistence-reviewer` |
| a UI/UX direction | `react-reviewer` (it owns accessibility) — there is no separate UI/UX specialist agent today |
| anything else | the agent whose declared expertise *is* the fork's subject |

**Every lawyer seat uses the SAME base — this is not a style rule, it is the control.** Independence
must come from the briefing alone. Seat A on `rust-reviewer` and seat B on `software-architect` and a
disagreement between them is uninterpretable: you cannot tell whether the lens or the expertise
produced it. One base ⇒ the lens is the only variable ⇒ the disagreement means something.

State the chosen base and WHY in the plan you put to the user. If no single base fits the fork, that
is a signal the decision is really two decisions — split it rather than mixing bases.

All seats run on the **strongest model (Opus)** — do not downgrade any seat, and do not vary the model across seats (the substrate-diversity exception is WITHDRAWN; see §1a).

The reviewers are the **same** disposition-neutral base agent; independence comes **entirely
from the differing briefings**, not the model. Because they share a base, two things are
load-bearing: (1) the briefings must be **genuinely different questions** (Seat B is
deliberately adversarial — that engineered opposition is a key decorrelator), and (2) the
**arbiter must read the raw artifact** — its only safety net for a blind spot the reviewers
share.

**Do NOT swap a single seat to a different agent.** (An earlier version of this skill offered that
as a hatch for code-entangled decisions — it is withdrawn: it silently mixes bases and destroys the
control above.) If the call hinges on code-level facts a call-graph trace would settle, that is not a
reason to swap ONE seat — it is a signal that the `{tech}`-reviewer is the right base for **all** of
them. Derive it in §1a and seat it everywhere.

---

## 2. Procedure

```
1. State the decision + write out the ≥3 defensible answers (the framing artifact). Front-load ALL
   justifying evidence — especially runtime/external facts NOT visible in the code — and name every
   affected component NEUTRALLY: never "X is unchanged / fine / out-of-scope" (a dismissal steers
   every lawyer off it); say "verify X independently".
2. DISPATCH the lawyers (2 for trio, 3 for quartet) in ONE message = parallel Task calls,
   all on the SAME derived base (§1a) — never assume `software-architect`.
   • Identical material (the proposal + artifact paths + reference docs).
   • Different briefing per seat (§3). Ask each for STRUCTURED findings (§3e).
   • Neither/none is told the others exist.
3. COLLECT all reports.
   • Any disagreement → TRIPWIRE: do NOT pick a winner yourself. Spawn the `decision-arbiter`.
   • Full agreement → STILL spawn the arbiter. (An earlier version allowed "LOW-stakes:
     you may confirm & proceed" — withdrawn: §0's entry criteria admit no low-stakes
     run, so that branch only ever let the biased orchestrator this pattern exists to
     neutralize bless a unanimous verdict without an independent read.) HIGH-stakes (the costly/
     irreversible calls that justified this): still spawn the arbiter for an independent
     artifact spot-check — correlated reviewers agreeing is weak evidence, and the biased
     orchestrator should not bless it.
4. ARBITER returns item-by-item resolutions with reasoning (or ESCALATE).
   • ACCEPTANCE — REJECT the report and re-dispatch if it omits ANY of: the two
     standing-duty lines (option-set completeness · shared-substrate blind spot)
     or the Confidence line. They are the arbiter's mandate, not a template it may
     trim — and a silent omission is precisely the failure they exist to catch.
     (The `review-arbiter` gets this for free: a missing JSON key is malformed.
     A prose report can drop a line and look complete. Check it.)
   • Confidence `low` on a costly, hard-to-undo call → treat as ESCALATE, not
     APPROVED. Report the uncertainty to the user; do not launder it into a verdict.
5. CHANGES REQUIRED → iterate from step 2. APPROVED → present to the user. ESCALATE →
   surface the open question to the user.
6. CAP: 3 cycles → escalate.
```

---

## 3. The role briefings (inject VERBATIM into each lawyer seat — on whatever base §1a derived, never assume `software-architect`)

Keep these identical run-to-run. The base is disposition-neutral; the briefing supplies the
lens. **Do NOT mention that other reviewers or an arbiter exist** — the reviewers are blind.

**Shared preamble — prepend to EVERY lawyer briefing (§3a–§3c):**

> Before you evaluate the proposal, VERIFY THE FRAMING DOCUMENT's load-bearing claims against the
> actual code. It was written by the proposer and is the one input no one else audits — treat it
> as unverified. Report any claim that is wrong or overstated, and do not build your analysis on a
> premise you have not confirmed at `file:line`.
>
> And treat any framing phrase that calls a component *unchanged / fine / not a concern / out-of-scope /
> a bystander* as a **RED FLAG to open and verify that component directly** — a dismissal is exactly
> where a defect hides, because it tells everyone to look away. Distrusting the *word* is not enough:
> audit the *file*. (This preamble catches *wrong* framing claims; it cannot catch *omitted* evidence —
> if something looks unjustified, first weigh whether the justification is a runtime/external fact the
> framing simply left out.)

This is a precondition, not a lens: the framing artifact is the single **un-decorrelated** input to
the whole run (authored by the biased orchestrator), so every seat re-checks it independently rather
than trusting it.

### 3a. Reviewer A — Soundness (is it built right?)

> ROLE: Argue the soundness case. Judge this decision on structural correctness — SRP/cohesion,
> contract and boundary correctness, idiomatic patterns, long-term maintainability. Trace the
> actual dependency/call graph and verify every structural claim against the files. Where the
> proposal is sound, say so and why; where it is structurally wrong or risky, say so with the
> evidence. Commit to this lens fully.

### 3b. Reviewer B — Skeptic (do we even need it?)

> ROLE: Argue the minimalist skeptic case. Push back on EVERY move that lacks a named failure
> mode. For each change, demand: "what specific bug or failure does this prevent?" Be hostile to
> speculative future-proofing and to "this would be cleaner" with no concrete justification;
> default to the simplest shape the codebase already uses; call out over-engineering and any
> orchestrator bias you detect. FIRST do an independent first-principles scan of the artifact as
> if you are the only reviewer — do not anchor on the proposal's framing. IMPORTANT: demand
> justification for the *proposal*; do NOT manufacture justification for *rejection* by misreading
> the code — verify any comparative claim ("X is simpler today") against the artifact first. Before
> concluding "X is unjustified — drop it," weigh whether the justification could be a RUNTIME or
> EXTERNAL fact absent from the code (async payload shapes, production data, upstream behavior); if
> that is plausible, return "justification not shown — confirm premise Y" rather than a flat "drop it".
> Commit to this lens fully.

### 3c. Reviewer C — Operability & Evolution (quartet only; can we run & change it?)

> ROLE: Argue the operability & evolution case — judge this decision by life AFTER it ships, on
> two related questions. (1) OPERABILITY: how painful is this to run day-to-day? — deployment,
> monitoring/observability, rollback, runtime scope, on-call burden, production failure
> modes. (2) EVOLUTION: how painful is this to change over time? — migration cost, how it ages
> against the likely next requirement, reversibility, coupling to things that change. IMPORTANT:
> these two forces often CONFLICT (an ops-simple monolith can be evolution-hostile; a flexible
> plugin design eases evolution but complicates ops). When they pull in opposite directions here,
> SURFACE THE TENSION explicitly as a finding — do not average it into one muddy verdict. Ground
> every claim in the artifact. Commit to this lens fully.

### 3d. Arbiter

Full mandate (verify-every-claim, decide-*why*-not-*which*, **three STANDING duties — challenge
option-set completeness + name the shared-substrate blind spot + state confidence**, bias guards,
implementation-review nuance, escape hatch, structured verdict) lives in the **`decision-arbiter`
agent** — which binds the shared **`standard-judging`** constitution. The three standing duties
fire on *every* run and are required verdict fields, not behaviors the orchestrator must remember to
inject. Dispatch it with:
the decision, ALL reviews labeled neutrally ("Review 1"…"Review N" — **swap their order across
cycles** to blunt position bias), and the raw artifact paths (never the reviews alone).

### 3e. Ask each lawyer for STRUCTURED findings

So the arbiter can adjudicate 3 reviews without context dilution, ask each seat to return its
structured findings plus a one-line overall recommendation — not a prose essay — conforming to
`$HOME/.claude/crucible/contracts/decision-lawyer-finding.schema.json` (framework source:
software-development/contracts/decision-lawyer-finding.schema.json), which fixes the per-claim shape
(`claim`, `severity`, `evidence` at `file:line`, `verdict`) and the top-level recommendation.

---

## 4. Guardrails (the main thread's job)

| Risk | Guardrail |
|------|-----------|
| Runs when needless | **Never auto-run.** Explicit request or approved offer only. |
| Reviewers leak into each other | **One message, parallel Task calls, zero cross-reference.** Never put one report in another's prompt; never mention a counterpart. |
| Reviewers redundant | Same base, but **genuinely different questions** per seat (§3). Seat B stays adversarial. Never give two seats the same lens. |
| **Too many lawyers** | **3 is the hard ceiling.** Panels degrade past ~4; more count ≠ more signal. Never add a 4th lawyer. |
| Clone lens (no decorrelation) | If the 3rd lens rarely produces a *distinct* finding across runs, it isn't earning its seat — drop back to the trio. |
| Over-trusting unanimity | Agreement from same-base reviewers is weak evidence. On high-stakes calls the **arbiter still spot-checks** the artifact. |
| **Framing artifact carries the proposer's errors** (the one un-decorrelated input) | Every lawyer briefing is prepended with the **verify-the-framing-doc preamble** (§3): each seat independently checks the framing's load-bearing claims against the code before evaluating. The orchestrator should also self-verify it before dispatch. |
| **Framing OMITS justifying evidence, or EDITORIALIZES** a component as unchanged / fine / out-of-scope | The verify-preamble catches *wrong* claims but not *missing* evidence or *steering* dismissals (both hid findings in run 2). Orchestrator: front-load all justifying evidence incl. runtime/external facts, and name components neutrally (§2). Seat backstop: the §3 preamble treats any "unchanged / fine / out-of-scope" as a red-flag-to-audit-directly, and the Skeptic returns "justify-or-drop" rather than dropping on possibly-omitted runtime evidence (§3b). |
| **Shared-substrate blind spot** (all seats + arbiter share one base model) | A model-level blind spot is invisible to everyone at once. Mitigation: the arbiter's **standing duty** to re-derive from the artifact and name what all seats jointly miss (§3d + arbiter agent). Highest-stakes / irreversible calls only: optionally run ONE seat on a **peer-strength model from a different family** (lateral decorrelation, never a downgrade). Within one provider substrate diversity is limited, so the standing duty carries most of the load. |
| Arbiter context dilution at N=3 | Feed **structured findings** (§3e), not prose; **rotate review order** each cycle. |
| **Self-arbitration (cardinal sin)** | The instant you weigh one lens against another *in your own voice*, STOP — spawn the `decision-arbiter`. |
| Briefing drift | Briefings copied verbatim from §3. |
| Infinite loop | 3-cycle cap → escalate. |

---

## Invariants (NEVER break)

- **Never auto-run** — explicit request or user-approved offer only.
- **Render the Panel Plan before any panel runs** — both entry paths; it names *why a panel* AND *which seats* (§0). The offer gates on it via `AskUserQuestion`; the explicit path shows it as a one-look confirmation. A panel dispatched without the user having seen the seats is an auto-run in disguise.
- **Blind reviewers** — seats never see each other's briefing or output; never told a counterpart exists.
- **Different lenses** — every seat gets a different briefing; never the same lens twice.
- **Max 3 lawyers** — never a 4th. Decorrelate, don't multiply.
- **All seats on Opus** — never *downgrade* a seat. (WITHDRAWN — see §1a: a different model family reintroduces substrate as a second variable on exactly ONE seat, which is the identical argument that withdrew the agent-swap hatch. The Task tool's model enum is Anthropic-only, so it is likely undispatchable anyway. Former text: Exception — highest-stakes, least-reversible calls only: ONE seat MAY run on a **peer-strength model from a different family** for substrate decorrelation; a lateral swap, never a weaker model.)
- **No self-arbitration on disagreement** — spawn the `decision-arbiter`. On high-stakes agreement, still let the arbiter make the final call.
- **The arbiter is never the orchestrator.**
- **The arbiter's independent artifact read is non-negotiable** — never weaken it to "read the reviews + spot-check." It is the pattern's last line of defense against a framing that misdirects the lawyers (run 2: the arbiter was the only seat to catch a gating, ship-blocking bug).

---

## Reference

Empirically validated across n=8 trials (plans, docs, audits, implementations) in the
`claude-code-agent` project: `claude-code-agent/docs/dual-reviewer-arbiter-pattern.md`.

**Validation log — this implementation:**
- **2026-07-15 · n=1 · architectural decision (all-in-memory React 19 rendering performance) · trio (Soundness + Skeptic + arbiter):** SUCCESS — orchestrator bias neutralized (reflex answer demoted to #5 of 6; real dominant cost surfaced), verdict sound. Two structural weaknesses observed → **hardened in this version:** the framing artifact shipped 2 factual errors caught only by luck of briefing (→ §3 shared verify-the-framing preamble), and the highest-value finding (a shared-model `useMemo`-isn't-a-cache footgun) fired only because the orchestrator ad-hoc-instructed the arbiter (→ arbiter standing duties + §4 substrate row). See `feedback/2026/07/16/flow-decision-first-run.md`.
- **2026-07-16 · n=2 · implementation review (async sub-agent token capture + per-turn aggregation, 3 repos) · quartet (Soundness + Skeptic + Operability&Evolution + arbiter):** SUCCESS — the run-1 hardening fired NATIVELY: the arbiter's standing duty re-derived from the raw artifact a GATING, ship-blocking defect no other seat found (backend hydration seed used `.first(delta)` instead of summing per-Stop deltas — the *exact* bug the change existed to fix), which a full dev↔reviewer loop + all 3 lawyers + the framing all missed; all framing errors were independently caught by the lawyers. Residual weakness moved UPSTREAM to the orchestrator's framing — a framing OMISSION (runtime fact absent → one false "drop it") and an attention-steering "unchanged" editorial (hid the gating file; lawyers distrusted the word but none audited the file) that the verify-preamble structurally cannot catch → hardened here: §3 dismissal-as-red-flag + omission caution, §3b justify-or-drop, §2 front-load-evidence + neutral-framing step, §4 editorializing/omission row, and the arbiter-independent-read invariant. See `feedback/2026/07/16/flow-decision-second-run.md`.

Design refinements are drawn from the LLM-as-judge / panel-of-judges / multi-agent-debate
literature: 3 reviewers is the empirical sweet spot (PoLL, ChatEval, multiagent debate) and
5 is the ceiling before error-correlation saturates ("Nine Judges, Two Effective Votes");
decorrelation — not count — is what buys signal, achieved here via **aspect-different lenses
+ one adversarial stance** (the two schemes shown to actually decorrelate); a **reasoning
arbiter over voting** (fits few differentiated, information-rich lenses — MoA aggregator /
red-blue-green adjudicator); blind independence over debate (avoids conformity collapse);
structured findings + order-rotation to keep a 3-input judge reliable; and an
"insufficient evidence → escalate" hatch.

**Cost:** trio ~3×, quartet ~4× a single-reviewer cycle. Expensive per run, cheap relative to
a wrong architectural decision — the human gate and offer heuristic keep it rare.
