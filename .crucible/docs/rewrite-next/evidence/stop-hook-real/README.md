# Stop-hook assurance, step 4: the real definitions (stopped before the counted runs)

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
