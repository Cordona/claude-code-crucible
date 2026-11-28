# A/B: agents in their tree, or in main's folder. Fable's review (2026-11-26)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `spikes/dispatch/ab-results.md`; in `evidence/ab/`, both arms' `denials.tsv` line by line and the size of both `checkout-diff.txt` files (empty).

**Not done:** I ran nothing and read no transcripts. I did not open the kit or the cells. The guard counts of the earlier runs and the tool-call totals are Dev Beta's reading of the transcripts.

## Verdict

**Keep the tree start.** The counts don't decide it: both arms were accepted 6 of 6, with 10 and 9 wasted calls and the same time. What decides it is where a careless command lands.

I raised dropping it. The arm I asked for answers against that.

| Question | Answer |
|---|---|
| Keep or drop the tree start in auto mode | **Keep,** section 1 |
| What is past the evidence | Three claims, section 2 |

## 1. Why keep it

**In arm B the agent stands in the human's own checkout.** That folder has the same files at the same relative paths as the agent's tree. The agent reaches its tree only by starting each command with `cd <tree> &&`.

**One command without that prefix edits the human's working copy, and nothing notices:**
- there is no error, because the file exists there too;
- the hand-in check looks at the tree, which is clean;
- comparing the checkout before and after can't tell the agent's edit from the human's own work.

It happened 0 times in 6 jobs. But the framework would be relying on a habit, for a failure it can't detect and that damages the one folder the human cares about most. That is the kind of silent failure the framework is built to remove.

**In arm A the same slip lands in the agent's own tree,** where the hand-in check sees it.

**Two smaller points for A:**
- the agents used the write tools more (9 against 3), so the write step saw their changes; in B every code change went through the shell and that step saw none;
- every hook sees the tree as the agent's folder.

**The price of A,** all known now:
- Claude Code's worktree check refuses about 1.5 complex commands per job, each recovered at once. I would not chase them; wt3 showed where that leads. Half of them here are trial chains into the scratch folder, which sits outside the tree by the owner's decision.
- the hook answers for every worktree, with leftovers outside an effort (decided);
- one more hook at the start.

## 2. Past the evidence

1. **"A's guard bounds shell writes to the tree."** Nobody tried a plain write outside the tree in arm A. The check refused commands it couldn't follow; whether it stops a simple `cp` into another folder isn't shown. My reason for keeping A doesn't rest on it. One stand-in attempt would settle it, and the record should say which it is.
2. **"The report fix worked": 12 of 12 against 7 of 13.** One run per arm, and a large effect from one line, so I believe it. It is still one run. Every agent still sends its final message to main, so main must learn a job's end from its event. The fix made the slip rare; it didn't remove the need.
3. **"The door can create the folder."** Not tried. It should, in either design: a missing report folder is the framework's gap, not the agent's.

## 3. The new report line

"Report: write it to <path>, as one JSON object. That file is what is handed in; your final message is not."

**Fine as written.** It is the door's output, it names no plumbing, and a measured failure stands behind it. It ran before I saw it. The standing rule is that such lines come to me first; this one I'd have passed.

## 4. What is settled, and what is left

**Settled by the experiments:**
- no hook rewrites a call;
- two events, with the plugins at the start and the job as the call;
- the tree start, with the note and the assignment at the tree hook;
- one job agent per reply (the owner's decision);
- the scratch folder, the outward step, the time limit in the settings.

**Left before a spec:**
1. The owner's view of the plugin channel: four settings entries for one hook, parts in any order, a hand-in rule that counts every part.
2. The door creates the report folder and prints the one-per-reply rule.
3. The reading of every hook step where "no answer" was meant as "no".
4. The rerun in auto mode: all 15 real kinds, and the matrix cells that depend on an ask.
5. The two JSON shapes, to the owner before a build.
