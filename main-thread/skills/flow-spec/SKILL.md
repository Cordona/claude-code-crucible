---
name: flow-spec
description: The orchestrator's procedure for authoring a specification BEFORE implementation starts — for cross-repo/multi-tech-pair work (where it is close to mandatory, since independently-briefed parallel pairs drift) AND equally for any single-repo, single-tech-pair effort where the human wants the contract nailed down before building. Bind this when a task spans multiple repos, multiple `{tech}-developer`/`{tech}-reviewer` pairs working in parallel, a genuinely forked interface design, or on an explicit human ask for a spec-first approach regardless of scope. Covers deciding whether the interface decision itself needs a `flow-decision` panel first (propose-only, never auto-fired — same rule as a lens seat), briefing `software-architect` to draft the contract, the human approval gate, and persisting the spec as a durable artifact each `flow-implementation` pair is briefed against. Does NOT run the panel itself (flow-decision), build against the spec (flow-implementation), or review it (flow-review).
---

# Flow: Spec

The procedure the primary agent follows before implementation starts, whenever a contract is worth nailing down first. **Cross-repo/multi-tech-pair work is where this is closest to mandatory; a single repo, single tech pair is an equally legitimate use, just never a required one.**

**Why this exists — two distinct motivations, not one.** (1) Parallel tech pairs, each independently interpreting the same ambiguous request, do not converge by accident — they drift, each plausibly, each differently. A cheap, human-approved contract all of them build against removes that failure mode entirely; it doesn't just reduce cost, it removes an entire class of risk a cheaper checkpoint (a sketch, a plan) wouldn't touch. This is the near-mandatory case. (2) Even with only one tech pair, the same cheapest-checkpoint-first principle still applies: a contract agreed before a single developer writes a line is still cheaper than a full build the human has to redirect afterward. This is the optional but equally real case — bind it whenever the human asks for a spec-first approach, or you judge the request is large/ambiguous enough that nailing the contract down first would clearly help, and PROPOSE it rather than deciding alone. This is also the CHEAPEST checkpoint in the whole pipeline — one architect draft, one approval, before any build — so it belongs first whenever it runs at all.

---

## 0. When this applies

**Bind this skill when:**
- The task spans **multiple repositories**, each needing its own `{tech}-developer`/`{tech}-reviewer` pair — closest to mandatory, since independent pairs will drift without a shared contract.
- The task spans **multiple tech stacks** within one effort, even in a single repo — same reasoning.
- A **single-repo** interface decision is genuinely forked (multiple defensible designs) and costly to get wrong.
- **The human explicitly asks for a spec-first approach**, for ANY effort — including a single repo, single tech pair. Nailing down the contract before implementation is a general risk-reduction tool, not solely an anti-drift mechanism for parallel pairs, and it is available on request regardless of scope.

For a normal single-repo, single-stack build where nobody has asked for a spec, go straight to `flow-implementation` — this skill is never required there, only available.

---

## 1. Decide whether the interface itself needs a panel FIRST

**A `flow-decision` panel is propose-only, never auto-fired — identical rule to a lens seat in `flow-review`.** If, while scoping the work, the interface/contract has genuine forks (not just "write down the obvious contract"), say so explicitly to the human — *"this decision point has 2+ defensible options, here's why a panel might be worth it"* — and let them decide whether to invoke `flow-decision`. **Panels are expensive too** (all seats on Opus, blind reviewers + an arbiter) — they earn their cost the same way a lens swarm does, by an explicit ask, never by your own judgment that the decision "seems forked enough."

If a panel runs, its resolution becomes an input to §2's draft. If no panel is warranted or wanted, `software-architect` drafts directly.

---

## 2. Draft the spec

Brief `software-architect` (it has no conversation history — give it the full request, the repos/components in scope, the panel's resolution if one ran, and any known constraints). It drafts:

```markdown
# Spec: <short title>

**Status:** draft
**Created:** <date>
**Repos in scope:** <repo (tech)> — one entry for a single-repo effort, one per repo for cross-repo work

## Goal
<one paragraph: the outcome this spec exists to produce>

## Non-goals
<explicitly excluded scope>

## Interface contract

### <repo> (<tech>)
- Exposes: <contract>
- Consumes: <contract>

## Constraints
<backward-compat, perf budget, auth model, etc.>

## Decision log
*(populated only if a flow-decision panel ran)*
- <fork>: options considered → decision + why

## Open questions
<explicitly deferred, non-blocking>
```

---

## 3. The gate (MANDATORY — before ANY parallel dispatch)

**Present the draft and wait for approval before any `flow-implementation` pair starts.**

**Emit as LIVE MARKDOWN — never inside a code fence.** Show the full drafted spec, not a summary — the human is approving the actual interface contract every parallel pair will build against, not a description of it.

**Then gate via `AskUserQuestion`** — Header "Spec" · Question *"Approve this spec? All parallel builds will follow it verbatim."* · Options: **"Approve"** (status flips to `approved`, dispatch may begin) · **"Adjust"** or free text → re-brief `software-architect`, re-present.

**Ask about the contract's correctness — never cost.** Never surface token or time estimates, even though this gate is what stands between one draft and N parallel builds.

---

## 4. Persist the durable artifact

Location: `.crucible/docs/specs/{year}/{month}/{day}/{effort-slug}.md` (+ a same-named `.json` alongside it), written once at approval time, referenced (never re-dated) by every downstream commit/PR/`flow-implementation` dispatch for the life of the effort.

> **Not yet backed by a script.** Same status as `flow-review`'s artifact persistence — the design is agreed, the write mechanism is not yet script-backed. Persist by writing the file directly until the deterministic script exists.

---

## 5. Briefing each parallel `flow-implementation` pair

**Path + a short navigational hint — never the full spec pasted into the dispatch prompt.** E.g.: *"Read `.crucible/docs/specs/2026/07/29/cross-repo-job-submission.md` — focus on the `### service-api (Kotlin)` section, but the Goal/Non-goals/Constraints sections apply repo-wide too."* This is not a cost-saving shortcut at the expense of correctness — it's the more correct choice: a pasted excerpt is a snapshot that can drift from the committed file if the spec is later amended, while a path always resolves to the current truth. Each pair's `{tech}-reviewer` checks conformance against the spec's Interface contract section as an acceptance criterion, not just generic code quality.

---

## Invariants (NEVER break)

- **A panel is propose-only, never auto-fired** — same rule as a lens seat (§1).
- **No parallel `flow-implementation` dispatch without the human's explicit approval of the spec** (§3).
- **The spec is a durable, committed artifact, not conversational context** — every pair is briefed with a path, never a paraphrase (§4, §5).
- **Never paste the spec verbatim into a dispatch prompt** — path + hint only (§5).
- **Never price the review** — the gate asks about the contract's correctness, never tokens or time (§3).

---
*Procedure Version: 1.0 — the cross-repo/multi-tech-pair gate that precedes `flow-implementation`. The panel itself lives in `flow-decision`; the drafting specialist is `software-architect`. Artifact persistence mechanism agreed but not yet script-backed (§4).*
