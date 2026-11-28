# Probes 2: wasted rounds and the attention line (design, for Fable)

2026-11-26. Two small probes after the dispatch spike. The owner said go. Concept facts only; spike-grade code; same sandbox and kit as `design.md`.

## P-A: zero refused `cd <tree> && …` commands

**Problem.** A job agent starts in main's folder, so it runs `cd <tree> && <check>`. That needs permission, the deny-compound hook refuses it, and the agent retries as single commands: 36 wasted rounds in final round 2. The owner's target is zero.

**Idea.** The tree is added to the session's working folders before the job starts, so `cd <tree>` needs no permission and each part of the command is checked on its own.

**Questions.**
1. With the tree as an extra working folder (settings `additionalDirectories`, or `--add-dir`), does `cd <tree> && sh tests/run.sh` run without a permission ask, in permission mode default, with the allow-list holding `Bash(sh tests/run.sh)`?
2. Can the folder be added mid-session, at dispatch time (the session's own settings file, or another route), or only at session start? Record each route tried.
3. Does the deny-compound hook still fire for anything in a normal builder and tester run on that tree?

**Run.** A real Opus builder and tester on a small shell repo (as in F3), permission mode default, headless, tree added as a working folder. Count the PermissionRequest events and the deny-compound refusals.
**Pass.** 0 refusals, and the checks run.

## P-B: which hook carries a one-line attention notice to main

**Need.** A script reads the log at main's stop, and when something new needs main (a job gave up, faulted, stalled, vanished, dispatched but never started; all reviews in), main gets one short line per item, once; otherwise nothing, zero tokens. Not an event (a view computed from events).

**Questions.**
1. Main's Stop hook: a block with the line makes main act at once. What happens when main was only waiting for the human: does the block force a turn the human didn't ask for? Record both cases.
2. When a background agent finishes while main is idle, what wakes main, and which hooks fire on that wake (UserPromptSubmit? another)? Can a hook add context there (additionalContext) so the line rides on that turn?
3. "Told once": the simplest way to not repeat a line (e.g. the line names the seq of the event it reports, and the script skips seqs it already reported, kept in a small file in the effort). Record whether a re-told line ever appears across 3 stops.

**Run.** Opus main, headless and one interactive, with stand-in agents (haiku): (a) a job that gives up while main waits on it; (b) three reviewers finishing while main is idle; (c) a dispatched job main never starts.
**Pass.** Each item reaches main exactly once, in the turn it matters; no line when nothing needs main; record which hook did it.

## Out of scope

The pulled state view (main's command for "where am I"), the gates, the dispatch spec.

## Questions for Fable

1. Are these the right two probes, and is anything missing to decide the spec?
2. Is "not an event, a pushed line plus a pulled view" the right shape?

## After Fable (`reports/dispatch-probes2-design-fable.md`)

Corrections applied; these override the sections above.

- **The count is 30, not 36** (37 asks, 30 refused by the hook, 7 plain commands unanswered). By form: 13 `cd <tree> && git …`, 12 `cd <tree> &&` another chain, 5 chains with no cd.
- **P-A redirected:** the space (holding every tree) was already an additional working folder in round 2, so the idea was in force. Instead:
  1. Cause, one small command per form, stand-in, the space as working folder, the round 2 allow-list: `cd <tree> && ls`; `cd <tree> && git status`; `cd <tree> && sh tests/run.sh`; each again with `; echo "t=$?"`. Record which ask and what Claude Code says.
  2. One run with the tree itself named as a working folder. If nothing changes, the idea is closed.
  3. One line in the built prompt (where the tree is; each command runs alone, with the tree's path), then the real builder and tester. Count asks by form, with and without the line.
  No hook that rewrites commands or works out allow rules itself. Adding a folder mid-session: record, second priority. The 7 plain commands are the per-job allow-list, for the talk.
- **P-B additions:**
  1. Start from what main's Stop already runs (three hooks); record what each tells main and the human now. The line is one more step beside them; no two tell the same thing.
  2. Time the script at a stop where nothing is new; read only this session's jobs.
  3. Case (b) interactively too.
  A block at Stop only where main can act now and the slip is its own (dispatched, never started). Record what main does on the earlier wakes for "all reviews in".
