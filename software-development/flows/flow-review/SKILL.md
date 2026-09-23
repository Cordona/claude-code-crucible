---
name: flow-review
description: The orchestrator's procedure for an EXPLICIT, on-demand multi-lens review — the only place a DISCRETIONARY `lens-*` reviewer is dispatched (`flow-testing`'s `lens-test-quality-reviewer` pass is a separate, mandatory fixed seat, not a discretionary lens). Bind ONLY on an explicit human ask for a review beyond correctness; never fires from repo state, change size, or a build finishing. For a Validate-First `flow-implementation` result, bind only after its deferred `{tech}-reviewer` pass has closed — or seat the `{tech}-reviewer` inside this review explicitly. Does NOT run a fix loop, build the tech pair, or draft a cross-repo spec (`flow-implementation` / `flow-spec`), nor define review conduct/reports (review-core, review-report-standards).
---

# Flow: Review (on-demand)

The procedure the primary agent follows for a deep, multi-lens review. **Bound only when explicitly requested.**

**Why this is a separate skill and not part of building.** Running the full lens swarm on every build, automatically, means every lens firing on every round, of every repo, whether or not the change actually presents that lens's risk — cost and latency scaling with roster size and repo count, not with the size of the actual risk. Worse: an automatic swarm reviews and polishes whatever was built, including a misunderstood implementation, before a human ever gets a cheap look at the direction. **This skill exists so the expensive review only ever runs when a human decides it's worth running** — the tech-pair loop in `flow-implementation` is the safety net that ships correct code; this is the deliberately-invoked deeper pass.

---

## 0. When this applies — an explicit ask, never automatic

**Bind this skill ONLY when the human explicitly requests it.** Trigger phrases: "review this properly", "run the lens swarm", "check it for [security/performance/clean-code/…]", "full review". It does **not** fire because:
- a `flow-implementation` build just finished (however large),
- repository state shows unreviewed changes (that's `flow-git-operations`'s cheap check, not this),
- the change is large, risky-looking, or touches many files.

If none of those is an explicit ask, don't propose this skill unprompted beyond noting in `flow-implementation`'s executive summary that it's available.

**Rule, not observation, when `flow-implementation` used its Validate-First path (see that skill's §2):** bind this skill only after its deferred `{tech}-reviewer` pass (that skill's §4d) has closed. If asked to review a Validate-First result earlier than that — a live-validated, tested, but not-yet-correctness-reviewed diff — say so plainly, and either finish that deferred pass first or seat the `{tech}-reviewer` here explicitly (§3). **Seating it here is an additional correctness look for THIS review's own scope — it does NOT discharge `flow-implementation`'s own carried obligation.** That flow recognizes exactly two discharge routes for its deferred pass (its own §4d closing, or a `flow-testing`-originated case-1 re-entry's §4d, per its Invariants) — a seat inside this flow is neither, so the suspended `flow-implementation` invocation still needs its own §4d to run, and the diff remains not commit-eligible per `flow-git-operations`' commit gate (the rule's actual owner; `flow-testing` §6 restates it downstream, but only if `flow-testing` ran) regardless of what this review finds.

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

## 3. Roster — the lens swarm, derived from the confirmed scope, correctness NOT re-seated once its pass has closed

You already know the available subagents from your Task tool. Select dynamically; never from a hardcoded list.

**The `{tech}-reviewer` is NOT re-seated here — CONDITIONAL on it having actually run.** For a `flow-implementation` Pair-First result, it has, by construction — it ran in the same round as the developer. For a Validate-First result, confirm its deferred pass (that skill's §4d) has actually closed before assuming this; §0 above states the rule. If it has not closed, this is not "the exception" to route around — it is a missing correctness floor, full stop: say so, and either send the effort back to close that pass first, or seat the `{tech}-reviewer` here explicitly (this satisfies THIS review's own correctness prerequisite — see §0 for why it does not discharge `flow-implementation`'s own suspended §4d obligation). Once correctness is CONFIRMED CLOSED, this procedure adds quality lenses on top of it without re-checking it. **The seated-here exception does NOT wait for the `{tech}-reviewer` to close before dispatching the lenses** — §5a fires it in the SAME parallel round as the quality lenses, not before them; each lens is told explicitly that correctness "is being reviewed in this same round" (§5a) rather than already closed, so a lens whose territory borders correctness discloses openly instead of treating the gap as a false alarm. That is a deliberate cost tradeoff (one parallel round, not two sequential ones) — not a claim that the lenses reviewed already-correct code. If the human specifically wants a fresh correctness pass too even on an already-reviewed result, say so and seat it explicitly, but that's a separate, deliberate ask, not this skill's default shape.

**Read, don't audition.** For each `lens-*`, read the **Applicability** it declares in its own description and reason the target against it. That declaration is free. **Never invoke a lens to ask whether it wants a seat.** Where its declaration genuinely doesn't settle it, put it in the plan's **Uncertain** block and let the user resolve it at the gate. **On a full-codebase or named-subset scope (§2), reason each lens's Applicability against the target TREE, not a change** — there is no diff to weigh it against, so "Skip when" clauses that name a change's absence (no behavior change, no trust-boundary touch) are read as "this codebase does not present that risk" instead.

**Do NOT expect a small roster, and do not sell it as one.** On a substantive change most lenses genuinely apply — the filtering bites on small changes, where `Skip when` clauses fire honestly. **A large roster on a large change is the correct answer.** What keeps this cheap isn't a smaller roster on a big task — it's that the roster only ever runs when a human asked for it, once, not automatically on every build round.

**What the derivation buys is the EXCLUSIONS, not the inclusions.** "Seat, because [risk]" is unfalsifiable. **"No seat — accepting: [what we'd miss]" is a real claim the user can check and reject.** State every seat AND every exclusion.

**Security floor (hard).** Honor any lens marking itself security-critical; include it on ANY doubt.

**Resolving lens names.** Match the user's plain-words request ("logging", "conventions", "tests") against the `lens-*` agents' own descriptions.

**Naming a lens is a floor, not a ceiling.** When the human names specific lens(es) in their request, those named lenses are guaranteed a seat — but naming them does NOT cap the roster. The full derivation process above still runs regardless of which lenses were named, and any other lens whose Applicability genuinely fires is still seated too, exactly as if none had been named.

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
> - *Only if route B applies (§0/§3):* `{tech}-reviewer` — correctness for THIS review's scope only; **does not discharge `flow-implementation`'s deferred §4d pass** — that suspended invocation still needs its own §4d, and the diff stays not commit-eligible until it runs
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

Each reviewer binds `review-core` + `review-report-standards` + `review-boundaries` (its correctness-floor row applies to every lens, not only the ones with a named contested row), is read-only, returns a structured report.

**Reviewers have NO shell.** In diff/PR scope, materialize the diff to a file and pass its absolute path — `git diff` **omits untracked files**, enumerate new files explicitly. In a full-audit or named-subset scope (§2), there is no diff to materialize — hand exact file/directory paths instead and state plainly that this is a full audit, not a diff review.

Give each: **exact file paths** · diff/PR or full audit, **with the diff artifact path** · **tech version + language** · the spec (path + hint), if one governs this work · **that `{tech}-reviewer` correctness has already closed — or, where it was seated on THIS roster instead (§0/§3), that it is being reviewed in this same round** — without one of these two, a lens whose territory borders code correctness will disclose it as an unreviewed territory per `review-boundaries`, which is a false alarm either way · **whether `flow-testing` has run for this effort, and the test file paths if so** — a lens judging test coverage needs to know tests were expected, the same confirmation `flow-testing` §4c gives `lens-test-quality-reviewer` directly · **the commit message or PR/MR (pull request / merge request) description, if one already exists** (an already-open PR/MR being reviewed, or a re-review after commits landed) — `lens-self-documenting-code-reviewer`'s cross-artifact duplication signal needs this to fire at all; omit it when reviewing pre-commit working-tree changes, where no such text exists yet · **prior-round findings on a re-review**, so IDs stay stable.

### 5b. Merge.

Dedup by finding `id` internally, then group per `review-report-standards` **Rendering 1**'s reviewer → severity ordering. **This is an internal working view, not something shown to the human on its own** — unlike `flow-implementation` §4e / `flow-testing` §4d, where Rendering 1 IS the human-facing render, here it exists only to feed §5c's per-finding artifact blocks (which restore the ids Rendering 1 omits) in a stable, deduped order. The human only ever sees §5d's summary + link.

**A convergent finding — the same defect independently flagged by two or more reviewers, which `review-report-standards` calls the swarm's strongest signal — has no field in `review-artifact.schema.json` yet and is not preserved through this merge into anything §5c can render.** Same treatment as the out-of-scope disclosure below: until the artifact has a field for it, name it explicitly in §5d's summary ("X was found independently by lens A and lens B") rather than letting the signal disappear.

### 5c. Persist to the durable artifact.

Every review produces a durable, trackable record — not just conversation output. Location: `.crucible/docs/reviews/{year}/{month}/{day}/{repo-or-effort-slug}.md` (+ a same-named `.json` alongside it, conforming to `review-artifact.schema.json`), created once per review effort and updated in place across rounds — the date reflects when the effort started, not the most recent update. The JSON carries two SEPARATE tracked axes per finding — `status` (cross-round identity: NEW/OPEN/RESOLVED/REGRESSED/ACK — "acknowledged," the human waived it — per `finding-status.schema.json`) and `tracked_status` (workflow position: PENDING/IN_PROGRESS/APPROVED/APPROVED_WITH_FOLLOWUPS, per `tracked-status.schema.json`) — never conflated into one, since a finding can be REGRESSED and simultaneously back IN_PROGRESS. **The reviewer never writes this file directly** — it returns its findings, and the orchestrator is the one who persists/updates the artifact, the same division of labor already used for commits (`git-operator` plans, orchestrator executes) and Jira/GitHub/GitLab writes (`project-manager` drafts, a script writes).

**The rendered MD (Markdown) — every CONTENT field maps directly to the JSON schema, one-to-one** (`schema_version` and `id` are bookkeeping-only and never rendered; `summary` is also omitted here — its counts are available via `render-md.sh --summary` and are otherwise derivable from the findings below):

```markdown
# Review: <repo>

**Repo:** <repo>··
**Spec:** <spec_ref>  *(omit this line entirely when no spec_ref exists)*··
**Started:** <created> · **Last updated:** <last_updated>··
**Round:** <rounds.length>··
**Verdict:** <overall_verdict>

## Round history
- Round <round>: <reviewers[0]>, <reviewers[1]>, …

## Findings

### <id> — <severity>
**Tracked status:** <tracked_status, lowercased> · **Finding status:** <status, lowercased>··
**Reviewer:** <reviewer>··
**File:** <locations[0]>

<problem>··
→ Fix: <fix>
```

`··` above marks a **hard line break** (two literal trailing spaces, not shown as visible characters) on every intra-block line whose successor must start a new line — omitted on a line already followed by a blank line, on the last line of a block, and on headings. Without it, CommonMark collapses these into one run-on paragraph.

One `### <id>` block per finding, in the order they appear in `findings[]` — an empty `findings[]` renders as the bare `## Findings` heading with nothing under it (no dangling blank line either); this is the actual, tested renderer behavior, not a gap. **Deliberately not rendered here, unlike `review-report-standards`' Rendering 1** (which lists secondary locations in parentheses): `locations[1..]`, `category`, `first_seen`, and `addressed_in_round`. The MD is a human-facing summary of the JSON, not a full projection of it — all four remain in the JSON (the actual source of truth per §5c above) for anything that needs them; the MD trades completeness for a shorter per-finding block. Render both status axes explicitly, side by side — that's why they're two separate fields rather than one conflated enum (see `tracked-status.schema.json`'s own description for the REGRESSED-and-IN_PROGRESS case this exists to represent). **Also unlike Rendering 1's friendly-word `status` map** (`NEW`→New, `OPEN`→Tracking, etc.), this render lowercases the raw enum for both `status` and `tracked_status` (`new`, `open`, `pending`, …) — a deliberate simplification for this artifact's own compact style, not an inconsistency to reconcile with Rendering 1.

**`tracked_status` transitions** (the axis `review-update-status.sh --tracked-status` writes) are driven by the orchestrator, not automatically: a finding starts `PENDING`; flip it to `IN_PROGRESS` when §6's `flow-implementation` re-entry is actually briefed with its ID; flip it to `APPROVED` (nothing else open on that finding) or `APPROVED_WITH_FOLLOWUPS` (still open elsewhere) once a later round's re-review records its `status` as `RESOLVED`. An artifact sitting at `PENDING` past that point means the re-entry was never briefed — check §6 before assuming the finding is simply unaddressed.

**A reviewer's out-of-scope disclosure** (a territory `review-boundaries` assigns elsewhere, unseated on this roster) has no field in `review-artifact.schema.json` yet and the renderer below does not emit one — persisting it durably is future work, tracked separately, out of this flow's own scope. **Until then, the mechanism that actually carries it is §5d's exposure step below** — surface it there, every time, rather than letting it silently depend on unimplemented artifact support.

> **Script-backed.** The persist/render/status-update mechanism described here (mirroring the GTD — Getting Things Done — inbox's `capture.sh`/`process.sh`/`render-md.sh` discipline) is implemented: `review-create.sh` (round 1), `review-add-round.sh` (append a round), `review-update-status.sh` (flip one finding's status/tracked_status/addressed_in_round), and `render-md.sh` (the deterministic renderer — `render-md.sh --summary` recomputes and emits only the verdict + open counts by severity, a cheap "is this blocking?" check that never trusts a possibly-stale or tampered stored value). All four share their verdict-arithmetic definitions from one `scripts/lib/review-aggregates.jq`, read as jq source text, never sourced as shell. Persist and render through these scripts, never by hand. `review-add-round.sh` and `review-update-status.sh` each also print the sibling MD path (`REVIEW_MD=…`) on success as a re-render nudge; `review-create.sh` does not yet — a known, deliberately flagged inconsistency awaiting a decision, not an oversight.

### 5d. Expose.

Present a concise summary (verdict + counts per repo/severity) and a link to the durable artifact(s) — never re-paste the full findings inline; the artifact is the source of truth from this point on. **If any reviewer disclosed unreviewed territory** (an owner `review-boundaries` assigns elsewhere but that wasn't on this roster) **or two-plus reviewers converged on the same defect** (§5b), name both explicitly in this summary — neither has a home in the persisted artifact yet (§5c), so this is the only place either reaches the human at all.

---

## 6. This procedure does not fix anything

Findings are addressed by re-entering `flow-implementation` — the developer + `{tech}-reviewer` tech pair, not a lens, and not this skill. **Brief that re-entry with the durable artifact's path plus the specific finding IDs it should address — never by re-pasting the findings' full text into the dispatch prompt**, the same path+hint discipline `flow-spec` uses for its own artifact: the artifact is the current truth, a pasted copy is a snapshot that can drift from it. A lens is re-invoked ONLY on a fresh, explicit ask (a new `flow-review` invocation), never automatically because a fix touched the same files. If a fix causes a genuinely new issue, that's reported back to the orchestrator (never appended directly to the artifact by a reviewer), who updates the durable artifact and re-briefs the developer — mirroring exactly how `flow-implementation`'s own fix loop already works.

---

## 7. Cross-repo work — separate artifacts, never merged

When the effort spans multiple repos/tech stacks, this procedure runs **once per repo**, producing **one JSON+MD pair per repo**, sibling files under the same dated folder (`.crucible/docs/reviews/{year}/{month}/{day}/service-api.md`, `.../core-engine.md`, `.../web-client.md` — not nested per-repo subfolders, since each is a single evolving file, not a growing log). The scope confirmation (§2) is asked ONCE for the whole effort, not once per repo. Never merge findings across repos into one document — each tech pair addresses only its own repo's artifact. The exposure step (§5d) presents a short verdict table across all N artifacts (verdict + counts), linking to each — never the full inlined findings of all N repos in one response.

---

## Invariants (NEVER break)

- **Never fires automatically** — not from state, not from build size, not as an auto-followup. Only an explicit human ask (§0).
- **Scope is confirmed explicitly via `AskUserQuestion`, never inferred from the request wording** — the one exception is a re-review of prior findings, already scoped by the artifact it checks (§2). This exists specifically to prevent an ambiguous request silently becoming a full-codebase review.
- **Never dispatch the swarm without approval of the roster** (§4).
- **Security floor** — honor any lens marking itself security-critical; include it on ANY doubt (§3).
- **Every seat AND every exclusion is stated — "No seat" never omitted.** "Seat, because [risk]" is unfalsifiable; "No seat — accepting: [what we'd miss]" is the real, checkable claim (§3/§4).
- **A re-entry to address findings is briefed by artifact path + finding IDs, never by re-pasting the findings' full text** (§6).
- **The roster starts from the lens swarm only — the `{tech}-reviewer` is not re-seated here, CONDITIONAL on its pass having actually closed.** If it has not — a Validate-First result reviewed before its deferred pass — this is a missing correctness floor, not the exception to route around: seat it here explicitly, or send the effort back to close that pass first (§0/§3). **A `{tech}-reviewer` seated here does NOT discharge `flow-implementation`'s own carried §4d obligation** — that flow's suspended invocation still needs its own §4d to run (§0).
- **Never price the review** — neither gate (scope or roster) asks about tokens or time (§2/§4).
- **Reviewers are read-only** and have no shell; materialize the diff for them **in diff/PR scope** — in a full-audit or named-subset scope, hand exact paths/dirs and state "full audit" explicitly instead (§2/§5a).
- **This skill never runs a fix loop** — findings are handed to `flow-implementation` (§6).
- **A reviewer never writes the durable artifact directly** — the orchestrator persists it, same division of labor as commits and tracker writes (§5c).
- **A reviewer's disclosed unreviewed territory, and a convergent finding two-plus reviewers independently flagged, are never dropped** — neither has a field in the persisted artifact yet, so §5d's exposure must name both explicitly, every time (§5b/§5c/§5d).
- **This flow deliberately supersedes CLAUDE.md's general "expose every subagent report as it completes" invariant with a merged summary + durable-artifact link** — N raw lens reports would be unreadable pasted inline, and the artifact (not the conversation) is the durable record; this is a stated, intentional exception for this flow only, not an oversight (§5b/§5d).
- **Cross-repo work produces N separate artifacts, never one merged document; scope is confirmed once for the whole effort** (§7).
