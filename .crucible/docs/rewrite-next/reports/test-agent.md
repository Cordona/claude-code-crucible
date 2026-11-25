# The test agent: its reports, their checks, the stop hook, the commit and the events

By Dev Beta, for the owner. This covers only the test agent (`code-tester`), the way `build-agent.md` covers the builder.
- Version 2 applied the owner's suggestions, as Fable checked them (`test-agent-fable.md`).
- Version 3 applies the workers' real cases, as Fable judged them (`test-agent-fable-2.md`), the owner's decisions (`decisions.md`), and Fable's final check (`test-agent-fable-3.md`). Reports stay generic: a case gets free text in an existing field, or a gate, before it gets a new field.

Nothing is built yet.

The tester does four kinds of job:

| Job kind | What the tester does | It ends with | Commit |
|---|---|---|---|
| `test-plan` | drafts a test plan for a build | `test-plan.submitted` | no |
| `test-plan-update` | reworks the plan, after the challenge or the human's changes at the gate | `test-plan.updated` | no |
| `test` | writes exactly the tests of the approved plan | `test.submitted` | yes |
| `test-fix` | fixes, in the tests, the findings the human chose | `test-fix.submitted` | yes |

**Reused from the builder, unchanged:**
- the stop hook (validate, stamp, pin, commit, event, held stops);
- the slim event body, pinned by hash;
- the working commit;
- the iteration and the fix round;
- the readiness check.

**The tester's own component,** `agents/code-tester/`, holds one `<kind>-submission.json` and one `<kind>-report-validation.sh` per kind.

## 1. Where the tester sits in the flow

```text
build.submitted (iteration 2)
  → [offer] "plan the tests for: add a retry limit to the upload client"
  → test-plan job            → test-plan.submitted      the draft
  → [owed] the challenge     → test-plan.challenged     (the challenger: the reviewer's slice)
  → [owed] the rework        → test-plan-update job     → test-plan.updated
  → plan gate: the human approves (gate.answered), or sends changes back
                               → another test-plan-update job → test-plan.updated → the gate again
                               (not challenged again by itself; main may offer it)
  → [offer] write the tests
  → test job                 → test.submitted           the tests, committed
  → [offer] review the tests (a review loop, as for a build)
  → a test-fix job           → test-fix.submitted
```

Every tester event carries the iteration of the build it tests. A fix also carries its `fix_round`.

**Report files:** `reports/<job kind>/<job seq>.json`, for example `reports/test-plan/21.json`, `reports/test-plan-update/25.json` or `reports/test/31.json`.
- The folder helps a human reading the effort.
- No script reads the kind from the path; the job says it.
- The builder's reports move the same way (`reports/build/2.json`, `reports/build-fix/17.json`).

## 2. The test plan report (kinds `test-plan` and `test-plan-update`)

A plan job changes nothing in the tree, and makes no commit.

```json
{
  "behaviours": [
    {
      "id": "B-1",
      "text": "a 5xx is retried up to the limit",
      "at": "app/Upload/Client.php:42"
    },
    {
      "id": "B-2",
      "text": "a 4xx is never retried",
      "at": "app/Upload/Client.php:48",
      "guarded_by": [
        "tests/Upload/UploadClientTest.php: rejects on 400"
      ]
    }
  ],
  "tests": [
    {
      "id": "T-1",
      "action": "add",
      "file": "tests/Upload/UploadClientTest.php",
      "name": "retries a 503 three times then fails",
      "level": "integration",
      "why": "the retry loop needs the real HTTP stub",
      "guards": [
        "B-1"
      ],
      "breaks_on": "the limit is ignored"
    },
    {
      "id": "T-2",
      "action": "modify",
      "file": "tests/Upload/UploadClientTest.php",
      "names": [
        "rejects on 400"
      ],
      "changes": "adds rows for 401 and 403",
      "keeps": "every existing row and its assertion",
      "guards": [
        "B-2"
      ],
      "breaks_on": "a 4xx is retried"
    },
    {
      "id": "T-3",
      "action": "remove",
      "file": "tests/Upload/OldClientTest.php",
      "names": [
        "retries forever"
      ],
      "covered_by": "T-1"
    }
  ],
  "support": [
    {
      "file": "tests/fixtures/503.golden.json",
      "what": "a captured 503 body; holds no real token"
    }
  ],
  "untested": [
    {
      "id": "N-1",
      "case": "a retry during a token refresh",
      "reason": "needs a clock seam the code doesn't have",
      "risk": "a double upload",
      "proof": "unproven",
      "recommend": "test"
    }
  ],
  "baseline": {
    "gate": "test",
    "where": "php8.4",
    "result": "narrowed",
    "note": "--filter Upload"
  },
  "run": [
    {
      "where": "docker, the job's worktree mounted",
      "command": "./vendor/bin/phpunit --filter 'Upload(Client|Retry)Test::.*'"
    }
  ]
}
```

### The fields of a test, by action

| Action | Required | Why |
|---|---|---|
| `add` | `id`, `file`, `name`, `level`, `guards`, `breaks_on`; plus `why` for `unit` or `integration` | a new test: how high it tests, why not end to end, what it guards, what makes it fail |
| `modify` | `id`, `file`, `names`, `changes`, `keeps`, `breaks_on`; `guards` optional | existing tests in one file sharing one change: what changes, what they must still assert (the guard against weakening), what makes them fail. A pure repair (a shared base class changed) guards no behaviour of this change, so `guards` is optional |
| `remove` | `id`, `file`, `names`, `covered_by` | tests going away: what still covers them. `covered_by` is a `T-` ID, a `<file>: <test>`, or `nothing: <why>` when the behaviour itself is gone |

**`names`** (on modify and remove) lists one or more tests in one file that share the entry's fields. A test whose `keeps` differs gets its own entry, and the card counts the names. A move, a rename or a merge is said in words in `changes`. The receiving test has its own entry, and a merge is a modify plus a remove covered by it.

**`level` sits on `add` only.** A rule reads it there: a unit or integration test must say why it isn't end to end. Nothing would read or check it on a modify. The card counts added tests by level, and modified or removed tests by action.

**A plan that adds no tests** says why, and still lists the behaviours:

```json
{
  "behaviours": [
    {
      "id": "B-1",
      "text": "the log line's wording changed",
      "at": "app/Upload/Client.php:90"
    }
  ],
  "no_tests": "a wording change in a log line: no behaviour to guard",
  "baseline": {
    "gate": "test",
    "result": "pass"
  },
  "run": [
    {
      "where": "repo root",
      "command": "./vendor/bin/phpunit --filter UploadClientLogTest"
    }
  ]
}
```

**A rework** (`test-plan-update`) is the whole plan again, with the changes applied.
- **Its job carries** the challenges (`C-1`, `C-2`), the human's words from the plan gate, or both.
- **It answers each challenge once.** The human's words get no answer of their own: the human sees the result at the gate.
- **The answers use the same key as a fix's `fixes`,** `id`.

Only the added part is shown:

```json
{
  "answers": [
    {
      "id": "C-1",
      "answer": "applied"
    },
    {
      "id": "C-2",
      "answer": "cannot",
      "reason": "the clock seam is out of this change"
    }
  ]
}
```

### What each field is for

| Field | What the tester puts there | Who reads it |
|---|---|---|
| `behaviours` | what the change does, each with its location, and the tests that already guard it | the challenger; the plan card; the tester at the test job |
| `tests` | each test to add, modify or remove, with its action's fields | the challenger; the card; the tester, who writes exactly these |
| `support` | every file besides the tests that the tests need, or that the tester will change: fixtures, goldens (or a folder of them), factories, seeders, helpers, base classes, a suite registry, a test dependency. `what` says in words what it is, how it's made (captured, hand-written, regenerated by a command), what an existing shared file's change does and which tests it reaches, and when a file holds a generated test-only secret | the challenger (a support file can make a test meaningless); the tester; §5 (a planned file may be changed) |
| `untested` | what won't be tested, with why, the risk, proof, and whether to test it anyway | the challenger; the plan gate (`recommend` splits its options) |
| `baseline` | the tests' state before any change, shaped like a gate. Known failures come from the job, and an unknown red is a blocker for the human. A `failing` entry may name a file or a group, with a count. `not_run`, with a note, when it can't run here | the plan gate (a failing baseline is said up front) |
| `run` | how to run them, where | the tester; the human |
| `no_tests` | why no test is needed | the plan gate's "agree, no tests" option |
| `blockers` | why the plan can't be drafted: `gate_red` or `cannot` | main |
| `answers` | one per challenge: `applied`, or `cannot` with a reason | the plan gate, which shows anything that couldn't be applied |

## 3. The test report (kind `test`)

**It has every field of the build report** (`build-agent.md` §2): `summary`, `gates`, `decisions`, `impact`, `noticed`, `questions` and `blockers`. Empty lists are left out. An unknown key is refused with a line that lists these seven.

**The differences:**
- **One more blocker kind,** `production_bug`: a new test fails because the code is wrong, and its `at` is the production line that is wrong. A test that fails for a reason in the test itself is a `gate_red`, as for the builder.
- **The tester runs the builder's gates,** including lint and format on test files, and a narrowed gate's note says which suites ran.
- **`mutation` is a gate** that every test report lists, run or not:
  - `pass`, with a note such as "34 breaks, all caught";
  - `fail`, with what survived;
  - `not_run`, with why.

  Whether a surviving break is acceptable is the test reviewer's call.
- **The rule that a `fail` with unknown failures needs a `gate_red` blocker covers the checks of the tree, and leaves `mutation` out.** A failed `mutation` gate's `failing` list holds what survived. It needs no blocker, so the job goes to review, not to "answer the blocker".
- **A tester's fix lists the `mutation` gate too.** Nothing requires it of a builder, though a builder may list it.

```json
{
  "summary": "cover the retry limit and the 4xx case",
  "gates": [
    {
      "gate": "test",
      "where": "php8.4",
      "result": "narrowed",
      "note": "--filter Upload"
    },
    {
      "gate": "format",
      "result": "pass"
    },
    {
      "gate": "mutation",
      "result": "pass",
      "note": "34 breaks of Client.php's retry loop, all caught"
    }
  ],
  "decisions": [
    {
      "at": "tests/Upload/UploadClientTest.php:120",
      "choice": "stub the clock with a fixed instant",
      "why": "the planned retry test needs a deterministic delay"
    },
    {
      "at": "tests/Support/HttpStub.php:14",
      "choice": "added a 503 helper to the shared HTTP stub",
      "why": "the plan's support list missed it; three planned tests need it"
    }
  ],
  "impact": [
    {
      "text": "the test suite now needs the ext-pcntl extension in CI"
    }
  ],
  "noticed": [
    {
      "at": "app/Upload/Client.php:60",
      "text": "the upload isn't idempotent; a timeout retry sends the file twice"
    }
  ],
  "questions": [
    {
      "text": "should a 429 count against the retry limit?"
    }
  ]
}
```

**A test that finds a production bug.** The tests are still committed: the red test is what the builder's fix must turn green, and the next job starts from a clean tree.

```json
{
  "summary": "cover the retry limit and the 4xx case",
  "gates": [
    {
      "gate": "test",
      "result": "fail",
      "failing": [
        "UploadClientTest::testRetriesA503ThreeTimes"
      ]
    },
    {
      "gate": "mutation",
      "result": "not_run",
      "note": "the new tests are red, so no breaks were tried"
    }
  ],
  "blockers": [
    {
      "kind": "production_bug",
      "at": "app/Upload/Client.php:42",
      "detail": "the loop retries four times, not three"
    }
  ]
}
```

## 4. A fix in the tests (kind `test-fix`)

This is the builder's fix report (`build-agent.md` §3): the test report plus one fix per chosen finding in `fixes`, each `done`, `partly` or `declined`, with the same rules. A finding the human sent back can't be declined again.
- **No `side` field.** Which agent's component checks the report already says it is the tester's.
- **The fix job's dispatch names its plan,** as the test job's does.

## 5. The validation: what refuses a report

Each rule refuses with one line the tester can act on alone.

**The test plan, and its rework:**

| Rule | The repair line it gets |
|---|---|
| A bad or duplicate ID | `tests[1].id "T1" must be T- and a number, unique in the plan` |
| A bad `action` | `tests[0].action "extend" is not add, modify or remove` |
| A field its action requires is missing (the table in §2) | `tests[1] modifies a test: add keeps, what it must still assert` |
| `guards` naming an unknown behaviour | `tests[0].guards names B-9, which isn't a behaviour in this plan` |
| A bad `level` | `tests[0].level "component" is not e2e, integration or unit` |
| `no_tests` together with tests, or no tests and no `no_tests` | `the plan has no tests: add tests, or no_tests saying why` |
| `behaviours` missing | `list the behaviours the change has, even with no_tests` |
| A baseline that breaks the gate rules | `baseline fails on UploadClientTest::testA, which isn't a known failure: add a gate_red blocker, or a modify that repairs it` |
| An `untested` entry missing a field, or a bad `proof` or `recommend` | `untested[0].proof must be a test, a path:line, or unproven` |
| Human-read text naming an internal ID | `tests[0].why names T-2: say it in words; the IDs are for scripts` |
| A missing `at`, or one that doesn't exist | as for the builder |
| `run` missing, or a blank `command` | `add run: where and how to run these tests` |
| The tree changed in a plan job | `a plan job changes nothing in the tree: undo the change to tests/Upload/X.php` |
| **Rework only:** a challenge with no answer | `answer C-2: applied or cannot` |
| **Rework only:** `cannot` without a reason | `answers[1] is cannot: add a reason` |
| **Rework only:** an applied `add` challenge with no new test | `C-1 asked to add a test and is applied, but no new T- test was added` |

**The test report and a tester's fix,** on top of the builder's rules:

| Rule | The repair line it gets |
|---|---|
| A file not in the approved plan that the build under test changed | `you changed app/Upload/Client.php, which the build under test changed and the plan doesn't name: undo it, and say what you need in a question or a cannot blocker` |
| A file neither in the approved plan nor explained in `decisions` | `you changed tests/Upload/OtherTest.php, which isn't in the approved plan: undo it, or add a decisions entry at it saying why` |
| A planned test not touched | `the approved plan adds a test in tests/Upload/UploadClientTest.php, which didn't change: write it, or add a cannot blocker` |
| A `production_bug` whose `at` is one of the plan's own files | `blockers[0] is production_bug: at must be the production line that is wrong, not a test or support file` |
| A bad blocker `kind` | `blockers[0].kind "flaky" is not gate_red, cannot or production_bug` |
| The `mutation` gate missing | `list the mutation gate: pass with a note, fail with what survived, or not_run with why` |

**What a tester may change.** The approved plan is the list: it is made per change and approved by the human.
- **Named in the approved plan** (in `tests` or `support`, a folder included): allowed, whatever else is true of it. The planned file wins.
- **Not in the plan, and the build under test changed it:** refused. Undo it, and say what's needed in a question or a `cannot` blocker.
- **Not in the plan, anything else:** refused unless a `decisions` entry points at it. The card shows it as a departure from the plan.

**How the workers' cases fall:**
- a factory, a seeder, a suite registry, a test dependency, or a seam in a production file: support entries the planner names, which the challenger and the human see;
- a test file the build touched: planned;
- run outputs: the ignore rules.

A project's files that must never be touched are its own instructions, and reach the agent through the dispatch.

**`production_bug`** may point at any location outside the plan's own files, `@<where>:path` included for another repo. The human decides at the card what to do with it.

## 6. The working commit

A test job and a tester's fix commit like the builder, including when the job is blocked, as long as the tree changed. A plan job makes no commit.

```text
crucible(test): cover the retry limit and the 4xx case

Effort: upload-retries
Job: 31 test-php-77de01
Iteration: 2
Language: php
Framework: laravel
Standards: testing, security
```

```text
crucible(test-fix): assert the 4xx rows by status, not by message

Effort: upload-retries
Job: 40 test-fix-php-77de01
Iteration: 2
Fix-Round: 1
Language: php
Framework: laravel
Standards: testing, security
```

**The tester's setup includes the `testing` standard,** the owner's rule from the old rewrite. Where that rule is checked (the agent's own component saying what its jobs need) belongs to the dispatch talk, not this slice.

## 7. The events

All share the builder's slim body and field order: `job`, `iteration`, `fix_round` (a fix only), `agent`, `report`, `commit` (only when committed).

**`test-plan.submitted`**, the draft:

```json
{
  "type": "test-plan.submitted",
  "seq": 22,
  "by": "submission-event.sh",
  "body": {
    "job": 21,
    "iteration": 2,
    "agent": "77de01…",
    "report": {
      "path": "reports/test-plan/21.json",
      "sha256": "…"
    }
  }
}
```

**`test-plan.updated`**, the rework: the same shape, with its own job and report (`reports/test-plan-update/25.json`).

**`test.submitted`**, the tests:

```json
{
  "type": "test.submitted",
  "seq": 32,
  "by": "submission-event.sh",
  "body": {
    "job": 31,
    "iteration": 2,
    "agent": "77de01…",
    "report": {
      "path": "reports/test/31.json",
      "sha256": "…"
    },
    "commit": "a81c3f0…"
  }
}
```

**`test-fix.submitted`**, a tester's fix: the same body as the builder's `build-fix.submitted`.

**The plan a test job was written from** lives in its `job.dispatched`, not in the event: the event names the job, and `job-of.sh` prints it. So every submission event keeps one shape.

## 8. When a test plan is done, and approved

- **Done:** every challenge key is answered in a `test-plan.updated`, or at once when the challenge raised none. Then the plan gate is owed.
- **Approved:** the human's `gate.answered`, whose subject names the plan event the human saw. There is no second approval event.
- **The human's changes at the gate** become a `test-plan-update` job carrying the human's words. It isn't challenged again by itself; main may offer it.
- **A plan changed after approval** has no approval of its own. The test job's dispatch is refused until the new plan is approved.

## 9. Nothing shared with the builder

Agents share plumbing only (`agent-submission`: the stop hook's steps, the check runner, stamps and trailers). No report or event rule is shared. The tester's rules are its own:
- `code-tester/scripts/lib/tester-common.jq`, the tester's copy of the ground every report has;
- one `<kind>-report.jq` per kind, built on it.

Kind and event are paired in `code-tester/submissions/<kind>.json`. The tester reads the builder's work only through events and git (`tester-facts.sh`), never through its files. The tree is `agents-tree-proposal.md` (version 3).

## 10. What I'll show you when it's built

For each case below I'll run the real scripts and show you the report, the event, and the commit, or none. For a refusal, you get the lines instead.
1. A plan with tests, then its rework answering two challenges (one `applied`, one `cannot`).
2. A plan with `no_tests`.
3. A refused plan, with its repair lines (a missing `keeps`, an unknown guard, an internal ID in human text).
4. A plan job that changed the tree: refused.
5. The tests written: `test.submitted` and its commit.
6. A test that finds a production bug: blocked, with the tests still committed.
7. A tester that changed a file the build changed and the plan doesn't name: refused. A planned file that the build also changed: accepted. A file outside the plan explained in `decisions`: accepted.
8. A tester's fix: `test-fix.submitted` with its fix round.
9. A rework from the human's words at the gate: `test-plan.updated`, with no challenge answers.
10. A test report without the `mutation` gate: refused. A failed `mutation` gate: accepted with no blocker.

Then one live run with a real stand-in tester, as for the builder.

## 11. Also to do when building

- The builder's reports move to `reports/<kind>/<seq>.json`, and the one pattern in `events-view.sh` that checks a report's path follows.
- `git-commit`'s `--help` names `crucible(test)`.
- `mutation` is added to the gate list (the builder's too; a builder may list it).

## 12. Answered elsewhere

- **Landing:** a committed red test blocks any push until it's green; a new dependency or a CI change is shown before it lands.
- **Dispatch:** known failures reaching later jobs; a project's never-touch paths and filter-only rule reaching the agent.
- **Reviewer:** whether `keeps` held, goldens that mirror the code, a shared helper's reach, judging the breaks tried.
