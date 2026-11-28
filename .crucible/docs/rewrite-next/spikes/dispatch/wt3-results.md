# wt3: the allow-list run, agents in their trees (results)

2026-11-26, Claude Code 2.1.332, Opus main and agents (`claude-opus-5-5` per run), permission mode default, headless. Spike-grade. No specification written. Nothing in `new-rewrite/` changed (frozen hash `f71a0054…` at setup and collect; install = source). Nothing committed. Run on the owner's go; prompt lines approved by Fable.

## What was run

Real `code-builder` and `code-tester`, 3 builds and 3 tests (F3 cells), started in their trees exactly as wt2 run 2, plus:

- **Prompt lines** in place of the `Tree:` line:
  - "Your tree: you start in it. Run commands there, with relative paths."
  - "Scratch: <abs path>. Trial files go here, not in your tree; run them from your tree. Nothing here is handed in."
- **Scratch folder** per job: `<effort>/scratch/<job>/`, outside the tree. A kit wrapper around the real `job-agent-tools.sh` allows the job agent's Write/Edit there, and passes every other call to the real hook unchanged.
- **Per-job allow-list.**
  - **Delivered as:** static patterns in the session's `--settings` (`permissions.allow`), relative to the tree the agent starts in. The one per-job entry is `Bash(sh <this job's scratch>/*)`, written into that job's session settings. There is one session per job in this kit, so "per session" equals "per job" here.
  - **The list:** `sh tests/run.sh`, `sh tests/*`, `sh bin/*`, `shellcheck *`, `sh -n *`, `echo *`, `cat *`, `head *`, plain git reads (`git status|diff|log|show|ls-files|rev-parse|blame|merge-base *`). No `git -C`.
- **The tree hook:**
  - It has Fable's prompt_id check: the note records the PreToolUse `prompt_id`, and the tree hook sets aside notes from another turn.
  - A clash gives one reason to both starts.
  - "Inside an effort" means an open effort, one with no `effort.closed`.

## Result

All 6 handed in and were accepted at the first stop: 0 `job.refused`; `build.submitted` ×3, `test.submitted` ×3.

| Count | probes2 arm A | wt2 run 2 | **wt3** |
|---|---|---|---|
| Refused by the hook | 16 | 17 | **16** |
| Plain command, no answer | 6 | 8 | **5** |
| `cd T && git …` | 6 | 0 | **0** |
| Other `cd` chains | 4 | 2 | **0** |

By Fable's three causes (`evidence/wt3/asks.tsv`):

| Cause | Refused | Unanswered | What |
|---|---|---|---|
| 1. Checks, chained or on own files | 8 | 1 | **All 8 carry an unquoted `echo x=$?`** (e.g. `shellcheck … tests/lib.sh; echo rc=$?`, both parts allowed). The 1 unanswered is a tester's `git -C <T> status` |
| 2. Manual trial | 3 | 4 | Inline `S=<scratch>; mkdir …; touch …; sh bin/…` chains (2); `git show … > <scratch>/…` (1); `mkdir -p`, `touch` and `cp … <scratch>/` (4) |
| 3. Shell writes | 5 | 0 | `cat > file <<EOF` (1), `cat >> tests/… <<EOF` (2), `python3 - <<EOF` (2) |

## The cause of cause 1 (a quick probe, `evidence/wt3/qprobe/`)

Settings allowed `shellcheck *`, `echo *`, `sh tests/*` and `cat *`, with a haiku main, headless:

| Command | Asked |
|---|---|
| `shellcheck -V; echo rc=$?` | **yes** |
| `shellcheck -V; echo "rc=$?"` | no |
| `shellcheck -V; echo rc` | no |
| `sh tests/run.sh; echo rc=$?` | **yes** |
| `cat tests/run.sh; sh tests/run.sh` | no |
| `cat > tests/x.txt <<EOF …` | **yes** |

- **Chains of allowed commands pass.** The ask comes from the unquoted `$?`; the same line with `"rc=$?"` passes.
- **A heredoc write asks** even with `cat` allowed.

## Extra records (`evidence/wt3/extras.tsv`)

| Cell | Bash calls | `pwd` | Full tree path | `cd` | Write/Edit | Write/Edit denied |
|---|---|---|---|---|---|---|
| build-1 | 12 | 0 | 0 | 0 | 4 | 0 |
| build-2 | 10 | 0 | 1 | 0 | 4 | 0 |
| build-3 | 13 | 0 | 0 | 0 | 2 | 0 |
| test-1 | 13 | 0 | 2 | 1 | 8 | 0 |
| test-2 | 15 | 0 | 2 | 0 | 8 | 0 |
| test-3 | 16 | 0 | 0 | 0 | 8 | 0 |

- **Dropping the tree's path cost nothing:**
  - 0 `pwd` calls;
  - 0 Write/Edit failed or was denied;
  - every Write/Edit used a full path: the tree, the scratch folder or the report.
- **Full tree path or `cd`:**
  - 5 commands carried the tree's full path: build-2 ×1 (inside a `python3` heredoc), test-1 ×2 (`git -C <T> status`), test-2 ×2 (`cp <T>/bin/…` and a redirect into the scratch folder);
  - 1 `cd`, by test-1;
  - none from the prompt line.
- **Scratch worked when the agent wrote a file:**
  - build-1 and build-2 each Wrote `<scratch>/trial.sh`, then ran `sh <scratch>/trial.sh` with no ask;
  - 0 commands touched `/tmp`, against 2 `/tmp` trial scripts and 2 denied `/tmp` Writes in wt2;
  - inline trials (`mkdir`/`touch`/`cp` into the scratch folder) still asked, because only `sh <scratch>/*` is allowed.
- **`cat > file <<EOF` with `cat` allowed:** asked, every time (in the run and in the probe).
- **Tree integrity, all 6:**
  - HEAD equals the submission's commit;
  - the working tree is clean;
  - WorktreeRemove never fired;
  - no notes were left (0 stale, 0 collided, 0 waiting).

## What this says (facts, no spec)

1. **Cause 1 is one habit: an unquoted `$?`.** With the list as it was, those 8 calls ask only because of that habit; chains of allowed commands pass. Removing it needs either the agent quoting it (prose) or a rule that matches it. No rule tried here matched.
2. **Cause 2 halves when the agent Writes a trial script.** The scratch folder plus `sh <scratch>/*` covered it with no ask, and `/tmp` went to 0. Inline trials (mkdir, touch, cp into the scratch folder) are left: allowing those commands for paths in the scratch folder would cover the rest. Not tried.
3. **Cause 3 stays.** Heredoc writes ask whatever is allowed, so per Fable's plan this is the one clause per definition, to Fable first.
4. **The new prompt line removed the `cd <own tree>` habit:** 2 in wt2, 0 here.

## Kit bugs fixed

- **`waves` misread its count:** I passed `waves all 6`, so the count read "all". The loop wrote errors until I stopped it by its task ID. No agent had started; the runaway log was deleted and the run restarted with `waves 6`. That log (my own oversized tool output) had been saved under the session's tool-results folder in `~/.claude/projects/…`, and I deleted that copy too.
- **`count.sh`:** its path pattern was updated for this sandbox.

## Evidence

- `evidence/wt3/`: one folder per cell, with events, hooks, git.txt and the reports.
  - `asks.tsv`, `extras.tsv`, `qprobe/`;
  - the raw sub-agent transcripts under `*/transcripts/` are local only.
- **Kit:** `kit-wt3/` (run.sh, lab/scratch-tools.sh, agent-dispatch/ with the prompt_id check, count2.sh).

**Housekeeping:**
- The kit's skill links were removed from the sandbox config.
- No processes are left.
- The trust entries for the sandbox repo and the probe repo were added to the sandbox config's `.claude.json`; copies of the earlier file are at `pa/run/claude.json.before` and `qprobe/claude.json.before`.
