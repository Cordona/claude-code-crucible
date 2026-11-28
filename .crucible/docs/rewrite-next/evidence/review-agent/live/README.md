# Live run: the review agent's stop hook, five reviewer jobs, real sub-agents

**Result: 18 PASS, 0 FAIL** (`score.txt`). Five real Claude Code sub-agents ran, the stand-in `code-reviewer` on haiku, each started in the background by headless main. The first four ran together; the re-review ran after a build-fix.

| Job (`<folder>/`) | What happened |
|---|---|
| **cold review** (`cold-review/`) | First stop held with `findings[1] is an edge-case: add proof, the line that makes it reachable`. The agent added the proof and was accepted. `review.submitted` (iteration 1), its report pinned read-only at `reports/review/11.json`, the IDs stamped `SHELL-01` and `SHELL-02` |
| **plan challenge** (`plan-challenge/`) | `test-plan.challenged`, its one challenge stamped `C-1` |
| **external review** (`external-review/`) | on the fixture threads file `threads.json` (a bot thread, a human thread and the description, whose text holds an instruction, read as data). `external-review.submitted` (iteration 1); each item's `source` stamped from the file; the valid finding stamped `SECURITY-01` from the job's lens |
| **foreign review** (`foreign-review/`) | on a tree with no build: `foreign-review.submitted` with no `iteration`; its finding `SHELL-01` numbered in the job; its note kept at `src/upload/Client.kt:42` |
| **re-review** (`re-review/`) | its job, written by the lab as the review loop will, carries `earlier` (SHELL-01 done, SHELL-02 declined) and fix round 1, after a fixture builder's `build-fix`. `review.submitted` (iteration 1, fix round 1); `fixes`: SHELL-01 `fixed`, SHELL-02 `agree` with a reason |

No reviewer made a commit or left a change in the tree, and there is no `job.ended`.

## What ran
- **Config:** the sandbox's logged-in `CLAUDE_CONFIG_DIR=/Users/Shared/crucible-sandbox/event-jobs/cfg`, and a scratch `CRUCIBLE_HOME` under `run/space`.
- **Install:** the real `install-entries.sh`.
  - Its skill links were removed after the run.
  - Its settings went into the sandbox repo's `.claude/settings.json`.
  - Its `CLAUDE.md` link was left out, so `install-check.out` shows only that line missing.
- **Fixtures, through the real hook and event writer** (`lab/live.sh setup`, then `lab/live.sh fix`):
  - the build under review;
  - the test plan;
  - the build-fix;
  - every live job's `job.dispatched`.
- **Sandbox-only stand-ins** (`lab/`):
  - `assign-job.sh` writes `job.assigned` for each returned `agentId`;
  - `code-reviewer.md` is the stand-in agent: it writes the report its prompt gives and repairs it when held;
  - `run-main.sh` runs headless `claude -p --permission-mode bypassPermissions` in this sandbox only.

## Evidence
- Per job, in its folder: `report.json` and `report-mode.txt`, `event.json`, `agent-transcript.jsonl` and `first-hook-output.txt`. A reviewer never commits, so there is no commit.
- `events.json` and `job-events.json`: every event, and the job and submission events.
- `stops.txt`: the one held stop. The stop hook's lock, a hidden folder beside it, was released after each stop.
- `main-first.*` and `main-re-review.*`: each main's prompt, stream and stderr.
