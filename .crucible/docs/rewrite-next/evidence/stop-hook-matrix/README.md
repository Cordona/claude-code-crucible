# Stop-hook mechanism matrix (assurance plan, step 3), rerun after the hook rework

**Result: 86 of 86 cells PASS, 884 checks, 0 FAIL** (`score.txt`). **Control run, done first: 86 of 86 cells red** (`control-score.txt`): with every framework hook removed, no cell's scenario checks pass. S12 to S15 are included.

**The framework didn't change during either run.** Both scores carry the same hash of every file in `new-rewrite/`, taken at setup and at collect (`400b15f1…`, `logs/framework-hash.txt`).

Claude Code 2.1.332, run 2026-11-25. Real Claude Code sub-agents (stand-ins on haiku) were started in the background by headless main (sonnet).

## The layout (the real one)
- **Main** starts in its batch's **repo**, in permission mode `default`. Bypass is never used.
- **The trees and the reports live in the space** (`CRUCIBLE_HOME`), outside the repo: `efforts/<id>/worktrees/<tree>` and `efforts/<id>/reports/`.
- **`--settings` carries:**
  - Bash allow rules only for the project's gate commands: `sh tests/run.sh`, `sh tests/slow.sh:*`, `sh tools/fmt.sh`, `sh tools/fmt.sh --undo`;
  - the read-only `git -C * status|diff|log|show*` forms;
  - Agent, SendMessage, TaskStop and ToolSearch;
  - the space in `additionalDirectories`, and the installer's deny rule on `events/`.
- **There are no Write or Edit allow rules.** A job agent's writes pass only through the write-scope step.
- **Install:**
  - the real `install-entries.sh` from the current `new-rewrite`, links made into the sandbox config only and removed after the run;
  - the hooks and env go in the repo's `.claude/settings.json`, which `.git/info/exclude` keeps out of `git status`;
  - `install-check.out`, run against both settings files, shows only the expected two lines: the `CLAUDE.md` link, and `BASH_MAX_TIMEOUT_MS` set to 30000 on purpose.
- **Fixtures:**
  - git runs with `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1` and `commit.gpgsign=false`, so nothing is signed with a real key;
  - working commits are `--unsigned`.

## Results

Each cell's evidence is in `logs/<scenario>-<kind>/`, for example `logs/S14-build/`. `—` means the plan doesn't assign that scenario to that kind.

| | build | build-fix | test-plan | test-plan-update | test | test-fix | review (cold) | review (hot) | re-review | test-plan-challenge | external-review | foreign-review |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| S1 accepted first time | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| S2 refused on its own rule, repaired | PASS | PASS | PASS | PASS | PASS | PASS | PASS | — | PASS | PASS | PASS | PASS |
| S3 wrong path | PASS | PASS | PASS | PASS | PASS | PASS | PASS | — | — | PASS | PASS | PASS |
| S4 refused twice | PASS¹ | PASS | PASS | PASS | PASS | PASS | PASS | PASS | — | PASS | PASS | PASS |
| S5a install fault before acceptance | PASS | — | PASS | — | — | — | PASS | — | — | — | — | — |
| S5b fault after acceptance | PASS, and `S5b-build-giveup` PASS | — | — | — | PASS | — | — | — | — | — | — | — |
| S6 a bad location | PASS | PASS | PASS | PASS | PASS | PASS | PASS | — | — | PASS | PASS | PASS |
| S7 the tree changed where it may not | — | — | PASS | — | PASS | — | PASS | — | — | — | — | — |
| S8 not one JSON object | PASS | PASS | PASS | PASS | PASS | PASS | PASS | — | — | PASS | PASS | PASS |
| S9 twelve reviewers refused at once | — | — | — | — | — | — | PASS | — | — | — | — | — |
| S10 no job found (A0) | PASS | — | PASS | — | — | — | PASS | — | — | — | — | — |
| S11 a parked stop | PASS | — | — | — | PASS | — | PASS | — | — | — | — | — |
| S12 the no-stop writer | PASS | — | PASS | — | — | — | PASS | — | — | — | — | — |
| S13 the Bash hook's background deny | PASS | — | — | — | — | — | — | — | — | — | — | — |
| S14 a Write into the repo | PASS | — | — | — | — | — | — | — | — | — | — | — |
| S15 `cd` before git | — | — | — | — | — | — | PASS | — | — | — | — | — |

¹ Rerun alone, see Notes.

What some cells show:
- **R3, no main involvement:** every cell with a refusal and a submission was checked. No SendMessage from main reached the agent between its `job.refused` and its submission: 47 cells, and all 12 jobs of S9.
- **S3:** the wrong-path Write was already denied by write-scope, with `Write only your report …` or `Write only in <tree> and to your report …`. The stop was then refused with `write your report as one JSON object to <the right path>`, and the agent wrote it there.
- **S7:**
  - the planner and the reviewer changed the tree through the project's formatter, `cd <tree> && sh tools/fmt.sh`, since their write scope is the report only. They were refused with `undo …` and undid it with `sh tools/fmt.sh --undo`;
  - the tester edited `src/upload/Client.kt`, outside its plan. It was refused with `you changed src/upload/Client.kt, which isn't in the approved plan: undo it…` and removed its edit.
- **S11:** the timeout step gave `cd <tree> && sh tests/slow.sh 45` a timeout of 30000. The agent parked, was refused with `write your report…`, then wrote it and was accepted.
- **S13:** `run_in_background` was denied with `Run this command in the foreground…`. The agent reran in the foreground and submitted.
- **S14:**
  - a Write to `<repo>/notes.txt` was denied by write-scope: `Write only in <tree> and to your report <report>.`;
  - the agent wrote `<tree>/notes.txt` instead, and it is in the working commit;
  - the repo's `git status` is empty.
- **S15:** `cd <tree> && git status` was denied by `refuse-denied-forms.sh`: ``Don't `cd` before git: run `git -C <tree> …`. Your other commands still run.`` The agent ran `git -C <tree> status`, which wasn't refused, and submitted.
- **S1 to S12** show the same events as the first run: refusals with their lines, `job.ended` gave-up, fault, no-stop, `job.stalled`, then `--finish` and `--give-up`, and A0 told to the human.
- **No sealed-folder denial:** the read guard denied no agent call anywhere in the run. No job needed a sealed folder.

## Hook cost (`score.txt`, "hook cost")

Each figure is the time a job agent's call spent in the hook, from the saved calls' start and end times, over every call in the run. Up to three sessions of about twelve agents each ran at once, so these numbers are under load.

| Hook, tool | n | median | p90 | max |
|---|---|---|---|---|
| `job-agent-tools.sh`, Bash (background deny, refuse-denied-forms, timeout) | 35 | 141 ms | 422 ms | 460 ms |
| `job-agent-tools.sh`, Write (write-scope) | 192 | 692 ms | 1460 ms | 2217 ms |
| `job-agent-tools.sh`, Edit (write-scope) | 17 | 791 ms | 1511 ms | 2141 ms |
| `guard-framework.sh`, Bash (direct-event-write, sealed reads) | 35 | 102 ms | 345 ms | 377 ms |
| `guard-framework.sh`, Read (sealed reads) | 125 | 98 ms | 268 ms | 383 ms |

- A Bash call goes through both wrappers, each well under half a second.
- **The write-scope step is the slow one:** about 0.7 s at the median, and over a second at p90, under load. By Fable's bar ("if it is over a second…"), that is where to look first.
- This build has no Grep or Glob tool (P18), so no call was measured for them.

## The control run
- `run.sh all control` ran the same 86 cells first, from a clean start. Every framework hook was removed from the settings: the stop hook, the job-agent tools wrapper, main's Stop hook, the read guard, and the gate and flow hooks. The lab's capture, observe and assign hooks stayed.
- With no write-scope allow and no Write rule, the agents' Writes went to Claude Code's own permissions and were denied headless, so no report was handed in.
- Every cell is red on its own scenario checks, S12 to S15 included. `control-score.txt` ends with `… without the hooks: 0 (must be 0)`.

## The audit (in `score.txt`, per cell, over every job, fixtures included)
- every job ended or submitted;
- `job.stalled` only in S5b;
- every pinned report matching its hash;
- every working commit with its event;
- every refusal followed by a submission or an end;
- no job with more than two refusals.

All pass. **Plus the framework-hash check:** a run whose framework changed between setup and collect fails.

## Stand-ins and fixtures
- **The stand-ins** (`lab/agents/`): `code-builder`, `code-tester` and `code-reviewer` on haiku, with Read, Write, Edit and Bash.
  - Each Reads its recipe from `<space>/recipes/<cell>/<tag>.md`, which the space's working-dir status lets it read.
  - It then does each step with the real tools:
    - Write of the given report content;
    - Edit of a tree file, after a Read;
    - Bash of a gate command.
  - HELD 1 and HELD 2 are the repairs.
- **The fixtures** (`lab/cells.sh`):
  - one repo per batch, holding the fixture project: `a.sh`, `b.sh`, `src/upload/Client.kt`, a test file, `tests/run.sh`, `tests/slow.sh` and `tools/fmt.sh`;
  - one effort per cell, and one tree per live job;
  - earlier jobs are handed in by fixture agents through the real stop hook;
  - each `job.dispatched` goes through the real event writer;
  - `lab/assign-job.sh` writes `job.assigned` with `session`, at PostToolUse(Agent) and PreToolUse(SendMessage).
- **The capture wrapper:** every hook is registered through `lab/capture.sh`, tagged `<event>-<script>`, for example `PreToolUse-job-agent-tools` or `PreToolUse-guard-framework`. It saves `{tag, input, stdout, exit, t_start, t_end}` per call. No transcript is read.
- **S5a:** run alone, with each agent type's rules module removed from a copy in place of its link, and the links restored after.
- **S5b:** an `index.lock` was left in the tree's git folder; `run.sh post` clears it and runs `recover-submission.sh`.

## Files
- `run.sh`:
  - `all MODE [SCENARIO...]` runs a whole run;
  - `setup MODE [SCENARIO|CELL...]`, `waves`, `s5a`, `post` and `collect` run it in parts;
  - `batch MODE BATCH` runs one batch;
  - `RUN_SUFFIX=-x` reruns cells beside a run.
- `score.sh real|control [CELL...]`: reads only `logs/`: events, reports, git log and status (the trees and the repo), and the saved hook calls. It also prints the hook-cost table.
- `logs/<cell>/` holds `events.json`, `reports/`, `git.txt`, `hooks/`, the recipes and prompts, and for S5b `recover.out`. `logs/_sessions/<batch>/` holds main's stream, prompt, settings and every hook call. `logs/control/` has the same for the control run.

## Notes
- **Runs discarded before this one.** Two builds landed in `new-rewrite` while the first reruns were going, and the install links point into that source, so those cells mixed old and new hooks.
  - One trial stop ended "unexpectedly at its stamp step", with `submit-agent-work.sh: unexpected EOF`. The script was being rewritten at that moment.
  - Every cell run before 14:10 was discarded. After a ten-minute quiet window, the control and the full matrix were run from a clean start.
  - The framework hash proves the clean runs saw one framework.
- **¹ S4-build, a stand-in problem, rerun alone.** On HELD 1, haiku repaired the summary as the repair line asked, instead of writing the bad report again. So the job was accepted after one refusal, and the scorer was right to fail S4's checks.
  - Its HELD 1 now says the test needs a second refusal.
  - The cell was rerun in both modes with `RUN_SUFFIX=-rerun` (`logs/_sessions/b-build-rerun/`): PASS in the real run, red in the control.
  - The other eleven S4 cells passed in the main run unchanged.
- **No framework bug was found,** and no job needed a sealed folder.
- **Cleanup:** the skill links are removed, no process is left running, and no `index.lock` remains. The sandbox run folders are kept under `/Users/Shared/crucible-sandbox/stop-hook-matrix/`.
