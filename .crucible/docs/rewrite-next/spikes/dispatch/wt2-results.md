# wt2: twelve starts and real agents in their trees (results)

2026-11-26, Claude Code 2.1.332, Opus main, permission mode default. Spike-grade; nothing in `new-rewrite/` changed; nothing committed. Asked by Fable (`reports/dispatch-wt-probe-fable.md`), run on the owner's go.

## The owner's decision (recorded)

Inside an effort, the worktree hook gives a worktree only to a dispatched job (its main-cut tree) and refuses any other request with a reason. Outside an effort it makes one the way Claude Code would: `<repo>/.claude/worktrees/<name>` on branch `worktree-<name>`.

## The mechanism as built

- The guard's swap step adds `isolation: "worktree"` and leaves one note for the session, `{effort, job, tree}` (`job-note.sh`).
- `WorktreeCreate` (`give-tree.sh`):
  - exactly one note: take it, write `job.assigned` (agent id from `name: "agent-<id>"`) through `job-assign.sh`, print the tree;
  - more than one: refuse and clear the notes;
  - none inside an effort: refuse;
  - none outside: the Claude Code default (`steps/default-tree.sh`).
- `job-assign.sh` is the one writer of the assignment. It is called by the tree hook for a cold start, and after a SendMessage for a hot one. There is no PostToolUse assignment for cold starts.

## Run 1: twelve starts in one message (stand-ins, the real installed hooks)

| Count | Result |
|---|---|
| Starts refused | **0 of 12** |
| Agents in a tree not their job's | **0**: 12 of 12 SubagentStart `cwd` values, and all 24 agent tool calls, in the job's own tree |
| Assignments written | 12, each before its agent's SubagentStart |
| Reports handed in | 12 `echo.submitted` |
| Asks | 0 |

**Order.** Each call ran its guard, then its own WorktreeCreate, then the next call's guard, for all 12. The hooks overlap: the next guard starts 1 to 250 ms after the previous WorktreeCreate starts. The tree hook reads the notes at its start, and the next guard writes its note at its own end. The margin between them was **0.36 to 0.82 s** (minimum at calls 14→15 and 19→20). It is a margin, not a guarantee; if it is ever lost, the start is refused with a reason (the "more than one note" branch), never silently mispaired. Timings: `evidence/wt2/run1/r1-twelve/hooks/`.

**Three reviewers on one tree** (r1-shared): three jobs on tree t2, started in one message. The hook answered t2 three times; all started, ran and handed in. A shared read tree works.

**A start failing after its assignment** (r1-fail, forced by `SPIKE_FAIL_AFTER_ASSIGN`):
- the tree hook wrote `job.assigned` (seq 51), then exited 1;
- main saw "start of job 50 failed after its assignment";
- at main's stop, `end-gone-jobs` wrote `job.ended {reason: no-stop}` (seq 52), with `background_tasks: []`.

**The owner's policy, checked once each:**
- **Inside an effort:** a general-purpose agent with isolation was refused, and main reported the reason verbatim: "Inside an effort, worktrees come only from a dispatched job: …".
- **Outside any effort:** the default made `repo/.claude/worktrees/agent-<id>` on `worktree-agent-<id>`, and the agent's `pwd` was that folder. Claude Code does **not** remove a hook-made default afterwards: it was still there, and WorktreeRemove didn't fire. Claude Code's own default removes its clean worktrees, so ours would need its own cleanup to match.

## Run 2: the real Opus builder and tester started in their trees

Setup: 3 builds and 3 tests, F3 cells, no prompt line, the round-2 allow-list, the same as probes 2's arm A except for the start folder.

| Form | Arm A (main's folder) | wt2 (own tree) |
|---|---|---|
| `cd T && git …` refused | 6 | **0** |
| `cd T &&` other chain refused | 4 | 2 (`cd <own tree>; …`, a habit from the prompt naming the tree) |
| Chain with no `cd` refused | 6 | **15** |
| **Refused by the hook** | **16** | **17** |
| Plain command, no answer | 6 | 8 |

All 6 were accepted at the first stop: 0 refusals, `build.submitted` ×3 and `test.submitted` ×3.

**What's left (`evidence/wt2/run2/asks.tsv`):**
- **Chained checks:** several checks in one call with `; echo x=$?` (6), or `| head`. In arm A the same checks came prefixed with `cd T &&`.
- **File writes through Bash:** `cat > file <<EOF` and `python3 - <<EOF` (4).
- **Manual trials:** `d=$(mktemp -d) && for …` (3).
- **Plain commands not on the list:** `sh tests/test_prune.sh` (3), the changed script's `--help` (2), `/tmp` trial scripts (2), and `mktemp -d`.

So starting in the tree removes the cd forms, as expected, but not the chaining: the total is unchanged on this sample. The cd prefix was a symptom of where the agent started; the chaining habit is its own cause.

**Tree integrity, all 6:**
- HEAD equals the job's submission commit;
- the working tree is clean, on the same `crucible/<effort>/j` branch;
- WorktreeCreate fired once and WorktreeRemove never;
- every agent tool call ran in its own tree.

## Kinds with no tree

None. `job.dispatched` requires an absolute `tree` for every kind. Reviewers read the builder's tree, and a foreign review reads a tree of the fetched MR. So every kind can be started this way. Several reviewers sharing one tree works (r1-shared). Agents writing one tree at the same time (a hot builder while reviewers read) is a dispatch rule to state, not a hook matter.

## Kit bugs fixed

- `capture.sh` swallowed a hook's stderr, so a refusal's reason would never have reached main. It now passes stderr through.
- Pre-dispatching by hand needed the settings' plugin folders in the environment. The dispatch's first 12 calls failed on `PLUGINS_LANGUAGES` unbound and were rerun.
- `count.sh` path pattern updated for the new sandbox.

## What changes the design

1. **Keep the tree start:** it removed the cd forms, and assignment is now by construction (one note, one tree hook, one assign writer).
2. **The notes' margin depends on where the guard writes the note.** It must stay the guard's last act. State it in the spec, with the fail-loud branch.
3. **Zero refusals needs more than the start folder.** In the tree, a chain's parts are plain commands, so an allow-list with the agents' check commands (shellcheck, `sh -n`, `sh tests/*.sh`, `echo`, `cat`, `head`) would likely let most chains through with no ask. This is untested; it is the per-job allow-list talk, now measurable in one run. File writes through Bash heredocs are prose-shaped (the agent has Write and Edit).
4. **The outside-effort default needs a cleanup step,** or Claude Code's own default stays unmatched.
5. **The prompt line from probes 2 stays dropped,** but the prompt's "Tree:" line led two agents to `cd` into their own folder. Saying "you start in your tree" may remove that.

## Evidence

- **Run 1:** `evidence/wt2/run1/`, with r1-twelve, r1-fail, r1-outside, r1-shared, events.json, settings.json and worktrees-after.txt.
- **Run 2:** `evidence/wt2/run2/`, the cells with their hooks, events, git.txt and asks.tsv. The raw sub-agent transcripts under `*/transcripts/` are local only.
- **Kits:** `kit-wt2/` (run 1) and `kit-wt2pa/` (run 2).

**Housekeeping:**
- The kit skill links were removed from the sandbox config.
- The setup's trust entry for each sandbox repo was added to the sandbox config's `.claude.json`; the earlier copies are at `run/claude.json.before`.
