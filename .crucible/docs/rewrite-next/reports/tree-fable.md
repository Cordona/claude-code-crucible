# The build agent's tree: Fable's proposal (2026-11-24)

By Crucible Fable Reviwer, for the owner, on `tree-fable-brief.md`. Talking only; the owner's go is the only go.

**What I read:** the brief, `build-agent.md` v2, `build-agent-tree.md`, and in new-rewrite: the folder tree, `install-entries.sh`, `event-write.sh` with `beside.sh`, the internals guard, and the layouts of `crucible-gate`, `crucible-events`, `git-commit` and `git-worktree`. I ran nothing.

## In short

1. **An `agents/` folder beside `main-thread/`,** as the owner suggested. The split is by who runs a thing: main, or an agent's own stop.
2. **Everything goes in the software-development domain for now, the jobs too.** The framework core changes in one file only, the installer.
3. **The installed name is always the folder name.** So no `common`: each folder gets a name that still means something once installed.
4. **A hook's own steps sit in a folder named after that hook,** so every script directly in a hook-type folder is still a hook.
5. **One thing must be talked through first:** the shape of `job.dispatched`. The stop hook reads it, and the dispatch is the design the owner said needs a long talk.

## 1. The tree

`NEW` is added by this build, `CHANGED` is edited, `LATER` is named so the place is known but isn't built now.

```text
new-rewrite/
├── framework/core/
│   ├── install/
│   │   └── install-entries.sh                    CHANGED: also scans agents/ folders; maps subagent-stop;
│   │                                             refuses two components with one name (section 3)
│   └── main-thread/
│       └── crucible-events/                      unchanged; its lib/sha256.sh is reused for the pin
│
└── domains/software-development/core/
    │
    ├── main-thread/                              what main runs or loads
    │   ├── agent-jobs/                           NEW: a job, from its dispatch to its end
    │   │   ├── SKILL.md                          LATER, with the dispatch
    │   │   ├── events/
    │   │   │   ├── job.dispatched.jq             the rule for a job's start (its shape: section 5)
    │   │   │   ├── job.assigned.jq               LATER, with the dispatch
    │   │   │   └── job.ended.jq                  gave-up now; cancelled and died later
    │   │   ├── hooks/                            LATER: the hooks on main's Agent and SendMessage calls
    │   │   └── scripts/
    │   │       ├── main/                         LATER: job-dispatch.sh, after the dispatch talk
    │   │       ├── internal/
    │   │       │   ├── job-of.sh                 prints what a caller needs about one job, by seq or agent id.
    │   │       │   │                             The one reader of job.dispatched (section 5)
    │   │       │   └── events-view.sh            the events, each submission joined to its pinned report;
    │   │       │                                 refuses a report that changed. The one place that opens reports
    │   │       └── lib/
    │   │           ├── iteration.jq              the one count: iteration at a build's dispatch,
    │   │           │                             fix round at a fix's dispatch
    │   │           └── pinned-report.jq          the join that events-view.sh runs
    │   │
    │   ├── git-commit/                           unchanged; makes the working commit
    │   └── …                                     unchanged
    │
    └── agents/                                   NEW: what belongs to agents, not to main
        │
        ├── agent-submission/                     NEW: handing in any agent's work
        │   ├── hooks/
        │   │   ├── matchers.json                 {"subagent-stop/submit-agent-work.sh": null}
        │   │   └── subagent-stop/
        │   │       ├── submit-agent-work.sh      the hook: finds the job (none: stands aside), runs the steps
        │   │       │                             in order, holds the stop or lets it through
        │   │       └── submit-agent-work/        this hook's own steps, called by nothing else
        │   │           ├── report-validation.sh  calls the stopping agent's own check, prints its repair lines
        │   │           ├── report-pin.sh         hashes the report, makes it read-only
        │   │           ├── working-commit.sh     commits through git-commit, with the trailers
        │   │           ├── submission-event.sh   writes the agent's event
        │   │           └── held-stop.sh          counts held stops; on the second writes job.ended (gave-up)
        │   └── scripts/
        │       ├── internal/
        │       │   └── recover-submission.sh     shared with main's door: a working commit with no event
        │       │                                 gets its event, from its Job trailer
        │       └── lib/
        │           └── trailers.sh               writes and reads the commit's trailers
        │
        └── code-builder/                         NEW: the build agent and its contract
            ├── code-builder.md                   LATER: the agent's prose
            ├── submission.json                   per job kind: the event type, and whether a commit is made
            │                                     {"build": {"event": "build.submitted", "commit": true},
            │                                      "fix":   {"event": "fix.submitted",   "commit": true}}
            ├── events/
            │   ├── build.submitted.jq
            │   └── fix.submitted.jq
            └── scripts/
                ├── internal/
                │   └── report-validation.sh      checks a build or fix report (build-agent.md section 4)
                └── lib/
                    └── report-validation.jq      its rules
```

**In an effort, at run time:** as in `build-agent-tree.md` section 2 (`events/`, `reports/<job seq>.json`, `stops/<job seq>.held`). **The proof:** as its section 3, with one change in section 5 below.

## 2. Why this shape

- **`main-thread/` and `agents/` split by who runs it.** Main dispatches a job and reads the events, so `agent-jobs` is main's. The stop hook fires on an agent, and the report check is the agent's own contract, so those are the agents'.
- **Each event rule sits with its owner,** as the owner asked: `job.*` with the jobs, `build.submitted` and `fix.submitted` with the builder. The stop hook writes `job.ended` from another component; the rule checks who wrote it, as rules already do.
- **The submission hook knows no agent kind.** It needs two things from the stopping agent, and finds both by a fixed convention:
  - the component is named as the agent type (`code-builder`);
  - it holds `scripts/internal/report-validation.sh` and `submission.json`.

  So a tester or a reviewer is added by adding its folder. Nothing in `agent-submission` changes, and there is no table of agent kinds to keep in step.
- **Why the jobs are in the domain.** The brief calls them generic. They may be, but the last lift into the core before a second domain needed it was reverted. A job's start names a tree, known failures and plugins, which are this domain's ideas. Moving the folder to the core later changes no caller, because scripts find each other by installed name, not by path. That is why it isn't named `crucible-`: the name shouldn't have to change on the day it moves. It is the owner's call.

## 3. Installation (questions 2 and 3)

**Two small changes to `install-entries.sh`, both general:**

1. **Components are the folders directly in a `main-thread/` or an `agents/` folder.** Both kinds are linked the same way. The event writer finds rules among the linked components, and a hook's command runs through its component's link, so an agent's component must be linked like any other. A folder with no `SKILL.md` is not shown as a skill.
2. **`subagent-stop` is mapped to SubagentStop,** beside the three hook folders mapped today.

And one refusal to add: **two components with the same name.** Today nothing checks it, and with two kinds of folder it becomes easier to do.

**The installed name stays the folder name.** A path-based name would give every component two names: one when installed, one when run from the tree. Scripts find their neighbours by name, so that would break them in one of the two cases.

**So `agents/common/` keeps its place but not its name.** The owner's idea is the folder `agents/` for what agents share. Inside it, each folder is named for what it does: `agent-submission`. If more shared pieces come, they get their own names too.

**Later, with the prose:** the agent's own file has to reach the agents folder of the config. The installer doesn't do that yet. It belongs to the slice that writes `code-builder.md`.

## 4. The hook-folder rule (question 4)

**No clash with the main and internal split, and none with the internals guard.** A step called only by one hook is neither main's nor shared, and the guard already refuses everything under `hooks/`.

**One refinement.** Today every script directly in `hooks/<type>/` is a hook; that is how a reader knows what fires. Five step scripts beside the hook would end that: only `matchers.json` would tell which one is the hook. So the steps go one level down, in a folder named after their hook (`submit-agent-work/`). It follows the owner's rule more closely, since the scripts sit with that hook and not merely with its type. The installer already takes only the files `matchers.json` names.

A step that a second caller comes to need moves to `scripts/internal/`. `recover-submission.sh` starts there because main's door will call it.

## 5. Before building: the dispatch

**The stop hook can't be built without knowing a job's start.** It reads the kind, the tree, the report path, the chosen findings, the known failures, the iteration and the setup for the trailers, all from `job.dispatched`. That event's shape is the dispatch's design, and the owner's standing word is that the dispatch needs a long talk before anything is implemented.

`build-agent-tree.md` has "a minimal `job-dispatch.sh`, now" in `scripts/main/`. I'd not do that: it starts the dispatch by the back door, in the place main would find it.

**What I'd do instead:**
- **`job-of.sh` is the only reader of `job.dispatched`.** The hook and every later script ask it for what they need. When the dispatch talk changes the event, one script changes.
- **The rule `job.dispatched.jq` holds only what this build reads.** The dispatch spec adds the rest.
- **The proof writes its jobs itself,** from a fixture script in the evidence folder, through the real event writer. No dispatch script exists in the tree until the talk has happened.
- The same goes for knowing which agent has which job: the proof writes that fact itself until `job.assigned` is built.

## 6. Small

- **Six scripts for one hook is the upper end.** The pin is a few lines. If a step turns out to be three lines, fold it into the wrapper; a file per step is for steps worth reading alone.
- **The core's `--iteration` option** on `event-write.sh` is then used by nothing. It stays noted for removal, as agreed.
- **Nothing here is linked into the owner's own config.** The proof runs against a scratch config folder.
