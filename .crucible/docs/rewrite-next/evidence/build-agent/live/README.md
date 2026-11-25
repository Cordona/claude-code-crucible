# Live run: the build agent's stop hook, a build then a build-fix, real sub-agents

**Result: 13 PASS, 0 FAIL** (`score.txt`). Two real Claude Code sub-agents ran, the stand-in `code-builder` on haiku, each started in the background by headless main.

- **The build** (`build/`):
  - its report's summary was 61 characters, so the SubagentStop hook held the stop with `summary is 61 characters; shorten it to 55 or fewer` (`build/first-hook-output.txt`);
  - the agent shortened it and stopped again, and the stop was accepted;
  - `build.submitted` pins `reports/build/4.json`, read-only;
  - the working commit is `crucible(build)`, unsigned, with Effort, Job, Iteration, Language and Standards.
- **The build-fix on that build** (`build-fix/`):
  - the job carried finding REVIEW-01 and fix round 1;
  - the agent's report listed REVIEW-01 in `fixes` as done and was accepted on its first stop;
  - `build-fix.submitted` (iteration 1, fix round 1) pins `reports/build-fix/7.json`, read-only;
  - the working commit is `crucible(build-fix)`, with `Fix-Round: 1`.
- There is no `job.ended`, and the tree is clean.

## What ran
- **Config:** the sandbox's logged-in `CLAUDE_CONFIG_DIR=/Users/Shared/crucible-sandbox/event-jobs/cfg`, and a scratch `CRUCIBLE_HOME` under `run/space`.
- **Install:** the real `install-entries.sh`.
  - Its skill links went into the config and were removed after the run.
  - Its settings went into the sandbox repo's `.claude/settings.json`.
  - Its `CLAUDE.md` link was left out, since the config is shared, so `install-check.out` shows only that one line missing.
- **Fixtures:** a scratch repo and worktree, a scratch effort, the identity fixture (no key), and each job's `job.dispatched`, written through the real event writer before main started (`lab/live.sh setup`, then `lab/live.sh fix`).
- **Sandbox-only stand-ins** (`lab/`):
  - `assign-job.sh`, a PostToolUse hook on Agent, writes `job.assigned` for the returned `agentId` as `assign-job.sh`, named after the job's kind;
  - `code-builder.md` is the stand-in agent, with one recipe per kind;
  - `run-main.sh` runs headless `claude -p --permission-mode bypassPermissions` in this sandbox only.

## Evidence
- Per kind, in `build/` and `build-fix/`: `report.json` and `report-mode.txt`, `event.json`, `commit.txt` (`git log -1 --format=%B` and `git show --stat`), `agent-transcript.jsonl` and `first-hook-output.txt`.
- `events.json` and `job-events.json`: every event, and the job and submission events.
- `stops.txt`: one held stop, the build's.
- `main-build.*` and `main-build-fix.*`: each main's stream and stderr. `stderr` has the untrusted-folder note about `additionalDirectories`, which didn't matter here, since bypass mode was on.
