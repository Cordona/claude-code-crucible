# The review agent: its reports, their checks, the stop hook and the events

By Dev Beta, for the owner. This covers only the review agent (`code-reviewer`), the way `build-agent.md` and `test-agent.md` cover the builder and the tester. Draft 2: checked by the five PS workers (`worker-*-reviewer.md`) and Fable (`review-agent-fable.md`), with the owner's decisions applied. Nothing is built.

**Grounded in:**
- `report-schemas.md` §0 and §4–8;
- `decisions.md`;
- `event-timeline.md` (its `pr.*` and `round.made` names are stale);
- the job model (no seats; reviewers have no tree of their own; hot or fresh is main's choice);
- `agents-tree-proposal.md` v3 (agents share plumbing only).

Reports stay generic.

The reviewer does four kinds of job:

| Job kind | What the reviewer does | It ends with | Commit |
|---|---|---|---|
| `review` | reviews our change through one lens: cold, hot, or a re-review | `review.submitted` | never |
| `test-plan-challenge` | challenges a draft test plan once, before the human sees it | `test-plan.challenged` | never |
| `external-review` | judges each thread someone else left on our MR | `external-review.submitted` | never |
| `foreign-review` | reviews someone else's MR; we comment, never fix | `foreign-review.submitted` | never |

**Hot, cold and re-review are not kinds.**
- **Hot or cold** is main's choice of agent: resume the one that already read the change, or start a fresh one for an unbiased eye. The report is the same.
- **A re-review** is a `review` job that carries earlier findings and the fixer's `fixes`. Its report gives its own status for each fix.

**Reused from the builder and the tester, unchanged:**
- the stop hook (validate, stamp, pin, event, held stops);
- the slim event body, pinned by hash;
- the report folders `reports/<kind>/<seq>.json`.

The working-commit step is skipped: every reviewer submission file says `commit: false`.

## 1. Where the reviewer sits in the flow

```text
build.submitted / build-fix.submitted / test.submitted / test-fix.submitted
  → [offer] review it (or [owed]: the re-review after a fix)
  → review-round.opened         (the review loop's spec)
  → review job ×n, one per lens → review.submitted ×n
  → [owed] the merge            (the review loop's spec)

test-plan.submitted
  → [owed] the challenge
  → test-plan-challenge job     → test-plan.challenged
  → [owed] the rework           (a test-plan-update job carrying the challenges)

external-review.received        (our MR got threads; the remote's spec)
  → [offer] triage it
  → external-review job         → external-review.submitted
  → the valid items' findings go to the fix choice; the replies go to the replies gate

a foreign MR, fetched into a tree of its own
  → [offer] review it
  → foreign-review job ×n       → foreign-review.submitted ×n
  → the comments gate; no fix loop
```

**The reviewer has no tree of its own.**
- It reads the tree its job names: the builder's or tester's tree for our work, or the foreign MR's tree.
- It changes nothing there. The stop check refuses a report if the reviewer left changes in the tree. Files the project's ignore rules leave out don't count.

**Report files**, for example:
- `reports/review/41.json`;
- `reports/test-plan-challenge/23.json`;
- `reports/external-review/60.json`;
- `reports/foreign-review/72.json`.

## 2. The review report (kind `review`)

This is `report-schemas.md` §5, unchanged in shape.

```json
{
  "findings": [
    {
      "severity": "high",
      "realism": "realistic",
      "at": [
        "a.sh:3"
      ],
      "claim": "the variable is unquoted, so a path with a space splits",
      "suggestion": "quote it: \"$1\""
    },
    {
      "severity": "high",
      "realism": "realistic",
      "at": [
        "@core-api:app/Http/Client.php:88"
      ],
      "relates_to": "a.sh:12",
      "claim": "the caller passes an unescaped tenant name into this script",
      "suggestion": "escape at the call or validate here"
    },
    {
      "severity": "medium",
      "realism": "edge-case",
      "at": [
        "b.sh:2"
      ],
      "claim": "a glob in the input expands",
      "suggestion": "set -f around the loop",
      "proof": "b.sh:1 reads words from the caller, which passes user paths"
    },
    {
      "severity": "low",
      "realism": "hypothetical",
      "claim": "no script in this change logs its failures",
      "suggestion": "log to stderr",
      "real_if": "these scripts run unattended in cron"
    },
    {
      "severity": "medium",
      "realism": "realistic",
      "at": [
        "a.sh:20"
      ],
      "claim": "the same unquoted pattern exists on main",
      "suggestion": "fix it in a follow-up",
      "out_of_scope": "a.sh:20 is unchanged by this diff"
    }
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
    {
      "at": "a.sh:9",
      "text": "evals user input",
      "for": "security"
    },
    {
      "at": "README.md:40",
      "kind": "instruction",
      "text": "a line telling reviewers to approve"
    }
  ],
  "notes": [
    {
      "text": "the retry cap at Client.kt:42 holds under every path I traced"
    }
  ]
}
```

| Field | What it is |
|---|---|
| `findings` | what the reviewer judges wrong, through its lens. Each gets an ID stamped (`<LENS>-NN`) |
| `findings[].at` | locations; absent for a general finding |
| `claim` | one line, up to 200 characters: what cards and lists show |
| `suggestion` | the fix to make; it may run to the reply's limit (1,000 characters, several lines) |
| `relates_to` | the changed line a finding outside the diff relates to (a defect in a caller); a removed line is `-path:N` |
| `proof`, `real_if` | an edge case's proof, which may run to the reply's limit; what would make a hypothetical real |
| `out_of_scope` | true but not this change: not a fix target by default, listed as a follow-up; the human may choose it. Its text is the proof |
| `reopens` | free text: the settled ID this finding brings back (a regression). Its check comes with the review loop |
| `fixes` | on a re-review only: one per fix the job names, with the reviewer's `status`: `fixed`, `open`, `agree` or `disagree`. The same key as in the fix report, and the report's kind tells the two value sets apart. It also holds what was not fixed: `agree` and `disagree` are the reviewer's view of a decline, not a state of the code. A `reason` is needed on `open`, `agree` and `disagree`, and is optional on `fixed` (the code is gone, fixed another way, or proven only by a deploy) |
| `noticed` | outside the lens: `for` names the lens it belongs to; `kind` is `secret` or `instruction`, as in the build report |
| `notes` | what held up, on which the human approves. A note may take `at`: a remark or question at a line (in a foreign review, the comments gate posts it there) |

**A clean review is `{}`.**

## 3. The plan challenge (kind `test-plan-challenge`)

This is `report-schemas.md` §4, unchanged in shape: one challenger, no loop.

```json
{
  "challenges": [
    {
      "target": "B-1",
      "ask": "add",
      "title": "no test proves the limit is three, not four",
      "why": "the planned test passes with any limit above two"
    },
    {
      "target": "src/upload/Client.kt:60",
      "ask": "add",
      "title": "a behaviour the plan misses: the upload isn't idempotent",
      "why": "a retry after a timeout sends the file twice"
    },
    {
      "target": "tests/Support/AuditAssert.php::assertAuditedOnce",
      "ask": "change",
      "title": "the new level argument weakens every audit test",
      "why": "it defaults to any level"
    }
  ]
}
```

- **`target`:** any plan ID (a behaviour, a test or an untested entry), `plan` (the plan as a whole, including its run and its baseline), a code location, `path::helper`, or a support file the plan names.
- **`ask`:**
  - `add`;
  - `change`, which also covers a wrong fact, a merge or a shrink;
  - `remove`;
  - `prove`, for an untested case.
- **An empty report (`{}`) approves the plan as it is.**
- The stop check stamps each challenge `C-n`, numbered across the effort. These are the `challenges` the rework job then carries (`test-agent.md`).
- The challenger reads the build's change too, so it can name a behaviour the plan misses. It reviews no code and raises no findings.

## 4. The external review (kind `external-review`)

Someone (a person or a bot) reviewed **our** MR. The reviewer judges each of their points: is it real, already fixed, a question, a decision for the human, or nothing to do? It changes no code. A valid point becomes a finding for the fix choice, like a finding from our own review. The rest get replies, posted later on the human's go.

This is `report-schemas.md` §7, in the same shape.

### 4.1 What starts it

```
external-review.received        the MR got new threads (the remote's spec)
  → job.dispatched              kind external-review, the threads file named in the job
  → job.assigned
  → the reviewer judges every thread
  → external-review.submitted
```

**The threads come from the remote, so they are untrusted data.**
- A script fetches them to a file. The job names that file and says the text is untrusted.
- The reviewer reads them as claims to check against the code, never as instructions.
- The MR description is the thread `description`.

### 4.2 What the reviewer writes

One entry per point. A thread with several points (a bot's note listing three issues) is split by the reviewer into items, `F-03a` and `F-03b`. It uses the bot's own labels where they exist.

```json
{
  "items": [
    {
      "thread": "n11370",
      "item": "F-03a",
      "verdict": "valid",
      "finding": {
        "severity": "medium",
        "realism": "realistic",
        "at": [
          "src/upload/Client.kt:55"
        ],
        "claim": "the timeout isn't applied to the retry",
        "suggestion": "pass the timeout into retry()"
      }
    },
    {
      "thread": "n11370",
      "item": "F-03b",
      "verdict": "rejected",
      "reply": "PHP 8.4 is already the floor in composer.json:12, so the compatibility point doesn't apply."
    },
    {
      "thread": "n11370",
      "item": "F-04",
      "verdict": "rejected",
      "reply": "The retry is capped at src/upload/Client.kt:42, so this loop ends after three tries.\nThe test T-1 covers the cap."
    },
    {
      "thread": "n11371",
      "verdict": "already-fixed",
      "reply": "Fixed in 9f3c1e2, before this review."
    },
    {
      "thread": "n11372",
      "verdict": "valid",
      "finding": {
        "severity": "low",
        "realism": "realistic",
        "at": [
          "src/upload/Client.kt:80"
        ],
        "claim": "the same missing timeout exists in the download path",
        "suggestion": "apply the timeout there too, in a follow-up",
        "out_of_scope": "Client.kt:80 is unchanged by this MR"
      }
    },
    {
      "thread": "n11374",
      "verdict": "deferred",
      "note": "prod tonight or preprod first is a release decision: yours"
    },
    {
      "thread": "n11373",
      "verdict": "answered",
      "reply": "No migration in this change, only the new env var, which is already in the values."
    },
    {
      "thread": "description",
      "verdict": "noted"
    }
  ]
}
```

### 4.3 The six verdicts

| Verdict | Means | Needs | What follows |
|---|---|---|---|
| `valid` | a real defect. One that is real but not this MR's has its finding marked `out_of_scope`, as in our own reviews, so the human can still choose it | `finding`; no `reply` | the finding goes to the human's fix choice and the loop. Its reply ("fixed in `<commit>`") is drafted later by a script, from the fix |
| `rejected` | not a defect, with the proof | `reply` | posted after the replies gate |
| `already-fixed` | fixed before this review | `reply`, naming the commit | posted after the replies gate |
| `deferred` | a decision only the human can make (release timing, scope, the MR's description) | `reply` (a proposal) or `note` (what the decision is) | the human decides at the replies gate |
| `answered` | a question or a request, answered | `reply` | posted after the replies gate |
| `noted` | praise, a check that passed, or nothing to do | nothing; a `reply` is optional | its reply, if any, posted after the replies gate |

**The rules:**
- every thread in the job is judged at least once;
- each point in a thread is judged once, under its own `item` label;
- two defects in one point are split into two items;
- only `valid` has a `finding`, and every `valid` has one;
- `rejected`, `already-fixed` and `answered` need a `reply`. `deferred` needs a `reply` or a `note`. `noted` may take one. `valid` takes none;
- a valid finding names no lens: it takes the job's lens (§15, item 6);
- a `reply`, a `suggestion` and a `proof` may be up to 1,000 characters over several lines. Every other text is one line of up to 200 characters.

### 4.4 What the stop check fills in

The reviewer never writes these; the stop check stamps them before the pin.

```json
{
  "items": [
    {
      "thread": "n11370",
      "item": "F-03a",
      "source": "bot",
      "verdict": "valid",
      "finding": {
        "id": "SECURITY-04",
        "severity": "medium",
        "realism": "realistic",
        "at": [
          "src/upload/Client.kt:55"
        ],
        "claim": "the timeout isn't applied to the retry",
        "suggestion": "pass the timeout into retry()"
      }
    },
    {
      "thread": "n11373",
      "source": "human",
      "verdict": "answered",
      "reply": "No migration in this change, only the new env var, which is already in the values."
    }
  ]
}
```

| Stamp | From |
|---|---|
| `source`: `human` or `bot` | the fetched threads file |
| `finding.id` on each valid item | the job's lens and the iteration's IDs so far (§8) |

The cards and the replies gate show human threads first.

### 4.5 What refuses it

| Problem | Repair line |
|---|---|
| A thread left unjudged | `judge thread n11373: valid, rejected, already-fixed, deferred, answered or noted` |
| A thread that isn't in the job | `thread n99 is not one of this job's threads` |
| A bad `verdict` | `items[2].verdict "wontfix" is not valid, rejected, already-fixed, deferred, answered or noted` |
| `valid` without a `finding` | `items[0] is valid: add its finding` |
| A `finding` on another verdict | `items[3] is rejected: remove its finding` |
| A missing `reply` (or, on `deferred`, a `note`) | `items[1] is rejected: add the reply to post` |
| A `reply` on `valid` | `items[0] is valid: remove its reply; it's drafted from the fix` |
| The same `item` label twice in one thread | `thread n11370 has item F-03a twice: give each point its own label` |
| A stamped key written by the agent (`source`, `id`) | `remove "source": this is filled in for you` |
| Changes left in the tree | the shared line for every reviewer kind (§6) |

### 4.6 The commit, the event and the report folder

- **No working commit:** a reviewer never changes the tree (§7).
- **The report goes to** `reports/external-review/<seq>.json`.
- **The event is `external-review.submitted`.** Its body is the slim one, the same as every other agent's: `job`, `iteration`, `agent` (the agent's id) and `report {path, sha256}`. The verdicts and replies are in the report, not the event (§15, item 1).

```json
{
  "type": "external-review.submitted",
  "seq": 61,
  "by": "submission-event.sh",
  "body": {
    "job": 60,
    "iteration": 2,
    "agent": "7d03be…",
    "report": {
      "path": "reports/external-review/60.json",
      "sha256": "4be1…"
    }
  }
}
```

### 4.7 After it is submitted (not this slice)

**There are two reply offers:**
1. after the triage: the replies that are ready (rejected, already-fixed, answered and deferred);
2. after the fix has landed: the replies to the valid items, drafted from the fix and edited by the human.

The human posts each set on their own, or both together. Posting is main's step behind the replies gate, never the reviewer's. It belongs to the review loop's spec, like the fix choice for valid findings.

## 5. The foreign review (kind `foreign-review`)

**It is the review report of §2, minus `fixes`.** The same `findings`, `noticed` and `notes`, under the same rules. It differs in three places:
- **No `fixes`:** nothing of ours was fixed.
- **No iteration:** it isn't our build. Its finding IDs are numbered per foreign-review job (§8).
- **Its next step is comments, not a fix:** main drafts comments from the report, the human edits and approves them at the comments gate, and a remote script posts them. A note with an `at` is posted at that line. `claim` and `suggestion` are written for the MR's author, since here the comment is the product.

It is a kind of its own, with its own event, only because of that next step: main must know at once that this report goes to comments, not to the merge and the fix loop. Its rules are not written twice: `foreign-review-report.jq` builds on the reviewer's own common lib, like `review-report.jq` (§10).

## 6. The validation: what refuses a report

Each rule refuses with one line the reviewer can act on alone.

**Every kind** (the reviewer's own common rules):

| Rule | The repair line it gets |
|---|---|
| The file is missing or isn't one JSON object | `write your report as one JSON object to <path>` |
| A key only a script fills in (`id`, `kind`, `lens`, `source`, …) | `remove "id": this is filled in for you` |
| An unknown key | `unknown key "verdict"; the keys are findings, fixes, noticed, notes` (the keys of the job's kind) |
| Text over 200 characters, more than one line, or blank (a `reply`, `suggestion` or `proof` may be up to 1,000 characters, over several lines) | `findings[0].claim is 240 characters; shorten it to 200` |
| An `at` in the tree that doesn't exist at the job's head (`-path:N` is read at the base) | `findings[1].at b.sh:90 is past the end of the file (40 lines)` |
| The reviewer left changes in the tree (the project's ignore rules apply) | `you changed files: undo your changes; a reviewer changes nothing` |

**Review and foreign review:**

| Rule | The repair line it gets |
|---|---|
| A bad `severity` or `realism` | `findings[0].severity "major" is not critical, high, medium or low` |
| An `edge-case` with no `proof` | `findings[2] is an edge-case: add proof, the line that makes it reachable` |
| A `hypothetical` with no `real_if` | `findings[3] is hypothetical: add real_if, what would make it real` |
| An `at` outside the job's cover, with no `relates_to` or `out_of_scope` | `findings[1].at x.sh:3 is outside this change: add relates_to, the changed line it relates to, or out_of_scope with its proof` |
| `relates_to` that isn't a changed line (a removed line is `-path:N`) | `findings[1].relates_to a.sh:2 is not a line this change touches` |
| A bad `noticed[].kind` | `noticed[1].kind "leak" is not secret or instruction` |

**Review only, on a re-review:**

| Rule | The repair line it gets |
|---|---|
| A fix with no status | `give SHELL-01 a status: fixed or open (the fixer said done)` |
| A status for an ID that isn't in the job | `SHELL-09 is not one of this job's earlier findings` |
| The wrong status for the fixer's status | `SECURITY-01 was declined: give agree or disagree, with a reason` |
| A reason missing on `open`, `agree` or `disagree` (optional on `fixed`) | `fixes[1] is open: add a reason` |

**Plan challenge:**

| Rule | The repair line it gets |
|---|---|
| A target that doesn't exist | `challenges[0].target B-9 is not an ID in the plan; name a plan ID, plan, a code location or a file the plan names` |
| A bad `ask` | `challenges[1].ask "fix" is not add, change, remove or prove` |
| `title` or `why` missing | `challenges[2] needs why: what the plan gets wrong` |
| An internal ID in `title` or `why` | `challenges[0].title names B-1: say it in words, the target names the ID` |

**External review:**

| Rule | The repair line it gets |
|---|---|
| A thread with no verdict | `judge thread n11373: valid, rejected, already-fixed, deferred, answered or noted` |
| A thread that isn't in the job | `thread n99 is not one of this job's threads` |
| A bad `verdict` | `items[2].verdict "wontfix" is not valid, rejected, already-fixed, deferred, answered or noted` |
| `valid` without a `finding`, or a `finding` on another verdict | `items[0] is valid: add its finding` / `items[3] is rejected: remove its finding` |
| A missing `reply` (or, on `deferred`, a `note`) | `items[1] is rejected: add the reply to post` |
| A `reply` on `valid` | `items[0] is valid: remove its reply; it's drafted from the fix` |
| The same `item` label twice in one thread | `thread n11370 has item F-03a twice: give each point its own label` |

The stop check prunes empty lists first. A second held stop ends the job as `gave-up`.

## 7. No working commit

Every reviewer submission file says `commit: false`, so the plumbing makes no commit. That's what makes a reviewer read-only. The tree check in §6 makes sure the reviewer left no changes in the tree.

## 8. The stamps

The builder and the tester stamp nothing. The reviewer does, before the pin:

| Kind | Stamped | From |
|---|---|---|
| `review` | each finding's `id`: `<LENS>-NN`, unique in the iteration; numbering starts again when a new iteration starts | the job's lens; the iteration's IDs so far |
| `foreign-review` | each finding's `id`: `<LENS>-NN`, unique in the job (a foreign review has no iteration) | the job's lens |
| `test-plan-challenge` | each challenge's `C-n`, numbered across the effort | the effort's keys so far |
| `external-review` | each thread's `source` (`human` or `bot`); each valid finding's `id` | the fetched threads; the job's lens and the iteration's IDs so far |

These are the reviewer's own rules. Under the owner's rule they live in `code-reviewer`, and the plumbing only runs them (§12).

**Parallel reviewers of one lens get unique IDs.** The stop hook takes its own lock, one per effort, from the stamp to the event. Two reviewers stopping at the same moment take turns, so they can't both take `SECURITY-03`. The lock is plumbing: it names no agent, and it isn't the core's events lock. It also closes the lost event the lab saw when two agents stopped at once.

## 9. The events

All four share the slim body and field order: `job`, `iteration`, `fix_round` (inside a fix loop only), `agent`, `report`. None has `commit`.

**`review.submitted`:**

```json
{
  "type": "review.submitted",
  "seq": 42,
  "by": "submission-event.sh",
  "body": {
    "job": 41,
    "iteration": 2,
    "fix_round": 1,
    "agent": "5c21aa…",
    "report": {
      "path": "reports/review/41.json",
      "sha256": "…"
    }
  }
}
```

**`test-plan.challenged`, `external-review.submitted` and `foreign-review.submitted`:** the same body, each with its own job and report path.
- A `foreign-review.submitted` carries no `iteration` (§15, item 4).

**Everything else is read from the pinned report,** through the event view:
- the findings, their severity and realism;
- the fixes, and the routed `noticed`;
- the security count;
- the challenges, the verdicts and the replies.

`report-schemas.md` put those lists in the event bodies. The slim body (`build-agent.md` §1: the report is the one source) replaces that, for every agent alike (§15, item 1).

## 10. Nothing shared with the other agents

```
agents/code-reviewer/                    THE REVIEWER: everything of its own
├── submissions/
│   ├── review.json                      kind review              → event review.submitted
│   ├── test-plan-challenge.json         kind test-plan-challenge → event test-plan.challenged
│   ├── external-review.json             kind external-review     → event external-review.submitted
│   └── foreign-review.json              kind foreign-review      → event foreign-review.submitted
├── events/
│   ├── review.submitted.jq
│   ├── test-plan.challenged.jq
│   ├── external-review.submitted.jq
│   └── foreign-review.submitted.jq
└── scripts/
    ├── internal/
    │   └── reviewer-facts.sh            reads events and git only: the cover, the effort's IDs and
    │                                    keys, the earlier findings and fixes, the plan, the threads
    └── lib/
        ├── reviewer-common.jq           the reviewer's own ground: keys, text, locations, the tree check
        ├── review-report.jq             a review: common + findings + fixes
        ├── foreign-review-report.jq     a foreign review: common + findings, no fixes
        ├── test-plan-challenge-report.jq
        ├── external-review-report.jq
        └── reviewer-stamps.jq           §8
```

- `review-report.jq` and `foreign-review-report.jq` share the reviewer's own findings rules, inside one agent.
- The reviewer reads the plan, the fixer's `fixes` and the threads only through events and pinned reports, never through another agent's files.
- **Watch `reviewer-facts.sh` (Fable):** if it grows a branch per kind, split it by kind.

## 11. What I'll show you when it's built

For each case I'll run the real scripts and show you the report and its event, or the lines of a refusal. There is no commit in any case.
1. A cold review with five findings (one each: realistic, outside the diff with `relates_to`, edge-case, hypothetical, out of scope): `review.submitted`, with the IDs stamped.
2. A clean review, `{}`: `review.submitted`.
3. A refused review: an edge-case with no proof, an `at` outside the cover, a 240-character claim.
4. A reviewer that left changes in the tree: refused. An ignored file doesn't count.
5. A re-review after a build-fix: `fixed` without a reason, `open` with a reason, and `agree` on a decline. Its `fix_round` is the fix's.
6. A re-review missing a fix's status, and one giving a declined ID with `fixed`: refused.
7. A plan challenge with three challenges: `test-plan.challenged` with `C-1` to `C-3`, which a test-plan-update job can then carry.
8. An empty challenge, `{}`: the plan is approved as it is.
9. An external review with all six verdicts, a valid finding marked `out_of_scope`, and a `noted` with a reply: `external-review.submitted`, with the sources and the valid findings' IDs stamped from the job's lens.
10. An external review missing a thread, or with a reply on `valid`: refused.
11. A foreign review with a note at a line: `foreign-review.submitted`, with no iteration and its IDs numbered in the job. The same report with `fixes`: refused.
12. A finding ID unique across two reviews of the same lens in one iteration, even when both stop at the same moment, and numbered from 01 again in the next iteration.

Then one live run with a real reviewer, as for the builder and the tester: a cold review of the sandbox's build, then a re-review after its build-fix.

## 12. Also to do when building

**The plumbing, still agent-blind:**
- **A stamp step that runs the agent's own stamps,** named in the submissions file (`stamps: {rules, def}`, optional). Today the step stamps nothing.
- **The location forms the contract names:** `path`, `path:N`, `path:N-M`, `-path:N` read at the job's base, `@<where>:…`, and `at` as a string or a list.
- **The tree check for `commit: false` jobs:** the tree has no changes, by the project's ignore rules.
- **The stop hook's own lock,** one per effort, from the stamp to the event (§8).

**agent-jobs:** the fields a review job carries, which the dispatch talk decides:
- `lens`;
- `base` and `head`;
- `cover`;
- `earlier`, the earlier findings with the fixer's `fixes`. A re-review carries them under `earlier`, never `findings`: a fix job is told apart by carrying the findings the human chose;
- `plan`, for the challenge;
- `threads`, the path of the fetched threads;
- `foreign`, the MR named for a foreign review.

## 13. Answered by the design

The workers raised these, and the spec already answers them (Fable):

| Case | The answer already there |
|---|---|
| The same point in two threads | judge the repeat `answered`, with a reply saying it is handled under the other label. One finding, no new field |
| A location in an installed dependency | `@vendor:path:N`. The `@<where>` form isn't checked for existence |
| A fix that broke something else | a new finding; its `claim` says which fix it came from |
| The same defect back in a later iteration | a new finding that says so in words. `reopens` is for IDs of the same iteration |
| A valid point about the MR's description | not a code defect: `deferred` with a note. Editing the description is main's step |
| A rejected point that hides a different real defect | two items |
| A fix only checkable by a deploy or in CI | `fixed`, with the reason naming the check |
| Replies in the reviewer's own language | free text |

## 14. Belongs to other specs

| Spec | What |
|---|---|
| **The review loop** | `review-round.opened`; the merge and the round's result; the review gate's lens choice; the end card; the answer to a routed `noticed`; turning findings into fix targets; a re-review's iteration and `fix_round`, copied from its round; a drafted reply for a valid item the human didn't choose; an `out_of_scope` security finding shown in full; the iteration shown beside an ID when a card spans two; the arbiter's offer |
| **The remote** | `external-review.received` and the threads file: the SHA the review was made at and each thread's original line, our own notes left out of a new fetch, a re-posted point shown with its earlier verdict, a follow-up in an answered thread as a new item, comments the human relays by hand, and a new fetch as a new file, never an edit. Also: the replies gate and the comments gate; posting; the commit a reply names is the pushed or landed one, never a working commit; inline comments only on the MR's diff, the rest as general notes; severity words not posted as they are; whether posting resolves a thread; a push resetting the approval |
| **The dispatch talk** | the job's fields (§12: the lens, the cover, the earlier findings, the plan, the threads); hot or fresh; the plugins per lens; "an agent never reviews its own commit"; mapping a moved line is the lens's prose |
| **Each lens's prose** | what to look for, including the tester's leftovers: whether `keeps` held, goldens that mirror the code, a shared helper's reach, and judging the breaks tried |

## 15. Decided

The questions the draft left open, settled by the owner with Fable's view:

1. **Event bodies: slim,** as for the builder and the tester. The report is the one source; `report-schemas.md` is updated to match.
2. **Kind names:** `test-plan-challenge` and `foreign-review` are kinds of their own.
3. **The external review's event:** `external-review.submitted`. One kind, one event.
4. **The foreign review has no iteration.** agent-jobs learns that "no build on this tree" means none.
5. **A re-review's `fix_round`:** the review loop's spec, copied from its round. A re-review carries its earlier findings as `earlier`, never `findings`.
6. **A valid external finding takes the job's lens.** There's no lens field: no failure stands behind one yet (the owner, against Fable's `for:` suggestion). Add one when a real run needs it.
7. **The stamp step is plumbing.** It runs only the agent's own named rules, before the pin, the same as the check step.
8. **`test-plan.challenged` stays,** owned by the reviewer.
9. **The arbiter is a separate agent,** specified later, after the review loop.
10. **One `code-reviewer` agent type,** with the lens chosen per job.
11. **Finding IDs reset when a new iteration starts.** The key is iteration + ID. A foreign review's IDs are numbered per job.
12. **Parallel reviewers of one lens:** the stop hook's own per-effort lock, from the stamp to the event (§8).
13. **Findings into fix targets:** the review loop's spec.
14. **A real point that isn't this MR's** is `valid`, with its finding marked `out_of_scope`. `deferred` means only "the human decides".
15. **The tree check is one rule:** "you changed files: undo your changes". There's no check that the tip moved, since the loop never runs a fix during a review.
