# The stop hook's assurance plan: Fable's check (2026-11-25)

By Crucible Fable Reviwer, for the owner. Talking only; the owner's go is the only go.

**What I read:** `stop-hook-guarantees.md`, `stop-hook-assurance-plan.md`, and the hook's code: `submit-agent-work.sh`, `held-stop.sh`, `stop-lock.sh`, `report-check.sh`.

**Not done:** I ran nothing. What I say about Claude Code's own behaviour is from memory, not from its docs, so each such point is written as a probe to run, not as a fact.

## Verdict

**The plan is the right shape and I'd agree to it after six additions.** Its four assurances, its order (design, probes, mechanism, real agents) and its rule that scripts do the scoring are right. As written it can still go green while two silent passes exist, and its last step can't be scored by a script.

| # | Addition | Why it matters |
|---|---|---|
| 1 | A fifth assurance: an agent with no job is never silent | today it stops unchecked, with no message and no event |
| 2 | A control run: the matrix must go red with the hook off | without it a green score proves nothing |
| 3 | Faults after the report is accepted | they are the realistic faults, and the plan tests only a missing install file |
| 4 | Two more probes: the hook's time limit, and an agent refused once that never returns | both end a job with no trace |
| 5 | Step 4 scored by counts, over several runs | "the prose misled it" can't be read by a script |
| 6 | The refusal event named for the fact | `job.held` is untrue for the second refusal |

## 1. Are the guarantees complete?

**One is missing, and it comes before the other four.**

**A0: the job is found.** The hook's first step is "no job means the agent stops freely". Everything after depends on `job.assigned` being in the log before the agent stops.
- **How it fails:** the assignment is written by a hook on main's side. If that hook runs only after the agent returns, as it may for an agent that isn't in the background, the stop comes first. The agent's report is never checked, and nothing says so.
- **The assurance:** an agent of a kind that hands in reports never stops without a job silently.
- **The mechanism, simplest first:** the stop hook is given the agent's type. When that type has a `submissions` folder and no job is found, tell the human. No event is possible, because no effort is known.
- **The probe:** the assignment is in the log before the stop, for a background agent and for a foreground one. How the dispatch writes it is the dispatch talk; that it is there in time is this plan's.

**A4 needs its honest limit written down.** "Every outcome is an event" can't hold when the event log itself can't be written. Say it: in that one case the human's message is the record, and the audit script will show the job as open.

**A4 by construction, the owner's call.** The hook ends with a trap that exits quietly on any error. A bug in the new event code would be a silent pass. Two lines close the whole class: the hook notes which outcome it reached, and an exit with none noted is a fault. I'm not reopening G2, which the owner dropped; this covers the code this plan is about to add.

## 2. The new events

| Event | View |
|---|---|
| `job.held` | **Rename, and settle what counts.** Below |
| `job.ended` `fault` | **Yes, with a decision to make.** Below |
| `job.ended` `no-stop` | **Yes.** Who writes it waits for the probes, as the plan says |

**`job.held`.**
- **The name.** The plan writes it on both refusals, and on the second the stop isn't held: it goes through. An event is a fact, so name it for what is true both times: the report was refused. `job.refused` with `try: 1` or `2`, then `job.ended` gave-up after the second.
- **The body.** `{job, iteration, fix_round?, agent, try, lines}`. I'd leave `report` out: the refused file is overwritten by the repair and is never pinned, so a path and a hash would point at nothing.
- **One count, not two.** Today the count is a file, `stops/<seq>.held`. With the event there would be two records of the same fact. Count the events and drop the file.
- **What happens when the event can't be written.** Today a refusal that can't be counted lets the stop through with a bad report. With an event on every refusal that path gets more likely, for example twelve reviewers refused at once. Decide it and test it: I'd still hold the stop, since delivery to the agent matters more than the record, and tell the human.

**`job.ended` `fault`.** The hook has two kinds of fault, and they shouldn't end the same way.
- **Before the check** (a missing submission file or rules): nothing was accepted. Ending the job is right.
- **After the report is accepted** (the stamp, the pin, the working commit, the event, or the lock held too long): the report may already be stamped and read-only, and the tree uncommitted. Ending the job as a fault throws away good work over something that may pass on a second try. The event should say which step failed, so main can tell "start again" from "finish handing in". `recover-submission.sh` already does that for a lost event.

## 3. The probes

**P1 to P4 are the right ones.** Add:

| # | Probe | Why |
|---|---|---|
| P5 | The assignment is in the log before the stop, background and foreground | A0 |
| P6 | What Claude Code does when the hook runs long | The stop lock waits up to 60 seconds, and a commit comes after it. If Claude Code ends a slow hook, the stop goes through with no check, no message and no event. Measure the hook's time with twelve parallel stops |
| P7 | An agent refused once that can't continue (its turn limit or context is spent) | It leaves one refusal and no end. `no-stop` must cover it, not only the agent that never stopped at all |
| P8 | A block reaches a foreground agent as it does a background one | P1 names only the background |

**For P2,** record which hooks fire at all in each case, not only SubagentStop. The design for `no-stop` needs to know what main's side can see without reading a transcript or polling.

**Keep the probes as a kit.** They test Claude Code, not Crucible, so they need running again after each Claude Code update. Record the version in each result.

## 4. The matrix

**The ten kinds are all there, and the kind-specific rules in S2 are well chosen.** Coverage should come from the checks themselves, not from a list either of us wrote. The refusals fall into six classes, and each needs a live case:

| Class | In the matrix |
|---|---|
| The report is missing or misplaced | S3 |
| The report isn't one JSON object | **missing.** A real agent writes a trailing comma or wraps the JSON in a code fence more often than it picks the wrong path |
| A wrong shape or value | S2 |
| A bad location | S6 |
| Something the job carries isn't covered | S2 |
| The tree is wrong | S7, **only for kinds that may change nothing** |

**Add:**
1. **Not one JSON object,** then repaired. Every kind.
2. **A test-writing job that changes a file outside its plan.** The repair there is to the tree or to a `decisions` entry, not to a field, and it is the tester's own largest rule.
3. **Twelve reviewers refused at once.** Twelve refusal events, twelve repairs, twelve submissions, unique IDs. P4 proves delivery; this proves the events under load.
4. **A fault after acceptance.** A scratch repo whose working commit fails. Expected: the event names the step, and the report and the tree are as the event says.
5. **A hot review** in S1 and S4, since the plan names it in scope and it runs through P3's path.

**The scripted side.** One exit criterion for `run.sh`: every distinct repair line in every rules module has a case. That is a count a script can make.

## 5. The steps and the exit criteria

1. **A control run, before anything else is believed.** Run the matrix once with the stop hook not installed. The scoring script must go red on every scenario. A score that can't fail gives no assurance.
2. **Step 4's bar can't be scored.** "No job ends gave-up because the prose misled the agent" needs someone to read why. Replace it with counts per kind: accepted at the first stop, repaired after one refusal, gave up. The bar is zero gave-up.
3. **One run per kind is an anecdote.** Step 3 is deterministic, so once is enough. Step 4 depends on the model, so I'd run each kind three times, on the model the framework will really use. The stand-ins ran on haiku; the result doesn't carry over.
4. **The audit script should check more than "every job has an end".** Also:
   - every submission's pinned report matches its hash;
   - every working commit has its event;
   - every refusal is followed by a submission or an end;
   - no job has more than two refusals.
5. **The sandbox** follows the owner's standing rules: outside the home folder, logged in, with everything a normal run has.

## 6. Two things I'd leave out

- **G6, not counting a first refusal for a missing report.** Leave the count simple. The dispatch's job check refusing a prompt without the report path is the right fix.
- **Any machinery that watches agents.** If the probes show nothing fires when an agent dies, the cheapest design is the dispatch noticing an assigned job the next time it looks, not a watcher.
