# The stop hook's event shapes: Fable's review (2026-11-25)

By Crucible Fable Reviwer, for the owner. Talking only; the owner's go is the only go.

**What I read:** `stop-hook-event-shapes.md`, against the job model as built: `agent-jobs/scripts/lib/jobs.jq` and `agent-submission/scripts/lib/stamps.jq`.

**Not done:** I ran nothing.

## Verdict

**The shapes are sound and fit the job model as it is. I'd build from them after five changes.** `job.stalled` is the right answer to my open question: the job waits, it ends once, and the log never shows two endings.

| # | Change | Weight |
|---|---|---|
| 1 | The `no-stop` writer must not end a job whose report is already pinned | **high**: it is the one way accepted work is still thrown away |
| 2 | The exit trap writes `job.stalled`, not `job.ended`, once the report was accepted | high, same reason |
| 3 | Finishing a stalled job runs the hand-in again; it doesn't resume at a step | design |
| 4 | Drop `stale`: it is `no-stop` written by another hand | vocabulary |
| 5 | A0 stays silent for an agent that is between jobs | or it fires on every chat with an idle agent |

## 1. What fits, checked against the code

- **`job.refused` and `job.stalled` don't end a job.** `jobs_finish` takes an event as an ending when it is `job.ended` or its body holds a `report` object. Neither new event has one. That is one more reason `job.refused` carries no `report`.
- **A stalled job can still be submitted.** The submission rule refuses a job that "already ended", and it asks `jobs_finish`. A stalled job hasn't ended, so its submission passes with no change to the rule.
- **The stamps** (`job`, `iteration`, `fix_round`, `agent`) are the ones `st_stamps` already gives every job event.
- **`jobs_state` gains one state,** `stalled`. `jobs_open_of`, which finds the job of a stopping agent, takes only `assigned`. So a hot agent whose earlier job stalled is matched to its new job, not to the stalled one. Right as it is.

## 2. The five changes

### 2.1 A pinned report with no event

Two realistic faults leave nothing in the log:
- the event write fails, and `job.stalled` can't be written either, as the draft says;
- Claude Code ends a slow hook after the report was pinned.

For a review, there is no commit, so `recover-submission.sh` has nothing to read. The job is still `assigned`. At main's turn end the agent is gone, and the `no-stop` writer ends it. An accepted, stamped, read-only report is discarded as "the agent never stopped".

**The change:** before it ends a job, the `no-stop` writer looks at the job's report. If it is pinned, it writes `job.stalled` with `step: event`. Otherwise it writes `job.ended` `no-stop`. One check, and the promise "an accepted report is never thrown away" holds in the cases the hook can't record.

### 2.2 The exit trap

The draft has the trap write `job.ended {fault, step: hook}` whenever a job was found. If the unexpected exit comes after the report was accepted, that ends a job whose work is good. The hook already has to note the outcome it reached; let it also note that it passed acceptance. Then:
- before acceptance: `job.ended` `fault`, `step: hook`;
- after: `job.stalled`, `step: hook`.

Add `hook` to the list of steps in the table.

### 2.3 What finishing means

The draft says main's script "finishes the hand-in". I'd fix how: **it runs the whole hand-in again, from the check,** and each step skips what is already done.
- `step` in `job.stalled` is then information for the human, not a place to resume from.
- It is safe for the `lock` step, where the report was accepted and not yet pinned. The file was writable in between, so it is checked again.
- It needs the stamping to do nothing on a report that is already stamped. Please confirm that it does.

**Reuse:** `recover-submission.sh` already finishes a hand-in from a commit. Extend it into the one script, don't add a second.

### 2.4 `stale`

`no-stop` and `stale` state the same fact: the agent is gone and never stopped. They differ in who wrote the event, and the event's `by` already says that. The owner's rule is that a new value needs something that treats it differently, and no script or card here does. I'd keep one reason, `no-stop`, with an optional `note` when main writes it.

**About that script:**
- it should refuse a job this session assigned: those are the hook's, and main can't see the list of running agents;
- it should take a job that is still only `dispatched`, where the agent never started. Nothing else ever ends one;
- another session's job may be alive in another terminal, and no script can tell. Ending one is the human's call, not main's. A gate is the dispatch talk's; the rule should be written down now.

### 2.5 A0 and the idle agent

As drafted, A0 tells the human whenever a job-taking agent stops with no job found. A hot agent that has finished its job, and is then asked a question by main, stops with no open job. That would raise the alarm every time.

**The change:** A0 fires only when the agent's id is in no job at all. An agent that has had a job and has none open stops in silence. The hook already makes that distinction in its first pass over the efforts.

## 3. Smaller

- **Where the rules live.** The writers' table is right. The event rules for `job.refused` and `job.stalled` belong in `agent-jobs/events`, beside `job.ended.jq`: the job model owns the job's words, whoever writes them.
- **The session on `job.assigned`.** The `no-stop` writer and the script in 2.4 both need to know which session assigned a job. Confirm the event carries it.
- **`try`.** The rule can check it is one more than the refusals already in the log, so the count can't drift.
- **A0 looking again for a few seconds** stays the owner's call, as the draft has it.

## 4. The states, as I'd draw them after these changes

```
dispatched ─┬→ assigned ─┬→ submitted
            │            ├→ ended {gave-up}
            │            ├→ ended {fault, step}
            │            ├→ ended {no-stop}
            │            └→ stalled {step} ─┬→ submitted
            │                               └→ ended {fault, step}
            └→ ended {no-stop}      (the agent never started)
```
