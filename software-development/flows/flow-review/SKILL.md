---
name: flow-review
description: The orchestrator's procedure for an EXPLICIT, on-demand multi-lens review — the only place a DISCRETIONARY `lens-*` reviewer is dispatched (`flow-testing`'s `lens-test-quality-reviewer` pass is a separate, mandatory fixed seat, and a background re-check's adversary is not a review seat). Bind ONLY on an explicit human ask for a review beyond correctness; never fires from repo state, change size, or a build finishing. For a Validate-First `flow-implementation` result, bind only after its deferred `{tech}-reviewer` pass has closed — or seat the `{tech}-reviewer` inside this review explicitly. Does NOT run a fix loop, build the tech pair, or draft a cross-repo spec (`flow-implementation` / `flow-spec`), nor define review conduct/reports (review-core, review-report-standards).
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

Read the request and identify the diff/target: file paths, repo, and whether this looks like a fresh review of a `flow-implementation` result or a re-review of specific prior findings. **The scope is fixed by §2 — the diff, never your read of the request.**

---

## 2. Scope — the diff, always

The review targets the current effort's diff — never the whole codebase, never another effort's changes. Never ask the human to widen it. Reviewers still read what the change uses or affects, and a defect there that the change relies on or exposes is a finding carrying `relates_to` (`review-core`, Review Scope); the target stays the diff. This section is the one statement of how an effort's diff is picked and restricted; `flow-implementation` and `flow-testing` point here for it.

`diff-scope.sh` exits **0** on success · **1** on an error — report it, never read it as "nothing to review" · **2** on a usage error, a path outside the change set, a selected symlink, or a pick that pulls in unselected changed files · **3** on an empty diff.

1. **Candidate set.** Run `diff-scope.sh` (`$HOME/.claude/skills/flow-review/scripts/diff-scope.sh --repo-root <repo> --out-dir <dir>`, by default the uncommitted work — the working tree against `HEAD`; `--whole-branch` for a whole-branch or pull/merge-request review, or for work already committed on the branch — everything since the branch's parent; `--base <ref>` only when the human named one). Show the gate what the diff is against, from `DIFF_BASE_REF` and `DIFF_BASE_FROM`. The script creates `<dir>` and refuses one inside the repo. It writes `changes.txt` (`<status>\t<path>\t<blob-sha>`), every change in that diff, untracked included. `.crucible/` paths are excluded (`--include-crucible` takes them in) and listed with status `X` so the gate can name them; changed symlinks are listed with status `S` and are never reviewed or tested; an `X` or `S` line is never selectable. **Exit 3 means the change set is empty: stop and tell the human there is nothing in the diff to review.** Never fall back to reviewing the codebase instead.
2. **Pick this effort's files.** The working tree can hold several efforts' changes, some already reviewed. Pick the files that belong to the effort being reviewed, from what you know: files built in this effort, files a developer report lists, and files changed since a prior closed lens review. A **closed lens artifact** is an earlier `flow-review` artifact of this effort (§5c, Which artifact) whose latest round reached §5d. A file whose blob-sha matches the sha a **lens round** of a closed lens artifact stored for it — a round whose `reviewers` include a `lens-*` seat, its `{path, sha}` list being `rounds[].diff_files` (round 1's is the artifact's top-level `diff_files` only while no later round exists) — was already lens-reviewed and is not picked again unless it changed; a non-lens round, and any `flow-implementation` correctness artifact, never excludes a file here. **A stored sha counts only from an artifact that is itself unchanged since the branch's parent — absent from `changes.txt`, whose `X` lines cover every `.crucible/` change since then, whatever the base (`diff-scope.sh --help`) — or that this session created.** An artifact that changed in this diff is never trusted: the files it lists are picked as if it did not exist. A file whose effort is unclear is named at §4's gate, never silently included. **A file the human names that is not in the change set is unchanged: say so and stop — never substitute other changed files.**
3. **Restrict.** Write the picked paths to a file and re-run `diff-scope.sh --paths-file <that file>`. Exit 2 here means a picked path is outside the change set, is a symlink, or pulls in changed files you did not pick — add the files the script lists, or drop the pick. **Its restricted `diff.patch` and `diff-files.txt` are the only target**; `diff-files.tsv` (`<path>\t<blob-sha>`) and `diff-hunks.tsv` (the changed hunks) are what the artifact writers take (§5c).

A **re-review of specific prior findings** runs the same three steps; the prior findings are checked against the current diff.

**Effort isolation.** Before dispatching a developer for an effort, run `diff-scope.sh --repo-root <repo> --snapshot-out <file>` (it takes no other option but `--include-crucible`) and keep the snapshot sha it records. Every later review and test run for that effort adds `--since-snapshot <sha>` to steps 1 and 3 (with `--out-dir`), so only this effort's hunks appear — even in a file another effort also changed; a `.crucible/` change since the snapshot is listed as `X`. Store the sha with `--snapshot <sha>` on `review-create.sh` (§5c) and `test-plan-create.sh` (`flow-testing` §3b). The review-only variant (`flow-implementation` §6) dispatches no developer, so it has no snapshot: its steps 1 and 3 run against the default diff (the uncommitted work), or `--whole-branch` when the change is already committed. A snapshot isolates efforts only in time — two efforts editing the same files at the same time need separate worktrees.

---

## 3. Roster — the lens swarm, derived from the diff, correctness NOT re-seated once its pass has closed

You already know the available subagents from your Task tool. Select dynamically; never from a hardcoded list.

**The `{tech}-reviewer` is NOT re-seated here — CONDITIONAL on it having actually run.** For a `flow-implementation` Pair-First result, it has, by construction — it ran in the same round as the developer. For a Validate-First result, confirm its deferred pass (that skill's §4d) has actually closed before assuming this; §0 above states the rule. If it has not closed, this is not "the exception" to route around — it is a missing correctness floor, full stop: say so, and either send the effort back to close that pass first, or seat the `{tech}-reviewer` here explicitly (this satisfies THIS review's own correctness prerequisite — see §0 for why it does not discharge `flow-implementation`'s own suspended §4d obligation). Once correctness is CONFIRMED CLOSED, this procedure adds quality lenses on top of it without re-checking it. **The seated-here exception does NOT wait for the `{tech}-reviewer` to close before dispatching the lenses** — §5a fires it in the SAME parallel round as the quality lenses, not before them; each lens is told explicitly that correctness "is being reviewed in this same round" (§5a) rather than already closed, so a lens whose territory borders correctness discloses openly instead of treating the gap as a false alarm. That is a deliberate cost tradeoff (one parallel round, not two sequential ones) — not a claim that the lenses reviewed already-correct code. If the human specifically wants a fresh correctness pass too even on an already-reviewed result, say so and seat it explicitly, but that's a separate, deliberate ask, not this skill's default shape.

**Read, don't audition.** For each `lens-*`, read the **Applicability** it declares in its own description and reason the target against it. That declaration is free. **Never invoke a lens to ask whether it wants a seat.** Where its declaration genuinely doesn't settle it, put it in the plan's **Uncertain** block and let the user resolve it at the gate.

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
> - **Scope:** this effort's diff from §2 — [n] files: [the picked paths] · [what it touches]
> - **Not included:** [changed files left out as another effort's, any whose effort is unclear, and every `X` line (excluded `.crucible/` paths) and `S` line (changed symlinks, never reviewed or tested) from `changes.txt` — the human corrects the pick here]
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

**Then gate via `AskUserQuestion`** — Header "Review" · Question *"Approve this review roster?"* · Options: **"Approve & run"** · **"Adjust roster"** or free text → apply, re-present, ask again. A corrected file pick re-runs §2's restrict step first.

**Ask about the roster — never cost.** Never surface token or time estimates.

---

## 5. Dispatch → merge → persist → expose

### 5a. Dispatch the swarm — in parallel, one Task call each.

Each reviewer binds `review-core` + `review-report-standards` + `review-boundaries` (its correctness-floor row applies to every lens, not only the ones with a named contested row), is read-only, returns a structured report.

**Reviewers have NO shell.** Pass the absolute paths of §2's `diff.patch` and `diff-files.txt` — the file list already includes untracked files — and state that those files are the review target.

Give each: **the diff artifact path (`diff.patch`) and its changed-file list (`diff-files.txt`)** — the review target; the reviewer still traces what the change uses or affects (`review-core`) · **tech version + language** · the related repos the reviewer may read and the feature's acceptance goal, written per `flow-implementation` §4a's brief rules · **every open handoff addressed to that reviewer**, for its ruling · the spec (path + hint), if one governs this work · **that `{tech}-reviewer` correctness has already closed — or, where it was seated on THIS roster instead (§0/§3), that it is being reviewed in this same round** — without one of these two, a lens whose territory borders code correctness will disclose it as an unreviewed territory per `review-boundaries`, which is a false alarm either way · **whether `flow-testing` has run for this effort, and the test file paths if so** — a lens judging test coverage needs to know tests were expected, the same confirmation `flow-testing` §4c gives `lens-test-quality-reviewer` directly · **the commit message or PR/MR (pull request / merge request) description, if one already exists** (an already-open PR/MR being reviewed, or a re-review after commits landed) — `lens-self-documenting-code-reviewer`'s cross-artifact duplication signal needs this to fire at all; omit it when reviewing pre-commit working-tree changes, where no such text exists yet · **prior-round findings on a re-review**, so IDs stay stable.

### 5b. Merge.

Dedup by finding `id` internally, then group per `review-report-standards` **Rendering 1**'s reviewer → severity ordering. **This is an internal working view, not something shown to the human on its own** — unlike `flow-implementation` §4e / `flow-testing` §4d, where Rendering 1 IS the human-facing render, here it exists only to feed §5c's artifact in a stable, deduped order. The human sees §5d's verbatim render of the artifact.

**A convergent finding — the same defect independently flagged by two or more reviewers, which `review-report-standards` calls the swarm's strongest signal — has no field in `review-artifact.schema.json` and is not preserved through this merge into anything §5c can render.** Same treatment as the out-of-scope disclosure below: say so under §5d's relay ("X was found independently by lens A and lens B") rather than letting the signal disappear.

### 5c. Persist to the durable artifact.

Every review produces a durable, trackable record — not just conversation output. Location: `.crucible/docs/reviews/{year}/{month}/{day}/{repo-or-effort-slug}.md` (+ a same-named `.json` alongside it, conforming to `review-artifact.schema.json`), created once per review effort and updated in place across rounds — the date reflects when the effort started, not the most recent update. **Which artifact:** a `flow-review` pass writes its own artifact, slug `<effort-slug>-lens` — created by the effort's first lens pass, appended to (`review-add-round.sh`) by every later lens pass and by the `flow-implementation` re-entry rounds that address its findings — never the `flow-implementation` artifact (slug `<effort-slug>`), so §2's exclusion reads only lens reviews. The JSON carries two SEPARATE tracked axes per finding — `status` (cross-round identity: NEW/OPEN/RESOLVED/REGRESSED/ACK — "acknowledged," the human waived it — per `finding-status.schema.json`) and `tracked_status` (workflow position: PENDING/IN_PROGRESS/APPROVED/APPROVED_WITH_FOLLOWUPS, per `tracked-status.schema.json`) — never conflated into one, since a finding can be REGRESSED and simultaneously back IN_PROGRESS. **Persist each finding's `realism`, `trigger`, `realism_reason`, `proof` or `unproven`, and `relates_to`, and each reviewer's `speculative` entries — with `real_if` and `proof` or `unproven` — tagged with that reviewer, and every handoff in `handoffs[]` with its receiver's ruling and proof (`review-core`, Stay in Your Lane)** — the artifact's verdict counts the findings `review-report-standards`' Verdict Arithmetic counts. **The reviewer never writes this file directly** — it returns its findings, and the orchestrator is the one who persists/updates the artifact, the same division of labor already used for commits (`git-operator` plans, orchestrator executes) and Jira/GitHub/GitLab writes (`project-manager` drafts, a script writes).

**The rendered MD (Markdown)** follows `review-report-standards` Rendering 1, the one owner of its layout — including the durable artifact's additions. `render-md.sh` renders it and recomputes the verdict and counts from `findings[]`, never the stored values.

**`tracked_status` transitions** (the axis `review-update-status.sh --tracked-status` writes) are driven by the orchestrator, not automatically: a finding starts `PENDING`; flip it to `IN_PROGRESS` when §6's `flow-implementation` re-entry is actually briefed with its ID; when a later round's re-review resolves it, record `status` `RESOLVED` with its `resolution_proof` (`review-update-status.sh --status RESOLVED` also needs `--diff-files` and `--repo-root`, and accepts the proof only when a stored location or `relates_to` file is in that diff), `tracked_status` `APPROVED` (nothing else open on that finding) or `APPROVED_WITH_FOLLOWUPS` (still open elsewhere), and `addressed_in_round` in that round's one `review-add-round.sh` entry — the render's "Resolved this round" counts from them. An artifact sitting at `PENDING` past that point means the re-entry was never briefed — check §6 before assuming the finding is simply unaddressed.

**A reviewer's out-of-scope disclosure** (a territory `review-boundaries` assigns elsewhere, unseated on this roster) has no field in `review-artifact.schema.json` and the renderer below does not emit one. **The mechanism that carries it is §5d's exposure step below** — surface it there, every time.

> **Script-backed.** Persist and render only through the scripts, never by hand: `review-create.sh` (round 1), `review-add-round.sh` (append a round), `review-update-status.sh` (one item's status, tracked_status, addressed_in_round, realism, edge-case confirmation, handoff ruling, re-check result, or a speculative entry's promotion to a finding), and `render-md.sh` (the renderer; `--summary` is a cheap "is this blocking?" check). Each script's `--help` owns its flags. All four share their verdict arithmetic from one `scripts/lib/review-aggregates.jq`, read as jq source text, never sourced as shell. What the writers enforce:
> - **Items are addressed by key, never by position** — a finding by `id`, a speculative entry by `speculative:<12-hex>` (`--speculative-key KEY`), an open handoff by `handoff:<N>` (1-based, as the render numbers it) — read from §5d's `REVIEW_ITEM` map.
> - **Categories and the security floor** — a category outside the declared vocabulary is rejected; a security item (`review-core`, Security is never rare) takes proof, never `--unproven`; an update never changes a finding's reviewer.
> - **Every proof points at something real** — the writers take `--repo-root`, and a `file:line` must exist there with the line in range. A `ran …` proof is accepted only on the orchestrator's own commands — `--proof`, `--resolution-proof`, or the proof given at an edge-case confirmation — never from a reviewer or `review-arbiter`. `--recheck-proof` is a locator; an `escalated` re-check takes `--recheck-reason TEXT` in plain words instead.
> - **The diff bounds the artifact** — with `--diff-files <§2's diff-files.tsv>` (each file's blob-sha is stored, so a later pass can tell it was reviewed) and `--diff-hunks <§2's diff-hunks.tsv>`, a new finding, speculative entry, or added or moved location outside the diff is rejected unless its `relates_to` lies inside one changed hunk; a location an update adds carries its own `relates_to`; a carried finding is not re-checked. An unrelated out-of-diff observation belongs only in a reviewer's `## Notes` as pre-existing, never in the artifact. **`diff_files` is cumulative across rounds; a carried finding can be `RESOLVED` only in a round whose diff covers its file or its `relates_to` file.**
> - `review-create.sh` takes the effort's `--snapshot <sha>` (§2); `--plan-review` on create and add-round marks a test-plan review record, which accepts `plan:<item>` locations (`flow-testing`'s findings persisted for a re-check).
>
> `review-add-round.sh` and `review-update-status.sh` print the sibling MD path (`REVIEW_MD=…`) on success as a re-render nudge; `review-create.sh` does not. **After every artifact write, re-render the sibling MD:** `render-md.sh < <artifact>.json > <artifact>.md`.

### 5d. Expose — and ask what to address.

Relay `render-md.sh`'s output **verbatim, as live Markdown** — every class is visible, nothing summarized away — plus the artifact's path. **Under the relay, list what the artifact has no field for:** unreviewed territory a reviewer disclosed, a defect two-plus reviewers converged on (§5b) — with both severities when they differ — and every reviewer Conflict note — the Conflicts as numbered items, numbered on from the artifact's last item. Open handoffs are in the artifact and render in its own Open handoffs section. An edge-case CRITICAL/HIGH awaiting the human's decision is asked about on its own question (`flow-implementation` §5).

If a reviewer's Notes (or Pre-existing notes) contain a security concern or other problem in code the change touches, relies on, or exposes — not a Handoff line, which stays a handoff — return the report to that reviewer to re-file it as a finding (`review-core`, Review Scope) before asking — never ask about an unnumbered note. Then load `flow-implementation` and ask its §5 Address question **with `AskUserQuestion`, never in prose** — Header "Address", options built from the report you relayed, your recommendation first; ask each edge-case CRITICAL/HIGH as its **own** `AskUserQuestion` (Header "Edge case") before it. The option-building rule, the background re-check, and routing are in `flow-implementation` §5. `render-md.sh` prints a `REVIEW_ITEM_<n>=<key>` map on stderr — a finding's `id`, `speculative:<12-hex>`, or `handoff:<N>`; translate the human's item numbers through it, never by re-deriving the order. Record the answer in the artifact before §6's re-entry:
- **An elected edge case:** `review-update-status.sh --realism realistic`.
- **A confirmed edge-case CRITICAL/HIGH:** `--confirm-edge-case --proof <text> --repo-root <repo>`, or `--unproven` (a security item: proof only).
- **A handoff ruling or waiver:** `review-update-status.sh --handoff-index <N>` with its 1-based `handoff:<N>` key (`flow-implementation` §5).
- **A background re-check result:** recorded as `flow-implementation` §5's Background re-check states.
- **A reviewer or arbiter proof a script rejects** goes back to its author once (`flow-implementation` §5).
- **An elected speculative item** has no id: it goes into the re-entry brief by its location and concern, and the reviewer files it as a finding next round.

---

## 6. This procedure does not fix anything

Findings are addressed by re-entering `flow-implementation` — the developer + `{tech}-reviewer` tech pair, not a lens, and not this skill. **Brief that re-entry with the durable artifact's path plus the specific finding IDs it should address (an elected speculative item by its location and concern, §5d) — never by re-pasting the findings' full text into the dispatch prompt**, the same path+hint discipline `flow-spec` uses for its own artifact: the artifact is the current truth, a pasted copy is a snapshot that can drift from it. A lens is re-invoked ONLY on a fresh, explicit ask (a new `flow-review` invocation), never automatically because a fix touched the same files. If a fix causes a genuinely new issue, that's reported back to the orchestrator (never appended directly to the artifact by a reviewer), who updates the durable artifact and re-briefs the developer — mirroring exactly how `flow-implementation`'s own fix loop already works.

---

## 7. Cross-repo work — separate artifacts, never merged

When the effort spans multiple repos/tech stacks, this procedure runs **once per repo**, producing **one JSON+MD pair per repo**, sibling files under the same dated folder (`.crucible/docs/reviews/{year}/{month}/{day}/service-api.md`, `.../core-engine.md`, `.../web-client.md` — not nested per-repo subfolders, since each is a single evolving file, not a growing log). Each repo's scope is that repo's own diff — §2 runs once per repo. Never merge findings across repos into one document — each tech pair addresses only its own repo's artifact. The exposure step (§5d) relays each repo's rendered artifact in turn, one per repo, each with its own §5d question.

---

## Invariants (NEVER break)

- **Never fires automatically** — not from state, not from build size, not as an auto-followup. Only an explicit human ask (§0).
- **The target is the current effort's diff — always; never ask the human to widen it** — picked from `diff-scope.sh`'s change set (isolated by the effort's snapshot), restricted with `--paths-file`, and listed at the roster gate; never the whole codebase, never another effort's changes; reviewers trace the change's effects, and a defect outside the diff is a finding only when the change relies on or exposes it (`relates_to`); an empty diff ends the flow with nothing to review (§2/§4).
- **Never dispatch the swarm without approval of the roster** (§4).
- **Security floor** — honor any lens marking itself security-critical; include it on ANY doubt (§3).
- **Every seat AND every exclusion is stated — "No seat" never omitted.** "Seat, because [risk]" is unfalsifiable; "No seat — accepting: [what we'd miss]" is the real, checkable claim (§3/§4).
- **A re-entry to address findings is briefed by artifact path + finding IDs, never by re-pasting the findings' full text** — an elected speculative item, which has no id, goes by its location and concern (§5d, §6).
- **The roster starts from the lens swarm only — the `{tech}-reviewer` is not re-seated here, CONDITIONAL on its pass having actually closed.** If it has not — a Validate-First result reviewed before its deferred pass — this is a missing correctness floor, not the exception to route around: seat it here explicitly, or send the effort back to close that pass first (§0/§3). **A `{tech}-reviewer` seated here does NOT discharge `flow-implementation`'s own carried §4d obligation** — that flow's suspended invocation still needs its own §4d to run (§0).
- **Never price the review** — the roster gate never asks about tokens or time (§4).
- **Reviewers are read-only** and have no shell; hand them `diff.patch` and `diff-files.txt` (§2/§5a).
- **This skill never runs a fix loop** — findings are handed to `flow-implementation` (§6).
- **A reviewer never writes the durable artifact directly** — the orchestrator persists it, same division of labor as commits and tracker writes (§5c).
- **A reviewer's disclosed unreviewed territory, and a convergent finding two-plus reviewers independently flagged, are never dropped** — neither has a field in the persisted artifact, so §5d's exposure must name both explicitly, every time (§5b/§5c/§5d).
- **This flow deliberately supersedes CLAUDE.md's general "expose every subagent report as it completes" invariant with the merged, script-rendered artifact** — N raw lens reports would be unreadable pasted inline, and the artifact (not the conversation) is the durable record; this is a stated, intentional exception for this flow only, not an oversight (§5b/§5d).
- **Cross-repo work produces N separate artifacts, never one merged document; each repo's scope is its own diff** (§7).
