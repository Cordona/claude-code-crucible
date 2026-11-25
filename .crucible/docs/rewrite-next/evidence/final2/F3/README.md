# F3, round 2: the location kinds, the forced park and the long suite

**Result: the bar is met.**
- The 15 location-kind runs: 15 submitted, 0 gave up, **13 accepted at the first stop** (the larger part), 2 repaired after one refusal.
- **Zero location refusals,** against 28 location lines in round 1, over the same kinds.
- **The forced 30 s limit works,** but the real agents still don't park: they wait for the backgrounded suite by reading its output, and report only what they saw finish.
- **The long 150 s suite is now run, not skipped,** by both the builder and the tester.

Claude Code 2.1.332, run 2026-11-25:
- Main is `claude -p --model sonnet --permission-mode default`, in the repo, with the narrow allow-list.
- Every job agent ran on `claude-opus-5-5`, checked per run from its transcript.
- The stubs are `evidence/final2/stub-bin`, first on PATH.
- No global git config, `gpgsign` false, never bypassed.

## Hashes (`hashes/`, all 8 setup and collect files)

| | |
|---|---|
| frozen (`../framework-hash.txt`) | `f71a00541cb850727fa31b8c82f665aab5c3cdd458e45e9a832209427acf2222` |
| `new-rewrite/`, at every setup and collect | the same |
| installed copy, and the same files at each link's target in `new-rewrite/` | `1cd013263e992aba2301722e865581cfdb0448bb18a9c9b21a124da86a950a06`, both, so the install is the frozen source |

## The 15 location-kind runs (`counts.md`, `score.txt`)

| Kind | Accepted at the first stop | Repaired after one refusal | Gave up |
|---|---|---|---|
| build | 3 | 0 | 0 |
| test | 3 | 0 | 0 |
| external-review | 3 | 0 | 0 |
| test-plan | 2 | 1 | 0 |
| test-plan-update | 2 | 1 | 0 |
| **total** | **13** | **2** | **0** |

Every check passes on all 15:
- outcome, Opus, the exact prompt, the frozen hash and install, no tracker call by the agent, and no refusal mentioning a length: 15 of 15 each;
- planted facts: 6 of 6;
- allowed gates run: 12 of 12;
- R3: 2 of 2;
- the R4 audit: 90 of 90.

The two refusals weren't about locations:
- test-plan-1: `support[0].what names T-5: say it in words`;
- test-plan-update-2: `untested[0].proof must be a test, a path:line, or unproven`.

Nothing is flagged: no line refused a kind twice.

## Locations, round 2 against round 1 (`lab/locations.sh`)

| Kind | Round 1: runs refused on a location / location lines / accepted first | Round 2: the same |
|---|---|---|
| build | 3 / 10 / 0 | **0 / 0 / 3** |
| test | 3 / 5 / 0 | **0 / 0 / 3** |
| external-review | 3 / 3 / 0 | **0 / 0 / 3** |
| test-plan | 2 / 8 / 1 | **0 / 0 / 2** |
| test-plan-update | 2 / 2 / 1 | **0 / 0 / 2** |

## The forced park (`parked.md`)

The settings: `BASH_MAX_TIMEOUT_MS=30000` in both the `--settings` env and the project settings, and a 60 s suite.
- **The limit is forced.** The agents asked for `timeout: 120000`, and the suite was still moved to the background at 30 s ("Command did not complete within its 30s timeout and was moved to the background").
- **No park.** Neither agent ended its turn. Each read the background task's output file again and again (the tester up to 7 times in a row) until `[exited with code 0]`, then went on.
- So there was no "write your report" refusal, and both were accepted at the first stop.
- **The reports are honest.** `test` pass was claimed only after the finished output was seen. The tester ran its three mutations the same way, each going red, then undone.
- **The trees** are clean after the submission.

## The long suite with the real limit

The settings: 2700000, and a 150 s suite.
- **long-build** ran the suite before and after (`test` pass, with lint and typecheck run). It was accepted at the first stop.
- **long-test** ran the suite five times (the baseline, the mutations, the final run): `test` pass, mutation pass. It was repaired after one refusal: it had put its report in its reply, and was refused with `write your report as one JSON object to …`.
- **Neither skipped the suite for its length.**

## Every FAIL in `score.txt`, with its diagnosis

None of the 11 is in a counted cell.
- **The parked expectation is missed in 4 cells.** The forced-park `parked-build` and `parked-test`, and the extra copies `extra-main-parked-*`, were accepted with no "write your report" refusal, because the agents wait actively rather than park (above).
- **`long-test`: `typecheck` reported `not_run` ("not applicable to sh").**
  - The tester's plugins (shell `SKILL.md` and the testing standard) carry no gate list, and it judged `sh -n` not to apply.
  - By the allowed-gates rule that is an allowed gate left unrun.
  - It is a tester-prose point, not a script fault.
- **`first-long-test`, 6 lines, a lab limit.**
  - The headless main had ended its turn. Claude Code's print mode stops background agents 10 minutes later ("Background tasks still running 10m after the last turn … stopping them"; debug `exitPath=cancelled`), so the tester was cancelled mid-suite.
  - No SubagentStop and no further Stop fired, so its job stays open: the audit's "every job ended or submitted" fails, as R5.2's dead-session limit says it will.
  - I reran it with `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` as `long-test`, which passed, apart from the typecheck point above.

## Lab notes

- **The main setup selected cells by kind,** so `build` and `test` also pulled in the parked and long cells. The main run ran them once more, with its settings (2700000, a 50-round suite). They are kept as `logs/extra-main-*` and not counted; all four submitted, with `test` pass.
- **Every cell's raw output is saved:** `logs/<cell>/`, with `logs/_sessions/<cell>[-suffix]/`.

## Hook cost (every run)

| Hook, tool | n | median | max |
|---|---|---|---|
| `job-agent-tools`, Write/Edit | 101 | 280 ms | 451 ms |
| `job-agent-tools`, Bash | 281 | 126 ms | 250 ms |
| `guard-framework`, Read | 136 | 89 ms | 122 ms |

**Sandbox state:**
- `/Users/Shared/crucible-sandbox/final2/real/` is kept: `run`, `run-p`, `run-l` and `run-l2`;
- the skill links and this run's trust entries are removed;
- no process is left.
