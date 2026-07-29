---
name: flow-review
description: The orchestrator's procedure for an EXPLICIT, on-demand lens review — the ONLY place a `lens-*` reviewer is ever dispatched. Bind this ONLY when the human explicitly asks for a review pass beyond correctness (e.g. "run a full review", "check this for security/performance/clean-code", "review it properly"). NEVER auto-fires — not from repository state, not from the size of a change, not as a followup to `flow-implementation` finishing. Covers deriving the lens roster from the actual diff, the approval gate, dispatching the swarm in parallel, merging findings, and persisting them to a durable, trackable artifact (one per repo in cross-repo work). Does NOT run a fix loop itself — findings are handed to `flow-implementation` to address. Does NOT define review conduct or report schemas (review-core, review-report-standards), the tech-pair build (flow-implementation), or the cross-repo spec (flow-spec).
---

# Flow: Review (on-demand)

The procedure the primary agent follows for a deep, multi-lens review. **Bound only when explicitly requested.**

**Why this is a separate skill and not part of building.** The previous design (`flow-orchestration`, now retired) ran the full lens swarm on every build, automatically. On a large or cross-repo task that meant every lens firing on every round, of every repo, whether or not the change actually presented that lens's risk — cost and latency scaling with roster size and repo count, not with the size of the actual risk. Worse: an automatic swarm reviews and polishes whatever was built, including a misunderstood implementation, before a human ever gets a cheap look at the direction. **This skill exists so the expensive review only ever runs when a human decides it's worth running** — the tech-pair loop in `flow-implementation` is the safety net that ships correct code; this is the deliberately-invoked deeper pass.

---

## 0. When this applies — an explicit ask, never automatic

**Bind this skill ONLY when the human explicitly requests it.** Trigger phrases: "review this properly", "run the lens swarm", "check it for [security/performance/clean-code/…]", "full review". It does **not** fire because:
- a `flow-implementation` build just finished (however large),
- repository state shows unreviewed changes (that's `flow-git-operations`'s cheap check, not this),
- the change is large, risky-looking, or touches many files.

If none of those is an explicit ask, don't propose this skill unprompted beyond noting in `flow-implementation`'s executive summary that it's available.

---

## 1. Brief yourself

Read the request and the diff/target. Establish scope: is this a fresh review of a `flow-implementation` result, a re-review of specific prior findings, or a full audit of existing code the human names directly? For **cross-repo work**: this runs once **per repo**, independently — see §6.

---

## 2. Roster — the lens swarm, derived from the diff, correctness NOT re-seated

You already know the available subagents from your Task tool. Select dynamically; never from a hardcoded list.

**The `{tech}-reviewer` is NOT re-seated here.** It already ran as part of `flow-implementation`'s correctness floor. This procedure adds the quality lenses on top of already-correctness-reviewed code — it does not re-check correctness. If the human specifically wants a fresh correctness pass too, say so and seat it explicitly, but that's the exception, not this skill's default shape.

**Read, don't audition.** For each `lens-*`, read the **Applicability** it declares in its own description and reason the change against it. That declaration is free. **Never invoke a lens to ask whether it wants a seat.** Where its declaration genuinely doesn't settle it, put it in the plan's **Uncertain** block and let the user resolve it at the gate.

**Do NOT expect a small roster, and do not sell it as one.** On a substantive change most lenses genuinely apply — the filtering bites on small changes, where `Skip when` clauses fire honestly. **A large roster on a large change is the correct answer.** What makes this cheap relative to the previous design isn't a smaller roster on a big task — it's that the roster only ever runs when a human asked for it, once, not automatically on every build round.

**What the derivation buys is the EXCLUSIONS, not the inclusions.** "Seat, because [risk]" is unfalsifiable. **"No seat — accepting: [what we'd miss]" is a real claim the user can check and reject.** State every seat AND every exclusion.

**Security floor (hard).** Honor any lens marking itself security-critical; include it on ANY doubt.

**Resolving lens names.** Match the user's plain-words request ("logging", "conventions", "tests") against the `lens-*` agents' own descriptions.

---

## 3. The gate (MANDATORY — before ANY dispatch)

**Present the plan and wait for approval before dispatching the swarm.**

**Emit as LIVE MARKDOWN — never inside a code fence.**

> ## 🔍 Review Plan
>
> - **Target:** [what's being reviewed — repo/component, diff or full audit]
> - **Scope:** [what changes · what it touches]
>
> ### Seats
> - `lens-…` — [the specific risk IN THIS CHANGE it catches]
>
> ### No seat
> - `lens-…` — [why this change doesn't present that risk] → accepting: [what we'd miss]
>
> ### Uncertain
> - `lens-…` — [why its declared applicability doesn't settle it]
>
> ### After this review
> - findings land in a durable artifact; addressing them is a separate, explicit `flow-implementation` re-entry — this procedure does not fix anything itself

**Rendering rules — part of the format, not style advice:**
- **Every field is a bullet.** Never align labels with padding spaces: markdown collapses whitespace, so alignment survives only inside a fence — and a fence turns the plan into an unreadable grey box.
- **Never join two lines with a single newline** expecting a break. Use separate bullets.
- Omit empty sections rather than emitting empty headings — **except No seat**, which always appears: an exclusion with nothing under it is a claim the user needs to see.

**Then gate via `AskUserQuestion`** — Header "Review" · Question *"Approve this review roster?"* · Options: **"Approve & run"** · **"Adjust roster"** or free text → apply, re-present, ask again.

**Ask about scope and roster — never cost.** Never surface token or time estimates.

---

## 4. Dispatch → merge → persist → expose

### 4a. Dispatch the swarm — in parallel, one Task call each.

Each reviewer binds `review-core` + `review-report-standards` (+ `review-boundaries` where it has contested territory), is read-only, returns a structured report.

**Reviewers have NO shell.** Materialize the diff to a file and pass its absolute path. `git diff` **omits untracked files** — enumerate new files explicitly.

Give each: **exact file paths** · diff/PR or full audit, **with the diff artifact path** · **tech version + language** · the spec (path + hint), if one governs this work · **prior-round findings on a re-review**, so IDs stay stable.

### 4b. Merge.

Dedup by finding `id` internally, then render per `review-report-standards` **Rendering 1** — grouped by reviewer → severity, status as words, no finding ids in the human view.

### 4c. Persist to the durable artifact.

Every review produces a durable, trackable record — not just conversation output. Location: `.crucible/docs/reviews/{year}/{month}/{day}/{repo-or-effort-slug}.md` (+ a same-named `.json` source of truth alongside it), created once per review effort and updated in place across rounds — the date reflects when the effort started, not the most recent update. The JSON carries the same stable IDs and status lifecycle `review-report-standards` already defines (open → in-progress → approved / approved-with-followups); the MD is the deterministically-rendered human-facing view. **The reviewer never writes this file directly** — it returns its findings as today, and the orchestrator is the one who persists/updates the artifact, the same division of labor already used for commits (`git-operator` plans, orchestrator executes) and Jira/GitHub writes (`project-manager` drafts, a script writes).

> **Not yet backed by a script.** The persist/render/status-update mechanism described here (mirroring the GTD inbox's `capture.sh`/`process.sh`/`render-md.sh` discipline) is the agreed design but is **not yet implemented** — this procedure currently persists by writing the file directly, pending the deterministic scripts. Do not treat the absence of the script as license to skip persisting the artifact; write it by hand until the script exists, then switch over without changing this procedure's shape.

### 4d. Expose.

Present a concise summary (verdict + counts per repo/severity) and a link to the durable artifact(s) — never re-paste the full findings inline; the artifact is the source of truth from this point on.

---

## 5. This procedure does not fix anything

Findings are addressed by re-entering `flow-implementation` — the developer + `{tech}-reviewer` tech pair, not a lens, and not this skill. **Brief that re-entry with the durable artifact's path plus the specific finding IDs it should address — never by re-pasting the findings' full text into the dispatch prompt**, the same path+hint discipline `flow-spec` uses for its own artifact: the artifact is the current truth, a pasted copy is a snapshot that can drift from it. A lens is re-invoked ONLY on a fresh, explicit ask (a new `flow-review` invocation), never automatically because a fix touched the same files. If a fix causes a genuinely new issue, that's reported back to the orchestrator (never appended directly to the artifact by a reviewer), who updates the durable artifact and re-briefs the developer — mirroring exactly how `flow-implementation`'s own fix loop already works.

---

## 6. Cross-repo work — separate artifacts, never merged

When the effort spans multiple repos/tech stacks, this procedure runs **once per repo**, producing **one JSON+MD pair per repo**, sibling files under the same dated folder (`.crucible/docs/reviews/{year}/{month}/{day}/service-api.md`, `.../core-engine.md`, `.../web-client.md` — not nested per-repo subfolders, since each is a single evolving file, not a growing log). Never merge findings across repos into one document — each tech pair addresses only its own repo's artifact. The executive summary presented to the human is a short verdict table across all N artifacts (verdict + counts), linking to each — never the full inlined findings of all N repos in one response.

---

## Invariants (NEVER break)

- **Never fires automatically** — not from state, not from build size, not as an auto-followup. Only an explicit human ask (§0).
- **Never dispatch the swarm without approval of the roster** (§3).
- **The roster starts from the lens battery only — the `{tech}-reviewer` is not re-seated here** (§2).
- **Never price the review** — the gate asks about scope, never tokens or time (§3).
- **Reviewers are read-only** and have no shell; materialize the diff for them (§4a).
- **This skill never runs a fix loop** — findings are handed to `flow-implementation` (§5).
- **A reviewer never writes the durable artifact directly** — the orchestrator persists it, same division of labor as commits and tracker writes (§4c).
- **Cross-repo work produces N separate artifacts, never one merged document** (§6).

---
*Procedure Version: 1.0 — split out of the retired `flow-orchestration` as the on-demand-only half. The tech-pair build lives in `flow-implementation`. The durable-artifact persistence mechanism is agreed but not yet script-backed (§4c) — schemas and the exact rendered output are still being finalized before that script gets written.*
