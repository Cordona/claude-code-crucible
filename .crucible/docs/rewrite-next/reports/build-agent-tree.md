# The build agent's submission: the agreed tree

By Dev Beta, for the owner. Fable's tree (`tree-fable.md`) with the owner's changes, which Fable approved: one submission file and one validation script per kind. This is what gets built for `build-agent.md`. It waits for the owner's go.

```text
new-rewrite/
├── framework/core/
│   ├── install/
│   │   └── install-entries.sh                    CHANGED:
│   │                                             · components are the folders directly in a
│   │                                               main-thread/ or an agents/ folder, linked the same way;
│   │                                             · hooks/subagent-stop is mapped to SubagentStop;
│   │                                             · two components with one name are refused
│   └── main-thread/crucible-events/              UNCHANGED: the event writer; its lib/sha256.sh is
│                                                 reused for the pin
│
└── domains/software-development/core/
    ├── main-thread/
    │   ├── agent-jobs/                           NEW: jobs, which main dispatches and reads
    │   │   ├── events/
    │   │   │   ├── job.dispatched.jq             only what this build reads: kind, tree, report path,
    │   │   │   │                                 chosen findings, known failures, iteration, fix round, setup
    │   │   │   └── job.ended.jq                  reason gave-up for now (cancelled, died later)
    │   │   └── scripts/
    │   │       ├── main/                         empty until the dispatch talk
    │   │       ├── internal/
    │   │       │   ├── job-of.sh                 the one reader of job.dispatched (by job seq or agent id)
    │   │       │   └── events-view.sh            events joined to their pinned reports; refuses a changed report
    │   │       └── lib/
    │   │           ├── iteration.jq              counts the iteration (a build's dispatch) and the fix round
    │   │           │                             (a fix's dispatch), once
    │   │           └── pinned-report.jq          the join and the hash check
    │   ├── git-commit/                           UNCHANGED: makes the working commit
    │   └── …                                     the other existing components
    │
    └── agents/                                   NEW, beside main-thread/: what agents run
        ├── agent-submission/                     handing in an agent's work; knows no agent kind
        │   ├── hooks/
        │   │   ├── matchers.json
        │   │   └── subagent-stop/
        │   │       ├── submit-agent-work.sh      the wrapper: runs the steps in order, holds or lets through
        │   │       └── submit-agent-work/        its steps:
        │   │           ├── report-validation.sh  calls <kind>-report-validation.sh of the stopping agent
        │   │           ├── report-pin.sh         hash and read-only
        │   │           ├── working-commit.sh     through git-commit, with the trailers
        │   │           ├── submission-event.sh   writes the event that <kind>-submission.json names
        │   │           └── held-stop.sh          counts held stops; on the second, job.ended (gave-up)
        │   └── scripts/
        │       ├── internal/
        │       │   └── recover-submission.sh     a working commit with no event: rebuilt from its Job trailer
        │       └── lib/
        │           └── trailers.sh               reads the Job, Iteration and Fix-Round trailers
        │
        └── code-builder/                         the build agent and its contract
            ├── code-builder.md                   LATER: the agent's prose
            ├── build-submission.json             {"event": "build.submitted", "commit": true}
            ├── build-fix-submission.json         {"event": "build-fix.submitted", "commit": true}
            ├── events/
            │   ├── build.submitted.jq
            │   └── build-fix.submitted.jq
            └── scripts/
                ├── internal/
                │   ├── build-report-validation.sh
                │   └── build-fix-report-validation.sh
                └── lib/
                    ├── report-validation.sh      shared shell, sourced by both: read the file, prune
                    │                             empties, check locations against the tree, print repair lines
                    ├── build-report.jq           the build rules (build-agent.md §4)
                    └── build-fix-report.jq       includes build-report.jq, adds the fixes rules, and
                                                  replaces the unchanged-tree rule (not a second copy)
```

## The convention the submission hook follows

**For a job of kind K, run by agent type A**, the component named A holds two files:
- `K-submission.json`: the event to write, and whether to commit;
- `scripts/internal/K-report-validation.sh`: the report check.

A missing file is one clear refusal naming what was looked for, never a silent pass. For example: `code-builder has no build-fix-submission.json`.

A tester is added by adding a `code-tester/` folder with `test-submission.json` and `test-report-validation.sh`. Nothing in `agent-submission` changes.

## The proof

```text
.crucible/docs/rewrite-next/evidence/build-agent/
├── run.sh            a scratch repo, effort and config folder; jobs written from a fixture
│                     through the real event writer; every case run through the real hook
├── fixtures/         the job.dispatched events, and which agent has which job
└── <case>/           report.json · hook-output.txt · event.json · commit.txt
```

The cases are `build-agent.md` §8. Everything runs against a scratch config folder, never `~/.claude`.
