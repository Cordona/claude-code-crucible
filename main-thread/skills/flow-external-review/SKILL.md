---
name: flow-external-review
description: >-
  The External Review procedure — turns an external/automated PR review
  (human comments + bot/static-analysis passes) into a DETERMINISTIC, TERMINATING, SELF-AUDITING
  run that adjudicates every finding with independent agents, fixes only what is genuinely broken,
  and posts one consolidated response. Roster-aware: findings route to the framework's own reviewers
  as cold PRO/CON advocates (the {tech}-reviewer for correctness/language, the matching lens-*
  reviewer for a concern, software-architect for a design finding), the `review-arbiter` is the
  judge, the {tech}-developer/{tech}-reviewer pair does fixes, and a general-purpose verifier
  re-derives ground truth at every gate. Bind this skill (as the ORCHESTRATOR) when a PR has received
  a review and you've been asked to address it. Judge conduct lives in `standard-judging`.
---

# Flow: External Review — the panel, run per finding (v5, roster-aware)

**Audience: AI agents.** You (the main-thread agent) are the **orchestrator**. This is a literal, step-by-step procedure. Follow it top to bottom. Do not improvise control flow. Do not skip the gates.

**What it does:** turns an external/automated PR review (one or more passes + inline static-analysis comments) into a **deterministic, terminating, self-auditing** run that adjudicates every finding with independent agents, verifies its own work at each step, fixes only what is genuinely broken, and responds on the PR.

**Core principles**
- The orchestrator **only delegates and records**. It never reviews code itself and never fixes code itself.
- **Technical decisions are made by agents, not the human.** The `review-arbiter` always chooses a recommended default for technical calls; the orchestrator applies it.
- **Every automated step is independently verified** before the run advances (bounded — §1).
- **The human is informed, never interrogated.** Human gates are *informational checkpoints*: stop → structured report → "Ok" → proceed. The human is **never** asked a code/technical question.

> **Changelog v4 → v5 (roster port into the decomposed framework):** **P1** — the external-review flow is no longer PHP-shaped. The adjudication seats are **routed by finding type** to the framework roster (§2, §2b): a `{tech}-reviewer` for correctness/language, the matching **`lens-*` reviewer** for a concern (security/perf/observability/clean-code/tests/consistency/compatibility), `software-architect` for a design finding. **P2** — the judge seat is now the dedicated **`review-arbiter`** agent (its conduct comes from **`standard-judging`** — the shared judge's constitution it co-binds with the panel `decision-arbiter`; its disposition schema lives in the agent). **P3** — advocates and the fix-reviewer judge against the **shared `standard-*`** the developer built to (build↔review parity: adjudication and remediation share one rubric). **P4** — fixes use the matching **`{tech}-developer` ↔ `{tech}-reviewer`** pair (+ the relevant `lens-*` when the fix touches that concern). Everything below the roles — invariants, disposition taxonomy, gates, PR mechanics — is unchanged from v4.
>
> **Prior changelog (origin repo, retained):** v3→v4 **R12** `ALREADY_RESOLVED`; **R13** compound disposition; **R14** consolidated `verdicts.jsonl` + `observations.md`. v2→v3 **R1/R10** review-side agents get the dumped diff; **R2** severity normalization; **R3** mechanical gates self-checkable; **R4** cwd discipline; **R5/R11** one consolidated comment (no threaded bot replies); **R6/R9** batched fix; **R7** within-run reuse; **R8** fix phase as safety net.

---

## 0. How to use this procedure (READ FIRST)

**Invoke when:** a PR has received an external/automated code review and you've been asked to address it.

**Inputs:** `OWNER`, `REPO`, `PR`, and the repo's primary **language/stack** (selects the `{tech}` pair). Publish authorization is requested at the informational gates (§9).

**Run it:** execute phases **0 → 7 in order**. Each automated phase ends with a **PHASE GATE** (§7b). Maintain the **state artifacts** (§3). Stop only at the **informational human gates** (§9). When Phase 7 completes, **STOP** — a new review pass (incl. one triggered by your own push) is a new invocation, never an auto-continuation.

**This procedure terminates by construction.** No open loops (§1).

---

## 1. Invariants & termination contract (NON-NEGOTIABLE)

| # | Invariant |
|---|---|
| I1 | Findings set is **frozen** in Phase 1; Phases 2–6 iterate it **exactly once**. |
| I2 | Adjudication is a **fixed fan-out** (routed PRO, routed CON, `review-arbiter`). No iteration. |
| I3 | **Code-fix** loop ({tech}-developer↔{tech}-reviewer) capped at **6** cycles per fix-unit. On non-resolution → `BLOCKED`, inform, move on. |
| I4 | Reviews are **snapshotted once** in Phase 0. Never re-ingest passes — including any triggered by your own push. |
| I5 | Any agent failure/null → mark the unit `BLOCKED` (max 1 retry). Never spin. |
| I6 | Human gates are **informational only** (no technical decision requested); a single "Ok" advances. |
| I7 | Monotonic state; never re-process a `RESOLVED`/`PASS` unit. |
| I8 | **Review/verification** loop (step-verifier remediation, any re-review) capped at **3** cycles per step. Then `BLOCKED` + inform. |
| I9 | **Technical decisions are auto-resolved** by the `review-arbiter`'s recommended default. Only genuine **product** questions become `TRACK_FOLLOWUP`. Neither blocks on a human answer. |

**7th-cycle rule:** if a code-fix needs a 7th cycle (I3) or a verification a 4th (I8), you MAY inform the human — but the human will not supply a technical answer, so **mark the unit `BLOCKED`, report it, and proceed**. Never loop.

---

## 2. Roles

| Role | Agent | MUST | MUST NOT |
|---|---|---|---|
| **Orchestrator** | you (main thread), binding this skill | fetch, dedup, classify, **route each finding to the right seat (§2b)**, spawn agents, **persist all artifacts**, **dump diffs for review-side agents**, run phase gates, apply the judge's defaults, commit, post comments, run informational gates | review/fix code yourself; ask the human a technical question; skip a substantive phase gate |
| **advocate** — PRO / CON / single | **routed (§2b): the `{tech}-reviewer`, a `lens-*` reviewer, or `software-architect`** — dispatched **cold** with a PRO / CON / single briefing; judges against its bound **`standard-*`** | argue PRO / CON, or rule one-shot, on evidence | hedge; decide by vote; punt a technical call to the human |
| **judge** | **`review-arbiter`** (conduct from `standard-judging`; disposition schema in the agent) | rule on the code, pick a recommended default, return the **verdict (+ secondary_actions)** — the orchestrator derives the disposition (§5.2) | vote; punt a technical call to the human; be the orchestrator |
| **step-verifier** | **`general-purpose` (cold)** — needs Bash + `gh` to re-derive PR ground truth | independently verify a phase's acceptance criteria against artifacts + re-derived ground truth | trust the orchestrator's claims |
| **developer** | the matching **`{tech}-developer`** | implement the fix(es), scoped, **to the shared `standard-*`** | touch unrelated code |
| **fix-reviewer** | the matching **`{tech}-reviewer`** (+ the relevant **`lens-*`** when the fix touches that concern) — orchestrator hands it the diff via a file | review the change for correctness + scope + regression against the shared `standard-*` | approve unverified |
| **human** | the requester | acknowledge informational reports ("Ok"); grant publish authorization | be asked to make a code/technical decision |

**"Cold"** = spawn with the claim + code/diff pointers and **no** hint of the orchestrator's opinion. **Blind** = advocates are never told a counterpart advocate exists.

### 2b. Seat routing (the roster upgrade) — pick the advocate/fix-reviewer by what the finding IS

| Finding nature | Advocate seat (PRO/CON/single) | Fix-reviewer |
|---|---|---|
| correctness / logic / language idiom | `{tech}-reviewer` (owns correctness) | `{tech}-reviewer` |
| security | `lens-security` | `lens-security` + `{tech}-reviewer` |
| performance / scaling | `lens-performance` | `lens-performance` + `{tech}-reviewer` |
| observability / logging / metrics | `lens-observability` | + `{tech}-reviewer` |
| clean-code / SOLID / naming | `lens-clean-code` | + `{tech}-reviewer` |
| tests / coverage | `lens-test-quality` | + `{tech}-reviewer` |
| convention / structure conformance | `lens-consistency` | + `{tech}-reviewer` |
| API / wire / schema breaking change | `lens-compatibility` | + `{tech}-reviewer` |
| persistence / data-layer correctness | `lens-persistence` | + `{tech}-reviewer` |
| "should this be split / restructured" (design) | `software-architect` | `{tech}-reviewer` |

**One row, ONE seat — PRO and CON are always seated on the SAME base.** When a finding appears to span two concerns, route it to the seat that owns **the defect claim itself**, not the incidental concern it brushes. If it genuinely carries two *separable* defect claims, **split it into sub-rows** (`F-03a`, `F-03b`) back in Phase 1 and route each to its own seat — never route one row to two seats.

**Why this is not negotiable:** PRO and CON differ ONLY by briefing. That shared base is the control that makes their disagreement *mean* something — seat them differently and you can no longer tell whether they disagree about the code or merely bring different expertise, which is exactly the reading the `review-arbiter` is being asked to make. (The decision pattern holds the identical control — see `flow-decision` §1a: one derived base, different lenses.) It is also what keeps the ledger's scalar `seat` honest.

A finding matching **none** of the rows defaults to the **`{tech}-reviewer`** (the correctness owner) as the catch-all seat. The judge is always the `review-arbiter`.

---

## 3. State & artifacts

Run dir: `<scratch>/external-review-<PR>/` (e.g. `/tmp/external-review-7942/`). **Ephemeral, NOT committed, never auto-cleaned** — preserve until audited/closed.

| Artifact | Phase | Content |
|---|---|---|
| `reviewed-sha.txt` | 0 | the HEAD SHA the review targeted |
| `sha-delta.txt` | 0 | the commits landed between the reviewed SHA and HEAD — the ALREADY_RESOLVED input (R12) |
| `pass-1.md`, `pass-2.md`, … | 0 | **one file per review pass**, raw verbatim |
| `inline.jsonl` | 0 | one line per inline comment: `{id, path, line, body}` — **verbatim body** |
| `ledger.json` | 1 | **canonical** frozen work set + live status (row schema referenced below); a human-readable `ledger.md` may be *derived* from it |
| `adjudications/<id>-<role>.json` **or** `adjudications/verdicts.jsonl` | 2 | **every** agent verdict, raw. Per-file (`F-02-pro.json`, `…-con.json`, `…-judge.json`, `<id>-reuse.json`) **or** a single consolidated `verdicts.jsonl` (one line per `(id, role)`, verbatim `evidence`) — R14. Consolidated preferred for many small verdicts; per-file for large individual ones. |
| `observations.md` | all | procedure-friction notes captured **during** the run (not code findings) — candidates for the next version bump (R14). Present them at Phase 7. |
| `fix.diff` | 4 | the working-tree diff, **dumped by the orchestrator** for the fix-reviewer |
| `gates/<phase>-verify.json` | gates | each gate result |
| `summary.md` | 7 | final report |

**`ledger.json` row schema:** defined by `$HOME/.claude/crucible/contracts/external-review-ledger.schema.json` (framework source: crucible/contracts/external-review-ledger.schema.json) — the schema owns the row shape (only `id`/`title`/`status` required, the rest filled in incrementally), including the `verdict`/`severity`/`provisional_severity` value domains it `$ref`s. The field semantics: `seat` (v5) is a **scalar** — exactly one seat per row (§2b); a finding needing two was split in Phase 1. `provisional_severity` is the Phase-1 triage hint from the external label and feeds ONLY the panel rule; `severity` is the Phase-2 evidence-based grade on the anchor scale and is the only one that reaches a human (§5.3). `secondary_actions[]` (R13) holds any additional action beyond the primary disposition; `resolved_by_commit` (R12) records the SHA that already fixed an `ALREADY_RESOLVED` row. Update the row **immediately** after each step.

---

## 4. The pipeline

> Automated phases (0,1,2,4,6) END with a **PHASE GATE (§7b)**. Phases 3 and 5 are **informational human gates (§9)**.

### PHASE 0 — Snapshot (once)
- Record HEAD sha (**run `git` from the repo dir, not the run dir**); record the **reviewed-SHA→HEAD delta** (the commits landed between the reviewed SHA and HEAD) to `sha-delta.txt` — the ALREADY_RESOLVED input (R12); fetch issue comments + inline comments; write `pass-N.md` (one per pass) and `inline.jsonl` (verbatim).
- **Exit → PHASE GATE 0** (acceptance: every pass + every inline comment captured; counts == the PR's actual counts; sha recorded). From here, never re-fetch reviews (I4).

### PHASE 1 — Frozen ledger (once)
- Extract atomic findings from every pass + inline comment; **dedup** (same location+claim → one row, merge sources/labels, set `agreement`); **split any finding carrying two separable defect claims into sub-rows** (`F-03a`/`F-03b`) so each row routes to exactly one seat (§2b); set **`provisional_severity` (§5.3)**; classify `tier` + `panel_required` (§5.1) **and the `seat` (§2b)**; flag any row whose cited code no longer exists at HEAD as an `ALREADY_RESOLVED` candidate (R12); write `ledger.json` (all `PENDING`).
- **Exit → PHASE GATE 1** (acceptance: every source finding maps to ≥1 row — nothing dropped; no over-merge; **every row has exactly ONE `seat`** — a row that needed two was split instead; every row has tier+agreement+panel_required+provisional_severity; schema valid). List now frozen (I1).

### PHASE 2 — Adjudicate (iterate frozen list once)
For each `PENDING` row:
- `panel_required==true` → **PRO + CON** (parallel, cold/blind, both at the routed `seat`) → **`review-arbiter`** (if PRO/CON disagree; if they converge, that verdict stands — EXCEPT on a high-stakes / irreversible finding, where the judge still independently blesses it, since correlated same-base advocates agreeing is weak evidence). Persist all to `adjudications/`.
- else → **single advocate** at the routed seat (may batch several). Persist.
- Set `verdict`/`severity`/`disposition` (route §5.2), `status:"JUDGED"`. Failure/null → retry once → else `BLOCKED` (I5). The `review-arbiter` MUST pick a recommended default for technical calls (I9).
- **Exit → PHASE GATE 2** (acceptance: every row has a verdict ∈ enum **including `ESCALATE`** + persisted adjudication evidence; every judge reply carries `option_completeness`, `shared_blind_spot` and `confidence` — a reply missing any of them is malformed, reject and re-dispatch; the judge is present where PRO/CON conflicted *and on any high-stakes convergent finding*; verdicts ∈ enum).

### PHASE 3 — Informational checkpoint 🟦 (§9)
- Present the adjudicated ledger (per finding: verdict · disposition · action; `TRACK_FOLLOWUP` + auto-chosen technical defaults called out). Ask only "Proceed? (Ok / veto ids)". No technical question.

### PHASE 4 — Fix (orchestrated; batched allowed)
- **Batch the trivial FIXes** (renames, comments, type hints, suppressions, declares) into **one `{tech}-developer` pass + one `{tech}-reviewer` pass**. Run a **per-finding** developer↔reviewer loop only for *substantive* fixes. Both capped at **6** (I3). The developer builds to the shared `standard-*`; the fix-reviewer (+ the relevant `lens-*`) judges against it.
- The orchestrator **dumps `git diff` to `fix.diff`** and hands it to the fix-reviewer. Accumulate changes in the working tree (no per-finding commit). Run targeted tests **once**.
- **Note (R8):** the fix phase is a real safety net — a fix that breaks tests/scope re-classifies the finding (→ `TRACK_FOLLOWUP`/`BLOCKED`) even if adjudication called it trivial.
- **Exit → PHASE GATE 4** (acceptance: every FIX has a recorded change + reviewer approval; tests green or failures recorded; scope respected).

### PHASE 5 — Commit & push 🟦 (§9)
- **This phase commits and pushes from the MAIN THREAD, so the main thread must bind the same gates the `git-operator` would.** Executing here instead of delegating changes *who acts* — it never lowers the bar. Bind **`standard-git-commit`** (message craft, signing, the commit-plan gate), **`procedure-git-identity`** (run `resolve-identity.sh --github`, present the identity report, get explicit confirmation), and **`procedure-git-ops`** (execute the commit via `commit.sh`) before anything lands. A commit made without them is a gate bypass, not a shortcut. **The commit message body OMITS `Signed-off-by`** — `commit.sh`'s `git commit --signoff` appends it from the resolved identity (`standard-git-commit` owns this rule); do not hand-write it, and do not commit through a path that skips `--signoff`, or the DCO trailer is lost.
- **Ask — do not merely inform:** "Fixes ready (N files). Commit + push?" Commit and push happen **only on the user's explicit approval in their own words**; being mid-flow is not authorization (`CLAUDE.md` §1). Present the commit message for approval per `standard-git-commit`'s commit-plan gate.
- Then: one commit `fix(<scope>): address PR #<PR> review` — materialize the approved message to a temp file and run `commit.sh --message-file` (signs + appends `Signed-off-by`, fails closed on an unsigned result), then `push.sh` once; record SHA into each fixed row.

### PHASE 6 — Respond
- Post **ONE consolidated top-level comment** grouping all findings by disposition (✅ fixed +sha / ℹ️ not-a-defect +evidence / 📋 follow-up / ✔️ already-resolved +sha). **Do NOT attempt threaded replies on bot/static-analysis comments** — the GitHub reply API rejects them once the fix commit makes them outdated (404/422). *Threaded replies MAY be used for human inline comments, with a consolidated fallback on failure.* Record `comment_url`.
- **Exit → PHASE GATE 6** (acceptance: the consolidated comment is posted and covers every finding — verifier re-fetches the PR).

### PHASE 7 — Close-out (STOP)
- Write `summary.md` (counts by disposition, commit SHA, comment URL, `TRACK_FOLLOWUP`/`BLOCKED` items, new review activity noted; present `observations.md`). Report to human. **STOP.**

---

## 5. Decision rules

### 5.1 Tier & panel
| Tier | Criteria | How it's judged |
|---|---|---|
| **A** | style / lint / formatting / naming / obvious linter false-positive — no behaviour implication | single advocate |
| **B** | logic, correctness, data integrity, security, performance, concurrency, API/contract, persistence | panel rule below |

**Within Tier B:** `panel_required = true` if `agreement == CONFLICT` **OR** `provisional_severity` ≥ `HIGH` (§5.3). Else `panel_required = false` ("B-lite", single advocate, batchable). When unsure A vs B → choose **B**.

### 5.2 Verdict → disposition
| verdict | disposition | action |
|---|---|---|
| `REAL` | `FIX` | Phase-4 fix |
| `ACCEPT_SUPPRESS` | `FIX` | apply repo suppression convention **with justification** |
| `FALSE_POSITIVE` | `NOT_AN_ISSUE` | reply with evidence, no change |
| `ESCALATE` | `ESCALATED` | the judge could not decide on the evidence (`standard-judging`'s escalate-don't-fabricate hatch). Do NOT re-dispatch and do NOT guess: carry the finding to the Phase-3 report with the judge's stated blocker, and surface it to the human as the one thing the run could not settle. Never let an undecidable finding be laundered into a verdict. |
| `NEEDS_PRODUCT_DECISION` | `TRACK_FOLLOWUP` | record as follow-up, inform, **not fixed in this PR** |
| `REAL` **at reviewed SHA, already fixed by a later commit** | `ALREADY_RESOLVED` (R12) | reply crediting the resolving commit SHA; **no new change**. NOT a false-positive — the concern was valid when raised. Phase 1 flags this when the cited code no longer exists at HEAD. |

No `DEFER_TO_HUMAN`: technical "decisions" are resolved by the `review-arbiter`'s recommended default; only product/business questions → `TRACK_FOLLOWUP`.

**Compound disposition (R13):** one finding may map to MORE THAN ONE outcome — arbitration routinely says "reject the proposed fix, apply a *smaller* change, AND file a follow-up." Represent it as a **primary disposition + `secondary_actions[]`** on the row, OR mint a **sub-row** (`F-03b`). Do not distort a genuinely compound outcome into a single disposition.

### 5.3 Severity — the ONE scale, plus provisional triage

**There is one severity scale in this framework: `review-report-standards`' — `CRITICAL | HIGH | MEDIUM | LOW`, anchored to consequence.** Every advocate seat here is a `lens-*` or `{tech}-reviewer` that already binds that contract and is forbidden by it to redefine the scale. This flow does **not** get a private scale; it uses that one.

Two distinct values, both on that enum — never conflate them:

| Field | Set in | Derived from | Means |
|---|---|---|---|
| `provisional_severity` | Phase 1 | the **external** reviewer's own label, mapped below | a **triage hint** — an unverified claim by a stranger. Its ONLY job is to decide `panel_required` (§5.1). |
| `severity` | Phase 2 | the advocate / judge, **after reading the code** | the real, evidence-based grade on the anchor scale. This is what the ledger carries and the PR comment shows. |

**External label → `provisional_severity`** (deliberately conservative — escalating buys a panel; a missed defect buys a production incident):

| External label | → | Why |
|---|---|---|
| `Critical` / `Blocker` | `CRITICAL` | take the claim at face value; Phase 2 grades it on evidence |
| `High` / `Major` / `Error` | `HIGH` | same |
| **`Medium` / `Warning`** | **`HIGH`** | **a deliberate escalation, not a translation.** An external `Medium` is not a consequence judgment — it is a bot's heuristic, and bots under-label real defects. Escalating buys a panel, and the panel is how we find out. (A dual-pass *Medium* data-integrity finding therefore triggers a panel — the R2 intent, preserved.) |
| `Low` / `Info` | `MEDIUM` | |
| style / convention / nit | `LOW` | |

**`provisional_severity` NEVER reaches the ledger's `severity`, the PR comment, or a human report.** It is scaffolding for the panel rule, discarded the moment Phase 2 grades the finding on evidence. When an advocate's evidence-based grade contradicts the external label, **the advocate is right** — adjudicating the stranger's claim is the entire point of this flow.

### 5.4 REUSE
A prior verdict may be reused — **including same-run reuse when the code is unchanged at the reviewed SHA** — **only if** copied verbatim into `adjudications/<id>-reuse.json` (claim, verdict, evidence, source SHA). Otherwise adjudicate fresh.

---

## 6. Agent prompt contracts

**Advocates (routed seat, cold/blind)** return ONLY an object conforming to `$HOME/.claude/crucible/contracts/external-review-advocate-verdict.schema.json` (framework source: crucible/contracts/external-review-advocate-verdict.schema.json) — the schema owns the shape, including the advocate `verdict` as the documented 4-value subset (advocates cannot rule `ALREADY_RESOLVED`/`ESCALATE`) and the `severity` scale it `$ref`s. `severity` is the advocate's own evidence-based grade on the **`review-report-standards` anchor scale it already binds** (§5.3) — NOT the external label, and never a scale invented here. PRO argues the finding is a real defect; CON argues it is a false-positive / not worth fixing; each judges against its bound `standard-*`. A single advocate one-shots the same schema.

**`review-arbiter`** — fires only when PRO/CON disagree (or on a high-stakes convergent finding). Its conduct is `standard-judging` and its output schema is defined in the agent (verdict + disposition-aware fields + the three required standing-duty fields — `option_completeness` · `shared_blind_spot` · `confidence`). Dispatch it with: the finding, BOTH advocate positions labeled neutrally (**rotate their order across cycles**), the cited code paths, and the reviewed-SHA→HEAD delta (never the positions alone).

**step-verifier** (`general-purpose`) returns ONLY an object conforming to `$HOME/.claude/crucible/contracts/external-review-step-verifier.schema.json` (framework source: crucible/contracts/external-review-step-verifier.schema.json).
Prompt: "Independently verify these ACCEPTANCE CRITERIA for phase <N> against the artifacts at <run-dir>, and **re-derive ground truth** (re-query the PR via `gh`, re-scan the passes). Do NOT trust the orchestrator. READ-ONLY. Return only the schema."

**fix-reviewer** (`{tech}-reviewer` + relevant `lens-*`) gets the diff: "Review `<run-dir>/fix.diff` for correctness + scope + regression against `standard-*`. Return APPROVED | CHANGES_REQUESTED{specifics}."

---

## 7. Fix sub-procedure (capped 6, I3)

```
# Trivial cluster (renames/comments/type-hints/suppressions/declares): ONE batched pass
developer  = {tech}-developer: "Apply exactly these N scoped fixes to standard-*: <list>. Run <targeted tests>. Don't touch unrelated code."
orchestrator: dump `git diff` → fix.diff
review     = {tech}-reviewer (+ relevant lens-*): "Review fix.diff (correctness/scope/regression vs standard-*). APPROVED | CHANGES_REQUESTED{specifics}."
if CHANGES_REQUESTED: feed specifics back; repeat; at attempt 6 → BLOCKED (I3)

# Substantive fixes: same loop, one finding at a time.
```
A fix that breaks tests or exceeds scope re-classifies the finding (→ TRACK_FOLLOWUP/BLOCKED) — the fix phase is a safety net beyond adjudication (R8). No commit inside this sub-procedure.

---

## 7b. PHASE GATE (verification, capped 3, I8)

After each automated phase:
```
attempt = 0
while true:
  attempt += 1
  # MECHANICAL gates (Phase 0 = counts/sha) may be an orchestrator SELF-CHECK.
  # SUBSTANTIVE gates (Phases 1, 2, 6) MUST use an independent general-purpose step-verifier.
  v = verify(phase acceptance criteria, run-dir)   # persist → gates/<phase>-verify.json
  if v.pass: proceed
  if attempt >= 3: mark BLOCKED; inform human (informational); proceed-or-HALT by severity   # I8
  orchestrator remediates exactly v.failures[]   # then re-verify
```

---

## 8. PR response mechanics

**Default: one consolidated top-level comment** (`gh pr comment <PR> --body-file <file>`) grouping every finding by disposition with evidence + the fix commit SHA.

**Do NOT thread replies onto bot / static-analysis comments** (reviewdog, AI-review bots): once the fix commit lands they go outdated and the reply API returns 404 (`/comments/{id}/replies`) or 422 (`in_reply_to`). Threaded replies (`gh api … /comments/{id}/replies`) MAY be used for **human** inline comments; on any failure, fall back to the consolidated comment.

---

## 9. Human gates — INFORMATIONAL ONLY

A gate = **stop → structured report → "Ok" → proceed**. Never ask the human to choose a technical option or break a tie (that's the `review-arbiter`'s job, I9).

| Gate | Phase | Report | Allowed input |
|---|---|---|---|
| **G1** | 3 | adjudicated ledger (verdicts, dispositions, auto-defaults, follow-ups) | "Ok" / veto ids |
| **G2** | 5 | fixes ready + diff summary | "Ok" to commit+push & post |

---

## 10. Halt & out-of-scope

- **HALT + report** if: the PR/repo can't be read; publish refused at G2; or an invariant would be violated.
- **Never:** ask the human a technical question; auto-re-run after a new pass (I4); per-finding commits (one commit only); a 7th fix cycle (I3) or 4th verify cycle (I8); re-process a `RESOLVED` unit (I7); edit unrelated code in a fix; thread replies onto bot comments (§8); let one agent be both advocate and judge (the `review-arbiter` is never an advocate, never the orchestrator).

---

## 11. Checklists

**Pre-flight:** OWNER/REPO/PR + `{tech}` known · run dir created.
**Per phase:** actions done · artifacts written · **PHASE GATE passed** (self-check for mechanical; independent verifier for substantive) within 3.
**Per finding:** tier+panel_required+**exactly one `seat`** set (+ `provisional_severity`) · adjudicated at that seat, PRO and CON both on it · `adjudications/*.json` persisted · verdict+**evidence-based** severity+disposition recorded · (FIX) reviewer-approved within 6 · covered by the consolidated comment · `status:RESOLVED`.
**Close-out:** one commit pushed (SHAs in ledger) · consolidated comment posted · `summary.md` written · `TRACK_FOLLOWUP`/`BLOCKED` listed · `observations.md` presented · STOP.

---

## 12. Worked example (reference — from the origin repo, PR #7942/#7999)

- **F-01** "justClosed double-count" → `agreement: CONFLICT` → seat `{tech}-reviewer` → PRO+CON → `review-arbiter` read `ConsolidateStats.php:226` → `FALSE_POSITIVE` → `NOT_AN_ISSUE`.
- **F-03** "hasTable memo → worker restart" → dual-pass external *Medium* (→ `provisional_severity: HIGH`, the deliberate escalation) → panel → PRO itself found the collectors are transient (non-singleton) → both converged `FALSE_POSITIVE` (escalation paid off; no judge needed — and the external *Medium* label never reached the ledger).
- **F-12** "`final` on collectors" → adjudication said trivial nit, but the **fix phase** found `final` breaks anon-subclass test doubles → re-classified `TRACK_FOLLOWUP` (R8).
- Response: one consolidated PR comment covering all findings (threaded replies on the reviewdog comments returned 404/422 — R11).

---

**End of procedure v5.** A single terminating, self-verifying run: every finding adjudicated once at the right seat with persisted evidence, judged (on conflict) by the `review-arbiter` whose conduct is `standard-judging`, every step independently verified (≤3), only real defects fixed by the `{tech}` pair to the shared standards (≤6 cycles, one commit, batched where trivial), one consolidated response — human informed at two checkpoints, never asked a technical question.
