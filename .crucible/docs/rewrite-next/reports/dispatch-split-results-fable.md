# The split probe: results. Fable's review (2026-11-26)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `spikes/dispatch/split-results.md`; in `evidence/split/`, `batch-v1/order.tsv` (the 28 hook times of the first batch), `arm/audit.txt`, `arm/plugins.tsv` and `arm/main-calls.tsv`.

**Not done:** I ran nothing and read no transcripts. I did not open the kit, `probe0/`, the cells' own folders, or `arm-o` and `arm-l`; those rows are Dev Beta's reading. Section 3.1 proposes an arm whose outcome I can't predict.

## Verdict

**The split is proven as a mechanism. It is not yet proven that the agents do the job as well this way.** Seven of thirteen real jobs were accepted at the first stop. In the auto-mode run before it, with the old brief, it was nine of nine. That drop is the result that matters most, and its cause isn't known.

**One question now sits above the five problems.** The start in the tree was built to remove refused `cd` commands. Those refusals exist only in default mode. In the owner's mode the tree start now costs three things and its benefit hasn't been measured. Section 3.1.

| Question | Answer |
|---|---|
| Are the concepts proven | **The mechanism, yes. The agents' behaviour under it, no.** Section 1 |
| What is past the evidence | Four claims, section 2 |
| Which problems change the design | **1 and 2 change it. 3 and 4 are script rules. 5 needs one measurement.** Section 3 |

## 1. What is proven

- **No hook rewrites a call, and auto mode has nothing to object to:** 0 "no verdict" and 0 denied on 27 cold calls and 5 hot messages.
- **The job message is short and main sends it as printed:** 470 to 831 bytes, 0 refused for a difference.
- **Plugins arrive whole:** 27 of 27, the tester's 21 KB set included.
- **The log has the right shape:** a cold agent has one `agent.initialized`, a hot job has none, and the audit found nothing beyond the two failures the cells were built to show.
- **The time limit set in the settings holds,** and the 150-second suites ran with no rewrite.
- **The outward step refuses** a push and the tracker tools, alone and in a chain.

## 2. Past the evidence

1. **"The agents follow plugins given this way."** This rests on one planted cell. Against it stands the drop to 7 of 13. Nobody has yet compared the new job message with the old brief to see what words about the report were lost, or whether text given as start context weighs less than text given as the prompt. Until that is known, the owner's doubt (will the agent follow it) is open, now about the report.
2. **"One job start per reply worked for 14."** One batch, with stand-ins.
3. **The 26 refusals by Claude Code's own worktree guard have no baseline.** The auto-mode run before this one also had agents in their trees and reported none. Either they were there and not counted, or something in this run brought them. That needs an answer before they are called a cost of the tree start.
4. **"The audit catches it."** The audit is a script of the kit. Nothing in the framework catches an agent that started without its plugins.

## 3. The five problems

### 3.1 Starts in one reply can't be paired (changes the design)

**The fact:** Claude Code gives no key that links a call to the agent it starts. In default mode the hooks of each start came one after another, so order could stand in for a key. In auto mode all checks run first and all tree hooks at once. I had written that the order was observed, not promised; it isn't even the same in the owner's mode.

**"One job agent per reply" is sound.** It is refused mechanically, and nothing is paired by guess. It is also a real cost: twelve reviewers are the framework's main parallel case, and fourteen starts took thirteen replies and 160 seconds. Main is now steered by a refusal on its most common fan-out.

**What I'd look at before accepting it:**

- **The pairing doesn't need the tree hook.** The start hook also receives the agent's id. It could take the note and write the assignment itself. The tree hook would then do one thing only: say which folder.
- **So the tree start can be judged on its own, in auto mode.** Its costs there:
  - the hook answers for every worktree Claude Code makes, with leftovers outside an effort;
  - Claude Code's worktree guard refuses complex commands (26, if they belong to it);
  - one more hook in the start path.

  Its benefit was zero refused `cd` commands, which default mode needed. Auto mode asks nothing.
- **One arm answers it:** auto mode, no isolation, the agent starts in main's folder, the note taken at the start hook, 3 builds and 3 tests. Count the wasted calls of every kind beside the same count with the tree start.

If the arm is clean, the worktree hook and everything that came with it can go, for the owner's mode. If default mode stays supported, that is the price to state. I don't know which way it comes out.

**The door should print the rule with the call,** as a fact in its output, so main doesn't learn it from thirteen refusals.

### 3.2 The report handed to main, not written to the file (changes the design, in two places)

- **The cause first, by reading.** Put the new job message beside the old built prompt and list what the old one said about the report. If words were lost, they go back into the message the door prints. That is a script's output, not prose in the agents' definitions. No clause goes into a definition until this comparison is done.
- **Main must learn a job's end from its event, never from the agent's message.** This is the attention line already probed: at its wake main is told "Job N accepted" or "Job N refused, the agent is repairing". The handback then carries no weight. And the door refuses a hot job for an agent whose job is still open, as Dev Beta says.
- **The headless ending** (main exits and the agent dies in its repair) is the dead-session limit seen in round 2. Real use is interactive, where main waits. Record it; don't design for it.

### 3.3 A failed start hook is silent (a rule at the hand-in, with one gap)

**The rule:** a cold agent's first job with no `agent.initialized` is not accepted. The job ends as faulted, and main is told. It is not sent back for repair, because the agent can't repair it.

**The gap:** `agent.initialized` is written by part 1. If part 2 of 3 fails, the event exists and a third of the plugins is missing. The rule has to count every part.

**This is the weakest piece of the design, and the owner should see it plainly:**
- the channel holds 10,000 characters and the plugin sets are 10 to 21 KB;
- so one hook became four settings entries, each sending a labelled part, arriving in any order;
- the largest set uses three of the four, and a set that outgrows them must be refused at the door, loudly, before the agent starts;
- the owner's rule is one settings entry per hook.

It works, 27 of 27. It also rests on a number that belongs to Claude Code. I have no better channel to offer. The smaller the plugin sets, the less of this there is.

### 3.4 The start hook fires again on a resume (a script rule)

An agent already initialized gets nothing. One check at the top of the step. No design change.

### 3.5 Claude Code's worktree guard (measure first)

See 2.3 and 3.1. If the 26 come with the tree start, they are about two wasted calls per job, close to what the tree start was built to remove in default mode.

## 4. Before the spec

1. Read the two texts for the report words (3.2).
2. Explain the 26 against the earlier auto-mode run (2.3).
3. On the owner's go, one run in auto mode, 3 builds and 3 tests in each arm: the tree start, and no tree start with the note taken at the start hook. The corrected job message in both. Count those accepted at the first stop and the wasted calls by kind.
4. The owner's decisions after it: keep or drop the tree start; one start per reply; the four-entry plugin channel.
5. The JSON shapes of `agent.initialized` and the smaller `job.dispatched`, to the owner before a build.
