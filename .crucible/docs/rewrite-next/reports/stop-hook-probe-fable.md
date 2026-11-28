# The probe results and what they change: Fable's check (2026-11-25)

By Crucible Fable Reviwer, for the owner. Talking only; the owner's go is the only go.

**What I read:** `evidence/stop-hook-probe/results.md`, `stop-hook-probe-implications.md`, and the raw hook inputs saved in `evidence/stop-hook-probe/logs/` for P2b (both runs), P2c (first run), P2d, P5 and P8.

**Not done:** I ran nothing. Where I say what a payload holds, I read it in those saved files, on Claude Code 2.1.332. Each such point should be confirmed by a run made for it before anything is built on it.

## Verdict

**The probes did their job, and the five breaks are real.** I agree with three proposals as they are (B2, B4, B5), and I'd change two (B1, B3). The saved logs already answer two of the three probes still owed, and the answer to P10 makes B1 much smaller than proposed.

| # | Dev Beta proposes | My view |
|---|---|---|
| B1 | two writers, with a main-side hook to design | **One writer, no TaskStop hook.** The fact it needs is already in main's Stop payload |
| B2 | no `maxTurns` on job agents | **Agree** |
| B3 | refuse background shells for job agents | **Agree, with one more thing to probe and one limit to tell the owner** |
| B4 | job agents only in the background, A0 as backstop | **Agree.** Assigning at SubagentStart is ruled out by the logs |
| B5 | an explicit 300 s timeout | **Agree, plus the hook's own time budget** |

## 1. B1: who writes `no-stop`

**This is not the watcher I ruled out.** I meant a process or a timer that looks at agents. A hook that runs when main ends its own turn, and compares the log with a list Claude Code hands it, is neither.

**The fact is already there.** Main's Stop hook is given `background_tasks`: every sub-agent still running, with its id and type.
- In P2d the first Stop lists the agent as running, and the second, after it finished, lists nothing.
- In P2b, after TaskStop, the list is empty.

**The rule, in one line:** when main ends a turn, a job that is assigned, has no submission and no end, and whose agent isn't in that list, has ended: `job.ended` with `no-stop`.

**What follows from it:**
1. **One writer, not two.** After a TaskStop main ends its turn, and the same rule catches it. The separate TaskStop hook isn't needed.
2. **It covers what couldn't be probed.** A transient API error and a spent context end the same way: the agent is gone from the list. The rule doesn't care why.
3. **It covers B2 and P7** (a refused agent that never came back) with no extra case.
4. **Its home** is `agent-jobs`, the job model, not the stop hook's component.

**One limit that must be in the rule.** The hook searches every effort, and the owner runs several sessions. A session must end only the jobs it assigned itself. Otherwise session B, which doesn't see session A's agents in its list, would end A's live jobs.

**What that leaves, and the backstop for it.** A job whose session died (main killed, or Ctrl-C twice, where nothing fires) is never ended by this rule. For that I'd add the invariant, in code that refuses:
- the dispatch refuses a new job on a tree that has an open job;
- an effort can't be closed while it has one.

Main then ends the old job with one script call. This is the certain layer: it holds whatever Claude Code does or doesn't fire. The Stop rule on top makes the common cases automatic.

**To confirm by a run (the reduced P10):**
- while an agent's own stop hook is still running, for example waiting on the lock, is the agent still in main's list? In the first P2c run an agent's own entry is still "running" inside its own stop payload, which suggests yes. If not, the rule would end a job that is about to be submitted;
- after a turn limit and after an API error, does main get a turn, so that Stop fires?

## 2. B3: the stop that fires mid-work

**I agree with refusing background shells for job agents.** It removes the state instead of guessing at it.

**Why the payload can't be used instead.** I looked for it, because it would be simpler. A parked stop does show a running `shell` in `background_tasks`. The list is for the whole session, and a shell entry carries no owner. In the first P2c run one agent's stop lists two shells, and one of them is the other agent's. With twelve reviewers that tells the hook nothing.

**One more thing for P9 to probe.** Does Claude Code ever move a foreground command to the background by itself, for example when it runs past its time limit? If it does, the refusal doesn't stop it, and a parked stop comes back.

**One limit the owner should know.** A foreground command runs for ten minutes at most. A project whose test suite takes longer can't be run in full by a job agent. Its gate becomes `narrowed` or `not_run`, with a note. I think that is acceptable, and it should be said, not found later.

## 3. B4: the foreground agent

**Agree: job agents run in the background, and A0 is the backstop.** The interactive session already runs every agent that way.

**P11 is answered by the logs, and the answer is no.** SubagentStart is given `agent_id`, `agent_type`, `cwd`, `prompt_id` and `session_id`. It has no prompt and no tool-use id. `prompt_id` is main's turn, shared by every agent launched in it, so twelve reviewers would be matched to their jobs by order alone. A wrong match sends an agent's report to another job's check. PostToolUse on the Agent tool has the prompt and the agent's id together, so it stays the one exact place.

**One probe to add, for hot agents.** A job given to a resumed agent is assigned at the SendMessage call. Is that in the log before the resumed agent's stop? P3 shows the hook runs again; it doesn't show the order.

## 4. B5 and B2

- **B5:** agree with the explicit timeout. Add the other half: the hook's own waits (the lock, the commit) must add up to less than it, so the hook gives up first and writes its fault event. A hook that Claude Code kills leaves an open job and nothing else; the rule in section 1 then catches it.
- **B2:** agree. No `maxTurns` on job agents.
- **Helper agents with an empty type:** agree that A0 skips them.

## 5. Probes still owed

| Probe | Status |
|---|---|
| P9: does PreToolUse inside a sub-agent carry its `agent_id` | **Owed.** The saved PreToolUse inputs are all main's own calls and carry none. Add: does Claude Code background a command by itself |
| P10: what tells main an agent finished | **Answered by the logs:** `background_tasks` in main's Stop payload. Two confirmations owed, section 1 |
| P11: can SubagentStart find the job | **Answered by the logs: no.** Drop it |
| New: a hot agent's assignment comes before its stop | **Owed** |

## 6. What changes in the plan's wording

**A4** should say what is now true: every outcome is an event by the time main ends its turn, or, for a session that died, before anything else is done with that tree or effort. "Every outcome is an event" with no time attached promises more than Claude Code allows.
