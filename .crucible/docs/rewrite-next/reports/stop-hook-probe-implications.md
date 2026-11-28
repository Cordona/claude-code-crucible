# What the probes change in step 2

By Dev Beta. The evidence is `evidence/stop-hook-probe/results.md` (Claude Code 2.1.332). The plan says the owner is told before step 2 when an answer breaks something we rely on. Five do.

## What holds

- **Blocks are reliable:** blocks reach background and foreground agents, every time, with no cap. 2, 8 and 25 blocks in a row each arrived and were acted on (P1, P8).
- **Parallel blocks don't mix:** each of five parallel agents got only its own reason (P4).
- **Resumed agents run the hook again:** a resumed agent's next stop does, with the same `agent_id` (P3). Our count is per job, not per agent, so a hot agent's new job starts at zero.
- **Twelve parallel stops queued on one lock all completed**, the longest at 59 s (P6).

## What breaks, and what I propose

| # | Probe answer | What it breaks | Proposal |
|---|---|---|---|
| B1 | **SubagentStop fires only on a normal end.** Not on the turn limit, TaskStop, the human interrupting, main killed, or an API error. No hook fires at all for an interrupt or an API error (P2, P7). | `job.ended no-stop` can't come from the stop hook, and most abnormal ends fire nothing. | Two writers. (1) **TaskStop:** its PostToolUse fires with the agent's id, so a hook writes `job.ended no-stop`. (2) **Everything else:** the only certain signal is that main is told when a background agent finishes. A main-side hook (Stop or UserPromptSubmit) ends any job whose agent has finished with no submission and no end. This needs a cheap, reliable "agent finished" fact. The candidate is `TaskOutput` or the completion notice, not the debug log. **To design with Fable; one more probe needed.** |
| B2 | **A block on an agent with no turns left is silently lost** (P7). | A refused agent may never see its repair lines. | Job agents get no `maxTurns`, so only context exhaustion remains. B1's main-side writer then catches the silent end. |
| B3 | **SubagentStop also fires mid-work**, when an agent parks on a background shell and ends its turn "waiting". The payload doesn't tell the two apart (P2b run 1). | The hook would check a half-done job, refuse "write your report", and count a try. Two parks would be a false gave-up. | Job agents may not run a background shell: a PreToolUse hook on Bash refuses `run_in_background` for an agent with a job. This needs a probe that PreToolUse carries the `agent_id`. |
| B4 | **Foreground: SubagentStop fires before PostToolUse(Agent)** (P5). Today `job.assigned` comes from PostToolUse. | A foreground job agent's stop finds no job, so its report goes unchecked. That's exactly A0. | Job agents run only in the background: the dispatch refuses a foreground job (dispatch talk). A0's "a job-taking type with no job is told to the human" is the backstop. Alternatively, assign at SubagentStart, if its payload can be matched to the job: a probe. |
| B5 | **A hook killed by its timeout lets the stop through with no trace** (P6t). The default is above 120 s; a per-hook `timeout` is honored. | A slow stop (twelve queued, a slow commit) could pass unchecked. | The installer sets an explicit, generous `timeout` (300 s) on the stop hook, and the stop lock's wait stays well under it. |

Also seen: Claude Code's own helper agents stop with `agent_type: ""`. The hook already lets an agent with no job through, and A0 must skip an empty type.

## Probes still owed before step 2

- **P9:** does PreToolUse carry the sub-agent's `agent_id` (for B3)?
- **P10:** what certain fact tells main that a background agent finished (for B1)?
- **P11:** does SubagentStart's payload carry what is needed to find the job (for B4's alternative)?

## After Fable's verdict (`stop-hook-probe-fable.md`)

- **B1, one writer:** main's Stop payload lists `background_tasks`, every sub-agent still running. A hook in agent-jobs, run when main ends a turn, ends with `job.ended no-stop` any job this session assigned that has no submission and no end, and whose agent is not in that list. It needs no TaskStop hook, and it also covers B2, a spent context and transient API errors. It ends only the jobs this session assigned, because other sessions' agents aren't in its list.
- **A dead session** (main killed, Ctrl-C twice) is covered by invariants that refuse. The dispatch refuses a new job on a tree with an open job, and an effort can't close with one open. Main ends the stale job with one script call.
- **B3:** job agents may not run background shells, so **a job agent can't run a test suite longer than Claude Code's foreground command limit (10 min).** Such a gate is `narrowed` or `not_run`.
- **B4:** background only, with A0 as the backstop. P11 is answered from the logs, and the answer is no: SubagentStart can't be matched to a job.
- **B5:** the hook's own waits (lock, commit) add up to less than its timeout, so it gives up first and writes its fault.
- **A4's wording:** every outcome is an event by the time main ends its turn, or, for a dead session, before anything else is done with that tree or effort.

## Probes still owed

- **P9:** does PreToolUse carry a sub-agent's `agent_id`? Does Claude Code ever background a foreground command by itself, for example past its time limit?
- **P10a:** while an agent's own stop hook is still running (waiting on the lock), is the agent still in main's `background_tasks`?
- **P10b:** after a turn limit, and after an API error, does main get a turn, so its Stop fires?
- **P12:** for a hot agent resumed with SendMessage, is its new job's assignment in the log before its stop?

## The last four probes (results.md: P9, P10a, P10b, P12)

- **P9a, b: yes.** A sub-agent's PreToolUse carries its `agent_id` and `agent_type`. A deny of `run_in_background` reaches the agent, and it goes on in the foreground. B3's refusal works.
- **P9c, a new break (B6):** Claude Code moves a foreground Bash command to the background **by itself after 120 s** when no `timeout` is given. The agent then parks, and its stop fires mid-work. No hook can prevent this once the command runs. **Proposal:** the same PreToolUse hook, for a job agent's Bash call with no `timeout`, either denies it with "add `timeout: 600000`" or sets the timeout itself through the hook's input rewrite. The rewrite is unprobed (P13). Either way, a gate longer than 10 min stays `narrowed` or `not_run`.
- **P10a: yes.** An agent whose own stop hook is still running is still listed as running at main's turn end. B1's writer won't end a job that is being handed in.
- **P10b: yes.** After a turn limit or an API error, main gets another turn, and the list is empty by then. B1's writer sees it.
- **P12:** on a SendMessage resume, only **PreToolUse(SendMessage)** is certain to finish before the resumed agent's stop. PostToolUse can still be running when the agent stops. So a hot agent's new job is assigned at PreToolUse(SendMessage), where the target agent's id is in the tool's input. A new background agent is still assigned at PostToolUse(Agent), proven first by P5.

## Probe still owed

- **P13:** can a PreToolUse hook rewrite a sub-agent's Bash input to add `timeout`? If not, deny with the repair line.
