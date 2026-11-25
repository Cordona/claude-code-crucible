# The stop hook's assurance plan, v2: Fable's reply (2026-11-25)

By Crucible Fable Reviwer, for the owner. Talking only; the owner's go is the only go.

**What I read:** `stop-hook-assurance-plan.md`, version 2, against my first verdict. I ran nothing.

## Verdict

**Yes, it has my agreement as the plan to put to the owner.** Every point of my verdict is in it as I meant it, and putting the probes first is right: their answers decide two designs.

Three things to settle inside the plan. None changes its shape.

## 1. How a script scores "the human told"

S4, S5 and S10 expect that the human is told, and S10 expects nothing else. The plan says the scorer reads only events, report files and git. A message to the human is in none of those, so today S10 can't be scored at all.

**What I'd do:** in the sandbox, register the hook through a small wrapper that saves what the hook prints, one file per stop. The scorer reads those files. The hook itself stays as it is, and no transcript is read.

## 2. What "green" means for a probe

A probe answers a question about Claude Code. An answer we don't like (for example, nothing fires when an agent is killed) isn't a failed probe. Say it in step 5:
- a probe is done when its answer is recorded with the version;
- an answer that breaks something we rely on changes the design in step 2, and the owner is told before step 2 starts.

## 3. A fault after acceptance: is the job ended?

Step 2 writes `job.ended` for it and also says main can "finish handing in". Those pull apart: a job that has ended and is then submitted has two endings in the log, and the audit's "every job ended or submitted" would count it either way.

This is for the event-shape review the plan already gives me, so it needn't be solved now. Note it there as the open question: one of
- the job ends, and finishing is a new fact that refers to it;
- the job doesn't end, and the event says it is waiting to be handed in.

## 4. Checked and right

- A0, and its mechanism through the agent's type.
- `job.refused`, counted from the events, with the stop still held when the event can't be written.
- The control run before the matrix.
- S7 with the test job outside its plan, S8, S9, and the hot review in S1 and S4.
- Step 4: three runs per kind on the real model, counted, with zero gave-up as the bar.
- The audit's five checks.
- The exit trap, left as the owner's call.
