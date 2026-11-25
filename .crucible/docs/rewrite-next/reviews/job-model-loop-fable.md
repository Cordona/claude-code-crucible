# The kept loop and arbiter under the job model: Fable's answer (2026-11-23)

By Crucible Fable Reviwer, for the owner, on `job-model-loop-kept.md`. Talking only; nothing here is a go or a design. I ran nothing.

The owner keeps the unattended loop (D11) and accept-or-insist with the arbiter (D10). I had suggested dropping both at the start; this answer takes them as kept.

## In short

**It holds.** The loop fits the job model without a loop record, and Dev Beta's points 2, 3 and 4 are right. **"A few rows" understates it in three places,** and one of Dev Beta's rows should not exist:

- **Accept-or-insist is not a job.** In the old design it is two fields in the re-review report. Making it a job adds a kind, a report, a stop check and a timing problem, for nothing.
- **The harvest is a script with a rule, not a row.**
- **The arbiter is a fourth agent with its own report.** It is small if its job is simply one more member of the round.

**On driving the loop:** an agent's submit doesn't wake main, but the agent's end does. The loop runs on that plus the held stop. One link is unproven, and one failure is silent.

## 1. Does it hold?

### What is right as written

- **The cap is a count** (point 2), with one correction: it counts the rounds since the **latest** `fix.chosen` on the root, not all rounds under the root. A second choice at the cap starts a new count, as D4 says ("the latest one is the whole contract").
- **`fix.chosen` is the approval** (point 3). The dispatch script can refuse on it, and "the loop is over" is derivable: the count reached the cap, or the last merge left no targets. After that a stale `fix.chosen` approves nothing.
- **The rows are the inside of an agreed step** (point 4). They may hold main's stop.

### Accept-or-insist: fold it into the re-review, as D7 did

Dev Beta's row is "a decline → an accept-or-insist job for the reviewer that raised it". The old design has no such job. The lens that re-reviews answers each of its keys in the same report: `fixed`, still a concern, `withdrawn` or `insisted` with its reason.

Kept that way, three of Dev Beta's own questions disappear:

- **"A decline arriving while a round is open"** can't happen. A decline arrives in the fix job's report, and the re-review round is made from that report.
- **"A reviewer that raised the key is no longer hot"** doesn't matter. The key goes to the reviewer of that kind that holds its file; the finding, the decline's note and the code are all it needs. This is why the round's cover must include the chosen findings' files (my change 9).
- **"The stop check of an accept-or-insist job"** is the re-review's own check, from D7: every earlier ID the job was given is answered once, in an answer its fix entry allows (reported done: resolved or still open; reported declined: withdrawn or insisted).

### The arbiter: one more job in the round

- **When:** the fix report of a round declines a key that the last merge holds as insisted. A script sees that from two events; nobody judges it.
- **One per round, by construction.** D10's "the first deadlock spins it up, later ones message it" existed because deadlocks arrived one at a time. Here the round is made once, from all the fix reports of the round, so the script puts every deadlocked key into one arbiter job.
- **Put that job in the round's set.** Then "round complete" is the same rule as always: every job of the set has submitted. The merge reads the ruling. No extra row is needed for "wait for the arbiter", and a round where every key was declined again is simply a round whose set is the arbiter alone.
- **What it costs, plainly:** a fourth agent definition (read-only, like a reviewer), a ruling report, and a stop check that every key is ruled once. That is real, and it is bounded.
- **A deadlocked key is not given to a re-reviewer in that round.** The reviewer already insisted; there is nothing new for it to judge.

### The harvest is the rule, and it should be named as one

"Targets left → a fix job" hides what computes the targets. From D9 and D10:

- carry over what is not fixed: still open, insisted, or ruled `fix` (with the reviewer's or the arbiter's reason);
- add new realistic critical, high and medium findings raised on the fix;
- never add what the human skipped;
- drop what was withdrawn or ruled `drop`.

That is one script. It needs no event of its own: the fix job's `job.dispatched` carries the targets, which is the record. But it is where the loop's judgement-free rule lives, so it deserves its own evidence.

**One thing the human should see when choosing:** the loop also fixes findings the human never saw, the new ones raised on the fixes. That is D9's decision and it is kept, so the choice card should say it in a line.

### Three things an unattended loop needs that a gated one didn't

1. **A swarm with no human to agree it.** In a gated round main proposes kinds and file groups. In the loop a script must derive them: the kinds that have a target in this fix, plus the tech reviewer, one reviewer per kind on the whole fix diff, no split by files. Hot or fresh stays main's choice; the script checks it.
2. **A way out.** "Stop the loop" from the human needs a recorded fact that the dispatch script refuses on. Otherwise the next agent to finish starts the next step.
3. **Limits on what repeats.** D11 says a dead agent is replaced without asking. A job that dies twice would be replaced for ever. One replacement per slot; after that the loop ends and says why on its end card.

## 2. How main drives the loop with nobody typing

**The premise needs one correction.** The submit event doesn't wake main. The end of a background agent does: main is told and takes a turn. The stop check runs before the agent ends, so the event is already there when main wakes.

So the loop is driven by two things that exist:

1. **An agent ends → main takes a turn.**
2. **Main's stop is held** while the scan finds something owed inside the loop. The reason names the one script to run. Main runs it, makes the Agent or SendMessage calls it prints, and tries to stop again.

A round is then about four held stops: make the round, start the reviewers, merge, start the next fix. Between them main is stopped and waiting, which is right: waiting on an agent never holds the stop.

**What holds, and on what evidence:**

- **The state survives anything.** A closed session, a compaction or a crash loses nothing: the next time main runs, the scan finds the same owed step. The loop pauses; it doesn't break.
- **Main follows a held stop without asking the human.** The owner's earlier lab runs showed a stop hook fixing dropped steps. That is evidence for the pattern, not for this loop.

**What is unproven:**

- **Does the end of a resumed agent wake main again?** The hot builder is resumed by SendMessage for each fix. If its second end doesn't reach main, the loop stops after the first fix. This is the one probe that matters most here. The old rewrite had a second channel, a stop hook that woke main itself; that is the fallback.
- **The probe shows the wake only indirectly.** Its main output has a second message after the agent finished. Probe it on purpose: an agent ends, main is held, main dispatches the next, with no input in between.

**The silent failure.** If an agent hangs and never ends, nothing wakes main, and the human, who is out of the loop by design, sees nothing. I would not build a watchdog for this. Record it as a known limit, and make the status say "the loop has waited on this job since this time", so the first glance shows it.

**One caution on form.** Each held stop must name a step that changes the events, so the next scan differs. A held stop whose step can't be done (a script that refuses) must end the loop with its reason, not hold again.

## 3. Is it "a few rows, not a machine"?

It is a small state machine, and that is fine: the constitution accepts complexity in code and refuses it in prose. What matters is where it lives and how it is proven.

- **One script answers "what does this root owe next".** It belongs to the review component, and it is declared the way the catalogue declares steps (my change 4).
- **It can be proven with no agent at all.** Feed it hand-written events and check the answer, as the roll-back evidence does. Every path gets a case: fix then clean; targets left; a decline accepted; a decline insisted; declined again and ruled `fix`; ruled `drop`; the cap used up; a dead job replaced; a second death; the human's stop.

That offline evidence is the strongest argument for Dev Beta's position, and I would ask for it before any live run of the loop.

## 4. Does this change my ranked changes or the build order?

**The changes:**

- **Change 10** is settled by the owner: both stay.
- **Change 6** (what approval covers a dispatch) is answered for the loop by Dev Beta's point 3. Its scope should be exact: the loop covers fix jobs, re-review by kinds the first swarm already had, and the arbiter. A new kind or a build is not covered.
- **Change 1** (a job can end without a result) moves from "needed" to "needed first". Unattended replacement stands on it.
- **Changes 2, 3, 4, 5, 7, 8 and 9 stand as written.** Change 9's cover rule is now what makes accept-or-insist work.

**The build order doesn't change, and the loop makes it tidier.** A loop with a cap of one is exactly the gated version: one fix, one re-review, back to the human. So:

1. Jobs with their end states, the first review, the merge, the choice, one fix, one re-review. Run it live with a cap of one.
2. Raise the cap. Nothing new is built except the harvest and the scripted swarm; this is the live test of the wake.
3. The arbiter last. Until it exists, a deadlocked key ends the loop and goes to the human on the end card, which is safe.

## 5. A caution on confidence

The logic above is checkable on paper and, better, by replaying events. The driving is not: whether main reliably takes each step unattended, round after round, is known only from a live run. I would treat the wake of a resumed agent as the open risk of the whole loop until a probe shows it.
