# Report inventory: build, test, fix and review reports and their events

Evidence for the report-schema design. Read-only survey of three trees, as of 2026-11-24, made by an independent agent:

- **rewrite/** (the old rewrite, the most complete). Paths are relative to `rewrite/domains/software-development/core/` unless they start with `rewrite/`.
- **new-rewrite/** (partial). It has no agents, no report skills and no report events yet. Only the commit message and the event writer exist (items 6 and 7).
- **software-development/** (v1, the framework that is deployed now). Its `contracts/*.schema.json` files are the only JSON-Schema contracts in the repo. The external review exists only here.

In rewrite/, `code-reviewer/.../scripts/report.sh` is modified and not committed, `report.jq` is untracked, and `main-thread/flows/flow-code-review/` is untracked. The committed version and the work-in-progress version of the review report are two different shapes; both are documented.

## 1. Build report (code-builder)

| Role | Path |
|---|---|
| Report skill | `agents/code-builder/skills/standard-code-build-report/SKILL.md` |
| Example | `.../references/report-iteration.json` |
| Validator | `.../scripts/build-report-check.jq`, `build-report-check.sh --kind build\|test --report FILE --worktree DIR` |
| Pruner | `.../scripts/build-report-prune.sh --report FILE --apply` (drops `null`, `[]`, `{}`) |
| Card | `.../scripts/card.sh`, `.../views/card.jq` |
| Caller | `main-thread/procedures/procedure-seat-run/scripts/hooks/report-commit-hook.sh` (SubagentStop) |

The report goes to `<effort>/drafts/agents/<seat>/report.json`, outside the worktree, and is never committed.

```json
{
  "summary": "string, required, one line, <= 55 chars, no 'word:' prefix",
  "verification": [
    { "gate": "format|lint|typecheck|test|build|scan|manual",
      "result": "pass|fail|not_run|narrowed",
      "note": "string; required when result is fail, not_run or narrowed" }
  ],
  "deviations": [ { "from": "string", "what": "string", "why": "string" } ],
  "decisions":  [ { "choice": "string", "why": "string" } ],
  "noticed":    [ { "at": "path:line", "text": "string" } ],
  "security":   [ { "at": "path:line", "text": "string" } ],
  "open":       [ { "text": "string", "at": "path:line (optional)" } ],
  "blockers":   [ { "kind": "gate_red|request_unclear", "location": "string", "detail": "string" } ]
}
```

**What makes it invalid:**
- **Keys:**
  - not one JSON object;
  - a key outside the 8 above, with derived keys refused with a reason (`files`, `toolchain`, `plugins`, `mode`, `round`, `dispatch`, `started`, `finished`, `effort`, `seat`, `agent_id`, `base`);
  - an unknown item key;
  - `null`, `[]` or `{}`.
- **Text:**
  - a text that isn't one line;
  - a control character or blank text;
  - more than 200 characters;
  - a `summary` over 55 characters, or one with a `type(scope):` prefix.
- **Content:**
  - `verification` missing or empty;
  - a bad enum;
  - an `at` that is not a real `path:line` in the worktree (relative, no `..`, the line exists, not a symlink);
  - `open` with more than 8 items;
  - a `fail` gate without a red blocker, or the reverse.
- **Output:** at most 30 problem lines, each a repair the agent can make from that line alone.

**Readers:**

| Field | Read by |
|---|---|
| `summary` | `commit-input.sh` (the commit subject); `card.jq` |
| `verification` | `card.jq` |
| `blockers` | `card.jq`, `iteration.sh read_report_state`, `render-what-next.sh`, `render-test-next.sh` |
| `deviations`, `open`, `noticed`, `decisions`, `security` | `card.jq`, counts only; no script reads their text |
| the whole body | the `build.committed` event body |

**What the prose tells the agent:**
- never soften a result;
- never carry an item over from an earlier iteration;
- rewrite the whole report each time;
- 2 blocked stops; after a third misfit the work stays uncommitted.

## 2. Fix report

**No separate fix-report schema or validator exists in any tree.**

- **rewrite/, as built:** a fix is another builder iteration with the build report. Nothing names a finding ID.
- **rewrite/, assumed by the untracked review flow:**
  - `request-review.sh` and `review.jq` read `build-fix.committed` and `test-fix.committed`, with the body `{entries: [{key, status fixed|declined, note}]}`;
  - they also read `fix-targets.built` and `fix-scope.chosen`;
  - **nothing writes these, and no validator or prose defines them.**
- **v1:** an inline prose report per finding ID. An item the human chose can't be declined, only reported as a blocker.
- **Spike:** `build.submitted` and `test.submitted` carry `answers: {id: done|declined}` and `declines: {id: reason}`.

## 3. Test plan, test report and plan challenge

### 3a. Test plan (rewrite/)

Files: `agents/code-tester/skills/standard-code-test-report/` (SKILL.md, `references/test-plan.json`, `scripts/test-plan-check.jq`, `plan-card.jq`, `plan-draft.jq`). Gate: `main-thread/flows/flow-code-test/scripts/render-plan-gate.sh`, `plan-approval.sh`. Recorded as `test-plan.made`, with no commit.

```json
{
  "behaviours": [ { "id": "B-n", "text": "string", "at": "path:line", "guarded_by": ["<file>: <test name>"] } ],
  "add": [ { "id": "T-n", "kind": "new_test|new_rows", "file": "path", "name": "string",
             "rows": ["string"], "level": "e2e|integration|unit", "why": "string",
             "guards": ["B-n"], "breaks_on": "string", "fixtures": ["F-n"], "ci": "string" } ],
  "modify": [ { "id": "M-n", "file": "path", "name": "string", "changes": "string", "keeps": "string",
                "guards": ["B-n"], "move": { "row": "...", "from": "...", "to": "..." },
                "breaks_on": "string", "fixtures": ["F-n"] } ],
  "remove": [ { "id": "R-n", "file": "path", "name": "string",
                "covered_by": "T-n | M-n | <file>: <test> | nothing: <why>" } ],
  "fixtures": [ { "id": "F-n", "action": "add|modify|remove", "file": "path",
                  "source": "captured|hand-written|existing", "from": "string", "why": "string", "changes": "string" } ],
  "support": [ { "action": "add|remove", "file": "path", "why": "string" } ],
  "untested": [ { "id": "N-n", "case": "string", "reason": "string", "risk": "string", "category": "string",
                  "proof": "a test | path:line | another repo | unproven", "recommend": "test|waive" } ],
  "no_tests": "string",
  "baseline": "pass|fail",
  "run": [ { "where": "string", "command": "string" } ],
  "blocker": { "kind": "request_unclear|gate_red", "detail": "string" }
}
```

**What makes it invalid:**
- **Keys:** an unknown or derived key.
- **IDs:**
  - an ID that isn't `<P>-n` for its list's prefix, or a duplicate;
  - `guards`, `fixtures` or `covered_by` that don't resolve.
- **Locations:** an `at` that is not a real `path:line`.
- **Whole-plan rules:**
  - `no_tests` is set if and only if add, modify and remove are all empty;
  - a `fail` baseline needs a `gate_red` blocker, unless the failing tests are repaired;
  - a human-read text names an internal ID (`\b[A-Z]-[0-9]+\b`).
- **There is no text cap.**

**Readers:**
- `plan-card.jq`;
- `render-plan-gate.sh` (`untested[].recommend` splits the options, `no_tests` gives "Agree, no tests");
- the tester at TEST;
- the `test_plan` fact on `test.committed`.

### 3b. Test report (rewrite/)

The build report, checked with `--kind test`:
- `blockers.kind` adds `test_red` and `production_bug`, whose location must be a production `path:line`;
- `deviations.from` may be `plan: <id>`;
- the prose says the only gate is `build`, but the validator accepts all 7;
- recorded as `test.committed`, with the commit `crucible(test): …`.

### 3c. Plan challenge

- **rewrite/: none.**
- **v1:** `lens-test-quality-reviewer` in PLAN-CHALLENGE mode decides each test (approve, reject, change, add) and challenges each `not_tested` entry, which needs `proof` or `unproven`. It emits `plan_revision` (the whole revised plan plus `reviewer {approved, rejected, changes}`), or `amendments` on a re-challenge. Its plan schema, `contracts/test-plan.schema.json`, is a different shape: `behaviors B1`, `tests[] {n, name, level, unit_kind, guards, why, fails_if, …}`, `not_tested {what, reason, accepting, category enum, proof|unproven, waived_by_human}`.
- **Spike:** a `challenge` job with `{challenges: [{target, title}]}`, numbered `C-n`, answered by the rework as `applied` or `cannot`.

## 4. Review report

### 4a. Committed (HEAD): findings and previous_findings

```json
{
  "findings": [ {
    "severity": "CRITICAL|HIGH|MEDIUM|LOW",
    "realism": "realistic|edge-case|hypothetical",
    "locations": [ { "file": "repo-relative", "line": "72 | \"72-80\"", "relates_to": "path:line (optional)" } ],
    "trigger": "string", "problem": "string", "fix": "string",
    "proof": "path:line (required on edge-case)",
    "real_if": "string (required on hypothetical)",
    "security": true
  } ],
  "previous_findings": [ { "id": "string", "status": "RESOLVED|OPEN", "proof": "path:line (on RESOLVED)", "note": "string (on OPEN)" } ],
  "flags": [ { "source": "code|non-code", "location": {}, "severity": "CRITICAL|HIGH", "text": "string" } ],
  "not_reviewed": [ { "text": "string", "location": {}, "plugin": "lens name" } ],
  "found": [ { "kind": "instruction|secret", "location": "string", "text": "string" } ]
}
```

**Rules:**
- **Text and list caps:** text is one line of at most 200 characters; at most 20 locations and 200 findings.
- **Realism:** a `realistic` finding carries neither `proof` nor `real_if`.
- **What the reviewer may never write:** `id`, `plugin`, `verdict`, `status` or `waiver`. The flow stamps `plugin`.
- **Prior IDs:** `previous_findings` must hold exactly the prior IDs given, once each.
- **Locations:** each must be in a changed file, unless it carries `relates_to`.
- **A clean review:** `{}`.

**Readers:** named in the prose (the verdict, the render, the fix round), but none exists as a script in rewrite/.

### 4b. Work in progress: concerns and keys

```json
{
  "concerns": [ {
    "severity": "critical|high|medium|low",
    "realism": "realistic|edge-case|hypothetical",
    "claim": "string", "suggestion": "string",
    "at": ["path | path:N | path:N-M | -path:N (base) | @ref:path"],
    "relates_to": "a changed diff line",
    "proof": "string", "out_of_scope": "...", "key": "an earlier key reopened",
    "thread": "id (external)", "rejected": "...", "item": "label", "quote": "...", "matches": "own key"
  } ],
  "fixed": ["key"],
  "withdrawn": [ { "key": "key", "proof": "string" } ],
  "insisted":  [ { "key": "key", "reason": "string" } ],
  "handoffs":  [ { "lens": "string", "claim": "string", "at": ["location"] } ],
  "notes":     [ { "text": "string", "thread": "id", "item": "label", "quote": "..." } ],
  "thread_items": [ { "thread": "id", "items": ["label"] } ]
}
```

**What makes it invalid:**
- **Shape:**
  - an unknown field;
  - `concerns` missing (write `[]`);
  - a blank `claim` or `suggestion`.
- **Proof:** missing on a non-realistic, `rejected` or `out_of_scope` concern.
- **Locations:** one that doesn't exist at head or base, or no diff location without `relates_to`.
- **Keys:**
  - every target key answered exactly once;
  - fixer `fixed` → `fixed` or a reopening concern;
  - fixer `declined` → `withdrawn` or `insisted`;
  - no fixer status → no `insisted`.
- **External:** every concern needs a known `thread`, and every `thread_items` item is answered.

**Keys:**
- `review-keys.sh` stamps `<LENS>-NN`;
- a guard refuses a key another seat raised;
- key states are `open`, `fixed` and `withdrawn`, and the newest report wins.

**Readers:**
- `review.jq review_keys`: `key`, `claim`, `at`, `thread`, `fixed`, `withdrawn`;
- `request-review.sh`: `handoffs`;
- round completion: `concerns`, `insisted` and the threads.

Nothing reads `severity`, `realism`, `suggestion` or `proof` (no verdict, no render).

The round's `next` (`fix-choice`, `fix-round` or `loop-end`) is the only verdict-like rule.

### 4c. v1 (deployed)

`contracts/review-finding-report.schema.json` v1.2:
- **Envelope:** `schema_version`, `reviewer`, `target[]`, `round`, `generated`, `verdict`, `summary {open {critical, high, medium, low}, resolved, new, ack}`, `findings`, `speculative`.
- **Finding:** `id` (`^[A-Z]+-[0-9]{3,}$`), `status NEW|OPEN|RESOLVED|REGRESSED|ACK`, `severity` (upper case), `realism realistic|edge-case`, `trigger`, `category` (a large enum), `locations[]`, `first_seen`, `problem`, `fix`; optionally `proof|unproven`, `resolution_proof`.
- **Speculative:** `{location, concern, why_speculative, category, real_if?, proof?|unproven?}`.

**The verdict arithmetic:**
- the counted set is the findings that are realistic and not resolved or acknowledged, plus any unconfirmed edge-case CRITICAL or HIGH;
- a CRITICAL or HIGH in that set gives `CHANGES_REQUIRED`;
- only MEDIUM or LOW gives `APPROVED_WITH_FOLLOWUPS`;
- otherwise `APPROVED`;
- across a swarm, the strictest wins.

`ACK` is a human waiver only.

**The arbiter's verdict schema:**
- `verdict`: REAL, FALSE_POSITIVE, ACCEPT_SUPPRESS, NEEDS_PRODUCT_DECISION, ALREADY_RESOLVED or ESCALATE;
- `severity`, `evidence`, `recommended_action`, `secondary_actions`, `confidence`;
- `item`: an ID, `speculative:<12hex>`, `handoff:<n>` or `not_tested:<n>`.

## 5. External review

- **v1:** `flow-external-review` has no scripts.
  - **The ledger row** (`external-review-ledger.schema.json`):
    - `id`, `title`, `status`, `source`;
    - `channel` (`inline` or `issue`), `comment_id`, `locations`;
    - `agreement` and `tier`;
    - `provisional_severity` (never shown), `verdict`, `severity`;
    - `disposition`: FIX, NOT_AN_ISSUE, ESCALATED, TRACK_FOLLOWUP or ALREADY_RESOLVED;
    - `secondary_actions`, `fix_commit`, `comment_url`.
  - **Posting:** one consolidated comment, with no per-thread reply field.
  - **External text** is untrusted data.
- **rewrite/ (untracked):** `request-review.sh --kind external` reads `remote-review.fetched {threads}`; concerns answer threads (item 4b). Nothing writes the fetch, and nothing posts.
- **Foreign review:** nothing exists anywhere. The only trace is the spike's `pr.review-requested` and `pr.posted`.

## 6. Commit messages

- **rewrite/:** `procedure-git-worktree/scripts/commit/commit-message.sh` and `commit-message.jq`, input from `commit-input.sh`, called by `report-commit-hook.sh`, signed.

  ```text
  crucible(<kind>): <report.summary>

  Iteration: <n>
  Effort: <effort folder name>
  Agent-Seat: <seat>
  ```

  The kinds are `build` and `test` only, with no `fix` kind and no body. The subject is at most 72 characters. `iteration.sh` counts `crucible(build): ` commits by `Agent-Seat`; recovery reads `Iteration`.
- **new-rewrite/:** `domains/software-development/core/main-thread/git-commit/scripts/lib/commit-message.jq` and `scripts/main/commit-message.sh`.
  - `kind` is any lowercase dash word.
  - Trailers are any keys, title-cased (`change-id` becomes `Change-Id`).
  - The `effort` trailer is added by the scripts.
  - `snapshot` is reserved.
  - There is no body; commits come back `signed: true|false`.
- **v1:** the `git-operator` under `standard-git-commit` (Conventional Commits), not tied to report fields.

## 7. Events written on submission

**rewrite/ envelope** (`rewrite/framework/core/engine/crucible/scripts/events.sh`): `{type, seq, at, by, claude_session_id, iteration, <facts>, body}`, with `--guard` jq, and faults in `events/faults/`.

**new-rewrite/ envelope** (`crucible-events/scripts/internal/event-write.sh`): `{type, seq, at, by, claude_session_id, iteration?, body}`. Each type has exactly one rule file `<component>/events/<type>.jq`, given `{event, prior}`, which pins `by`.

| rewrite/ type | Writer | Facts | Body |
|---|---|---|---|
| `build.committed` | report-commit-hook.sh | `seat`, `dispatch`, `commit`, `iteration` | the build report |
| `test.committed` | report-commit-hook.sh | `seat`, `dispatch`, `commit`, `test_plan` | the test report |
| `test-plan.made` | report-commit-hook.sh | `seat`, `dispatch` | the plan |
| `stop.blocked`, `stop.gave-up` | report-commit-hook.sh | `request` | `{agent_id, hook_event, reason?}` |
| `review.requested` | request-review.sh | `iteration`, `build_seat`, `round`, `seat`, `remote_review` | `kind`, `lens`, `base`, `head`, `diff`, `threads`, `guidance`, `handoffs`, `entries`, `settled`, `skipped`, `others` |
| `review.submitted` | review-keys.sh | `seat`, `request` | the draft, keys stamped |
| `review.completed` | review-complete.sh | `iteration`, `build_seat`, `round` | `{answered, missing, next, unanswered, replaces?}` |
| `review.cancelled` | review-cancel.sh | `request` | `{reason}` |

Read but never written: `fix-targets.built`, `fix-scope.chosen`, `build-fix.committed`, `test-fix.committed`, `remote-review.fetched`.

## 8. Spike: newest shapes (event-jobs)

See `spikes/event-jobs/contract.md` §1.2–1.4.

- **The envelope:** `{seq, type, at, session, root, round, job, agent, body}`.
- **The job events:** `job.dispatched {kind, target, tree, report, agent_type, delivery, hot_agent, slot, replaces, approval, payload, act}`, `job.assigned {name, tool_use_id}` and `job.ended {reason}`.

| Kind | Report | Stop-check rule |
|---|---|---|
| build | `{}` | the tree must change |
| fix | `{answers: {ID: done\|declined}, declines: {ID: reason}}` | every payload finding is answered |
| test | as for fix | the tree must change |
| test-plan | `{answers: {C-n: applied\|cannot}}` on a rework | — |
| review | `{findings: [{kind, file, severity, realism, title}], answers: {ID: fixed\|open\|withdrawn\|insisted}}` | every earlier ID is answered; the tree is at the round's head |
| arbiter | `{rulings: {ID: fix\|drop}}` | every key is ruled |
| challenge | `{challenges: [{target, title}]}` | numbered `C-n` across the effort |
| external-review | findings + `thread`, `threads: {tN: valid\|rejected}` | every thread is judged |

- **The report stays at its path;** the event points at it with an extracted summary.
- `review.merged {findings [{id, kind, file, severity, realism, status}], verdict pass|changes, targets, gaps}`.

## Gaps and contradictions

- **Two review shapes live in rewrite/:**
  - the committed `findings` shape, matching the prose;
  - the work-in-progress `concerns` shape, matching the checker.

  A reviewer that follows its prose fails the checker. The work-in-progress shape lost `flags`, `not_reviewed`, `found` (the secret and instruction channel), `security` and `real_if`.
- **Severity, realism and IDs differ across all four sources:**
  - severity is UPPER in v1 and HEAD, lower in the work-in-progress shape and the spike;
  - `hypothetical` (rewrite/) against `speculative` (v1 arbiter);
  - IDs: 3 digits in v1, `<LENS>-NN` in the work-in-progress shape, unstated in the spike.
- **The status vocabularies differ** (v1 NEW/OPEN/RESOLVED/REGRESSED/ACK; the spike fixed/open/withdrawn/insisted, plus ruled-fix/ruled-drop/skipped).
- **A verdict exists only in v1 (three values) and the spike (`pass`/`changes`).**
- **The fix report is missing in rewrite/:**
  - events are read but never written;
  - there is no `fix` commit kind;
  - the decline reason sits in different places in every source.
- **The plan challenge:** missing in rewrite/. v1's challenge rewrites the whole plan, against a different plan schema. The spike's challenge is a light list.
- **The untested fields differ** (`untested` against `not_tested`, with no `accepting` and no waiver record in rewrite/).
- **The text caps are inconsistent:** 200, 55, none, 100.
- **The tester's gate name** is in the prose only.
- **Most build-report fields have no reader** beyond a count. Secrets reach the human only as a count.
- **The envelopes differ:**
  - rewrite/ copies the report into the event;
  - the spike points at the file;
  - none validates the body in the event rule.
- **External review:**
  - v1 has no per-thread replies;
  - rewrite/ has no fetch and no poster;
  - foreign review has no report shape anywhere.
- **The handoffs differ** across v1, rewrite/ and the work-in-progress shape, and the spike has none.
- **The arbiter:** v1 has 6 verdicts; the spike only `fix`/`drop`.
- **The prose points nowhere:** the review SKILL.md names a validator that differs by working tree, and the v1 PLAN-CHALLENGE text names a plan schema that isn't the rewrite/ plan.
