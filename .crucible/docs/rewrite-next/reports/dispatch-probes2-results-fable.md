# Probes 2, the results: Fable's verdict (2026-11-26)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `spikes/dispatch/probes2-results.md`, and from the raw evidence: the three arms' `asks.tsv` (totals recounted, the refused commands of two arms read), the told files and one hook output of P-B, and the stop hook's calls in the interactive case.

**Not done:** I ran nothing and read no transcripts or screens. The form table (which command asks) is Dev Beta's; I did not open its raw files. Section 2.1 rests on a Claude Code feature I have not seen work, so it is a probe to run, not a fact.

## Verdict

**The facts are sound and my recounts match. P-B is settled. P-A found the real cause, and it points to a cheaper route to zero than the two on the results page:** start the agent in its tree, which one more small probe can prove or close.

## 1. Claims past the evidence

| Claim | What the evidence carries |
|---|---|
| "The line roughly halves the refusals" | 16, 7 and 9 over six runs per arm, one sample each. The third arm is worse than the second with more allowed, so the noise is at least two. The line helps; by how much is not known |
| "The wider allow-list adds nothing" | It was not aimed at what is left. Nothing in it lets an agent try its changed script, which is most of the rest |
| "Zero isn't reached by prompt or allow-list" | True for this line and this list only |
| "Only the Bash sandbox passes `cd` + `git`" | True, and the same column shows it still asks for the `echo` forms. So the sandbox doesn't reach zero either |

P-B's claims are within the evidence. They rest on six cases, which is enough for a choice of carrier.

## 2. The route to zero

**What the form table really says:** `cd` is not the problem, and neither are the folders. Two things ask: `git` after a `cd`, which is Claude Code's own rule, and a part that isn't allowed. Agents write `cd <tree> && …` only because they don't start in their tree.

### 2.1 First: start the agent in its tree

The dispatch spike showed the Agent call has no start-folder field, only `isolation: worktree`, which makes Claude Code cut its own tree. As far as I know, Claude Code also has a hook that fires when it is about to create that tree and lets a script answer with the folder to use. If so:
- the prompt swap adds `isolation: worktree` to a job agent's call;
- that hook answers with the job's own tree, which the framework has already cut;
- the matching removal hook does nothing, so Claude Code never deletes it.

The agent then starts in its tree. `git status` and `sh tests/run.sh` are plain commands that match the allow-list as written. Both `cd` forms disappear: 10 of the 16 refusals without the line, 5 of the 7 with it. The prompt line is then not needed, which is better than keeping prose.

**The probe, small:** one stand-in. Does the hook exist on 2.1.332, does it fire for a sub-agent, is the agent's start folder the job's tree, and is the tree still there, untouched, after the agent ends. If any answer is no, this route is closed and the line stays.

### 2.2 Then: let the agent try what it built

What is left after 2.1 is one thing seen two ways: the hand-built chains (`d=$(mktemp -d); for …; sh <tree>/bin/x`) and the plain commands nobody answers (`sh <tree>/bin/x --help`, `mktemp -d`). Both are the manual check.

**The point for the owner:** a builder may already run `sh tests/run.sh`, and it writes that file. So a job agent can already run any code it writes. Refusing it to run the script it just changed protects nothing and costs the manual check, which is reported as not run in most builds. Allowing an agent to run the files of its own tree, and to make a temp folder, is the same trust the framework already gives.

That is the allow-list per job, already on the list for the talk. It is the owner's decision, and it is the second half of zero.

### 2.3 What I'd not do

- **The Bash sandbox:** a change of security model that, by this evidence, still leaves asks.
- **A hook that allows or rewrites commands:** unchanged from my last review.
- **More prose:** if 2.1 works, even the one line goes.

**What may remain after both:** the habit of adding `; echo "t=$?"`. Allowing `echo` removed it in the form table. If a few are left, that is the honest floor, and one round each.

## 3. P-B: settled

- **The carrier is right:** the line rides the turn main takes anyway when an agent finishes, at no cost. Stop carries only the job that was dispatched and never started, as plain context, never a block.
- **I agree with keeping that one Stop case.** It costs one extra turn, once. Without it, the human waits for an agent that was never started.
- **"All reviews in" told when the line runs, possibly one wake early:** fine.
- **Claude Code's own side agents** fire the stop hook in interactive use. I checked: it says nothing for them.

**One thing not to build:** the "index from session to efforts". 250 ms with 54 efforts is tolerable today, and it is the same cost as at the write guard: reading every effort on disk grows with the owner's history. It belongs to the parked discussion about the log, with this number added, and deserves one answer for every reader.

**One limit to state in the spec:** a job ended because its agent vanished reaches main only at its next wake or the human's next message. That is acceptable; it should be written down.

## 4. Next

1. The small probe of section 2.1.
2. The owner's decision on section 2.2, at the talk.
3. Then the dispatch spec, with P-B's carrier as found.
