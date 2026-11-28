# Step 2: the event shapes

By Dev Beta, for Fable's event-shape review, then the owner. It follows the assurance plan v2, the probes (`evidence/stop-hook-probe/results.md`), and Fable's two probe verdicts.

## The job's states

A job is `dispatched`, then `assigned`, then exactly one ending: `submitted` or `ended`. One state is new: `stalled`, meaning the report was accepted but handing it in didn't finish. A stalled job ends exactly once too.

```
dispatched → assigned ─┬→ submitted                     (accepted and handed in)
                       ├→ ended {gave-up}               (refused twice)
                       ├→ ended {fault, step}           (a fault before acceptance)
                       ├→ ended {no-stop}               (the agent is gone with no stop)
                       ├→ ended {stale}                 (main ends it after a dead session)
                       └→ stalled {step} ─┬→ submitted  (main finishes the hand-in)
                                          └→ ended {fault, step}
```

## The events

**`job.refused`** (new type), one per refusal. It is written by the stop hook and holds the stop.

```json
{
  "job": 4,
  "iteration": 1,
  "agent": "a1b2c3",
  "try": 1,
  "lines": [
    "summary is 61 characters; shorten it to 55 or fewer"
  ]
}
```

- The fields are `job`, `iteration`, `fix_round` (on a fix only), `agent`, `try` (1 or 2) and `lines` (the repair lines the agent got).
- The tries are counted from these events, so `stops/<seq>.held` goes.
- If the event can't be written, the stop is still held, and the human is told.

**`job.ended`**, an existing type with new reasons:

| `reason` | Written by | Extra fields | Meaning |
|---|---|---|---|
| `gave-up` | the stop hook, after the second `job.refused` | none | as today |
| `fault` | the stop hook, before acceptance; or main's finish script, giving up on a stalled job | `step` (`check`, `stamp`, `pin`, `commit`, `event`, `lock`), `fault` (the line the human was told) | start again |
| `no-stop` | agent-jobs' hook at main's turn end: a job **this session** assigned, with no ending, whose agent is no longer in Claude Code's `background_tasks` | none | the agent was stopped, interrupted, hit its limit, or errored |
| `stale` | main's script for a dead session's job, refused by nothing else | `note` | main closed it by hand |

**`job.stalled`** (new type), written by the stop hook after acceptance when stamping, pinning, the commit or the event write fails:

```json
{
  "job": 4,
  "iteration": 1,
  "agent": "a1b2c3",
  "step": "commit",
  "fault": "working-commit.sh: index.lock exists"
}
```

- The report is accepted and possibly pinned, so it is never thrown away.
- Main's one script either finishes the hand-in, writing the submission event (the job is then `submitted`), or gives up, writing `job.ended {fault, step}`.
- The `no-stop` writer ignores a stalled job: it ends only `assigned` jobs.
- When the event log itself can't be written, `job.stalled` can't be either. Then the human's message is the record, as A4 says. That's the case `recover-submission.sh` already covers from the commit's `Job` trailer.

## The open question, answered this way

Fable asked: does a job that faulted after acceptance end, with finishing as a new fact, or not end, waiting? This draft takes **"doesn't end, waits"**, as `job.stalled`. It avoids two endings in the log, and it keeps the end-of-turn writer from ending a job that main is still finishing. The other way would need one more new type ("finished after a fault") and an audit exception.

## Not events

- **A0, a job-taking agent with no job found:** there is no job to put it on, so the human is told, and nothing is written. If the owner wants the stop hook to look again for a few seconds first (Fable's point on new agents racing their assignment), it's a small change.
- **The outcome note on an unexpected exit** (the owner said yes): the trap writes `job.ended {fault, step: "hook"}` when a job was found, and otherwise tells the human.

## Writers, by home

| Home | Writes |
|---|---|
| the stop hook (agent-submission) | `job.refused`; `job.ended` gave-up, and fault before acceptance; `job.stalled`; the submission events |
| agent-jobs | `job.ended` no-stop (main's Stop hook); `job.ended` stale, and the finish or give-up for a stalled job (main's scripts) |
| the dispatch, later | `job.dispatched`, `job.assigned` |

## v2, after Fable's review (`stop-hook-event-shapes-fable.md`)

1. **The `no-stop` writer looks at the report first.** If the report is pinned, the writer records `job.stalled {step: event}`, not `job.ended no-stop`, so an accepted report is never thrown away. If it isn't pinned, the job ends `no-stop`.
2. **The exit trap knows whether acceptance was passed.** An unexpected exit before acceptance is `job.ended {fault, step: hook}`; after it, `job.stalled {step: hook}`. `hook` joins the steps.
3. **Finishing a stalled job is one script:** `recover-submission.sh`, extended, not a second script. `step` is information, not a resume point. The script picks up after acceptance:
   - `job.stalled` exists only after the check passed, so the script doesn't re-run the check. A stamped reviewer report carries `id`s, which the check refuses.
   - it stamps only if the report isn't stamped yet, and pins only if it isn't read-only yet;
   - then it makes the commit if the job commits and none is found by its `Job` trailer, and then writes the event.

   Each step is skipped when it's already done. Proof cases cover each `step`.
4. **`stale` is dropped.** It's the same fact as `no-stop`, and `by` says who wrote it, so there's one reason, `no-stop`, with an optional `note`. Main's script:
   - refuses a job this session assigned;
   - accepts a job that is only `dispatched`, whose agent never started, since nothing else ends one;
   - leaves ending another session's live job to the human, written down in the script's help.
5. **A0 fires only when the agent's id is in no job at all.** A hot agent whose job is done, and that stops after answering main, raises no alarm. Plus the brief re-look for a new agent whose assignment races its stop, if the owner agrees.

Smaller:
- the rules for `job.refused` and `job.stalled` live in `agent-jobs/events/`, beside `job.ended.jq`;
- the `job.refused` rule checks that `try` is one more than the refusals already in the log;
- **`job.assigned` gains `session`**: today it carries only `{job, agent, name}`. The `no-stop` writer needs it to pick this session's jobs. The dispatch's assignment writes it.
