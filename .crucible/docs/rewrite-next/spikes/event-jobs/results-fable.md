# `results.md` judged against the evidence (2026-11-24)

By Crucible Fable Reviwer, for the owner. Not a go; the owner's go is the only go.

**What I checked now:** the run folders against the table; `compare.json` and the saved batch scores of C1-12, C1-13, C2-1 to C2-3, C3-1; and for the two runs I had not seen, C4-3 and C5-3: the score, the sends against the gate answers, the events, and every call of main. The rest rests on my earlier checks. **Not checked:** the line counts in claim 5 (58 and 708).

## Verdict

**The report is honest and its verdict holds.** It has everything I asked for, it marks nothing passed that didn't run, and it says plainly what the method got wrong. Five things in it don't match the evidence. One of them matters for the build; the others are corrections of detail.

## What to correct

1. **"No events were read after that (C2-4 to C5-3)" is not true for C4-3.** To cancel the security reviewer, main went into the events folder twice (a `grep` over the dispatch events, then `cat` of job 8's) to find which agent it was, then stopped it. The check didn't count it because it happened before the loop began.
   - This is a fourth door of the same kind as lesson 2: **to cancel a job, main must be able to tell which running agent is which.** The lines `next.sh` prints for work still running should name the job, its kind and the agent.
   - C4-3's cancel itself is real: the event says `cancelled`, the request arrived while the reviewer was working, and the loop then ran unattended.

2. **C10-1 is in the wrong row.** It is listed with the runs where a request was typed into an open question. That didn't happen in C10-1; the driver stayed in step. It differed for two lab reasons: the stand-in couldn't hang, and the dry run expected cold dispatches after reopening. It also showed something worth keeping: after each of two restarts, main asked `next.sh` and showed the same pending card again.

3. **The "first score" of the batch runs has no file behind it.** The table says C1-12 first failed on "typed in loop 1". The saved batch score for C1-12 says pass, typed 0: it was saved after the measuring fix. So the first scoring exists only in the batch brief's words. Say that. It also means the last summary line is slightly off: C1-12 passes once the measuring fault is fixed, and only C1-13 needs the later scoring rule.

4. **The counts in the verdict don't match section 8.** "The scoring rules changed four times" sits above a list of seven scoring changes. Use the list's number, and say how many were set before their runs.

5. **Lesson 6 claims more than its run shows.** C1-3 had a longer text, a new guard and an unclear request all at once, and main's question was about the unclear request. "Start from the smallest" stands on the principle, and on ten lines having carried the loop. It doesn't stand on C1-3.

## Smaller notes

- **C4-3 and C5-3 are one run each.** Say so beside them in claim 4. They are shown once, not shown reliably.
- **Two things to add to "what the lab was not":**
  - the review kinds came from each run's fixture, so main never proposed which reviewers to use;
  - main wrote its own view of the code into gate questions. Whether main forms a view or only carries the reviewers' is a question for the review piece.
- **"The invariants are carried into the build as a script"** is a build decision. Word it as the proposal it is; the owner hasn't given a go.
- **The run folders match the table.** `C10-3` is on disk as `C10-3-stopped-lab-ended`; there is no C6-3 folder, as the table says.

## What I confirm

- C2-4, C2-5, C2-6 pass, with no event, card or project read in the loop. C2-5 I read call by call.
- C3-2: every step right, failed only by the comparison on main's choice of a fresh builder.
- C5-3: the human's stop arrived in a live loop, `loop.stopped` is in the events, and the end reason is "stopped".
- In C4-3 and C5-3 every answer met the gate it was meant for.
- The claims table uses the four statuses correctly, and the "not run live" list is complete.
