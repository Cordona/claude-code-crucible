# Do we know enough to build? Fable's view (2026-11-24)

By Crucible Fable Reviwer, for the owner, on `enough-brief.md`. Talking only; the owner's go is the only go.

**What I checked for this:** the `compare.json` of C2 runs 4, 5, 6 and C3 run 2, and every call of main in C2-5 and C3-2 from the scope logs. Everything else rests on my earlier checks (`dry-check`, `baseline`, `batch`).

## In short

1. **Yes. Stop the lab and talk building.** The question the lab was built to answer is answered. More runs would mostly test the driver.
2. **The owner's suspicion of the method is fair, and part of it is mine:** I signed each change. But the result doesn't rest on the rules that moved. It can be read straight from the logs.
3. **Don't carry this way of testing into the build.** Check what must always hold in the events, on real runs, and drop the scripted human and the exact-sequence comparison.

## 1. Is the suspicion right?

**On the method, yes.** Three things changed after red runs, and they are not equally worrying:

| What changed | Is it tuning toward a pass? |
|---|---|
| The lab's scripts: `--help`, `next.sh`, cards without commands, the three outputs | No. These are the design findings. Main's behaviour changed, and that shows in the raw logs. |
| The scoring rules: chains, reads, scoring by effect | A fair worry. Each was set before the next runs and old runs kept their scores, but the rules were shaped by what had just failed. |
| The driver: trust prompts, gate lookup, timers, requests into open questions | Not tuning, but noise. It is where most failures came from, and each fix made the harness bigger. |

**Why the result still stands.** C2-5's log needs no rule to read. In the whole run main made 31 shell calls: every one is `next.sh`, a script that `next.sh` or a card named, or `--help`. It never opened an event, a card file or the project. In the first batch the same case had 8 to 11 calls into the events folder. Nothing in the scoring explains that difference; the three script outputs and the plain request do.

**What the method got wrong** is the third point of the brief. Comparing a model against a script that plays the model fails good judgement. C3-2 is the clear case: main gave the third fix to a fresh builder because the first had missed the finding twice. That is what `main.md` asks for, and the check failed it. I flagged this risk before the first live run (`dry-check-fable.md`, 1.3) and the fix only went half way. C3-2 should be reported as right on substance, failed by the comparison.

## 2. Do we know enough?

**Yes, for the question asked:** can the events and a few printed lines carry main through a review loop without a flow written in prose, and without the human typing. C1 twice and C2 three times say yes, on a ten-line text.

**No single experiment is missing that the lab could run better than the build.** The two real unknowns both need things the lab doesn't have:
- the flow test needs the real adaptive flow's stop hook beside the new one;
- real judgement needs real agents on a real task.

Running either in the lab means building stand-ins for them first, which is the pattern the owner is tired of.

**The rerun in flight:** stop it. Whatever has finished is listed as it scored; nothing is picked.

## 3. What in "proven" is weaker than the brief says

- **It is one small task, five clean runs, with agents that follow a script.** Stand-ins answer in seconds and never surprise main. With real agents main sits idle for minutes and the human talks in between. That part is unseen.
- **"Stage A covers every flow" means the rules are right given the events.** It says nothing about main. The test plan, external and foreign review have never run with a model. And Stage A's approvals are a different event type from the live gate's answer.
- **Main ran with permissions bypassed in every run.** Its own script calls in a normal mode are untested.
- **Cancel, stop, two builds, death and reopen never ran live in step.** Not failed: not run.
- **The held stop is a net that was rarely needed** (0 to 2 holds a run once `next.sh` existed). Good, but it means the net itself is lightly tested.
- **"Thin prose" is the lab's ten lines, not the real pieces.** That main finds a piece from an offer line is still a claim.
- **A hung agent wakes nobody,** and the scan's time on a long log was measured once on an unreal shape.
- **One new fact rests on one run:** a continued session still reaches its agents (C10-1).

None of these says don't build. They say what the build has not yet earned.

## 4. Carrying the two unknowns into the build

**Sound, on three conditions.**

1. **The flow test comes first, before any piece is written as a flow step.** Say before it runs what counts as failing (main hears the same step from two hooks, or the two disagree), and what happens then (one hook owns the stop; the other only reports).
2. **The real run is judged on what must always hold, not on a script's order.** For example:
   - no dispatch without the human's answer behind it;
   - no question to the human between a fix choice and its loop's end;
   - every round merged;
   - a loop ends at or under its cap;
   - every job dispatched has ended or is waiting.

   Code can check these on the events of any run, the owner's real ones included. It is the "tracked for completeness" part of the owner's goal, and it can't be tuned toward a pass the way a sequence can.
3. **Add a third early check:** main in a normal permission mode.

Then small steps, as the constitution says: the review piece first, run on a real task, then the others.

## 5. What `results.md` must contain

- **Each claim of the spec, with one of four words:** shown live, rules only, not run, failed. And the run folders behind it.
- **Every run, the set-aside ones too** (the `C1-0-*` and `*-lab-*` folders), each with its reason. Runs made against runs counted.
- **Every change to the harness after a red run:** what, why, and which runs were re-scored. Scores as first scored, beside any re-score.
- **What the lab was not:** stand-in agents, one task, bypassed permissions, a lab text in place of the real pieces.
- **The design lessons,** each with the run that showed it.
- **The open risks of section 3,** each with the check that would settle it.
- **C3-2 named as it is:** main's judgement, failed by the comparison.

No "pass" for anything that did not run.
