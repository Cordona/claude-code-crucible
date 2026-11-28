# Live run: the test agent's stop hook, a test then a test-fix, real sub-agents

**Result: 14 PASS, 0 FAIL** (`score.txt`). Two real Claude Code sub-agents ran, the stand-in `code-tester` on haiku, each started in the background by headless main.

- **The test job** (`test/`):
  - its report first lacked the `mutation` gate, so the SubagentStop hook held the stop with `list the mutation gate: pass with a note, fail with what survived, or not_run with why`;
  - the agent added the gate as `not_run` with a note, stopped again, and the stop was accepted;
  - `test.submitted` pins `reports/test/11.json`, read-only;
  - the working commit is `crucible(test)`, unsigned, with Effort, Job, Iteration, Language and Standards, and no Framework.
- **The test-fix** (`test-fix/`):
  - it came after a builder's `build-fix` on the same build (`build-fix/`), a fixture agent through the real hook, fix round 1;
  - the test-fix job carried finding TEST-01 and its own fix round 1, counted apart from the build-fix's;
  - the agent's report listed TEST-01 in `fixes` as done and was accepted;
  - `test-fix.submitted` (iteration 1, fix round 1) pins `reports/test-fix/17.json`, read-only;
  - the working commit is `crucible(test-fix)` with `Fix-Round: 1`, and changes the test file only.
- There is no `job.ended`, and the tree is clean.

## What ran
- **Config:** the sandbox's logged-in `CLAUDE_CONFIG_DIR=/Users/Shared/crucible-sandbox/event-jobs/cfg`, and a scratch `CRUCIBLE_HOME` under `run/space`.
- **Install:** the real `install-entries.sh`.
  - Its skill links were removed after the run.
  - Its settings went into the sandbox repo's `.claude/settings.json`.
  - Its `CLAUDE.md` link was left out, so `install-check.out` shows that one line missing.
- **Fixtures, written through the real hook and event writer** (`lab/live.sh setup`, then `lab/live.sh fix`):
  - the build under test;
  - the approved plan, with its `gate.answered`;
  - the builder's `build-fix`;
  - each live job's `job.dispatched`.
- **Sandbox-only stand-ins** (`lab/`):
  - `assign-job.sh` writes `job.assigned` for the returned `agentId` as `assign-job.sh`;
  - `code-tester.md` is the stand-in agent, with one recipe per kind;
  - `run-main.sh` runs headless `claude -p --permission-mode bypassPermissions` in this sandbox only.

## Evidence
- Per kind, in `test/`, `test-fix/` and `build-fix/`: `report.json` and `report-mode.txt`, `event.json`, `commit.txt`, and, for the live agents, `agent-transcript.jsonl` and `first-hook-output.txt`.
- `events.json` and `job-events.json`: every event, and the job and submission events.
- `stops.txt`: one held stop, the test's.
- `main-test.*` and `main-test-fix.*`: each main's stream and stderr.
