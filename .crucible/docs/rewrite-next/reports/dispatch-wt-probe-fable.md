# The worktree-hook probe: Fable's verdict (2026-11-26)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `spikes/dispatch/wt-probe-results.md`, and from the raw evidence the state, hook counts and tool results of the bridge and parallel cases, and the hook times of the parallel case.

**Not done:** I ran nothing, read no transcripts, and did not open the native and veto cases or the Claude Code docs page; those are Dev Beta's reading.

## Verdict

**The route holds: an agent can be started in its own tree, by a documented Claude Code feature.** My read of the raw files agrees. Three things are claimed past the evidence, the order may be relied on only in a way that fails loudly, and one cost is understated: **this hook takes over worktree creation for everything in the session, not only for jobs.** That is the owner's decision before the spec.

## 1. Claims past the evidence

| Claim | What the evidence carries |
|---|---|
| "The `cd <tree> && …` forms have no reason to exist" | A stand-in ran three scripted commands with no ask. The real builder and tester were not rerun. The count of asks is still to measure |
| The order: each call's tree hook runs before the next call's first hook | One sample, with hooks that take a few milliseconds. The real first hook takes about half a second |
| "The tree is left as it was" | Shown for an agent that changed nothing. A tree with a working commit in it was not run; the docs say it is kept |

Also not run: an interactive session, and a hot agent resumed by message (no tree hook fires there; it should still be in its tree).

## 2. Relying on the order

**Sound only if a wrong order can't pair silently.** A queue (first job, first tree) would put agent A in job B's tree if Claude Code ever interleaves two calls. A builder would then edit the wrong tree, with nothing to show it. That is far worse than today's race, which fails safe.

**So the hand-off takes no guess:**
- the step before the call leaves one note for the session: this job, this tree;
- the tree hook acts only when exactly one note is waiting. It takes it and answers with that tree;
- with more than one waiting, it refuses the start. The reason reaches main, which starts them again.

In the order seen, this always works. If the order ever changes, starts are refused in the open, and nothing is mispaired. With that rule, relying on the order is sound.

**One run before the spec:** twelve calls in one message with hooks of real weight, counting refused starts. If many are refused, the order isn't what one sample showed, and main starts job agents one per message.

## 3. Where the assignment is written

**At the tree hook, for a cold start.** It needs the note anyway to find the tree, so it knows the job and the agent's id together, before the agent exists. Splitting that over two hooks would have two readers of one note. The hook after the Agent call is then not needed.

- **One script writes the assignment,** called from two places: the tree hook for a cold start, and after the message for a hot one, as the spike did.
- **One case to check:** a start that fails after the assignment leaves a job assigned to an agent that never ran. The step that ends the jobs of agents that are gone should cover it. Show that once.
- **This needs every job to have a tree.** If some kind of job has none, that kind can't start this way, and the assignment would live in two shapes. Say in the spec which it is.

## 4. What it changes elsewhere

1. **The hook replaces Claude Code's own worktree creation, for every caller.** It has no filter. Once installed, the human's `claude -w`, any other agent that asks for isolation, and Claude Code's own uses all reach this hook, and there is no answer that means "do what you normally do". With no note waiting, the hook must either refuse or cut a tree itself. Refusing is the simple choice and fits "the framework cuts every tree", but it switches off a Claude Code feature wherever the framework is installed, the owner's other projects included. **This is the owner's call,** and the results page lists it as a benefit when it is an obligation.
2. **Every hook now sees the tree as the agent's folder,** not main's. The final verification was signed off with agents starting in main's folder. After this is built, the matrix runs again in full, and the real kinds in part.
3. **The prompt line from probes 2 goes.** The agent is in its tree, so it has nothing to be told.
4. **The second half of zero is unchanged:** an agent trying what it built, which is the allow-list per job.

## 5. Next

1. The owner's decision on section 4, point 1.
2. The twelve-call run of section 2, and the real builder and tester once more with the agent in its tree, counting asks by form. Both need the owner's go.
3. Then the dispatch spec.
