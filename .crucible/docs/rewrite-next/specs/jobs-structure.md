# The jobs structure (for the owner's review, before any rewiring)

2026-11-27. Everything about jobs under one folder, `domains/software-development/core/main-thread/jobs/`, three pieces, each one thing: `define` (the job and its kinds), `assign` (the job onto an agent), `track` (the job until it ends). The agent itself coming to life is not a job: it is `core/agents/agent-init/`. `agent-jobs/` is emptied into them and deleted.

## The tree

```
jobs/
├── define/                          defining a job (built, step 1)
│   ├── SKILL.md
│   ├── kinds/
│   │   ├── build.json               built
│   │   ├── test.json                new
│   │   └── review.json              new
│   ├── events/
│   │   └── job.defined.jq
│   └── scripts/
│       ├── main/
│       │   ├── job-resolve.sh       main's jobs → full jobs
│       │   ├── job-card.sh          the human's card, a recorded gate
│       │   └── job-define.sh        job.defined × N
│       └── lib/
│           ├── job-frame.jq         the shapes, the iteration count
│           └── job-resolve.jq
│
├── assign/                          a job onto an agent (new)
│   ├── SKILL.md
│   ├── events/
│   │   └── job.assigned.jq          {job, agent, tree}, moved from agent-jobs
│   ├── hooks/
│   │   ├── matchers.json
│   │   ├── pre-tool-use/
│   │   │   └── start-from-door.sh   an Agent call for a job is the door's; one per message
│   │   ├── worktree-create/
│   │   │   └── job-tree.sh          answers the job's tree path
│   │   ├── subagent-start/
│   │   │   └── job-assigned.sh      job.assigned + agent.initialized (cold), from the door's note
│   │   └── post-tool-use/
│   │       └── job-sent.sh          job.assigned (hot, after SendMessage)
│   └── scripts/
│       └── main/
│           └── job-assign.sh        the door: checks a job, prints the Agent call or SendMessage
│
└── track/                           a started job until it ends (moved from agent-jobs)
    ├── events/
    │   ├── job.ended.jq
    │   ├── job.stalled.jq
    │   └── job.refused.jq
    ├── hooks/
    │   ├── matchers.json
    │   └── stop/
    │       └── end-gone-jobs.sh     main's turn end ends jobs whose agent is gone
    └── scripts/
        ├── main/
        │   └── end-job.sh
        ├── internal/
        │   ├── job-of.sh            the one job view the agent side reads
        │   ├── agent-job.sh         an agent's open job, any effort
        │   ├── agent-had-job.sh
        │   ├── events-view.sh
        │   └── report-hash.sh
        └── lib/
            ├── jobs.jq              a job's state, from job.defined on
            ├── pinned-report.jq
            └── pinned.sh
```

Gone: `agent-jobs/` (folder), `job.dispatched.jq` (see "Open" below), `iteration.jq` (the count is `define`'s `job-frame.jq`).

Installed as `jobs-define`, `jobs-assign`, `jobs-track`.

## The agent's start (not a job): `core/agents/agent-init/`

```
core/agents/agent-init/
├── events/
│   └── agent.initialized.jq         {agent, base, type, plugins}
└── scripts/
    ├── main/
    │   └── agent-files.sh           writes the kind+set agent files, at the card
    └── lib/
        └── agent-name.jq            <base>-<language>-<frameworks>-<standards>, and its skills
```

Installed as `agent-init`. It owns the event's rule and the agent files; it has no hook (owner and Fable, 2026-11-27): a starting agent's effort is known only from the door's note, a private file of `jobs/assign`, so assign's start hook writes both events. No rule or audit requires agent.initialized before job.assigned. `job-card.sh`'s output names `agent-files.sh`, run when the card is shown.

## The plugins as skills (owner 2026-11-27: model-invocable)

Today a plugin is one `SKILL.md` plus `references/build.md` and `references/review.md`, and the installer doesn't link plugins at all. `skills:` preloads a `SKILL.md` only, never its references. So each plugin becomes one skill per part:

```
plugins/tech/languages/kotlin/
├── SKILL.md                 language-kotlin: what every job on Kotlin needs
├── build/SKILL.md           language-kotlin-build
└── review/SKILL.md          language-kotlin-review
```

Standards stay one skill each (`standard-security`). No `disable-model-invocation`; short descriptions.

## Before the real install (not now: every run uses a scratch config)

- Skill names shared with the old harness (`standard-security`, `language-shell`, …): settled by the owner, 2026-11-27: the real install removes the legacy framework entirely, so nothing clashes and nothing is prefixed.
- A user-level `worktree-create` hook is asked about every tree start in every session: a probe first proves it steps aside for a start that is no job's.

## Two installer changes (core, generic)

1. Hook events `subagent-start` and `worktree-create`, beside the five it knows.
2. Plugin folders linked as skills, by their `name:`.

## The order

1. You review this structure.
2. Build `define`'s two kinds, `assign` (without its `job.assigned` rule: one rule per type, it moves in step 3) and `agent-init` (new files only; no rewiring).
3. Rewire: the job view on the new chain, paths untouched, regression runs passing.
4. Move: `agent-jobs` into `track` and `assign` as paths only, the same runs passing; nothing names agent-jobs; the folder deleted.
5. The plugins as skills; then the live run with the real builder, tester and reviewer.

## Open: the seven other kinds

`job.dispatched` also carries build-fix, test-fix, re-review, test-plan, plan update, challenge, external and foreign review. Either all ten kinds move now (about six payload shapes for you: findings, sent_back, earlier, challenges, threads, foreign), or `job.dispatched` stays in `track` only for the seven until each moves (two job models for a while, shrinking). Beta's lean: the second.
