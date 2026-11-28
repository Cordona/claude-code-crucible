# The dispatch spike results: Fable's verdict (2026-11-26)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `spikes/dispatch/results.md`, and from the raw evidence: every built and received prompt pair (compared byte for byte), `timing.txt`, `S4-links.txt`, main's prompt in each spike, the events of S1, S3, S4, S5, S6 and S8, and S6's hook calls. I also read the kit's file list and its job-taking marker.

**Not done:** I ran nothing and read no transcripts. I did not read the kit's code, the interactive screen, or S7 and S9 beyond the results page.

## Verdict

**The concepts are proven. The mechanism is the right one to spec.** My checks of the raw files agree with the results page. Three claims reach a little past the evidence, and five of the eight design notes should change the spec.

## 1. What is proven

| Concept | Evidence I checked |
|---|---|
| The agent gets the script's prompt, not main's | 6 pairs equal byte for byte, up to 25,945 bytes; the hot one sits whole inside Claude Code's wrapper |
| The assignment is written by a hook, with no lab help | `job.assigned` by the hook in every run, then the real stop hook's submission |
| Nothing is written before the call | S6: one dispatched job, one assignment, no leftover |
| A new agent is only a folder | S4: a doc writer dispatched first time, the job-taking fact is its job check |
| Main recovers alone | S2: denied, then dispatched and started with no help |
| Other agents and messages pass | S7, per the results page |

## 2. Three claims past the evidence

1. **"Tied to its job before its first tool call" is a race won, not a guarantee.** The margin was 0.43 to 1.07 s in 13 runs, with small stand-ins and short prompts. The agent's start event carries nothing that links it to a job, so the end of the Agent call is the only place, and nothing shows the agent waits for it. I'd still build it this way: a real agent reads a long prompt first, and the two fallbacks exist (the write guard gives no answer, the stop hook looks again for five seconds). The spec should call it a margin.
2. **"The same for every agent" is shown for two made-up agents.** The builder, the tester and the reviewer were not dispatched. Each needs its own job check written, and that is where their real rules will show. This is the spec's first work, not a doubt about the mechanism.
3. **"Unsteered" needs its context.** In all but S2, main's prompt named the dispatch script and said to read its help. That stands in for the skill main will have. S2 is the real proof, and it is one headless run plus one interactive.

## 3. The design notes

| # | Note | For the spec? |
|---|---|---|
| 2 | Kinds aren't discoverable | **Yes.** The refusal lists the agent's kinds, read from its folder. Not the help: the dispatch code must name no agent |
| 3 | Refusals one layer at a time | **Yes.** One refusal lists everything wrong. It is the rule I asked for at the stop hook |
| 5 | SendMessage carries the text twice | **Yes.** Set both |
| 8 | `Job N` across efforts | **Yes, by a simpler route:** the door prints the exact line main passes on, so main never composes it and the form is the door's own |
| 4 | Two calls on one job | **Small change.** Accept the outcome, but the refused assignment should tell main at once. Today it is silent, and the stray agent works until its stop. No claim before the call |
| 7 | The writer's name | **Minor.** The rule should pin the script that really writes |
| 1 | No slot for grills | **Not now.** Every ended grill in the prompt worked. A new field waits for a case that needs the choice, and the owner approves the shape |
| 6 | No start folder | **No change to the dispatch.** It stays for the talk, section 4 |

**The plugin check added mid-run** is right in kind: a made-up plugin name was accepted in silence, which is a real failure. In the spec it should be one line of the same single refusal as note 3, not a layer of its own.

## 4. For the talk with the owner

- **Main can speak to an agent mid-job (S8).** The message arrives as "address this before completing your current task". That is main steering a job in prose, which the whole design exists to avoid. Allow or deny is the owner's call.
- **The start folder can't be set.** So the refused `cd <tree> && …` commands stay. With the prompt now built by script, the cheap fixes are the allow-list per job or how the prompt names the tree.
- **The human never sees the built prompt.** The Agent call doesn't ask. The prompt script runs alone, so "show me what the agent got" is one command if the owner wants it.
- **Still open from before:** who ends a job dispatched and never started, and the gates in front of the door.

## 5. Next

The spike has done its job. I'd not run more of it. What remains is decided on paper with the owner, and the spec comes to me before anything is built.
