# Stop-hook mechanism matrix (assurance plan, step 3)

**Result: 84 of 84 cells PASS, 814 checks, 0 FAIL** (`score.txt`). **Control run, done first: 84 of 84 cells red** (`control-score.txt`): no cell's scenario checks pass with the three hooks removed.

Claude Code 2.1.332, run 2026-11-25. Real Claude Code sub-agents (stand-ins on haiku), started in the background by headless main (sonnet) in permission mode `default`.

## Results

Each cell is one scenario on one kind. Its raw evidence is in `logs/<scenario>-<kind>/`, for example `logs/S2-test-plan-update/`. `—` means the plan doesn't assign that scenario to that kind.

| | build | build-fix | test-plan | test-plan-update | test | test-fix | review (cold) | review (hot) | re-review | test-plan-challenge | external-review | foreign-review |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| S1 accepted first time | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| S2 refused on its own rule, repaired | PASS | PASS | PASS | PASS | PASS | PASS | PASS | — | PASS | PASS | PASS | PASS |
| S3 wrong path, then moved | PASS | PASS | PASS | PASS | PASS | PASS | PASS | — | — | PASS | PASS | PASS |
| S4 refused twice | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | — | PASS | PASS | PASS |
| S5a install fault before acceptance | PASS | — | PASS | — | — | — | PASS | — | — | — | — | — |
| S5b fault after acceptance | PASS, and `S5b-build-giveup` PASS | — | — | — | PASS | — | — | — | — | — | — | — |
| S6 a bad location | PASS | PASS | PASS | PASS | PASS | PASS | PASS | — | — | PASS | PASS | PASS |
| S7 the tree changed where it may not | — | — | PASS | — | PASS | — | PASS | — | — | — | — | — |
| S8 not one JSON object | PASS | PASS | PASS | PASS | PASS | PASS | PASS | — | — | PASS | PASS | PASS |
| S9 twelve reviewers refused at once | — | — | — | — | — | — | PASS | — | — | — | — | — |
| S10 no job found (A0) | PASS | — | PASS | — | — | — | PASS | — | — | — | — | — |
| S11 a parked stop | PASS | — | — | — | PASS | — | PASS | — | — | — | — | — |
| S12 the no-stop writer | PASS | — | PASS | — | — | — | PASS | — | — | — | — | — |
| S13 the Bash hook's deny | PASS | — | — | — | — | — | — | — | — | — | — | — |

What some cells show:
- **S2:** each kind's own line came back as the plan names it. For example, build gave `summary is 72 characters; shorten it to 55 or fewer`, and re-review gave `give SHELL-02 a status: agree or disagree (the fixer said declined)`.
- **S4:** two `job.refused` with try 1 and try 2, then `job.ended` gave-up. The human was told `job N (...) gave up: its report was refused twice...`. Nothing was pinned or committed. The hot review (`S4-review-hot`) is the same, on a job assigned at `PreToolUse(SendMessage)`.
- **S5a:** `job.ended {fault, step check}`. The human was told `the report check of job N can't run: ... which aren't installed; the job ends, nothing handed in`.
- **S5b:** `job.stalled {step commit}`, with the report pinned. The human was told the `recover-submission.sh` command. Then:
  - `--finish` gave the submission, by `recover-submission.sh`, with its working commit;
  - `--give-up` (`S5b-build-giveup`) gave `job.ended {fault, step commit}` and no commit.
- **S9:** twelve `job.refused`. Each block reached its own agent and named its own report. Then twelve submissions, with 24 unique stamped IDs.
- **S10:** the human was told `agent ... (code-builder) stopped, and no effort has a job assigned to it`. No event was written.
- **S11:** the Bash hook gave `act.sh sleep 45` a timeout of 30000. The agent parked ("Waiting."), and its stop was held with `write your report as one JSON object to ...`. It then wrote the report and was accepted.
- **S12:**
  - the TaskStopped agent got `job.ended no-stop` by `end-gone-jobs.sh`;
  - at that same turn end, `background_tasks` listed the running agent and the hot one, and their jobs were untouched;
  - a later turn end listed the hot agent while it ran its second job, assigned at `PreToolUse(SendMessage)`, and that job was untouched too;
  - all three later submitted.
- **S13:** `run_in_background: true` was denied with `Run this command in the foreground...`. The agent reran the command in the foreground and submitted.

## The control run
- `run.sh all control` ran the same 84 cells with the stop hook, the job-agent Bash hook and main's Stop hook removed from the settings.
- Every cell is red on its own scenario checks: no `job.refused`, submission, `job.ended`, `job.stalled` or message; no deny; no timeout rewrite. That includes S12 and S13. Its audit lines fail too where jobs stay open.
- `control-score.txt` ends with `cells whose own scenario checks all pass without the hooks: 0`.

## The audit (in `score.txt`, per cell, over every job, fixtures included)
- every job ended or submitted;
- `job.stalled` only in S5b;
- every pinned report matching its hash;
- every working commit (a `Job:` trailer) with its submission event;
- every refusal followed by a submission or an end;
- no job with more than two refusals.

All pass.

## What ran
- **Sandbox:**
  - `CLAUDE_CONFIG_DIR=/Users/Shared/crucible-sandbox/event-jobs/cfg`;
  - the working folder `/Users/Shared/crucible-sandbox/stop-hook-matrix/` (`run-real/`, `run-control/`, and `run-*-rerun/`, see below);
  - a scratch `CRUCIBLE_HOME` in each.
- **Install:**
  - the skill links come from the real `install-entries.sh`, made in the sandbox config only and removed after the run (`run.sh unlink`);
  - the settings come from its entries, in each session's `.claude/settings.json`;
  - `install-check.out` shows two lines missing: its `CLAUDE.md` link (left out, as in the earlier labs) and `BASH_MAX_TIMEOUT_MS=2700000`, which this run sets to `30000` on purpose, through the same settings `env` block.
- **Main:**
  - headless `claude -p --permission-mode default --model sonnet`, one session per batch (`logs/_sessions/<batch>/`);
  - the allow-list is passed with `--settings` (P15). It holds `Bash(sh <sandbox>/lab/act.sh:*)` plus Agent, SendMessage, TaskStop and ToolSearch. No bypass anywhere.
- **The hook-output capture:** every hook is registered through `lab/capture.sh`, which runs it unchanged and saves `{tag, input, stdout, exit, t_start}` per call. No transcript is read.
- **Fixtures** (`lab/cells.sh`):
  - one effort per cell, and one tree per live job;
  - earlier jobs (build, plan, challenge, review, build-fix) are handed in by fixture agents through the real hook;
  - each `job.dispatched` goes through the real event writer;
  - `lab/assign-job.sh` writes `job.assigned` with `session`, as a PostToolUse hook on Agent and a PreToolUse hook on SendMessage.
- **Stand-ins** (`lab/agents/`): `code-builder`, `code-tester`, `code-reviewer` on haiku, with Bash only.
  - Each follows its recipe (`logs/<cell>/*.recipe`): STEPS, then HELD 1 and HELD 2. Every step is one `lab/act.sh` call: put a prepared report, move, edit, undo, sleep.
  - The recipe makes the first report fail as the scenario says. HELD 1 is the repair the repair line asks for.
  - The prepared reports keep haiku deterministic. Steering what the agent writes is step 4's subject, with the real definitions.
- **S5a:** run alone. Each agent type's component link was replaced by a copy without its rules module (`build-report.jq`, `test-plan-report.jq`, `review-report.jq`), and the links were restored after.
- **S5b:** an `index.lock` was left in the tree's git folder. `run.sh post` removed it, then ran `recover-submission.sh`.

## Files
- `run.sh`:
  - `all MODE [SCENARIO...]` runs a whole run;
  - `setup MODE [SCENARIO|CELL...]`, then `waves`, then `collect`, runs it in parts;
  - `batch MODE BATCH` runs one batch;
  - `RUN_SUFFIX=-x` reruns cells beside a run.
- `score.sh real|control [CELL...]`: reads only `logs/`: events, report files, the trees' git log and status, and the saved hook calls.
- `lab/`: `agents/*.md`, `act.sh`, `capture.sh`, `assign-job.sh`, `observe.sh` (a no-op hook, captured, so the control has the agents' stops too) and `cells.sh`.
- `logs/<cell>/`: `events.json`, `reports/`, `git.txt`, `hooks/` (the cell's agents' hook calls and main's turn ends listing them), its recipes and prompts, and for S5b `recover.out`. `logs/_sessions/<batch>/` holds main's stream, stderr, prompt, settings and every hook call. `logs/control/` has the same for the control run.

## Notes
- **One rerun, a lab bug, not the framework.**
  - In the first real run, `S4-review-hot` failed: its hot job was given the S1 recipe, because `scenario_recipe` overwrote the cell's scenario variable. The job was accepted at once, and the scorer was right to fail it.
  - The fix is in `lab/cells.sh`. The cell was rerun alone, in both modes, with `RUN_SUFFIX=-rerun` (`logs/_sessions/b-hot-rerun/`). It passed real and stayed red in control.
  - The first run's sessions are kept as `logs/_sessions/b-hot/`.
- **A stand-in quirk, harmless.** In S11, after the agent was accepted, its background `sleep` finished and the agent resumed. It ran its step 3 again and hit `Permission denied` on the pinned, read-only report. That last stop went through untouched: its job was already handed in. This shows the pin holding against a late write.
- **No framework bug was found.**
- **Not done here:** step 4, the real definitions. The sandbox run folders are kept under `/Users/Shared/crucible-sandbox/stop-hook-matrix/`; the skill links are removed, and no process is left running.
