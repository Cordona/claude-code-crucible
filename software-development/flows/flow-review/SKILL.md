---
name: flow-review
description: The orchestrator's procedure for an EXPLICIT, on-demand lens review — the ONLY place a `lens-*` reviewer is ever dispatched. Bind this ONLY when the human explicitly asks for a review pass beyond correctness (e.g. "run a full review", "check this for security/performance/clean-code", "review it properly"). NEVER auto-fires — not from repository state, not from the size of a change, not as a followup to `flow-implementation` finishing. Covers an EXPLICIT, MANDATORY scope confirmation (diff-only vs. full audit — never inferred from the request wording, to prevent an accidental whole-codebase review), deriving the lens roster from that confirmed scope, the approval gate, dispatching the swarm in parallel, merging findings, and persisting them to a durable, trackable artifact (one per repo in cross-repo work). Does NOT run a fix loop itself — findings are handed to `flow-implementation` to address. Does NOT define review conduct or report schemas (review-core, review-report-standards), the tech-pair build (flow-implementation), or the cross-repo spec (flow-spec).
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

Read the request and identify the diff/target: file paths, repo, and whether this looks like a fresh review of a `flow-implementation` result or a re-review of specific prior findings. **Scope itself is confirmed explicitly next (§2) — do not decide it here, and do not skip ahead to the roster on the strength of your own read of the request.**

---

## 2. Confirm the scope (MANDATORY — ask, never infer)

Scope decides how big this review is — the diff, or the entire codebase — and that is the human's decision, not an inference from wording. A misread "review this properly" defaulting silently to a full-codebase audit is exactly the accident this step exists to prevent.

**Collect via `AskUserQuestion`** — Header **"Scope"** · Question *"What should this review cover?"* · Options:
- **"Only the changes"** (Recommended) — the diff/target identified in §1. This is what an ambiguous request should resolve to by default.
- **"The entire codebase / repo"** — a full audit. State plainly, before the human picks it, that this is materially larger and slower than a diff review, so the choice is informed, not accidental.
- **"Something else"** — free text, for a specific file/directory/subset the human names directly.

**Ask every time — do NOT infer scope from the request and skip this question**, even when the request sounds unambiguous. The one exception: a **re-review of specific prior findings** is already scoped by the artifact it's re-checking — re-asking there is pure friction, not safety.

For **cross-repo work**, ask this ONCE for the whole effort, not once per repo — see §7.

---

## 3. Roster — the lens swarm, derived from the confirmed scope, correctness NOT re-seated

You already know the available subagents from your Task tool. Select dynamically; never from a hardcoded list.

**The `{tech}-reviewer` is NOT re-seated here.** It already ran as part of `flow-implementation`'s correctness floor. This procedure adds the quality lenses on top of already-correctness-reviewed code — it does not re-check correctness. If the human specifically wants a fresh correctness pass too, say so and seat it explicitly, but that's the exception, not this skill's default shape.

**Read, don't audition.** For each `lens-*`, read the **Applicability** it declares in its own description and reason the change against it. That declaration is free. **Never invoke a lens to ask whether it wants a seat.** Where its declaration genuinely doesn't settle it, put it in the plan's **Uncertain** block and let the user resolve it at the gate.

**Do NOT expect a small roster, and do not sell it as one.** On a substantive change most lenses genuinely apply — the filtering bites on small changes, where `Skip when` clauses fire honestly. **A large roster on a large change is the correct answer.** What makes this cheap relative to the previous design isn't a smaller roster on a big task — it's that the roster only ever runs when a human asked for it, once, not automatically on every build round.

**What the derivation buys is the EXCLUSIONS, not the inclusions.** "Seat, because [risk]" is unfalsifiable. **"No seat — accepting: [what we'd miss]" is a real claim the user can check and reject.** State every seat AND every exclusion.

**Security floor (hard).** Honor any lens marking itself security-critical; include it on ANY doubt.

**Resolving lens names.** Match the user's plain-words request ("logging", "conventions", "tests") against the `lens-*` agents' own descriptions.

**Naming a lens is a floor, not a ceiling.** When the human names specific lens(es) in their request, those named lenses are guaranteed a seat — but naming them does NOT cap the roster. The full derivation process above still runs regardless of the confirmed scope, and any other lens whose Applicability genuinely fires is still seated too, exactly as if none had been named.

---

## 4. The gate (MANDATORY — before ANY dispatch)

**Present the plan and wait for approval before dispatching the swarm.**

**Emit as LIVE MARKDOWN — never inside a code fence.**

> ## 🔍 Review Plan
>
> - **Target:** [what's being reviewed — repo/component]
> - **Scope:** [as confirmed in §2 — diff-only / full audit / the named subset] · [what it touches]
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

**Ask about scope (§2) and roster (here) — never cost.** Never surface token or time estimates.

---

## 5. Dispatch → merge → persist → expose

### 5a. Dispatch the swarm — in parallel, one Task call each.

Each reviewer binds `review-core` + `review-report-standards` (+ `review-boundaries` where it has contested territory), is read-only, returns a structured report.

**Reviewers have NO shell.** Materialize the diff to a file and pass its absolute path. `git diff` **omits untracked files** — enumerate new files explicitly.

Give each: **exact file paths** · diff/PR or full audit, **with the diff artifact path** · **tech version + language** · the spec (path + hint), if one governs this work · **prior-round findings on a re-review**, so IDs stay stable.

### 5b. Merge.

Dedup by finding `id` internally, then render per `review-report-standards` **Rendering 1** — grouped by reviewer → severity, status as words, no finding ids in the human view.

### 5c. Persist to the durable artifact.

Every review produces a durable, trackable record — not just conversation output. Location: `.crucible/docs/reviews/{year}/{month}/{day}/{repo-or-effort-slug}.md` (+ a same-named `.json` alongside it, conforming to `review-artifact.schema.json`), created once per review effort and updated in place across rounds — the date reflects when the effort started, not the most recent update. The JSON carries two SEPARATE tracked axes per finding — `status` (cross-round identity: NEW/OPEN/RESOLVED/REGRESSED/ACK, per `finding-status.schema.json`) and `tracked_status` (workflow position: PENDING/IN_PROGRESS/APPROVED/APPROVED_WITH_FOLLOWUPS, per `tracked-status.schema.json`) — never conflated into one, since a finding can be REGRESSED and simultaneously back IN_PROGRESS at once. **The reviewer never writes this file directly** — it returns its findings as today, and the orchestrator is the one who persists/updates the artifact, the same division of labor already used for commits (`git-operator` plans, orchestrator executes) and Jira/GitHub writes (`project-manager` drafts, a script writes).

**The rendered MD — every field maps directly to the JSON schema, one-to-one:**

```markdown
# Review: <repo>

**Repo:** <repo>
**Spec:** <spec_ref>  *(omit this line entirely when no spec_ref exists)*
**Started:** <created> · **Last updated:** <last_updated>
**Round:** <rounds.length> (of 3 max)
**Verdict:** <overall_verdict>

## Round history
- Round <round>: <reviewers[0]>, <reviewers[1]>, …

## Findings

### <id> — <severity>
**Tracked status:** <tracked_status, lowercased> · **Finding status:** <status, lowercased>
**Reviewer:** <reviewer>
**File:** <locations[0]>

<problem>
→ Fix: <fix>
```

One `### <id>` block per finding, in the order they appear in `findings[]`. Render both status axes explicitly, side by side — that's the whole reason they're two fields now instead of one conflated enum (see `tracked-status.schema.json`'s own description for the REGRESSED-and-IN_PROGRESS case this exists to represent).

> **Script-backed.** The persist/render/status-update mechanism described here (mirroring the GTD inbox's `capture.sh`/`process.sh`/`render-md.sh` discipline) is implemented: `review-create.sh` (round 1), `review-add-round.sh` (append a round), `review-update-status.sh` (flip one finding's status/tracked_status/addressed_in_round), and `render-md.sh` (the deterministic renderer — `render-md.sh --summary` emits only the verdict + open counts by severity, a cheap "is this blocking?" check that skips the full findings render). Persist and render through these scripts, never by hand.

### 5d. Expose.

Present a concise summary (verdict + counts per repo/severity) and a link to the durable artifact(s) — never re-paste the full findings inline; the artifact is the source of truth from this point on.

---

## 6. This procedure does not fix anything

Findings are addressed by re-entering `flow-implementation` — the developer + `{tech}-reviewer` tech pair, not a lens, and not this skill. **Brief that re-entry with the durable artifact's path plus the specific finding IDs it should address — never by re-pasting the findings' full text into the dispatch prompt**, the same path+hint discipline `flow-spec` uses for its own artifact: the artifact is the current truth, a pasted copy is a snapshot that can drift from it. A lens is re-invoked ONLY on a fresh, explicit ask (a new `flow-review` invocation), never automatically because a fix touched the same files. If a fix causes a genuinely new issue, that's reported back to the orchestrator (never appended directly to the artifact by a reviewer), who updates the durable artifact and re-briefs the developer — mirroring exactly how `flow-implementation`'s own fix loop already works.

---

## 7. Cross-repo work — separate artifacts, never merged

When the effort spans multiple repos/tech stacks, this procedure runs **once per repo**, producing **one JSON+MD pair per repo**, sibling files under the same dated folder (`.crucible/docs/reviews/{year}/{month}/{day}/service-api.md`, `.../core-engine.md`, `.../web-client.md` — not nested per-repo subfolders, since each is a single evolving file, not a growing log). The scope confirmation (§2) is asked ONCE for the whole effort, not once per repo. Never merge findings across repos into one document — each tech pair addresses only its own repo's artifact. The executive summary presented to the human is a short verdict table across all N artifacts (verdict + counts), linking to each — never the full inlined findings of all N repos in one response.

---

## Invariants (NEVER break)

- **Never fires automatically** — not from state, not from build size, not as an auto-followup. Only an explicit human ask (§0).
- **Scope is confirmed explicitly via `AskUserQuestion`, never inferred from the request wording** — the one exception is a re-review of prior findings, already scoped by the artifact it checks (§2). This exists specifically to prevent an ambiguous request silently becoming a full-codebase review.
- **Never dispatch the swarm without approval of the roster** (§4).
- **The roster starts from the lens swarm only — the `{tech}-reviewer` is not re-seated here** (§3).
- **Never price the review** — neither gate (scope or roster) asks about tokens or time (§2/§4).
- **Reviewers are read-only** and have no shell; materialize the diff for them (§5a).
- **This skill never runs a fix loop** — findings are handed to `flow-implementation` (§6).
- **A reviewer never writes the durable artifact directly** — the orchestrator persists it, same division of labor as commits and tracker writes (§5c).
- **Cross-repo work produces N separate artifacts, never one merged document; scope is confirmed once for the whole effort** (§7).

---
*Procedure Version: 1.1 — added the mandatory, explicit scope confirmation (§2) before roster derivation: scope was previously inferred from the request wording alone, which risked an ambiguous "review this" silently becoming a full-codebase audit. Prompted by field feedback flagging that gap. All subsequent sections renumbered (old §2→§3 Roster, §3→§4 Gate, §4→§5 Dispatch/merge/persist/expose, §5→§6 Does-not-fix, §6→§7 Cross-repo). Split out of the retired `flow-orchestration` as the on-demand-only half. The tech-pair build lives in `flow-implementation`. The durable-artifact persistence mechanism is script-backed (§5c): `review-create.sh`, `review-add-round.sh`, `review-update-status.sh`, and `render-md.sh`.*
