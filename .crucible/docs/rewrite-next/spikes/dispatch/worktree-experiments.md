# Worktree experiments: one page

2026-11-26. Every experiment about where a job agent works and why it wasted rounds. No spec written.

## The problem we started from

A job agent started in main's folder, not in its tree. To run anything it wrote `cd <tree> && …`; Claude Code asked permission, our hook refused it, and the agent retried. Final verification round 2: 30 refused commands.

## The experiments

| # | What we tried | Refused | Unanswered | What we learned |
|---|---|---|---|---|
| probes2 A | Baseline: agent in main's folder | 16 | 6 | Cause is `cd <tree> && git …` (Claude Code always asks for git after a cd) and chains |
| probes2 B/C | A prompt line ("each command alone, with the tree's path"), and a wider allow-list | 7 / 9 | 6 / 6 | Helps, noisy, not zero. Tree as a "working folder": no effect, idea closed |
| wt-probe | Claude Code's worktree option, our hook answers with our tree (1 stand-in) | 0 | 0 | Works: agent starts in our tree, plain commands, tree untouched. Hook refuses with a reason; without it Claude Code makes its own |
| wt2 run 1 | 12 agents started at once | n/a | n/a | 0 refused starts, 0 wrong trees; the job is tied to the agent before it exists; a failed start is ended automatically |
| wt2 run 2 | Real builder and tester in their trees | 17 | 8 | `cd` forms gone (10 → 0), but other chains, shell file writes and `/tmp` trials took their place |
| wt3 | + better prompt lines, allow-list of check commands, scratch folder | 16 | 5 | Every `cd` gone; scratch used, `/tmp` gone; what's left is three habits (below) |

All 6 real jobs in wt2 and wt3: accepted first time, trees intact (the job's commit, clean, nothing removed).

## What's decided (your decisions)

- Agents start in their own tree, through Claude Code's worktree option and our hook.
- Inside an open effort, a worktree only for a dispatched job; anything else refused with its reason.
- Outside an effort, a normal worktree; leftovers accepted, with a line saying where.
- Each job: the tree for code, the report in the effort, a scratch folder for trials.
- Reports stay in the effort (not committed, not git notes).

## What's left: 16 refusals, three habits

1. **`echo x=$?` without quotes (8).** Claude Code asks for an unquoted `$?` even when every command is allowed; `echo "x=$?"` passes. One habit.
2. **Inline trials in the scratch folder (3 + 4 unanswered):** `mkdir`, `touch`, `cp`, redirects. Running a trial script there already passes.
3. **Files written through the shell (5):** `cat > file <<EOF`, `python3 - <<EOF`. Always asks, even with `cat` allowed. The Write tool is the agent's own way.

## Open questions (not spec, for you)

- How to close the three habits: allow more commands in the scratch folder, or one prose line each (quote `$?`; write files with Write), or accept a few refusals.
- A real per-job allow-list: in the runs, one session held one job, so its settings were the job's. A session with several jobs needs a real way to give each job its own.

## Fable's view (reports/dispatch-wt3-fable.md)

The count isn't converging (16, 17, 16): each fix removes one habit and the next takes its place. All 18 real jobs were accepted first time anyway. Routes:
1. Fix each habit with prose: advised against (micromanaging, never finishes).
2. Accept about 3 recovered calls per job.
3. When Claude Code would ask for a job agent, a hook answers yes, except a short fixed list of forbidden commands (push, tracker tools, network). Fable's recommendation; your decision. Reason: the agent can already run anything by writing it into a script and running it, so the allow-list isn't a real boundary. Needs a small probe first.
4. Claude Code's Bash sandbox: the only real boundary; needs its own probe.

Per-job allow-list: not a real problem (one fixed pattern covers every scratch folder).

## Evidence

`spikes/dispatch/`: `probes2-results.md`, `wt-probe-results.md`, `wt2-results.md`, `wt3-results.md`; Fable's reviews in `reports/dispatch-*-fable.md`.
