# F3: step 4 on the frozen framework (the real definitions, on Opus)

**Result: R1 met for the 33 counted runs: 33 submitted, 0 gave up, 17 accepted at the first stop, 16 repaired after one refusal.**
- Every planted fact is met, every allowed check is run, and no refusal mentions a length.
- **R3:** 16 of 16 refused-then-submitted jobs had no message from main between the refusal and the submission.
- **R4:** the audit passes on every cell.
- **The parked cases didn't park,** in five tries with real agents. No report claims an unfinished check passed. See `parked.md`.

Claude Code 2.1.332, run 2026-11-25:
- Main is `claude --model sonnet --permission-mode default`, started in the repo: headless `-p` for the counted and parked runs, in tmux for the interactive set.
- Every job agent ran on **`claude-opus-5-5`**, checked per run from its transcript (33 of 33, plus every extra cell).
- Never bypassed. No global git config (`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`), and `commit.gpgsign false`.

## Hashes (`hashes/`)

| | |
|---|---|
| frozen (`../framework-hash.txt`) | `e9e6a1d2184b0ae65eacad698aba1bc635cdbb2568ff144423c96f04fe5ddd81` |
| `new-rewrite/` at every setup and collect | the same, in all 8 files |
| installed copy, the files reached through the sandbox config's links | `7a2d326d9cfd492ef3a67d9fb0856106cc2490e751dc81428867b357f68e0384` |
| the same files at each link's target in `new-rewrite/` | the same `7a2d326d…`, so the install is the frozen source |

`run.sh setup` refuses to run unless `new-rewrite/` is the frozen hash and the installed hash equals the source hash. The scorer fails any cell whose run's setup or collect hash differs; none does.

## Counts (33 counted runs, `counts.md`)

| Kind | Accepted at the first stop | Repaired after one refusal | Gave up |
|---|---|---|---|
| build | 0 | 3 | 0 |
| build-fix | 3 | 0 | 0 |
| test-plan | 1 | 2 | 0 |
| test-plan-update | 1 | 2 | 0 |
| test | 0 | 3 | 0 |
| test-fix | 1 | 2 | 0 |
| review | 3 | 0 | 0 |
| re-review | 3 | 0 | 0 |
| test-plan-challenge | 3 | 0 | 0 |
| external-review | 0 | 3 | 0 |
| foreign-review | 2 | 1 | 0 |
| **total** | **17** | **16** | **0** |

No job ended on a second slip, and 16 of 33 needed a refusal. The plan's step-4 trigger for three tries isn't met.

## R1, R3 and R4 per counted cell (`score.txt`)

| Check | Result |
|---|---|
| outcome: accepted or repaired | 33 of 33 |
| planted facts: review ×3 and foreign-review ×3 have a finding in the file holding the bug; external-review ×3 judge the point hidden in a reply valid, with a finding in `bin/prune-backups.sh`; build-fix ×3 and test-fix ×3 commits touch their findings' code; test ×3 and test-fix ×3 commits add tests to `tests/test_*.sh` that run and pass (the commit copied out and `sh tests/run.sh` exit 0) | 21 of 21 |
| allowed gates (lint, typecheck, test) never reported `not_run` | 18 of 18 builder and tester jobs |
| no refusal line mentions a length | 33 of 33 |
| R3: no SendMessage from main between a refusal and the submission | 16 of 16 |
| no `gh` or `glab` call by the agent (from its own Bash calls, in its hook calls) | 33 of 33 |
| the agent got exactly the prepared prompt | 33 of 33 |
| the pin matches the report; the working commit with its `Job` trailer; no `job.stalled` | 33 of 33 |
| R4 audit: every job ended or submitted; every pin matches its hash; every working commit has its event; every refusal followed by a submission or an end; no job with more than two refusals | 198 of 198 |

**Every FAIL in `score.txt`** (10 lines, none in a counted cell):
- **The parked expectation, 8 cells:** "one refusal, write your report, then the submission". It is missed in every parked attempt, because no agent parked; see `parked.md`.
- **The allowed `test` gate reported `not_run`: 2 cells.**
  - These are `parked-build` and `parked-test` with the 150 s soak test.
  - Each agent judged the suite longer than its 120 s limit. It didn't run it, said so in the report, and wasn't refused.
  - That is honest, but by the check it is an allowed gate left unrun.

## The flagged refusal lines (2 of 3 runs or more)

Every line is a location or plan-scope slip; none is about a length:
- **build, 2 runs:** `decisions[N].at bin/prune-backups.sh <words> names no file in the tree`. The location is written as a path plus words.
- **test, 3 runs:** `decisions[N].at "tests/test_prune.sh: --pattern without a value is a usage error" is not a location`. A test is named in the `<file>: <test>` form, where a location is wanted.
- **test-plan, 2 runs:** `behaviours[N].at "bin/prune-backups.sh:N-N,N" is not a location`. The location is a comma list.
- **external-review, 3 runs:** `noticed[N].at description names no file in the tree`. The thread ID is used as a location for the instruction in the description.
- **test-fix, 2 runs:** `you changed tests/lib.sh, which isn't in the approved plan: undo it, or add a decisions entry…`. This is the planted trap: the third finding needs a file the plan doesn't name.

Every one was repaired in its run.

## Text lengths

`counts.md` has the spread per kind and field. The fields that run longest:
- test-plan-challenge `challenges[].why`: median 334, max 532;
- external-review `items[].reply`: median 370, max 446.

Summaries run 131–163 characters, cut into the working commit's subject. No refusal mentions a length.

## Hook cost

| Hook, tool | n | median | max |
|---|---|---|---|
| `job-agent-tools`, Write/Edit | 206 | 274 ms | 823 ms |
| `job-agent-tools`, Bash | 420 | 125 ms | 195 ms |
| `guard-framework`, Read | 188 | 87 ms | 164 ms |

These are over every run, with six headless sessions at a time. Writes are within about 0.3 s at the median; one outlier reached 0.8 s under that load.

## The PermissionRequest hook, live

- It refused **64 compound commands** at an ask in the 33 counted cells (95 over all 45 cells; counted by the reviewer from the saved hook calls; no scorer line prints it), with "Run it as plain single commands, one per call. Your other commands still run."
- No run stopped using Bash after a refusal: every builder and tester ran its allowed checks.

## Lab notes and reruns, said plainly

- **Extra headless runs.** The interactive cells (`i-build`, `i-review`, `i-parked-build`) were also in the headless cell list, so the first waves ran them headless as well. They are kept as `logs/headless-i-*` and are not counted. All three were submitted.
- **The parked cells, three attempts:**
  1. `first-parked-*`: the 30000 limit was only in the `--settings` env;
  2. `p30-parked-*`: the limit was in the project settings too;
  3. `parked-*`: a 150 s soak test.

  The details are in `parked.md`.

## Files

- `run.sh`, `score.sh` and `lab/` (`cells.sh`, `capture.sh`, `inject-prompt.sh`, `assign-job.sh`, `interactive.sh`);
- `fixtures/`;
- `prompts/`, every cell's prompt;
- `logs/<cell>/`, for every cell, green ones included: events, reports, git, hook calls, transcripts, models, the commit's numstat, and the commit's test run;
- `logs/_sessions/<cell>[-suffix]/`: main's stream or transcript, settings, the allow-list and the debug excerpt; for the interactive cells, `panes.txt` and `keys.txt`;
- `score.txt`, `counts.md`, `parked.md`, `interactive.md`;
- `hashes/`.

**The allow-list** passed with `--settings`; there are no Write or Edit rules:

```
Agent, ToolSearch,
Bash(sh tests/run.sh), Bash(sh */tests/run.sh), Bash(shellcheck *), Bash(sh -n *),
Bash(git -C * diff*), Bash(git -C * log*), Bash(git -C * show*), Bash(git -C * status*),
Bash(git -C * ls-files*), Bash(git -C * rev-parse*), Bash(git -C * blame*), Bash(git -C * merge-base*)
```

The tracker stubs are `evidence/final/stub-bin`, first on PATH for main and every agent.

**Sandbox state:**
- `/Users/Shared/crucible-sandbox/final/real/` is kept: `run`, `run-p`, `run-p2`, `run-i` and `run-ip`;
- the skill links are removed, and the trust entries this run added are removed;
- no process and no tmux session is left.
