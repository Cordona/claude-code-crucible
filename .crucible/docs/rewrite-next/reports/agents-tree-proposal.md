# The agents tree, version 3: agents share plumbing only (Fable's v2 answers applied)

By Dev Beta, for the owner and the Fable Reviwer. Talking only.

## The owner's rule

> "We are coupling agents through shared stuff, and this is purely wrong. We are reintroducing coupling and spaghetti."

- **Shared is plumbing only:** steps that never read what a report or an event says, and that work the same for any agent.
- **Each agent owns all the rules for its own reports and events, even when that means copies.**
- Agents talk only through events, never through each other's files.

## Proposed tree

```
agents/
├── agent-submission/                    PLUMBING: shared, reads no report's content
│   ├── hooks/
│   │   ├── matchers.json
│   │   └── subagent-stop/
│   │       ├── submit-agent-work.sh     the wrapper: runs the steps in order
│   │       ├── report-validation.sh     runs the agent's rules, named by its submissions file
│   │       ├── report-pin.sh            hash and read-only
│   │       ├── working-commit.sh
│   │       ├── submission-event.sh      writes the event its submissions file names
│   │       └── held-stop.sh             refusal count, gave-up
│   └── scripts/
│       ├── internal/
│       │   ├── report-check.sh          runs one rules module on one report
│       │   └── recover-submission.sh
│       └── lib/
│           ├── stamps.jq                the fields a script fills in, never the agent
│           └── trailers.sh              the commit trailers
│
├── code-builder/                        THE BUILDER: everything of its own
│   ├── submissions/
│   │   ├── build.json                   kind build     → event build.submitted
│   │   └── build-fix.json               kind build-fix → event build-fix.submitted
│   ├── events/
│   │   ├── build.submitted.jq
│   │   └── build-fix.submitted.jq
│   └── scripts/
│       └── lib/
│           ├── builder-common.jq        the builder's own shared ground (keys, gates, at, blockers)
│           ├── build-report.jq          a build report: common
│           └── build-fix-report.jq      a build-fix report: build + the fix answers
│
└── code-tester/                         THE TESTER: everything of its own
    ├── submissions/
    │   ├── test-plan.json               kind test-plan        → event test-plan.submitted
    │   ├── test-plan-update.json        kind test-plan-update → event test-plan.updated
    │   ├── test.json                    kind test             → event test.submitted
    │   └── test-fix.json                kind test-fix         → event test-fix.submitted
    ├── events/
    │   ├── test-plan.submitted.jq
    │   ├── test-plan.updated.jq
    │   ├── test.submitted.jq
    │   └── test-fix.submitted.jq
    └── scripts/
        ├── internal/
        │   └── tester-facts.sh          reads events and git only, never the builder's files
        └── lib/
            ├── tester-common.jq         the tester's own shared ground (keys, gates, at, blockers)
            ├── test-plan-report.jq      a plan: common
            ├── test-plan-update-report.jq  a plan update: plan + the answers to challenges
            ├── test-report.jq           a test report: common
            └── test-fix-report.jq       a test-fix report: test + the fix answers
```

**Inside one agent there is one owner,** so its kinds share its own common lib. That's never shared with another agent: the shared ground exists twice, once per agent (Fable).

## The plumbing's contract (the only thing plumbing reads in a report)

The plumbing relies on three things in a report:
- **it is one JSON object;**
- **any `at` is a location** (`<file>:<line>`, or `@<where>:<file>:<line>`), which `report-check.sh` looks up before any rule runs;
- **if the job commits, the report has a `summary`,** which becomes the commit subject.

Everything else is the agent's. This contract is stated once: in `agent-submission`'s help, and in `report-schemas.md`.

**Cleanups:**
- `report-check.sh`'s help no longer names a shared rules module.
- `trailers.sh` and git-commit's help take whatever kind the job has, and no longer list kinds by name.

**The cost (Fable):** the report shapes in `report-schemas.md` §0 (text, locations, the gate shape) now live in each agent's copy, so they can drift. The cards and main's door rely on those shapes. The guard is the proofs: each reader's proof reads a real report from each agent.

## Read it like this

- **Who submits what?** Look in an agent's `submissions/` folder: one file per kind, naming its event.
- **What checks a report?** Look in `scripts/lib/<kind>-report.jq` in the same agent.
- **What is shared?** Only `agent-submission/`, and it holds no rules about any report.

## What changes from today

| Today | Version 2 |
|---|---|
| `agent-submission/…/work-report.jq`, shared rules plus the builder's | removed; its rules are copied into each agent's own report files |
| `agent-submission/…/fix-report.jq`, shared fix answers | removed; copied into `build-fix-report.jq` and `test-fix-report.jq` |
| `agent-submission/events/fix.submitted.jq` | removed; `build-fix.submitted.jq` in code-builder and `test-fix.submitted.jq` in code-tester |
| kind `fix` for both agents | kinds `build-fix` and `test-fix` |
| `<kind>-submission.json`, loose in the agent's root | `submissions/<kind>.json` |
| `test-plan.jq` for the plan and its update | `test-plan-report.jq` and `test-plan-update-report.jq` |

## Outside agents/ (agent-jobs, the job model on the main thread)

- **"Is this a fix?" is a fact in the job:** a fix is a job that carries the findings the human chose. No agent-jobs script names `build-fix` or `test-fix`.
- **The fix round** is still counted per kind.
- **Left for the dispatch talk:** `job.dispatched`'s list of fields a job may carry (findings, sent_back, plan, challenges, words). These are shapes only, but a new agent still means editing the list.
- **Reports** go to `reports/build-fix/<seq>.json` and `reports/test-fix/<seq>.json`.
- **Renames in `report-schemas.md`, `build-agent.md` and `test-agent.md`.**

The human's fix choice stays one event.

Behaviour stays the same. The proofs are re-run, and gain two checks:
- **No agent includes another agent's rules.** Naming another agent's event or kind stays allowed, as `tester-facts.sh` does.
- **Nothing in `agent-submission` or `agent-jobs` names an agent or one of its kinds,** except `build`, which opens an iteration in the job model.
