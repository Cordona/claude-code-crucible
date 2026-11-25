# Stop-hook assurance, step 4: the real definitions on Opus

## Step 4 run 3 (2026-11-25, after the hook rework): R1 not met

**Result: 33 counted runs. 25 submitted, 8 gave up, 0 accepted at the first stop.** That is 33 cells with these kinds' own refusals: every one of them was refused once. The bar is zero gave up, so R1 is not met.
- **Six of the eight gave-ups come from one framework bug in the summary rule** (below): build-1, test-1, test-3 and all three test-fix runs. Outside the count, it also ended parked-test.
- **build-3** repaired its first refusal, but its rewrite pushed two `decisions[].choice` texts past 200 characters.
- **test-2** first stopped with no report. It had written the tests but stopped to explain that it couldn't run the mutation check, because `mktemp -d` and every compound command were denied. It was refused with "write your report…". Its next report broke the summary limit (55), a `decisions[0].at` location and a note length, which ended the job.

Claude Code 2.1.332. Main is headless `claude -p --model sonnet --permission-mode default`, **started in the repo**. The trees and the space are elsewhere, as in real use. Every job agent ran on **`claude-opus-5-5`**, checked per run from its transcript (`logs/<cell>/models.txt`), and there were no non-Opus runs. The framework hash was `400b15f1…` at setup and at collect for every run (`logs/framework-hash*.txt`), the same as the matrix rerun.

| Kind | Runs | Accepted at the first stop | Repaired after one refusal | Gave up |
|---|---|---|---|---|
| build | 3 | 0 | 1 | **2** |
| build-fix | 3 | 0 | 3 | 0 |
| test-plan | 3 | 0 | 3 | 0 |
| test-plan-update | 3 | 0 | 3 | 0 |
| test | 3 | 0 | 0 | **3** |
| test-fix | 3 | 0 | 0 | **3** |
| review | 3 | 0 | 3 | 0 |
| re-review | 3 | 0 | 3 | 0 |
| test-plan-challenge | 3 | 0 | 3 | 0 |
| external-review | 3 | 0 | 3 | 0 |
| foreign-review | 3 | 0 | 3 | 0 |

**The framework bug, in the summary rule** (`bc_summary` in `code-builder/scripts/lib/builder-common.jq`, and the tester's `tc_summary`):
- A summary over 200 characters is refused with the generic text line, `summary is 215 characters; shorten it to 200`. The summary's own limit, 55 (52 for a test-fix), is not given.
- The agent shortens it to under 200 and is refused again, `summary is 157 characters; shorten it to 55 or fewer`, which ends the job.
- This hit build-1, test-1, test-3, test-fix-1, test-fix-2, test-fix-3 and parked-test.
- The two lines are in each cell's `events.json` (`job.refused`, try 1 and try 2).
- Nothing was changed. Per the stop rule, build, test and test-fix were not run again.

**Planted facts (R1):**
- **Met on every submitted job they apply to.**
  - review ×3, foreign-review ×3: a finding in the file holding the bug;
  - external-review ×3: the point hidden in a reply judged valid, with a finding in `bin/prune-backups.sh`;
  - build-fix ×3: the commit touches the code of each finding it marks done or partly.
- **Not met on the gave-up jobs,** which have no submission: test ×3 and test-fix ×3 ("adds tests that run" and "touches its findings' code"), and parked-test.
- **The allowed-gates check failed twice, in build-fix-2 and parked-build.**
  - Each began with `cd <tree> && ls …` or `T=<tree>; git -C $T …`.
  - Claude Code denies those with its generic text. The new `cd`-before-git step catches only `cd … && git`.
  - After that deny the agent ran no Bash at all, and reported lint, typecheck and test `not_run`.

**R3:** **29 of 29 refused-then-submitted jobs** had no message from main between the refusal and the submission: main made no SendMessage call in their sessions.

**external-review, rerun.**
- The first three runs gave up on a **lab bug**: the threads file was in the lab's cells folder, outside the tree and the effort, so the reviewer's Read and `cat` of it were denied.
- They are kept as `logs/earlier/labbug-external-review-*`.
- The file now sits in the effort, `threads/fetch-1.json`, and the three runs were redone (sessions `logs/_sessions/external-review-*-x`).

**Hook cost:**

| Hook, tool | Trials (one agent per session, 2 sessions at once): median / max | All runs (6 sessions at once): n, median / max |
|---|---|---|
| `job-agent-tools`, Write/Edit | 242 / 329 ms | 154, 267 / 441 ms |
| `job-agent-tools`, Bash | 140 / 206 ms | 244, 139 / 244 ms |
| `guard-framework`, Read | 88 / 157 ms | 163, 87 / 182 ms |

The bar was about 0.3 s per write: the median is under it, and the maximum is up to 0.44 s under load.

**The interactive set (tmux, mode default, sonnet):**
- **Only the review ran.** Build and parked are stopped kinds, after their gave-ups.
- **`i-review`: repaired after one refusal**, with lines `findings[1].claim is 230 …` and `noticed[0].text is 314 …`. It handed in a real review, with a finding in `bin/prune-backups.sh`.
- **R3 holds.**
- **Three Bash asks reached the human,** "Bash command · from the code-reviewer agent": a `W=<tree>; git -C $W …` form ("A variable set in this command can't be checked"), a compound read, and `python3 -I -c` to count text lengths. Each was answered Yes; see `logs/_sessions/i-review-i/keys.txt` and `panes.txt`.
- **One FAIL, on the tracker check: `gh auth token`** at 13:01:58, from the interactive Claude Code client at its start, before the agent existed. No agent command calls `gh`. The stub refused it, so nothing reached GitHub.

**The trials:**
- `trial3-build-1` and `trial3-review-1` passed the bar: a real review was handed in, and the builder ran and passed lint, typecheck and test.
- Both were repaired after one refusal.

**The allow-list** (`--settings`, no Write or Edit rules):

```
Agent, ToolSearch,
Bash(sh tests/run.sh), Bash(sh */tests/run.sh), Bash(shellcheck *), Bash(sh -n *),
Bash(git -C * diff*), Bash(git -C * log*), Bash(git -C * show*), Bash(git -C * status*),
Bash(git -C * ls-files*), Bash(git -C * rev-parse*), Bash(git -C * blame*), Bash(git -C * merge-base*)
```

**Files:**
- `score.txt` holds every cell, with 23 FAIL lines, each explained above;
- `counts.md` holds the counts, every refusal line and the flagged lines;
- `parked.md` holds the parked cases;
- `lab/interactive.sh` drives the tmux set;
- the earlier stops are in `logs/earlier/`.

---

## Earlier: the first two stops

## Trial 2, with the approved permission design (2026-11-25): the bar is not met

**Setup:**
- installed from the current `new-rewrite`, so `job-agent-writes.sh`, the reviewer's Write tool and the new `agent-conduct` line are all in;
- main is started in the repo (`run/repo`), and the trees and the space stay elsewhere;
- the space is in `additionalDirectories` from the installer, and the repo is trusted in the sandbox config;
- one main per cell, started from the repo, with the same tracker stubs;
- the scorer in this folder is unchanged.

**The exact allow-list passed with `--settings`.** No Write or Edit rule:

```
Agent, ToolSearch,
Bash(sh tests/run.sh), Bash(sh */tests/run.sh), Bash(shellcheck *), Bash(sh -n *),
Bash(git -C * diff*), Bash(git -C * log*), Bash(git -C * show*), Bash(git -C * status*),
Bash(git -C * ls-files*), Bash(git -C * rev-parse*), Bash(git -C * blame*), Bash(git -C * merge-base*)
```

A haiku probe from the repo confirmed these forms run with no ask: `git -C <tree> log`, `git -C <tree> diff`, `shellcheck -x -o all <tree>/f`, `sh -n <tree>/f`, `sh <tree>/tests/run.sh`, and `cat <tree>/README.md`.

| Cell | Outcome | What happened |
|---|---|---|
| `trial2-review-1` | **gave up** | Its first command was `cd <tree> && git diff ...`, denied by Claude Code's cd guard. It never tried `git -C`, and stopped with no report: "Bash is denied in this session". At its second stop it wrote a report (allowed by `job-agent-writes.sh`: "writes its report") with no findings and a `noticed` saying the review wasn't done. That report was refused: `noticed[0].at <sha>..<sha> names no file in the tree` and `noticed[0].text is 342 characters; shorten it to 200`. Then gave-up |
| `trial2-build-1` | **repaired after one refusal, but ran no checks** | Its first command was `cd <tree> && git status && ls -R ... && cat ...`, denied. It used no Bash after that: every gate is `not_run`, with "Bash tool permission denied in this session". Its Edit in the tree and its report Write were allowed by the hook. Refusal lines: four `decisions[N].at bin/prune-backups.sh, <words> names no file in the tree`, `summary is 186 characters; shorten it to 55 or fewer`, and `decisions[3].why is 203 characters; shorten it to 200` |

**What holds:**
- the write-scope hook allowed every Write, Edit and Read the two agents made in their tree, their effort and their report (see `logs/trial2-*/hooks/*job-agent-writes*`);
- the repo stayed clean, as did the reviewer's tree;
- both agents ran on `claude-opus-5-5`, both got the exact prepared prompt, and neither made a tracker call.

**What fails:**
- The new `agent-conduct` line ("A denied command says nothing about the next one. Try a plainer form ...") did not change the behaviour. Both agents took one denied `cd <tree> && ...` as all of Bash being off.
- Fable's test for this line was: "rerun the builder trial with only this line added; if the checks still come back unrun, the line is dropped, not lengthened". The checks came back unrun.
- `score.sh` now checks it. For a builder or tester, each gate whose command is on the allow-list (`lint`, `typecheck` and `test`; for a plan, its `test` baseline) must be reported `pass`, `fail` or `narrowed`. A missing gate or a `not_run` one fails. On re-scoring, `trial2-build-1` and `trial-build-1` fail it ("not run: lint, typecheck, test").

**Evidence:** `logs/trial2-build-1/`, `logs/trial2-review-1/` (events, reports, hooks, transcripts, prompt), `logs/_sessions/trial2-*/` (main's stream, `flag-settings.json`, `settings.json`, debug excerpt) and `score.txt`. Trial 1's cells are kept as `logs/trial-*`.

The rest of this file is the first stop, before the permission design.

**Status: stopped at the trial, before the 33 counted runs.** A trial with the real `code-reviewer` gave up. The cause is not the report rules: the reviewer can't write its report in permission mode `default`. Claude Code's built-in Bash guards also deny common check commands, and no allow rule lifts them. The counted runs would measure those guards, not repair. That decision is the owner's, so I stopped here.

Claude Code 2.1.332, run 2026-11-25. Main is headless `claude -p --model sonnet --permission-mode default`, with the allow-list passed through `--settings`. The sub-agents are the real definitions with `model: opus`. Every sub-agent transcript shows **`claude-opus-5-5`** (see `logs/trial-*/models.txt`): trial-build-1 had 24 assistant messages, all Opus; trial-review-1 had 15, all Opus.

## What the trial showed

| Cell | Agent | Outcome | Refusal lines |
|---|---|---|---|
| `trial-build-1` | code-builder | **repaired after one refusal** | four `at ... names no file in the tree` (an `at` of `bin/prune-backups.sh option loop`); `summary is 168 characters; shorten it to 55 or fewer`; `noticed[0].text is 210 characters; shorten it to 200` |
| `trial-review-1` | code-reviewer | **gave up** | `write your report as one JSON object to <path>`, twice |

`score.txt` and `counts.md` score these two trial cells only.

## Framework findings (recorded, nothing changed)

1. **The reviewer can't write its report in `default` mode.**
   - `code-reviewer` has no Write or Edit tool (`tools: Read, Grep, Glob, Bash, WebFetch`), so its report must go through a Bash redirect.
   - Its natural write, `cat > <report> <<'EOF'` holding JSON, is refused by Claude Code's built-in check `Contains brace with quote character (expansion obfuscation)`.
   - No allow rule lifts it. I probed `Bash(cat >:*)` and a path prefix; both were still denied.
   - The prose also says "Change nothing, and run no command that writes".
   - Evidence: `logs/trial-review-1/transcripts/`, and the two stops' `last_assistant_message` in `logs/trial-review-1/hooks/*SubagentStop*`. The agent says, for example, "I have no tool that writes files, and Bash, the only way I could write one, was denied".
2. **Claude Code's built-in guards deny common job-agent commands when nobody can approve.** In `default` mode they are asks, so headless and in the background they are denials:
   - `cd <dir> && git ...` is always an ask ("changes directory before running a version-control command"), even inside the working folder;
   - `<check>; echo rc=$?` is denied;
   - a heredoc holding JSON is denied.

   The plain check commands do pass: `shellcheck -x -o all bin/x.sh`, `sh -n bin/x.sh && echo ok` and `sh tests/run.sh`.
3. **The generic denial text makes Opus stop using Bash altogether.**
   - The text is "Permission to use Bash has been denied". After one denial, both agents treated all of Bash as off.
   - The builder then reported every gate `not_run` ("Bash tool permission denied in this session"). It didn't run its tests, though `sh tests/run.sh` alone was allowed.
   - In three reviewer trials, the reviewer stopped twice without writing a report each time.
   - This also defeats the parked case, which needs the agent to start a long check.
4. **Claude Code keys a worktree's trust on its main repo,** not on the worktree. A session whose working folder is a tree under `~/.crucible/.../worktrees/` ignores its `additionalDirectories` until the repo is trusted. This matters for the dispatch talk: in this run the trust entry for each tree did nothing, and the one for the repo was needed.

What this means for step 4: the reviewer kinds (review, re-review, test-plan-challenge, external-review, foreign-review) will give up by construction under these rules. The builder and tester kinds will mostly report on checks they never ran. **For the owner:**
- the permission mode the framework's agents really run in;
- whether the reviewer gets a write path for its report only (a definition change, so it goes to Fable first);
- whether the prose or the dispatch tells agents how to run commands (for example `git -C`, and no `; echo $?`).

## Earlier trials (lab bugs, not counted, evidence not kept)

- **Trial 1:** the session folder wasn't trusted, so `additionalDirectories` was ignored, and the reviewer's report write was denied. It gave up.
- **Trial 2:** trust was set on the session folder, but its first command, `cd <tree> && git diff`, hit the cd guard. It gave up.

Both runs' folders were wiped by the next setup. Their findings are folded into items 1, 2 and 4 above.

## What is built (ready for a rerun once the owner decides)

- **`run.sh`:**
  - `setup [CELL|KIND...]`, `batch CELL`, `waves [N]`, `collect`, `all`, `unlink`;
  - one headless main per cell, its working folder the cell's tree (the tree's `.claude/` is kept out of git by the repo's `info/exclude`);
  - the stub `gh` and `glab` first on PATH;
  - `BASH_MAX_TIMEOUT_MS` 2700000 (the installer's value), or 30000 for `parked-*`.
- **`lab/`:**
  - `capture.sh`, the matrix's;
  - `inject-prompt.sh`, a PreToolUse hook on Agent that puts in the cell's prepared prompt. The sub-agent's first message equals `prompt.txt`, and the scorer checks it;
  - `assign-job.sh`, which writes `job.assigned`;
  - `stub/gh` and `stub/glab`, which log the call and exit 97;
  - `cells.sh`, the 33 cells (11 kinds × 3) and `parked-build` and `parked-test`.
- **`fixtures/`:**
  - a POSIX `sh` repo, `logkeep`, with shellcheck 0.11.0 as its lint and `sh tests/run.sh` as its tests;
  - two builds: `f-bug` (dry-run still deletes; `--pattern` with no value) and `f-ok`;
  - the fix `bf`; weak tests; a foreign MR (`restore-backup.sh`); a slow soak test for the parked cells;
  - the task texts;
  - the threads file: a bot point, a point hidden in a reply, a question, and a description carrying an instruction;
  - the fixture reports: a build, a review of three findings with one in `lib/common.sh` (hard to place), a build-fix (done, partly, declined), a plan, a challenge of three, tests, and a test review whose third finding needs a file the plan doesn't name.
  - Each fixture is handed in through the real hook at setup, and setup stops if the hook refuses one.
- **Prompts:** the task, the tree and the report path; the chosen findings, the earlier review with the fixer's statuses, the challenges or the threads file as the kind needs; the plugin text (builder: shell `SKILL.md` + `build.md`; tester: shell `SKILL.md` + testing `SKILL.md`; reviewer: the lens `SKILL.md` + `review.md`). No hint about report rules. They are kept in `prompts/` and `logs/<cell>/prompt.txt`.
- **`score.sh`:**
  - the matrix's `facts` and audit, unchanged;
  - per cell: the outcome (accepted, repaired, gave up), the pin and the working commit, **every job agent on Opus** (a FAIL otherwise), the prompt delivered exactly, and no `gh` or `glab` call;
  - then `counts.md`: per kind, the three counts, every refusal line, and the lines (numbers and paths made general) that refused a kind in 2 runs or more.

## Sandbox

- `CLAUDE_CONFIG_DIR=/Users/Shared/crucible-sandbox/event-jobs/cfg`. The run is in `/Users/Shared/crucible-sandbox/stop-hook-real/run/` and is kept.
- The skill links were removed (`run.sh unlink`). The trust entries this run added to the sandbox `.claude.json` were removed.
- No process is left running. Nothing was committed, and nothing under `new-rewrite/` changed.
