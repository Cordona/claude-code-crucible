# F2: the stop-hook mechanism matrix on the frozen framework

**Result: 86 of 86 cells PASS, 884 checks, 0 FAIL** (`score.txt`). Every cell passed on its first run, with no rerun.

**Control run, done first: 86 of 86 cells red, each for the reason its scenario names** (`control-score.txt`): `cells red for the reason their scenario names: 86 of 86`, with every framework hook removed.

Claude Code 2.1.332, run 2026-11-25, sandbox `/Users/Shared/crucible-sandbox/final/matrix/`. Real Claude Code sub-agents (stand-ins on haiku), started in the background by headless main (sonnet).

## The hashes (`hashes-*.txt`, also in `logs/` and `logs/control/`)

| | control, setup | control, collect | real, setup | real, collect |
|---|---|---|---|---|
| frozen (`../framework-hash.txt`) | `e9e6a1d2184b0ae6…` | same | same | same |
| `new-rewrite/` | `e9e6a1d2184b0ae6…` | same | same | same |
| installed copy (every file through the config's skill links) | `7a2d326d9cfd492e…` | same | same | same |
| the source files those links reach | `7a2d326d9cfd492e…` | same | same | same |

- **How `new-rewrite/` is hashed:** the same way `framework-hash.txt` was, from the repository root: `find new-rewrite -type f | sort | xargs shasum -a 256 | shasum -a 256`.
- **Why the install is the frozen source:**
  - setup refuses to run unless `new-rewrite/` hashes to the frozen value;
  - every link is checked to point inside `new-rewrite/`;
  - the installed files and the source files they reach hash alike, at setup and at collect.
- **A changed hash voids the run:** `score.sh` checks all of this and fails the run if any hash differs.

## The layout
- **Main** starts in its batch's repo, in permission mode `default`. No bypass.
- **The trees and the reports** are in the space, outside the repo.
- **`--settings` carries:**
  - Bash allow rules only for the gate commands: `sh tests/run.sh`, `sh tests/slow.sh:*`, `sh tools/fmt.sh`, `sh tools/fmt.sh --undo`;
  - the read-only `git -C * status|diff|log|show*` forms;
  - Agent, SendMessage, TaskStop and ToolSearch;
  - the space in `additionalDirectories`, and the installer's `events/` deny rule.
- **There are no Write or Edit allow rules.**
- **The stubs:** stub `gh` and `glab` (`../stub-bin`) are first on PATH for main, its hooks and every agent. No tracker was called.
- **Git:** `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1` and `commit.gpgsign=false`; working commits are unsigned.
- **Install:**
  - the real `install-entries.sh`, its links made in the sandbox config only and removed after the run;
  - `install-check.out` shows only the expected two lines: the `CLAUDE.md` link, and `BASH_MAX_TIMEOUT_MS` set to 30000 on purpose for the parked-stop cells.

## Results

Each cell's raw evidence is in `logs/<scenario>-<kind>/`, and its control twin in `logs/control/<scenario>-<kind>/`. `—` means the plan doesn't assign that scenario to that kind.

| | build | build-fix | test-plan | test-plan-update | test | test-fix | review (cold) | review (hot) | re-review | test-plan-challenge | external-review | foreign-review |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| S1 accepted first time | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| S2 refused on its own rule, repaired | PASS | PASS | PASS | PASS | PASS | PASS | PASS | — | PASS | PASS | PASS | PASS |
| S3 wrong path | PASS | PASS | PASS | PASS | PASS | PASS | PASS | — | — | PASS | PASS | PASS |
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
| S13 the background deny | PASS | — | — | — | — | — | — | — | — | — | — | — |
| S14 a Write into the repo | PASS | — | — | — | — | — | — | — | — | — | — | — |
| S15 a compound command at an ask | — | — | — | — | — | — | PASS | — | — | — | — | — |

- **S2, build:** with no length rule left, the build's own rule is now a prefixed summary. `feat: echo the upload target` was refused with `summary starts with "feat:": drop the prefix; the commit adds its own`, then accepted.
- **S15:** `cd <tree> && git status` reached an ask. The real PermissionRequest hook `deny-compound-commands.sh` denied it with `Run it as plain single commands, one per call. Your other commands still run.` The agent reran `git -C <tree> status`, which ran with no ask, and submitted.
- **S14:** the Write to `<repo>/notes.txt` was denied by write-scope (`Write only in <tree> and to your report …`). The agent wrote `<tree>/notes.txt` instead, which is in the working commit, and the repo's `git status` is empty.
- **R3:** no SendMessage from main reached the agent between a `job.refused` and its submission. That holds in all 47 cells with a refusal followed by a submission, and for all 12 jobs of S9.
- **No refusal about a length anywhere.** No `job.refused` line mentions characters or shortening.
- **The read guard denied no call, so no job needed a sealed folder.**
- **The audit passes on every cell:**
  - each job has exactly one ending or a submission;
  - `job.stalled` appears only in S5b;
  - every pin matches its report;
  - every working commit has its event;
  - every refusal is followed by a submission or an end;
  - no job has more than two refusals.

## The control run (`control-score.txt`)
- **What was removed:** every framework hook: the stop hook, the job-agent tools wrapper, the PermissionRequest hook, main's Stop hook, the read guard, and the gate and flow hooks. Only the lab's capture, observe and assign hooks stayed.
- **The result:** each cell has a line `RED for its reason: <cell>: <the failed check>`. The key check its scenario is about failed in each, for example:

| Scenario | Why it is red |
|---|---|
| S1 | no submission |
| S2, S3, S6, S7, S8, S11 | no `job.refused` with the scenario's line |
| S4 | no two refusals |
| S5a | no `job.ended` fault |
| S5b | no `job.stalled` |
| S9 | no refusals |
| S10 | the human not told |
| S12 | no `job.ended no-stop` |
| S13 | no background deny |
| S14 | no write-scope refusal |
| S15 | no PermissionRequest deny |

## Hook cost per job-agent call (`score.txt`, "hook cost")

Each figure is from the saved calls' start and end times, under load: up to three sessions of about twelve agents at once.

| Hook, tool | n | median | p90 | max |
|---|---|---|---|---|
| `job-agent-tools.sh`, Bash (background deny, timeout) | 34 | 128 ms | 406 ms | 428 ms |
| `job-agent-tools.sh`, Write (write-scope) | 189 | 725 ms | 1588 ms | 2044 ms |
| `job-agent-tools.sh`, Edit (write-scope) | 17 | 810 ms | 1690 ms | 2001 ms |
| `guard-framework.sh`, Bash (direct event write, sealed reads) | 34 | 105 ms | 353 ms | 394 ms |
| `guard-framework.sh`, Read (sealed reads) | 124 | 98 ms | 202 ms | 341 ms |
| `deny-compound-commands.sh`, Bash at an ask | 1 | 472 ms | | |

The write-scope step is over a second at p90, so it is the first place to optimise.

## Evidence
Every cell's raw output is kept, green or red, in both runs:
- `events.json`;
- `reports/`;
- `git.txt`, the trees' log and status, and the repo's status;
- `hooks/`, every hook call of the cell's agents, input and output;
- `transcripts/`, each agent's own transcript, kept for sampling; the scorer reads none;
- the recipes and prompts;
- for S5b, `recover.out`.

Beside them:
- `logs/_sessions/<batch>/` holds main's stream, prompt, settings and every hook call;
- `logs/control/` holds the same for the control run.

The scripts:
- `run.sh all control`, then `run.sh all real`, ran everything. `run.sh` also has `setup`, `batch`, `waves`, `s5a`, `post`, `collect` and `RUN_SUFFIX` reruns.
- `score.sh real|control` reads only the saved evidence: events, reports, git and hook calls.
- `lab/` holds the stand-ins (`agents/`), the fixtures and recipes (`cells.sh`), and `capture.sh`, `assign-job.sh` and `observe.sh`.

## Notes
- **Lab changes from the earlier matrix:**
  - the build's S2 and S4 rule is now the summary prefix;
  - S15 now goes through the PermissionRequest hook;
  - recipe notes are on their own lines;
  - each cell keeps its agents' transcripts;
  - the hashes are as above.
- **One trial before the clean runs:** 4 cells, discarded. It found and fixed two lab issues: the links weren't made for a suffix run, and an empty installed-copy hash passed.
- **No framework bug, no stand-in failure, no rerun.**
- **Cleanup:** the skill links are removed, no process is left running, and no `index.lock` remains. The sandbox run folders are kept.
