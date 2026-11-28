# Step 3: the mechanism matrix, with real sub-agents in the sandbox

By Dev Beta. The plan: `stop-hook-assurance-plan.md`, step 3. Read it first.

## What it proves

For every report kind, real Claude Code sub-agents, steered to fail on purpose, are refused by the real stop hook. They get the repair lines, repair the report, and end with the right events. All of it is scored by a script.

## The setup

- **Sandbox:**
  - the logged-in config `CLAUDE_CONFIG_DIR=/Users/Shared/crucible-sandbox/event-jobs/cfg`;
  - a working folder under `/Users/Shared/crucible-sandbox/stop-hook-matrix/`, outside `/Users/cordona`;
  - a scratch `CRUCIBLE_HOME`;
  - headless main in permission mode `default`. The allow-list is passed with `--settings`, because P15 showed that an untrusted project's allow rules are dropped. bypassPermissions is used only where a case needs it, and the case says so.
- **Install:** the real `install-entries.sh`, its links into the sandbox config only, removed after the run. It brings the stop hook, the job-agent Bash hook, main's Stop hook and the `env` setting. The proofs use a short time limit, about 30 s, through the same setting.
- **Capturing what the human is told:** the hooks are registered through a small wrapper that saves each hook's stdout to one file per call. The scorer reads those files. The hook itself is unchanged, and no transcript is read.
- **Stand-in agents:** one per agent type (`code-builder`, `code-tester`, `code-reviewer`), on haiku, each with one recipe per kind and scenario. The recipe makes the first report fail in the named way, then repair it on the repair lines.
- **Fixtures:** a scratch repo and worktree, a scratch effort, and each job's `job.dispatched`, written through the real event writer, as the earlier live labs did (`evidence/*/live/lab/`). `job.assigned` comes from the lab's stand-in `assign-job.sh`, which now writes `session`, run as a PostToolUse hook on Agent. A resumed agent is assigned at PreToolUse(SendMessage).

## The matrix

The plan's S1 to S11, for the ten kinds, with each kind's own S2 rule from the plan's table.

**The control run first:** the same matrix with all three hooks removed (the stop hook, the job-agent Bash hook and main's Stop hook). The scorer must go red on every scenario, S12 and S13 included.

The matrix includes S12 (the no-stop writer, live) and S13 (the Bash hook's deny, live). S5b ends `job.stalled`, then `--finish`, and on one kind `--give-up`.

## The scorer

One script reads only:
- events;
- report files;
- git;
- the saved hook outputs.

Per scenario it checks the expected events, in order: `job.refused` with its try and lines, the submission or `job.ended` with its reason, `job.stalled` with its step. It also checks that the pins match, the commits exist, and the human's message is present where expected.

Then it runs the audit:
- every job ended or submitted, or stalled only where its scenario expects it;
- every pinned report matching its hash;
- every working commit with its event;
- every refusal followed by a submission or an end;
- no job with more than two refusals.

## Evidence

`evidence/stop-hook-matrix/`, holding:
- `run.sh`, one scenario or all;
- `lab/`;
- `logs/<scenario>/`;
- `score.txt`;
- `control-score.txt`;
- `README.md`.

## Rules

- Never commit.
- Never touch `~/.claude`.
- Kill by PID only.
- Waits of 2 minutes or less.
- Clean up everything, links and processes, after the run.
