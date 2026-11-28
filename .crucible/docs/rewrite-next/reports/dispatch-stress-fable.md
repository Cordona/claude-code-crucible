# The stress test of the job chain: results. Fable's review (2026-11-26)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `spikes/dispatch/stress-results.md`; the run's 90 event files and `logs/refusals.log` in `/Users/Shared/crucible-sandbox/stress/`.

**What I ran:** one read-only query of my own over the 90 events, to check the chain without the kit's audit. Nothing else.

**Not done:** I read no transcripts and did not open the kit. That each agent stood in its tree with its plugins, and the call counts, are Dev Beta's reading.

## Verdict

**The chain holds as a mechanism, and the shapes of draft 4 carried a real run.** My own count from the log agrees with the audit on every line I could check.

**One pass line was not met, and it is reported honestly:** seven agents alive at once, not ten.

**The run does not show real agents doing real jobs this way.** That was never its purpose; it stays with the rerun of the 15 kinds.

## 1. What my own check of the log shows

| Check | Result |
|---|---|
| Jobs defined / assigned | 21 / 20, each assigned once; the one unassigned (61) is the planted drop |
| Agents initialized | 16, each once; no assigned agent without one |
| Forms of `approved` | 17 by gate and job, 3 by round, 1 replacement; no gate and job used twice |
| Trees | 3 cut; every `of` names a job that cut; every assignment's tree is a real cut; one job with no tree (59, by design) |
| Writers | every event type has one writer, except `job.assigned`: the start hook (cold) and the step after the send (hot), as designed |
| Ends | 19 handed in, 1 dead and replaced, 1 dropped: 21 of 21 |
| Refusals | 14 lines, all from the ten planted causes and the one extra; nothing else |

**The overlap, from the order of events:** jobs 17, 18 and 19 each handed in before the next was assigned. Jobs 20 to 26 were all assigned before any handed in. So seven, as reported.

**One small mismatch:** the results say `human.sh` writes `gate.answered`; the log says `card.sh` did. It changes nothing; correct the text.

## 2. The line not met

**Seven alive, not ten, and I would not rerun for it.** Starts are made one at a time by design, under a lock, so the number alive doesn't change how a start is paired. What ten would add over seven is small. The split probe before it paired fourteen.

**The cause that matters is not the kit bug. It is the wording.** Main read "one job agent per reply" as one per turn, and ended its turn after each start. On a real swarm of twelve that is twelve turns and the human waiting between them. The refusal itself says "start job 59 in your next reply", which invites the same reading.

**Fix it in the scripts' own words, not in main's prose:**
- the door prints with its calls: "Send one per message; send the next as soon as this one returns, in the same turn."
- the refusal says the same.

Then main's prose needs no line for it. This wording should be seen working once before it goes into a spec: one swarm, started in one turn with no hint from the human.

## 3. The three findings for the design

1. **The card showed no inputs. This is the serious one.** Draft 4 says the human approves exactly what will run. In this run the human approved fix targets the card didn't list. What the human decides on belongs on the card: the findings, the lens, the range, what a tree is cut from. What merely follows (which context, spec and grills) can stay behind the path. The card stays short that way.
2. **A job not on code stands in the human's checkout.** For a reader this is fine. It is the same exposure the A/B run showed for an agent with no tree: a shell command there writes to the human's files and nothing notices. So the rule should be stated, not left open: a job with no tree writes only its report and its scratch, and a job that changes code always has a tree. If some kind needs to write elsewhere without a tree, that kind is the case to bring to the owner.
3. **The kind is checked too late.** An unknown kind reached the card. Shapes should be checked when the proposal is resolved, so the human never sees a card that can't be defined.

## 4. Past the evidence

- **Stand-ins with trivial jobs.** Nothing here says a real builder, tester or reviewer behaves well under this chain.
- **One session.**
- **The loop ran hot only.** A round that needs a new agent was not in the run. It should work as any cold start does; it isn't shown.
- **Main's hesitation.** Twice main checked a card against its file and stopped. Once it was right. Record it; no rule.
- **"Main read only 14 lines of prose."** Good, and it is the number the owner asked about. But main was also told, mid-run, how to read "one per reply". The 14 lines were not enough by themselves.

## 5. Where this leaves the dispatch

**Settled by experiment:** no rewrite of a call; plugins loaded natively from a kind+set agent file; the five shapes and the gate's one added field; the tree start with the start hook writing the assignment; one job agent per message; the bounded fix loop; drop and replace.

**Before a spec:**
1. The owner's approval of the shapes (draft 4, with the first loop round stated).
2. The card showing what the human decides on (3.1).
3. The door's wording for a swarm, seen working once (2).
4. The owner's choices still open: where agent files and plugins live; the plugin change (visible, short descriptions, build and review texts as their own).
5. The reading of hook steps where no answer was meant as no.
6. The rerun in auto mode with the 15 real kinds, on this chain.
