# The build agent: its reports, their checks, the stop hook, the commit and the event

By Dev Beta, for the owner. This covers only the build agent, in its two jobs: a **build** (the first work on a task) and a **fix** (findings the human chose). Version 2 applies the owner's two proposals as Fable checked them (`build-agent-fable.md`). Nothing is built yet.

## 1. What happens when the builder finishes

```text
agent tries to stop
  └─ stop hook
       1. read      the report at <effort>/reports/<job seq>.json
       2. validate  → a problem: hold the stop, one repair line per problem
                      (the second hold ends the job: job.ended gave-up; the tree is kept)
       3. stamp     anything only a script fills in, into the report (on a build or fix: nothing yet)
       4. pin       hash the report and make it read-only
       5. commit    the working commit, in the effort's worktree, unsigned (skipped when the tree didn't change)
       6. event     build.submitted (a build) or build-fix.submitted (a build-fix): where the report is, its hash, the commit
       7. let the stop through
```

**The report is the one source.**
- The event points at the report and pins it by hash.
- Every script that decides reads the report through the event view, the one place that joins each report to its event and refuses on a mismatch.
- A report changed after it was submitted is refused there, and the human is told. One changed report blocks the view of its whole effort, not only its own job, until a human looks.

## 2. The build report

The file is at `<effort>/reports/<job seq>.json`. The builder writes it; it is never committed.

```json
{
  "summary": "add a retry limit to the upload client",
  "gates": [
    {
      "gate": "test",
      "where": "php8.4",
      "result": "narrowed",
      "note": "--filter UploadClientTest only"
    },
    {
      "gate": "test",
      "where": "php8.1",
      "result": "fail",
      "failing": [
        "TranslationsImportServiceTest::testImport"
      ]
    },
    {
      "gate": "lint",
      "result": "not_run",
      "note": "the local image lacks ext-redis"
    }
  ],
  "decisions": [
    {
      "at": "app/Upload/Client.php:42",
      "choice": "retry only on 5xx, never on 4xx",
      "why": "a 4xx will not change on retry"
    }
  ],
  "impact": [
    {
      "text": "a new env var UPLOAD_RETRY_LIMIT, needed on UAT and PROD before release",
      "at": ".deploy/helm/values.prod.yaml:31"
    }
  ],
  "noticed": [
    {
      "at": "app/Upload/Auth.php:17",
      "text": "the token is refreshed on every call, outside this task"
    },
    {
      "at": "config/dev.env:3",
      "kind": "secret",
      "text": "a hard-coded cloud access key"
    }
  ],
  "questions": [
    {
      "text": "should the limit be configurable per tenant?"
    }
  ]
}
```

In this example, `TranslationsImportServiceTest::testImport` is in the job's known failures, so the `fail` needs no blocker.

**A blocked build** adds `blockers`, and may leave the tree unchanged:

```json
{
  "summary": "add a retry limit to the upload client",
  "gates": [
    {
      "gate": "test",
      "result": "fail",
      "failing": [
        "UploadClientTest::testRetriesA503"
      ]
    }
  ],
  "blockers": [
    {
      "kind": "gate_red",
      "at": "tests/Upload/UploadClientTest.php:88",
      "detail": "the retry test fails on a 503 stub"
    }
  ]
}
```

### What each field is for

| Field | What the builder puts there | Who reads it |
|---|---|---|
| `summary` | what it did, in one line | the commit subject; the card |
| `gates` | each check it ran, or couldn't run, with where and the result | the stop check (known failures); main (a red build: the offer is to fix it, not to review it); the card |
| `decisions` | choices a reviewer might flag, with the reason | the reviewers of this build; later, the MR body |
| `impact` | deploy facts: env vars, secrets to create, destructive migrations, an order of steps | the card, in full; later, the MR body |
| `noticed` | what it saw outside the task. `kind: secret` or `instruction` marks a security notice | the card. A security notice is always shown in full, and main hears it before anything else is offered |
| `questions` | what the human must answer or know | the card, in full |
| `blockers` | why it couldn't finish: `gate_red` (a check fails) or `cannot` (anything else stops it) | main: the next offer is to answer the blocker, not to review |

## 3. The fix report

A build-fix job carries the findings the human chose. The build-fix report is the build report plus `fixes`, one per finding.

```json
{
  "summary": "quote variables in a.sh and b.sh",
  "gates": [
    {
      "gate": "test",
      "result": "pass"
    }
  ],
  "fixes": [
    {
      "id": "SHELL-01",
      "status": "done",
      "note": "a.sh:3 now quotes $1"
    },
    {
      "id": "SECURITY-01",
      "status": "partly",
      "reason": "quoted at a.sh:3; the eval at a.sh:9 is still there"
    },
    {
      "id": "CLEAN-CODE-01",
      "status": "declined",
      "reason": "the word input is b.sh's documented contract; not this change"
    }
  ]
}
```

| Status | Needs | What follows |
|---|---|---|
| `done` | an optional `note` | the re-reviewer checks it: `fixed`, or `open` with a reason |
| `partly` | a `reason` | the re-reviewer treats it as open |
| `declined` | a `reason` | set aside. The re-reviewer gives its view, and you decide at the end card: waive it, or send it back. A finding sent back can't be declined again; a fixer that can't do it writes a `cannot` blocker |

## 4. The validation: what refuses a report

Each rule refuses with one line the builder can act on alone. These are the lines it would see.

| Rule | The repair line it gets |
|---|---|
| The file is missing or isn't one JSON object | `write your report as one JSON object to <path>` |
| A key only a script fills in (`id`, `commit`, `job`, `kind`, …) | `remove "commit": this is filled in for you` |
| An unknown key | `unknown key "verification"; the keys are summary, gates, decisions, impact, noticed, questions, blockers` (plus `fixes` on a fix) |
| `summary` is missing, over 55 characters, or has a `type:` prefix | `summary is 61 characters; shorten it to 55 or fewer` |
| `gates` is missing or empty | `list at least one gate you ran or couldn't run` |
| A bad `gate` or `result` value | `gates[2].result "skipped" is not one of pass, fail, not_run, narrowed` |
| `note` is missing on a `not_run` or `narrowed` result | `gates[2] is not_run: add a note saying why` |
| A `fail` with no `failing` list: whatever failed, for any gate (a test, a lint rule, a build step) | `gates[1] fails: list what fails in failing` |
| The same gate twice, with no `where` | `gates[0] and gates[1] are both "test": add where to each` |
| A `fail` with failures that aren't known, and no `gate_red` blocker | `gates[1] fails on UploadClientTest::testRetriesA503, which isn't a known failure: fix it, or add a gate_red blocker` |
| A `gate_red` blocker with no `fail` gate | `blockers[0] is gate_red but no gate failed` |
| A bad blocker `kind` | `blockers[0].kind "stuck" is not gate_red or cannot` |
| A missing `at` | `noticed[0] needs at: the file and line` |
| An `at` that doesn't exist at the head | `decisions[0].at app/Upload/Client.php:420 is past the end of the file (88 lines)` |
| A bad `kind` | `noticed[1].kind "leak" is not secret or instruction` |
| Text over 200 characters, more than one line, or blank | `impact[0].text is 240 characters; shorten it to 200` |
| The tree is unchanged, with no blocker | `nothing changed in the tree: make the change, or add a blocker saying why` |
| **Build-fix only:** a chosen finding with no fix | `list SECURITY-01 in fixes: done, partly or declined` |
| **Build-fix only:** an ID that isn't in the job | `SHELL-09 is not one of this job's findings` |
| **Build-fix only:** a reason missing on `partly` or `declined` | `fixes[2] is declined: add a reason` |
| **Build-fix only:** a decline of a finding the human sent back | `CLEAN-CODE-01 was sent back by the human: it can't be declined again; fix it, or add a cannot blocker` |
| **Build-fix only:** the tree is unchanged, but not every fix is `declined` | `nothing changed, but SHELL-01 is done: commit the fix` |

The stop check removes empty lists (`[]`, `{}`) first. A second held stop ends the job as `gave-up`, and its tree stays for the next job to pick up.

## 5. The working commit

This is made by the stop hook after the report is pinned. It goes into the effort's own worktree, on the effort's branch. It's unsigned and never lands; landing is the gated git step, in the project's own style.

**Build:**

```text
crucible(build): add a retry limit to the upload client

Effort: upload-retries
Job: 2 build-php-af6bac
Iteration: 2
Language: php
Framework: laravel
Standards: security, observability, persistence
```

**Build-fix:**

```text
crucible(build-fix): quote variables in a.sh and b.sh

Effort: upload-retries
Job: 17 build-fix-php-af6bac
Iteration: 2
Fix-Round: 1
Language: php
Framework: laravel
Standards: security, observability, persistence
```

- **The subject:** `crucible(<build|build-fix>): ` plus `summary`, at most 72 characters. There is no body.
- **`Job`:** the job's seq, then its readable name. The seq is the job's key: one builder reused for two fixes keeps its name, but each job has its own seq. Recovery reads it: a working commit whose job has no `build.submitted` gets its event written from this trailer.
- **`Iteration`** (on every working commit) and **`Fix-Round`** (on a fix commit, production or tests side): copies of the event's stamps (section 7), for the human reading `git log`. No script reads them.
- **The setup lines** (`Language`, `Framework`, `Standards`, and `Model` if the dispatch records one):
  - the dispatch's setup has exactly one `language`, zero or more `frameworks`, at least one of `standards`, and an optional `model`;
  - `Framework` is written only when there are frameworks, on one line joined by commas, as `Standards` is;
  - they are a copy of the job's dispatch, stamped by the hook under the dispatch's own keys, for the human reading `git log`;
  - no script reads them.
- **The working commit's rules:**
  - the effort branch is never rebased or rewritten;
  - a ref keeps its commits until the effort is pruned on purpose;
  - the job starts from a clean worktree, and the commit follows the project's ignore rules.

## 6. The events: `build.submitted` and `build-fix.submitted`

One is written after the commit, with the same slim body for both.

**They are two types because their next steps differ:**
- after a build, main offers the human a review;
- after a fix, the re-review round is owed and runs without asking.

With a slim body, the type is the only thing in the event that tells them apart. A fix of the tests is its own kind with its own event, `test-fix` and `test-fix.submitted` (`test-agent.md`).

**After a build:**

```json
{
  "type": "build.submitted",
  "seq": 4,
  "at": "2026-11-24T09:00:04Z",
  "by": "agent-stop.sh",
  "claude_session_id": "…",
  "body": {
    "job": 2,
    "iteration": 2,
    "agent": "af6bac…",
    "report": {
      "path": "reports/2.json",
      "sha256": "5f2b…"
    },
    "commit": "9f3c1e2"
  }
}
```

**After a fix:**

```json
{
  "type": "build-fix.submitted",
  "seq": 18,
  "at": "2026-11-24T09:12:40Z",
  "by": "agent-stop.sh",
  "claude_session_id": "…",
  "body": {
    "job": 17,
    "iteration": 2,
    "fix_round": 1,
    "agent": "af6bac…",
    "report": {
      "path": "reports/17.json",
      "sha256": "9a41…"
    },
    "commit": "c41a9d0"
  }
}
```

**The writer prints the body's fields in this order:** `job`, `iteration`, `fix_round`, `agent`, `report`, `commit`. That's for people and greps; no script depends on the order, since JSON objects have none and jq reads by key.

**Absent fields stay absent:**
- no `fix_round` outside a fix loop;
- no `commit` when the tree didn't change (a blocked build, or a fix that declined every finding).

`report` has the same shape in every submission event.

| Field | Why it's in the event |
|---|---|
| `job`, `agent` | which job and agent this ends (stamped). The event writer doesn't know what a job is; the view derives the root and the round from the dispatch |
| `iteration`, `fix_round` | which build this belongs to, and which fix in its loop (section 7) |
| `report.path` | where the report is, relative to the effort |
| `report.sha256` | pins the report; the view refuses it if it changed. The two sit together, so no reader takes the path without the pin |
| `commit` | the review round reads base..head and the changed files from it |

Everything else is read from the pinned report: whether the build is red or blocked, a security notice, the fixes.

## 7. The iteration and the fix round, stamped

**The terms** (the owner's definitions):
- **An iteration** is a build and everything that belongs to it: its test plan and challenge, its tests, its internal and external reviews, and its fixes. It starts at the build's dispatch. A fix doesn't start one, and builds may follow one another with nothing in between.
- **A fix round** is the n-th fix inside one fix loop, together with its re-review, up to the human's cap.

**The stamps** (Fable approved, with conditions):
- **Every event that belongs to a build** carries `iteration` in its body, beside `job` and `agent`. It isn't in the envelope, so the core event writer never learns what a build or a fix round is.
- **Every event inside a fix loop** also carries `fix_round`.
- **Both are stamped by the writing script,** never by an agent's report. Once stamped, no reader works them out again.

**How they're counted, once, and inherited everywhere:**
1. **A build's dispatch sets the iteration.** One function counts: the next number on the tree. A replacement of a build that gave up keeps the number.
2. **A fix's dispatch sets the fix round,** the next number inside its loop. This count is provisional until the review-loop spec: for now a new loop is known only by findings the human sent back, so a second fix choice continues the old count.
3. **Every later event copies its numbers** from what it answers: an assign or a submission from its job, a review from its round, a merge from its round. So a late review of build 1, arriving after build 2, still carries iteration 1. It isn't counted "so far".

**Limits:**
- `fix_round` counts within one loop. An iteration with two loops (a decline sent back, or a second fix choice) has two "fix round 1"s, told apart by their fix choice.
- **The core gate's own answer** (`gate.answered`) carries neither number: its body is the core gate's own fields. The view gives it the iteration of the event its subject names.
- **The core's optional envelope `iteration` field** is then written by nothing. It is noted for removal from the core.
- **The grouping key:** the iteration is the build's ordinal on its tree, computed in the same function as the chain's root, so the two can never disagree.

**Readers:**
- the cards ("iteration 2, fix round 2 of 3");
- the cap check;
- the timeline;
- the human, in the events and in `git log`.

## 8. What I'll show you when it's built

For each case below I'll run the real scripts and show you three things: the report, the event, and the commit. For a refusal, you get the lines instead.
1. A clean build (iteration 1), then a second build on the same tree (iteration 2).
2. A build with a known failure.
3. A blocked build (no commit).
4. A refused report, and the second refusal ending the job.
5. A build-fix with done, partly and declined: `build-fix.submitted` with its iteration and fix round 1, and the commit's trailers.
6. A fix that declines a finding you sent back: refused, then a `cannot` blocker.
7. A report changed after submission: refused by the view, with the line you'd see.
8. A working commit whose event is missing: recovered from its `Job` trailer.

## 9. Settled for the builder

- `job` and `agent` go in the event's body; the core writer stays unaware of jobs.
- **A build-fix submits `build-fix.submitted`** (Fable approved). Every reader that took `build.submitted` to mean "the tree changed" takes both types:
  - the round's base..head;
  - the busy tree;
  - recovery by the `Job` trailer, where a `crucible(build-fix)` commit recovers as a `build-fix.submitted`.

  An iteration runs between two `build.submitted` events; a fix doesn't start one.
- The `Job` trailer is the seq, then the readable name.
- No event-writer rule in the builder's slice needs an extract of the report. If a later rule (review, merge) checks a new event against an earlier submission under the lock, it reads the joined view there. Each case is named in its own slice.
