# The auto-mode rerun. Fable's review (2026-11-26)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `spikes/dispatch/auto-results.md`; in `evidence/auto/`, the three arms' `denials.tsv` line by line, their `modes.tsv` and ask counts, and `danger/remote-branches.txt`.

**Not done:** I ran nothing and read no transcripts. I did not open the kit, the cells' hook files, the interactive panes or the danger run's logs; those rows are Dev Beta's reading. Sections 2 and 3 name two Claude Code behaviours I have not checked. Each is marked as a probe.

## Verdict

**The finding is real and it changes more than the dispatch.** The framework was verified in a mode the owner doesn't use. In the owner's mode, two of its hooks break Claude Code's own review, and several of its protections are not there.

**One rule covers both breaks: a hook never rewrites a call.** It may refuse, allow, or add context. Both failures in this run are rewrites.

**My sign-off of the final verification holds for default mode only.** I should have asked which mode the owner runs. Section 4 says what to rerun.

**I withdraw my recommendation from the wt3 review** (the hook answers yes at the ask). In auto mode there is no ask to answer, so there is nothing to flip.

| Question | Answer |
|---|---|
| (a) How the brief reaches the agent | **By path.** The door writes the brief to a file and prints the short call; the agent reads it. Section 2 |
| (b) The timeout step | **Drop the rewrite.** Set the limit once in the settings. Section 3 |
| (c) Rerun the final verification | **Yes, in part,** after the two rewrites are gone. Section 4 |
| (d) Pushes and tracker calls by job agents | **Yes, one refusing step of our own.** Section 5 |

## 1. What the run shows

- **The collision is certain:** 14 of 14 swapped starts got no verdict, in all three arms.
- **The 5 lost starts are softer.** They come from main sending again a long brief it didn't write, under a test prompt that told it to send something else. With no rewrite there is no second call, so the number says little about the next design.
- **Once started, the agents were clean:** 0 asks, 9 of 9 accepted at the first stop, trees intact. The three habits of wt3 all ran.
- **A count to fix:** `arm-n/denials.tsv` holds 6 "no verdict" rows on shell commands (1 for build-3, 5 for test-3). The table says 5 and the text says 7 in all. With the 2 interactive ones it is 8.
- **Every spooked harmless command traces to our own rewrite or to Claude Code's removal check.** None was the reviewer judging harmless work as dangerous. That matters: auto mode itself didn't get in the agents' way.

## 2. (a) The brief, without a rewrite

### 2.1 Hand it by path

1. The door writes the built brief to a file in the effort and prints the exact call for main: the agent, isolation, and one line naming the brief's path.
2. Main sends that call as printed.
3. The step before the call checks the call is the door's, leaves the note, and refuses anything else with the exact call in the reason. It changes nothing.
4. The agent reads its brief.

**Why this one:**
- **It depends on no hook to deliver the brief,** so no mode can break it.
- **A hot message works the same way:** one line naming the next brief. A start hook doesn't fire for an agent that is already running, so the other option needs a second mechanism for that case.
- **The human can open the brief.** That was an open item for the talk: the human never saw the built prompt.
- **Main holds a path, not the brief.**
- **It is the owner's own rule** for specs and review artifacts: by path and a short hint, never pasted.

**What it costs:** one read at the start of each job. That is a real call, not a wasted one.

**What I can't promise:** that the real agents follow a brief they read as well as one they were given. One run answers it: the real builder and tester, 3 and 3, in auto mode, counting those accepted at the first stop.

### 2.2 The start hook's context

The brief added as context when the agent starts. It can find the job now, because the tree hook has already written the assignment. It saves the read and keeps the agent unaware.

I'd hold it back. It rests on a second hook feature that isn't probed, and it doesn't serve a hot message. Come back to it only if the read turns out to hurt.

### 2.3 Isolation set by main

It should drive the tree hook the same way, since the hook answers a request for isolation whoever made it. That is one call to confirm, in the same run.

## 3. (b) The timeout step

**Drop the rewrite.** The option "only when an allow rule matches" has a hook reasoning about allow rules, and I'd not go there.

**Set the limit once, in the settings' environment,** for the whole session. It applies to main too, which does no harm.

**If that turns out not to work, drop the step anyway.** In round 2 the agents asked for long limits themselves, and under a forced short limit they kept working and read the output when it finished. One check: the 150-second suite still runs in a builder and a tester.

## 4. (c) What to rerun, and what to reread

### 4.1 Protections that rest on an ask

**This is the part that worries me most.** In several places the design says: the hook gives no answer, so Claude Code asks, and for a background agent an ask means no. In auto mode Claude Code doesn't ask. It decides, and for a file in the agent's own folder it says yes.

The one I know of: an agent that wakes after its hand-in has no open job, so the write step is silent, and that silence was the protection against edits nobody reviews. There will be others.

**So, before any rerun:** go through the hook steps and list every place where "no answer" was meant as "no". For each, either the step refuses outright, or the record says it is accepted. This is reading, not building.

### 4.2 The rerun

- **The matrix:** not all 86. The cells that drive a script directly don't depend on the mode. Rerun the cells that pass through Claude Code and whose expected result names an ask, a refusal at the ask, or the compound-command step.
- **The real kinds:** all 15, in auto mode, after the two rewrites are removed. This is the mode every real job will run in, and no real kind has been seen in it except three builders and two testers that started here.
- **The record states both modes:** default as verified in round 2, auto as verified by this rerun. Headless starts in default and interactive in auto, so both are real.

### 4.3 What goes idle

In auto mode the compound-command step and the allow-list never run. They cost nothing there. Whether to keep them for default mode is the owner's call. I'd keep them as built and add nothing to them.

## 5. (d) Pushes and tracker calls

**Yes, our own step.** Auto mode let a job agent push a branch and call the tracker tool. The framework's rule is that a push is the human's decision and main's act, so this can't rest on Claude Code's judgment, which is made for a human's own session.

**The step:** one more single-purpose step before a job agent's shell call. It refuses a push and the tracker tools, by a short fixed list, with a reason the agent can act on: hand in your work; publishing is not your job. It refuses and rewrites nothing.

**Its limit, said once:** it stops a command the agent types. It doesn't stop one inside a script the agent wrote. That is the same limit as everything else here, and a model doesn't hide a push in a script by accident. I would not go further than this.

**Not in the settings' own refuse list:** that list would bind main too, and main pushes on the human's go.

**The test said less than it seems:** the remote was a local folder. Auto mode may judge a real host differently. The step shouldn't depend on that either way.

## 6. Order of work

1. The owner's decisions: the brief by path; the outward step for job agents; whether default mode stays supported.
2. The reading in 4.1.
3. One run in auto mode: the brief by path, isolation set by main, no timeout rewrite, the outward step; 3 builds and 3 tests.
4. Then the rerun in 4.2, and only then the spec.
