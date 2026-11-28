# The dispatch spike design: Fable's review (2026-11-26)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `spikes/dispatch/design.md`, against what the final verification showed about the hooks and the lab's stand-in for the assignment.

**Not done:** I ran nothing and checked no Claude Code behaviour. Every "does Claude Code allow it" below is a question for the spike, not a fact.

## Verdict

**The concepts and the seam are right, and the shape is the simplest I can see. One concept is missing, and it is the main one: where the agent's id meets the job.** Add it and four smaller probes, then the spike proves the design.

| Question | Answer |
|---|---|
| 1. `Job <N>` plus a prompt swap | **Yes.** No simpler shape is worth a spike |
| 2. The script split and the folder seam | **Yes, with two corrections,** section 3 |
| 3. Missing from S1 to S5 | **The assignment, and four probes,** sections 2 and 4 |

## 1. Why the shape is right

- **Main's judgement goes through a script, and nothing main writes reaches the agent.** That is the owner's rule for judgement and execution, and it ends prose drift between main and the agents.
- **The door is a script, so a gate can sit in front of it later.** Folding the door into the hook (main calls Agent with the draft, the hook checks and writes) would save main one step, but the hook would then write events for a call that may never run. I'd not spike it.
- **A swap is simpler than a check.** Handing main the built prompt and verifying it wasn't edited needs a comparison; the swap needs none.

## 2. The missing concept: the assignment

When the hook runs before the Agent call, the agent doesn't exist yet, so it has no id. Every existing hook finds a job by the agent's id, through `job.assigned`. In the final verification that event was written by a lab stand-in. This spike is where the real one is decided.

**What I'd spike:**
- **The step before the call writes nothing.** It reads: is job N dispatched, unassigned, and of this agent type. Then it swaps or denies. A call that is then refused by the human or by another hook leaves no trace to clean up.
- **`job.assigned` is written once, at the first moment the id exists.** The spike finds that moment: the agent's start, or the end of the Agent call. Record which comes before the agent's first tool call. If the start does, the small window I left open in the write guard closes.
- **Two calls naming the same job:** record what happens. I expect the second agent ends with no job and the human is told, which the matrix already covers. If so, no claim before the call is needed.
- **The join:** in S1 the stand-in hands in through the real stop hook, with no lab assignment. That proves the dispatch feeds what is already built.

This also settles "bind": with no write before the call, there is no bound-but-never-started job, and no meaning of "fresh" to define. A job that is dispatched and unassigned is enough. I'd drop "fresh" unless it has a failure behind it.

## 3. The scripts and the seam

**The split is right:** check, write, door, prompt, each callable alone, and the door holds no rule.

**Two corrections:**
1. **`bind-job` and `deny-unbound` are one decision.** Both answer "which job is this call for, or none". Make it one step that resolves the call to a job or denies, then `swap-prompt`. Two steps would each do the same lookup.
2. **The fact that makes an agent job-taking should be its job check, not `submissions/`.** One file answers both "does it take jobs" and "where is its check". `submissions/` is a software-development word, and a doc writer may not have one.

**To prove in S4:** the hook gets an agent type name, not a folder. Show how the name leads to the folder in the installed layout, through the links, not only in the source.

## 4. Four probes to add

1. **SendMessage to something that isn't a job agent passes untouched:** another session, a helper agent. Main talks to other sessions with the same tool, and a guard that breaks that would be felt at once.
2. **SendMessage to an agent whose job is still open.** The spike only records what the hook sees. Whether main may speak to an agent mid-job is the owner's question for the talk.
3. **Can the agent be started in its tree?** Record what the Agent call's input holds and whether any field sets the start folder. In round 2, 36 commands were refused because agents start elsewhere and reach their tree with `cd … &&`. If the swap can fix that, it is worth more than any prose.
4. **A prompt of real size.** Run S1 once with a prompt as large as a real job's (plugins, context cut, spec). Byte for byte on ten lines proves less.

**Also record, at no cost:** what the human sees at a permission prompt in the interactive check, the swapped prompt or main's; and whether the hooks of three calls in one message run one after another or together.

## 5. Scope

The out-of-scope list is right. Two items of mine from the final verification stay for the talk and should not creep into the spike: the allow-list per job, and who ends a job that was dispatched and never started.
