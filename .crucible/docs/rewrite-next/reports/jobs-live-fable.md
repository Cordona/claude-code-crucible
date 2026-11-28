# The live run of define and assign, and two prose items: Fable's review (2026-11-27)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `evidence/jobs-live/results.md`; the Never section of `new-rewrite/framework/core/CLAUDE.md`; `git-worktree/SKILL.md`.

**What I ran:** one read-only query over `evidence/jobs-live/out/events.json`, to see the chains without the results' wording.

**Not done:** I read no transcript, so "byte-equal" is Dev Beta's reading. I did not read `live.sh`.

## Verdict

**The run shows what it claims: the new chain carries the real builder, tester and reviewer, cold and hot, in auto mode.** My reading of the log agrees with the four chains: each job has its gate, its definition, its assignment to tree 12 and its hand-in; the hot review has no second `agent.initialized`.

**One thing the results table hides, and it is the same thing as prose item 2.** Both prose items need a small change.

## 1. What the log shows that the table doesn't

**The tree was cut before the job was approved.** In the log, `worktree.cut` is event 12; the jobs gate is 15 and `job.defined` is 16. Before that sits a whole flow of its own for the cut: agreed (11), step done (13), ended (14). The table writes the chain as "job.defined 16 → worktree.cut 12", which reads as the designed order. It isn't.

So the human went through a flow and a gate to cut a tree, and then approved a card saying "cut from ref:main" for a tree that already existed. That is three ceremonies for one tree, and the second approval approved nothing. Section 3 is the fix.

**Smaller limits of the run, all stated or harmless:**
- **Byte-equal is shown for the builder.** The results don't say it for the tester and the reviewer; say it or check it.
- **One small shell repo, one language, no framework.** The stress runs covered breadth with stand-ins; this covers the real agents. Together they are enough for this step.
- **The test plan came through the old chain as a fixture** (events 20 to 22). Fine, and it shows a new-chain job can take an old-chain event as an input.
- **Five faults found and fixed in the run.** That is what a live run is for. Fault 2 (resolve accepted a `from` the cut script refuses) is the one worth remembering: the same word has to mean the same thing in both scripts.

## 2. Prose item 1: the Never line in core's `CLAUDE.md`

> **Start an agent except through a skill that starts agents.** Started any other way, it works without the approved jobs, the context or the gates.

**Keep the line; change two things.**

1. **Its reason names a domain thing.** "The approved jobs" is the software domain's; core doesn't know jobs. Say what is true in any domain: it works outside what the human approved, without the context or the gates.
2. **Its reach is wider than the hook's, and the owner should say which is meant.** The hook denies only a job agent's start that isn't the script's. The line forbids every agent, including one main starts to search or read for itself. If that is meant, fine. If not, the line should say which agents: one that does the effort's work.

**Why the line stays although a hook exists:** the hook can't see main giving a build to a general agent. That is the slip the line is for, and no script catches it.

## 3. Prose item 2: two gates for one cut

**The fault is in `git-worktree`'s prose, not in the jobs card.** It says: cutting is always a step in the flow, one step line per tree, a card of your own, a gate. That was right when nothing else showed the human a tree. Now the jobs card shows each job's repository and base, and the human approves it there.

**What the rule is really for:** no tree is cut that the human didn't see. Say that, and stop saying how:
- a tree is cut only after the human approved its repository and base at a gate;
- a gate that already showed them is enough; otherwise show a card for it.

Then a job's cut needs nothing more than the jobs card, a tree cut for any other reason still gets its own card, and `git-worktree` names no jobs. "One step line per tree" goes: a step per tree is the old pipeline, and in the adaptive flow the step is the work, not the tree.

**Check one thing with it:** if `worktree-cut.sh` itself asks for a recorded yes, it must accept the jobs gate as that yes. Otherwise the prose is fixed and the script still asks twice.

**Then the order in the log returns to the design:** approved, defined, cut, assigned. Rerun only the build's chain to see it.

I'd like to see both reworded pieces before a session uses them.

## 4. For the owner

1. **The Never line's reach:** every agent, or agents that do the effort's work.
2. **Open from before:** the eight plugin names against your installed skills, before any real install.
