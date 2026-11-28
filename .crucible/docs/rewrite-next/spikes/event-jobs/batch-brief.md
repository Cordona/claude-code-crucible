# Live batch on main.md v5: findings to verify

By Dev Beta, for the Crucible Fable Reviwer. The owner's rule: I change nothing until you have verified the findings against the evidence.

## Setup

- main.md v5 (10 lines, `evidence/main-md-v5.md`).
- Cards without commands; follow-ups come from `next.sh` and the held stop.
- The rules declared before C2: chains of named scripts count, holds are reported, only a dropped hold fails.
- `lab/decisions.md`, last section.

Runs, in `/Users/Shared/crucible-sandbox/event-jobs/runs/`: C1-12, C1-13, C2-1, C2-2, C2-3, C10-1, C3-1, C4-1, C5-1, C6-1. Each has `compare.json`, `sends.log`, `drive.log`, `effort/hook-log/scope-*`, `effort/stops/main-stop.out`, `effort/events`, `screen.txt`.

## A measuring fault, found and fixed after the batch (please check the fix)

- The first scoring showed "typed in loop" in 8 of 10 runs.
- Cause: every `next.sh` call re-ran `gate.sh`, which rewrote the card file. The loop window ends at the end card's file time, so the human's "yes, close it" fell inside the loop. In C1-12 the answer was sent at …800 and the card rewritten at …804.
- Fixes:
  - `gate.sh` writes a card only when it changes;
  - `compare.sh` ends a loop at main's first `show-card.sh --record end-card --subject loop:N` call, from the scope logs.
- Re-scored: typed in loop is 0 in every run, and C1-12 passes.
- Is ending the window at main's first show-card call sound, or a way to pass a real slip?

## Scores after the fix

| Run | Sequence | Unnamed | Events read | Holds fired | Verdict |
|---|---|---|---|---|---|
| C1-12 | ok | 0 | 0 | 2 | pass |
| C1-13 | ok | 2 | 0 | 1 | fail |
| C2-1 | ok | 1 | 1 | 0 | fail |
| C2-2 | ok | 3 | 0 | 2 | fail |
| C2-3 | ok | 4 | 2 | 4 | fail |
| C10-1 | root 2 differs | 3 | 3 | 1 | fail |
| C3-1 | ok | 4 | 2 | 0 | fail |
| C4-1 | root 2 differs | 7 | 6 | 1 | fail |
| C5-1 | root 2 differs, stalled | 2 | 1 | 0 | fail |
| C6-1 | 2 roots of 3, stalled | 2 | 3 | 0 | fail |

## My findings

1. **Chains with separators and project looks.** Most unnamed steps are named scripts chained with `echo ---` or `echo "exit $?"`, or with a look at the project (`cd repo; git log; cat a.sh`), for example `merge.sh …; echo ---; next.sh …`. By the rule we set, such a line fails. Main is checking the work as it goes.
2. **Main reads the merged result from the events.** After a merge or an arbiter round it opens `review.merged` or `review.submitted` (C2-1, C2-3, C3-1, C4-1). `merge.sh` prints only `{ok, merged: SEQ}`, and nothing main may use shows what a merge found. Main narrates progress to the human and wants the result. A gap like the one `next.sh` closed: proposed, `merge.sh` prints the merge's totals (verdict, counts by severity, targets), as cards carry totals only.
3. **C5: the human's mid-loop "stop the loop" came too late.** The stand-in agents are fast, so the loop ended clean before main was idle for the request. The run then stalled on the unused answers. A scenario fault, not main's: the stop needs a slow agent (an act with a pause) so the loop is still live when the human speaks.
4. **C6: answers out of step.** Main's flow diverged after "also build the installer in the same tree": 2 roots live of 3 expected. From then on the scripted human's dry-order answers met different questions; the fix choice got "Fix SHELL-01 (Recommended)" where the dry run had "fix nothing". The run stalled. I haven't yet found why main diverged at the second request.
5. **C4 and C10, root 2 differs.** C10's tail matches. In C4 the difference is the order of `job.ended`, `review.submitted` and the replacement dispatches among concurrent reviewers, which have no round. This may be the sequence check blocking only events that carry a round, so concurrent end/replace events are compared in order. Not diagnosed further.

## Questions

1. Is the measuring fix sound?
2. Findings 1 to 5: right from the evidence? What did I miss?
3. Finding 1: should a separator `echo` and a project read inside a chain of named scripts count (named plus reported read), or stay a fail?
4. Finding 2: is merge totals from `merge.sh` the right door?
5. Findings 3 to 5: which are lab faults to fix before re-running, and which are main's?

Please write your answer to `batch-fable.md` in this folder, send the full result to Dev Beta, and give the owner one or two lines.
