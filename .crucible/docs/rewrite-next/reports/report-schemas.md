# Report schemas, submission events and working commits (draft 3, 2026-11-24)

By Dev Beta. Draft 3 applies the owner's round-3 proposals, checked by the workers (`worker-*-r3.md`) and Fable (`schemas-fable-3.md`). Draft 2 applied three sources:
- the PS Observer's workers (`worker-*.md`);
- the Crucible Fable Reviwer (`schemas-fable.md`);
- the owner's decisions (`decisions.md`).

Nothing here is built or approved; it goes to Fable, then to the owner.

**The test every field and enum value passed:** it exists only if a script or a card treats it differently. Otherwise it is free text, or it isn't here.

**What this spec decides:**
- what each agent writes;
- how it is checked;
- which event its submission writes;
- the working commit that hands in its tree.

**Not here:** how work lands (style, ticket, the split into commits, ports to release branches, the MR body). That is the landing step's spec. It builds its commits and MR text from these reports.

## 0. Rules for every report

1. **One report per job,** at the path its job names (`<effort>/reports/<job seq>.json`), outside the work tree. It is never committed.
2. **The stop check validates it** when the agent tries to stop.
   - Each problem is one line, with a repair the agent can make from it alone. A length problem's repair says how to shorten.
   - After two held stops the job ends `gave-up`. Its tree is kept as it is, for the next job to pick up, never thrown away.
3. **The agent writes only what it alone knows.**
   - Scripts stamp the job, kind, lens, root, round, IDs, commit, changed files, times and source.
   - A report holding one of those keys is refused with "this is filled in for you".
4. **The submission event carries what scripts decide on;** the report keeps the rest. A step that decides never needs to open a report file. A job or a card may carry report text to an agent or the human, such as the fixer's reasons.
5. **One vocabulary:**
   - **severity:** `critical`, `high`, `medium`, `low`;
   - **realism:** `realistic`; `edge-case`, which needs `proof`; `hypothetical`, which needs `real_if`;
   - **finding IDs:** `<KIND>-NN`, stamped by the stop check and unique in the effort.

   Realism is the reviewer's estimate. Edge cases stay visible on the cards, because one can come back as real.
6. **Text:**
   - one line, at most 200 characters, with no control characters and nothing blank;
   - two exceptions: `run.command`, with no cap; and an external `reply`, up to 1,000 characters and multi-line.
   - Report text never holds customer or tenant data, query output, or any part of a secret or its length. No script can check this, so each agent's prose carries it as one line.
7. **Locations:**
   - `path`, `path:N` or `path:N-M`, relative to the job's tree, existing at the head the job worked on;
   - `-path:N` reads at the diff's base, for removed lines;
   - `@<repo or ref>:path:N` names a place outside the tree, and is not checked for existence;
   - the job's tree is its worktree, never the repo root.
8. **Lists are absent when empty;** the stop check prunes `[]` and `{}`.
9. **The plumbing's contract with a report** (`agent-submission` reads this, and nothing more; every other rule is its agent's own): a report is one JSON object; any `at` in it is a location (rule 7, or a list of them), which the plumbing checks once for every agent: well formed, naming a file, the line within it, and a removed line `-path:N` only in a job with a base; a report whose job commits has a `summary`, the commit's subject.

## 1. Build report (kind `build`)

```json
{
  "summary": "add a retry limit to the upload client",
  "gates": [
    { "gate": "test", "where": "php8.4", "result": "narrowed", "note": "--filter ClientTest only" },
    { "gate": "test", "where": "php8.1", "result": "fail", "failing": ["TranslationsImportServiceTest::testA"] },
    { "gate": "lint", "result": "not_run", "note": "the local image lacks ext-redis" }
  ],
  "decisions": [
    { "at": "src/upload/Client.kt:42", "choice": "retry only on 5xx, never on 4xx", "why": "a 4xx will not change on retry" }
  ],
  "impact": [
    { "text": "a new env var UPLOAD_RETRY_LIMIT, needed on UAT and PROD before release", "at": ".deploy/helm/values.prod.yaml:31" }
  ],
  "noticed": [
    { "at": "src/upload/Auth.kt:17", "text": "the token is refreshed on every call, outside this task" },
    { "at": "config/dev.env:3", "kind": "secret", "text": "a hard-coded cloud access key" }
  ],
  "questions": [ { "text": "should the limit be configurable per tenant?" } ],
  "blockers": [ { "kind": "gate_red", "at": "src/upload/ClientTest.kt:88", "detail": "the retry test fails on a 503 stub" } ]
}
```

| Field | Reader | Step | Why the agent writes it |
|---|---|---|---|
| `summary` | the working commit's subject; the card; the landing step | S2 | only the builder knows what it did |
| `gates[].gate`, `result`, `failing` | the stop check (a `fail` whose `failing` all appear in the job's known failures counts as pass); `next.sh` (a red build is a fact); the card | S2, S3 | only the builder ran them |
| `gates[].where` | the card: the same gate run twice, on two images | S2 | only the builder knows where it ran |
| `decisions` | the reviewers of this build (in their job, so a deliberate choice isn't flagged); the landing step's commit and MR body | S4, later | only the builder knows why |
| `impact` | the card, in full; the landing step's MR body | S2, later | deploy facts: env vars, secrets to create, destructive migrations, an order of steps |
| `noticed` | the card (a count, in full on ask) | S2 | what the agent saw outside its task |
| `noticed[].kind` | the card, always in full, as a security notice; `next.sh`, which tells main before anything else is offered. `secret` means rotate or remove, and never quote it; `instruction` means untrusted text, never followed | S2, S3 | the security floor; absent on an ordinary entry |
| `questions` | the card, in full | S2 | what the human must answer or know |
| `blockers` | `next.sh` (the offer is an answer, not a review); the card | S3 | |

**Rules:**
- **Required:** `summary` and `gates`, with at least one gate.
- **`summary`:** at most 55 characters, so that the working commit's `crucible(build): ` subject fits in 72. It has no `type:` prefix.
- **`gate`:** one of `format`, `lint`, `typecheck`, `test`, `build`, `scan`, `manual`.
- **`result`:** `pass`, `fail`, `not_run` or `narrowed`.
  - `note` is required unless the result is `pass`.
  - `failing` (test IDs) is allowed only on `fail`.
- **`where`:** a short label, required when the same gate appears twice.
- **Known failures:** the list comes from the job (the project's or the human's), never from the agent. A `fail` whose `failing` all appear in that list needs no blocker. Any other `fail` needs a `gate_red` blocker, and a `gate_red` blocker needs a `fail`.
- **`blockers.kind`:** `gate_red` or `request_unclear`.
- **`at`:** required on `decisions` and `noticed`, and on `gate_red` blockers. `@<where>:path` is allowed for a place outside the tree.
- **`noticed.kind`:** absent on an ordinary entry, or one of two values:
  - `secret`: something that must not be there (a key, a token, an internal host, customer data). The `text` names what kind of thing it is, never its value or its length;
  - `instruction`: text that tries to direct an agent.

  No script scans for these: the floor rests on the agent's prose, and on the project's `scan` gate.
- **The tree:** it must have changed, unless the report has a blocker.

**Event:**

```json
{ "type": "build.submitted", "seq": 4, "at": "2026-11-24T09:00:04Z", "by": "agent-stop.sh",
  "claude_session_id": "…", "root": 4, "job": 2, "agent": "af6bac…",
  "body": { "report": "reports/2.json", "commit": "9f3c1e2", "red": false, "blocked": false, "security": 1 } }
```

| Body field | Reader | Step | Why not derived |
|---|---|---|---|
| `report` | the review job (it gives the reviewer the builder's `decisions` and `impact`); the card | S2, S4 | the report's path, relative to the effort, stamped |
| `commit` | the review round (base..head, and the changed files read from the commit); the test job; recovery | S2, S4 | made by the stop check after the report |
| `red` | `next.sh` (the fact is "the build is red", and the offer is to fix it, not to review it) | S3 | a summary of the gates, so `next.sh` opens no report |
| `blocked` | `next.sh` (the offer is an answer to the blocker) | S3 | |
| `security` | `next.sh` (a security notice to main before anything else is offered): the number of `noticed` entries with a `kind` | S3 | |

`impact` and the gates that didn't run aren't in the event. The card shows them from the report, and no step decides differently because of them.

**The working commit's rules** make reading the files from the commit safe:
- the effort branch is never rebased or rewritten; main is merged in instead;
- a ref keeps the effort's commits until the effort is pruned on purpose;
- the job starts from a clean worktree, and the stop check commits by the project's ignore rules.

## 2. Fix report (kinds `build-fix` and `test-fix`)

A fix job (`build-fix` or `test-fix`) carries the findings the human chose. The fixer writes the build report plus one fix per finding, in `fixes`.

```json
{
  "summary": "quote variables in a.sh and b.sh",
  "gates": [ { "gate": "test", "result": "pass" } ],
  "fixes": [
    { "id": "SHELL-01", "status": "done", "note": "a.sh:3 now quotes $1" },
    { "id": "SECURITY-01", "status": "partly", "reason": "quoted at a.sh:3; the eval at a.sh:9 is still there" },
    { "id": "CLEAN-CODE-01", "status": "declined", "reason": "valid, but the word input is b.sh's documented contract; not this change" }
  ]
}
```

| Field | Reader | Step | Why |
|---|---|---|---|
| `fixes[].status` | the next round (each reviewer gets its earlier IDs with the fixer's fixes); `merge.sh` | S4 | only the fixer knows |
| `done.note` | the re-reviewer; the landing step ("fixed in <commit>") | S4, later | |
| `partly.reason` | the re-reviewer, who treats it as open | S4 | |
| `declined.reason` | the re-reviewer, who gives its view; the end card, where the human waives it or sends it back | S4 | the decline overrides the human's choice, so the human decides |

**Rules:**
- every finding in the job has one fix, and no other ID does;
- `status` is `done`, `partly` or `declined`;
- `reason` is required on `partly` and `declined`; `note` is optional on `done`;
- a declined finding is set aside: the loop doesn't send it to a fix again unless the human does;
- an ID the human sent back after a decline can't be declined again. A fixer that can't do it writes a `request_unclear` blocker, and the human sees it;
- the tree may stay unchanged only when every fix is `declined`;
- everything else is as in the build report.

**Event:** `build-fix.submitted`, or `test-fix.submitted` for a `test-fix`, with `fixes: [{id, status}]` added. The reasons stay in the report, and the next review job carries them to the reviewer.

## 3. Test plan (kind `test-plan`)

```json
{
  "behaviours": [
    { "id": "B-1", "text": "a 5xx is retried up to the limit", "at": "src/upload/Client.kt:42" },
    { "id": "B-2", "text": "a 4xx is never retried", "at": "src/upload/Client.kt:48", "guarded_by": ["src/upload/ClientTest.kt: rejects on 400"] }
  ],
  "tests": [
    { "id": "T-1", "action": "add", "file": "src/upload/ClientTest.kt", "name": "retries a 503 three times then fails",
      "level": "integration", "why": "the retry loop needs the real HTTP stub", "guards": ["B-1"], "breaks_on": "the limit is ignored" },
    { "id": "T-2", "action": "modify", "file": "src/upload/ClientTest.kt", "name": "rejects on 400",
      "changes": "adds rows for 401 and 403", "keeps": "every existing row and its assertion", "guards": ["B-2"], "breaks_on": "a 4xx is retried" },
    { "id": "T-3", "action": "remove", "file": "src/upload/OldClientTest.kt", "name": "retries forever", "covered_by": "T-1" }
  ],
  "support": [ { "file": "tests/fixtures/503.golden.json", "what": "a captured 503 body; holds no real token" } ],
  "untested": [
    { "id": "N-1", "case": "a retry during a token refresh", "reason": "needs a clock seam the code doesn't have",
      "risk": "a double upload", "proof": "unproven", "recommend": "test" }
  ],
  "baseline": { "gate": "test", "where": "php8.4", "result": "narrowed", "note": "--filter Client" },
  "run": [ { "where": "docker, the job's worktree mounted", "command": "./vendor/bin/phpunit --filter 'Upload(Client|Retry)Test::.*'" } ]
}
```

| Field | Reader | Step | Why |
|---|---|---|---|
| `behaviours` | the challenger; the plan card; the tester | S4 | |
| `tests` (`action`: `add`, `modify`, `remove`) | the challenger; the card (counts by level); the tester, who writes exactly these | S4 | |
| `tests[].keeps` (on modify) | the challenger: what a repaired test must still assert, the guard against weakening | S4 | all five workers |
| `tests[].covered_by` (on remove) | the challenger; the human | S4 | |
| `support` | the challenger (a base class, a helper, a golden or a fixture can make a test meaningless); the tester | S4 | |
| `untested` | the challenger; the plan gate (`recommend` splits the options) | S4 | |
| `baseline` | the plan gate | S4 | the same shape as a gate, so the same known-failures rule applies |
| `run` | the tester; the human | S4 | |
| `no_tests`, `blockers` | the plan gate; `next.sh` | S3, S4 | |

**Rules:**
- **IDs:** `B-n`, `T-n` and `N-n`, unique within the plan. `guards` name existing `B-` IDs, and `covered_by` names a `T-` ID, a `<file>: <test>`, or `nothing: <why>`.
- **On `modify`:** `changes` and `keeps` are required. Extending a test with rows is a modify whose `keeps` says every row.
- **On `add`:** `level` and `breaks_on` are required, and `why` too for `unit` and `integration`.
- **`no_tests`** is set if and only if `tests` is empty.
- **The baseline:** follows the build report's gate rules; a `fail` with unknown failures needs a blocker, unless a `modify` repairs those tests.
- **`blockers`:** the same list and kinds as in the build report.
- **Text a human reads** (`text`, `why`, `breaks_on`, `changes`, `keeps`, `case`, `reason`, `risk`, `what`) never names an internal ID.

**A rework** (the job carries challenges) adds `answers: [{challenge, answer: applied | cannot, reason?}]`. `reason` is required on `cannot`. Every challenge with `ask: add` that is `applied` must end with a new `T-` item.

**Events, with no commit:**
- `test-plan.submitted {report, counts: {behaviours, tests, untested}, baseline: {result}, blocked}`: the first draft;
- `test-plan.updated`: a rework, with the same body plus `answers`.

The plan is done when every challenge key is answered in a `test-plan.updated`, or at once when the challenge raised none.

**The human's yes** at the plan gate is the core gate's `gate.answered`, whose subject names the plan event the human saw. There is no second approval event.

**The human's changes at the gate** ("drop T-3, add a 401 case") go to the planner as a rework, which hands in a `test-plan.updated`. Then the gate again.
- A plan changed after approval has no approval of its own, so the tester's dispatch is refused.
- It isn't challenged again by itself; main may offer it.

## 4. Plan challenge (kind `challenge`): one challenger, no loop

```json
{
  "challenges": [
    { "target": "B-1", "ask": "add", "title": "no test proves the limit is three, not four", "why": "the planned test passes with any limit above two" },
    { "target": "src/upload/Client.kt:60", "ask": "add", "title": "a behaviour the plan misses: the upload isn't idempotent", "why": "a retry after a timeout sends the file twice" },
    { "target": "tests/Support/AuditAssert.php::assertAuditedOnce", "ask": "change", "title": "the new level argument weakens every audit test", "why": "it defaults to any level" }
  ]
}
```

| Field | Reader | Step |
|---|---|---|
| `target` | the rework job: a plan ID, `plan`, a code location, `path::helper`, or a support file the plan names | S4 |
| `ask` | the rework: `add`, `change` (also a wrong fact, a merge or a shrink), `remove`, `prove` (an untested case) | S4 |
| `title`, `why` | the planner; the plan card when it can't be applied | S4 |

**Rules:**
- every target exists: a plan ID in the plan, a location in the tree, a helper in its file. A support file the plan names counts as existing, since it may be new;
- `title` and `why` never name an internal ID;
- an empty report (`{}`) approves the plan as it is;
- the stop check stamps each challenge `C-n`, numbered across the effort.

**Event:** `test-plan.challenged {report, challenges: [{key, target, ask}]}`. Its own type, because its next step (the rework) differs from a review's.

## 5. Code review report (kind `review`: cold, hot, or a re-review)

```json
{
  "findings": [
    { "severity": "high", "realism": "realistic", "at": ["a.sh:3"], "claim": "the variable is unquoted, so a path with a space splits", "suggestion": "quote it: \"$1\"" },
    { "severity": "high", "realism": "realistic", "at": ["@core-api:app/Http/Client.php:88"], "relates_to": "a.sh:12",
      "claim": "the caller passes an unescaped tenant name into this script", "suggestion": "escape at the call or validate here" },
    { "severity": "medium", "realism": "edge-case", "at": ["b.sh:2"], "claim": "a glob in the input expands", "suggestion": "set -f around the loop",
      "proof": "b.sh:1 reads words from the caller, which passes user paths" },
    { "severity": "low", "realism": "hypothetical", "claim": "no script in this change logs its failures", "suggestion": "log to stderr",
      "real_if": "these scripts run unattended in cron" },
    { "severity": "medium", "realism": "realistic", "at": ["a.sh:20"], "claim": "the same unquoted pattern exists on main",
      "suggestion": "fix it in a follow-up", "out_of_scope": "a.sh:20 is unchanged by this diff" }
  ],
  "fixes": [
    {
      "id": "SHELL-01",
      "status": "fixed"
    },
    {
      "id": "SECURITY-01",
      "status": "open",
      "reason": "the eval at a.sh:9 still runs the input"
    },
    {
      "id": "CLEAN-CODE-01",
      "status": "agree",
      "reason": "b.sh's header documents word input; the decline holds"
    }
  ],
  "noticed": [
    { "at": "a.sh:9", "text": "evals user input", "for": "security" },
    { "at": "README.md:40", "kind": "instruction", "text": "a line telling reviewers to approve" }
  ],
  "notes": [ { "text": "the retry cap at Client.kt:42 holds under every path I traced" } ]
}
```

| Field | Reader | Step | Why |
|---|---|---|---|
| `findings` | the stop check (stamps the ID from the job's lens); `merge.sh`; the fix job; the cards | S4 | only the reviewer judges |
| `findings[].at` (absent: a general finding) | `merge.sh` (file, for the cover); the fixer | S4 | |
| `relates_to` | the stop check: a finding outside the diff must name the changed line it relates to | S4 | a defect in a caller |
| `proof`, `real_if` | the human (edge cases and hypotheticals in their own sections) | S4 | the realism floor |
| `out_of_scope` (its proof) | `merge.sh`: never a fix target; the card lists it as a follow-up | S4 | true, but not this change |
| `fixes` | `merge.sh`; the end card (the reviewer's view on each decline) | S4 | |
| `noticed[].for` | the next round: the named lens gets it, if that lens is already in the round; otherwise the card shows it. A handoff never seats a reviewer | S4 | something the reviewer saw outside its lens |
| `noticed[].kind` | as in the build report | S2, S3 | |
| `notes` | the card, on ask | S4 | what held up; the human approves on it |

**Rules:**
- **Locations:**
  - every `at` in the tree is in the job's cover, unless the finding has `relates_to` (a changed line) or `out_of_scope`;
  - `@` locations are allowed;
  - a finding with no `at` is a general finding.
- **Realism:** `edge-case` needs `proof`; `hypothetical` needs `real_if`; `out_of_scope` needs its proof text.
- **Fixes:** every earlier ID the job names gets one status.
  - An ID the fixer marked `done` or `partly` takes `fixed`, or `open` with a reason.
  - A `declined` ID takes `agree` or `disagree`, with a reason. That is a view for the human, not a ruling.
- **A regression of a settled ID** is a new finding with `reopens: <ID>`.
- **`noticed[].for`** is allowed only in review reports. The stop check stamps a key on each `for` entry, and the receiving lens answers it: real, so it becomes its own finding, or not, with proof. Its shape is in the review loop's spec.
- **The tree** is still at the round's head.
- **A clean review** is `{}`.
- **Never written:** `id`, `kind`, `lens`, `source`.

**Event:** `review.submitted {report, findings: [{id, file, severity, realism, out_of_scope, reopens?}], answers: [{id, answer}], routed: [{key, for}], security: n}`.

## 6. Arbiter report (kind `arbiter`): on offer, not owed

Main and the human decide when to offer the arbiter. Its ruling is a third view on the end card; the human still decides.

```json
{ "rulings": [ { "id": "CLEAN-CODE-01", "ruling": "fix", "why": "the documented contract doesn't cover paths with spaces, which callers pass" } ] }
```

**Rules:** every ID in the job is ruled once. `ruling` is `fix` or `drop`, with `why` required.

**Event:** `ruling.submitted {report, rulings: [{id, ruling}]}`. This is its own type, because no merge follows a ruling; its next step is the end card.

## 7. External review triage (kind `external-review`: someone reviewed our MR)

```json
{
  "items": [
    { "thread": "n11370", "item": "F-03a", "verdict": "valid",
      "finding": { "severity": "medium", "realism": "realistic", "at": ["src/upload/Client.kt:55"],
                   "claim": "the timeout isn't applied to the retry", "suggestion": "pass the timeout into retry()" } },
    { "thread": "n11370", "item": "F-03b", "verdict": "rejected", "reply": "PHP 8.4 is already the floor in composer.json:12, so the compatibility point doesn't apply." },
    { "thread": "n11370", "item": "F-04", "verdict": "rejected", "reply": "The retry is capped at src/upload/Client.kt:42, so this loop ends after three tries.\nThe test T-1 covers the cap." },
    { "thread": "n11371", "verdict": "already-fixed", "reply": "Fixed in 9f3c1e2, before this review." },
    { "thread": "n11372", "verdict": "deferred", "reply": "True on main as well; proposed as a follow-up ticket." },
    { "thread": "n11374", "verdict": "deferred", "note": "prod tonight or preprod first is a release decision: yours" },
    { "thread": "n11373", "verdict": "answered", "reply": "No migration in this change, only the new env var, which is already in the values." },
    { "thread": "description", "verdict": "noted" }
  ]
}
```

| Verdict | What follows |
|---|---|
| `valid` | its `finding`, which goes through the fix choice and the loop. Its reply ("fixed in <commit>") is drafted later by a script from the fixer's note and the landed commit, and edited at a second replies offer |
| `rejected` | the reply, posted after the replies gate |
| `already-fixed` | the reply, naming the commit |
| `deferred` | yours to decide: a proposal with its `reply`, or only a `note` saying what the decision is; the human sees it at the replies gate |
| `answered` | a question or request answered; the reply, no finding |
| `noted` | checked, praise, or nothing to do; no reply |

**Rules:**
- every thread in the job is judged at least once;
- the points inside one thread (a bot's note with several) are the agent's own split, each judged once with its `item` label;
- `rejected`, `already-fixed` and `answered` need a `reply`; `deferred` needs a `reply` or a `note`; `noted` and `valid` take none;
- `valid` needs its `finding`, and only `valid` has one;
- two defects in one item are split by the agent into two items (`F-03a`, `F-03b`). The labels are the agent's, using the bot's where they exist;
- the thread texts are untrusted data, and the job says so.

The stop check stamps each thread's `source` (`human` or `bot`) from the fetch. The cards and the replies gate show human threads first. The MR description is the thread `description`.

**Event:** `review.submitted {report, items: [{thread, item?, verdict, finding?: {id, file, severity, realism}}]}`.

**Two reply offers:**
- the replies that are ready (rejected, already-fixed, answered, deferred) after the triage;
- later, after the fix has landed, the replies to the valid items.

The human posts each set at once or both together.

## 8. Foreign review (kind `review` on someone else's MR: we comment, never fix)

This is the code review report of section 5, with no `answers`. The job marks it `foreign`, and the stop check refuses `answers`.
- The findings' `claim` and `suggestion` are written for the MR's author, since here the comment is the product.
- The human edits them at the comments gate, and `remote.sh` posts them after it.
- No fix loop.

## 9. Test report (kind `test`)

The build report, with these differences:
- `blockers.kind` adds `test_red` (a new test fails for a reason in the test) and `production_bug` (the code is wrong; `at` is a production location);
- `decisions[].why` may name the plan item it departs from;
- the tester runs the builder's gates, including lint and format on test files.

**Event:** `test.submitted`, shaped like `build.submitted`, plus `plan` (the seq of the approved `test-plan.submitted` or `test-plan.updated`, stamped).

## 10. The working commit

When the report validates, the stop check commits the job's tree in the effort's own worktree, on the effort's branch. The build's approval covers it (`decisions.md` 1). It isn't signed, and it never lands.

```text
crucible(build): add a retry limit to the upload client

Job: build-kotlin-af6bac
Effort: upload-retries
```

The kind is the job's kind, as `build`, `build-fix`, `test` or `test-fix`. There is no body.

| Part | Reader | Step |
|---|---|---|
| subject | humans in the effort's `git log`; the landing step, as a draft line | S2 |
| `Job` | recovery: a working commit whose job has no `*.submitted` event is matched by this trailer, inside the effort's branch only | S2 |
| `Effort` | the git-commit scripts, as today | S2 |

**The landing step's spec (next, separate)** turns working commits into the project's commits:
- the house style and ticket, from the project's template;
- the atomic split into commits;
- ports to release branches;
- the MR body, built from `summary`, `decisions`, `impact` and the fix answers;
- the developer's own signing key;
- a gate per operation.

## 11. Not decided here

- **The job events** (`job.dispatched`, `job.assigned`): the dispatch spec, next.
- **The review loop's own events and gate:** S4, in their own spec, which follows `decisions.md` 2. They are `review-round.opened`, the merge (`review.merged`, name to decide), the review gate's lens choice, the end card's waive or send back, and the answer to a routed `noticed`.
- **The cards' look:** totals only.
- **The landing step.**
- **Project facts:** the project's gates and known failures need a home. Until then they come from the job.
