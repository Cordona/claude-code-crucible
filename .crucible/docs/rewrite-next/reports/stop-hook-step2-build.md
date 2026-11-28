# Step 2 build: what to build, piece by piece

By Dev Beta. The owner's go: 2026-11-25. Sources, in order of authority:
1. `stop-hook-event-shapes.md` (with its v2 section) and `stop-hook-event-shapes-fable.md`;
2. `stop-hook-assurance-plan.md`;
3. `stop-hook-probe-implications.md`, `stop-hook-probe-fable.md` and `stop-hook-probe-fable-2.md`;
4. `evidence/stop-hook-probe/results.md`, Claude Code's behaviour as probed.

Code lives under `new-rewrite/domains/software-development/core/`:
- `agents/agent-submission/`, the stop hook;
- `main-thread/agent-jobs/`, the job events and the job lib;
- the installer, `new-rewrite/framework/core/install/`.

## Rules for the build

- **Agents share plumbing only.** Each component owns its own rules. Never make one agent's lib import another's.
- **SRP:** one script does one thing. A new step is a new script beside the others.
- **Every new or changed behaviour gets cases** in the scripted proofs, `evidence/{build,test,review}-agent/run.sh`, or a new `evidence/agent-jobs/run.sh`. All runners end at 0 FAIL.
- **`--help` is each script's contract,** in the same short style as its neighbours.
- **No process traces in shipped files:** no IDs, history or owner notes in comments.

## The pieces

**1. `job.refused`** (agent-jobs `events/job.refused.jq`):
- body `{job, iteration, fix_round?, agent, try, lines}`;
- written by the stop hook on each refusal;
- the rule checks that `try` is one more than this job's earlier `job.refused` events, and that the job is assigned.

`held-stop.sh` becomes the step that writes it, counting the tries from the events. `stops/<seq>.held` goes. If the event can't be written, the stop is still held, and the human is told by a `systemMessage`.

**2. `job.ended`** (widen `events/job.ended.jq`):
- reasons:
  - `gave-up`, by the stop hook;
  - `fault` `{step, fault}`, by the stop hook before acceptance, or by the finish script's give-up;
  - `no-stop` `{note?}`, by the agent-jobs Stop hook or by main's end-job script.
- `step` is one of `check`, `stamp`, `pin`, `commit`, `event`, `lock`, `hook`.
- `by` limits who may write each reason.

**3. `job.stalled`** (agent-jobs `events/job.stalled.jq`):
- body `{job, iteration, fix_round?, agent, step, fault}`;
- written by the stop hook after acceptance, when stamping, pinning, the commit, the event or the lock fails, or on an unexpected exit;
- also written by the no-stop writer when the report is already pinned;
- a stalled job can still be submitted, or ended `fault`. Check this against `jobs.jq`'s `jobs_finish` and `jobs_state`. Add a `stalled` state that isn't `assigned`.

**4. `job.assigned` gains `session`** (Claude Code's `session_id`):
- required;
- update the lab stand-in `assign-job.sh` in each `evidence/*/live/lab/` and the proof fixtures.

**5. The stop hook's outcomes** (`submit-agent-work.sh` and its steps):
- **before acceptance,** a fault becomes `job.ended {fault, step}` plus the `systemMessage`;
- **after acceptance,** a fault becomes `job.stalled {step}` plus the `systemMessage`;
- **the EXIT trap** notes the outcome reached. An exit with none noted writes `job.ended {fault, step: hook}` before acceptance, `job.stalled {step: hook}` after it, or, with no job, just the `systemMessage`.

**6. A0** (the stop hook):
- **when it applies:** the stopping agent's `agent_type` is non-empty, has a `submissions/` folder, and its `agent_id` is in no job at all, in any effort;
- **what it does:** look again for up to about 5 s (a few short retries), then tell the human by a `systemMessage`. No event, since there's no job.
- **left alone:** an `agent_type` that is empty, or has no submissions folder, is let through silently, as today. So is an agent whose job is already done (a hot agent answering main).

**7. Waits under the timeout:**
- the stop lock's longest wait plus the commit's must stay under the hook's own timeout (300 s);
- set the lock wait to at most 120 s;
- on running out of time, the hook writes its own fault and doesn't get killed by Claude Code.

**8. The no-stop writer** (agent-jobs, new Stop hook for main, `hooks/stop/`):
- its input is main's Stop hook JSON, which has `session_id` and `background_tasks` (the running sub-agents, with id and type; see the probe logs P2d and P10a for the exact shape);
- for every effort, it takes each job with `job.assigned.session == session_id`, state `assigned`, and an agent not in `background_tasks`;
  - if its report exists and is read-only (pinned): `job.stalled {step: event, fault: "the agent ended after its report was pinned"}`;
  - else: `job.ended {reason: no-stop}`.
- it prints nothing to block main, and a failure is a `systemMessage`.

**9. Main's end-job script** (agent-jobs `scripts/main/end-job.sh --effort --job --note`):
- writes `job.ended {reason: no-stop, note}`;
- refuses a job this session assigned that is still running (the writer handles it);
- accepts a job that is only `dispatched`;
- **another session's assigned job:** its help says that's the human's call. It takes `--other-session` to do it on the human's word.

**10. Finishing a stalled job:** extend `agent-submission/scripts/internal/recover-submission.sh` into the one script, `--finish` or `--give-up`.
- **`--finish`** skips the check, since `job.stalled` exists only after acceptance. Then:
  - it stamps only if the report isn't stamped yet (prove that stamping a stamped report is a no-op, or detect it);
  - it pins only if the report isn't read-only;
  - it commits only if the job commits and no commit carries its `Job` trailer;
  - then it writes the submission event.
- **`--give-up`** writes `job.ended {fault, step}`.

**11. The job-agent Bash hook** (new, in `agent-submission`, `hooks/pre-tool-use/job-agent-bash.sh`):
- **trigger:** PreToolUse on Bash, from a sub-agent whose `agent_type` has a `submissions/` folder. The input carries `agent_id` and `agent_type`, as P9a proved;
- **a background call:** `run_in_background: true` is denied. The reason, in plain words, says to run it in the foreground;
- **no `timeout`:** the hook allows the call with `updatedInput` setting `timeout` to the value of `BASH_MAX_TIMEOUT_MS`. Its source depends on P14 (Dev Beta will tell you): the hook's environment, or else a value the installer hands the hook;
- **anything else** passes unchanged;
- the shapes are as proven in P9b and P13b (`hookSpecificOutput`, `permissionDecision`, `updatedInput`).

**12. The installer** (`install-entries.sh`, and `install-check.sh` to check it):
- settings `env.BASH_MAX_TIMEOUT_MS = "2700000"`;
- the SubagentStop hook gets `"timeout": 300`;
- register the PreToolUse(Bash) hook (piece 11) and the agent-jobs Stop hook (piece 8);
- install-check also checks that the builder's and tester's prose line names the same minutes as the setting.

**13. Prose:** one line in `code-builder.md` and `code-tester.md` (`## Work`):

> Don't start a command that may run longer than 45 minutes, or one that never ends (a watch mode, a server in the foreground). Run the checks that cover your change, and report the rest as `narrowed`.

## Proof cases to add (scripted)

- a refusal, then acceptance: `job.refused` try 1, no `.held` file;
- two refusals: `job.refused` tries 1 and 2, then `job.ended` gave-up;
- a refusal event that can't be written: the stop is still held, and the human is told;
- a fault before acceptance: `job.ended` fault, step check;
- a fault after acceptance: one case each for stamp, pin, commit, event and lock, giving `job.stalled` with that step;
- an unexpected exit, before and after acceptance;
- A0: no job, with a submissions type, gives the message after the re-look; an empty type passes silently; a done job's agent passes silently;
- the no-stop writer:
  - this session's job, agent gone, not pinned, gives `job.ended` no-stop;
  - pinned gives `job.stalled`;
  - another session's job is untouched;
  - a running agent is untouched;
- end-job.sh: refuses a running job of its own session; ends a dispatched-only job; ends another session's job only with `--other-session`;
- finishing a stalled job at each step, and giving up;
- the Bash hook:
  - a background call is denied;
  - a call with no timeout is rewritten to the limit;
  - an explicit timeout passes;
  - main's own call, and a non-job agent's call, pass;
- install-check: a prose mismatch is caught.

The proofs use short values (about 30 s), set through the same setting, never 45 minutes.
