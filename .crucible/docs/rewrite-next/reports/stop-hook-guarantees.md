# The stop hook's guarantees: what is in place, what is proven, what is missing

By Dev Beta, at the owner's request: "deeply analyze what we have in place … and did we validate with actual executions."

Code: `new-rewrite/domains/software-development/core/agents/agent-submission/hooks/subagent-stop/submit-agent-work.sh`, plus the steps beside it. Evidence: `evidence/{build,test,review}-agent/run.sh` (scripted) and `live/` (real sub-agents).

## 1. How the agent knows where to write

- The report path is fixed by the job, not chosen by the agent: `reports/<kind>/<job seq>.json` in the effort, in the job's `report` field (`job.dispatched`).
- The agent learns it from its prompt. In the live runs, main's prompt carried `REPORT: <absolute path>`, written by hand in the lab (`live/main-prompt-*.txt`). The dispatch that will build that prompt isn't built yet.
- The stop hook never trusts the agent on where the report is. It reads the job's own path.

## 2. What happens at the stop

All of this is automatic: Claude Code runs the SubagentStop hook, and main does nothing.

1. **Find the job:** the hook finds the job by the stopping agent's id (`job.assigned`). No job means the agent stops freely.
2. **Check the report:** `report-validation.sh`, then `report-check.sh`, then the agent's own rules:
   - **missing, misplaced, or not one JSON object:** refused with `write your report as one JSON object to <the exact path>`. A report written anywhere else is simply not found, so the line tells the agent where it belongs;
   - **every `at`:** must be well formed, name a real file, and point at a line inside it;
   - **the agent's rules:** shape, values, and coverage. A fixer must list every finding it was given (`list SECURITY-01 in fixes`), and may name none it wasn't given. A re-reviewer must give every earlier fix a status. An outside-review judge must judge every thread. A plan rework must answer every challenge;
   - **the tree:** a reviewer or planner that changed files is refused.
3. **Refused:** the hook prints `{"decision": "block", "reason": …}`. Claude Code holds the stop and hands the reason to the same agent as its next input. The reason holds one repair line per problem, under a heading naming the report path. The count goes in `stops/<seq>.held`.
4. **Second refusal:** `job.ended` with `reason: gave-up` is written to the event log, the human is told by a `systemMessage`, the stop goes through, and the tree is kept.
5. **Accepted:** under the effort's stop lock, the report is stamped (IDs), pinned (sha256 and read-only), committed (for jobs that commit), and the submission event is written. If the event write fails after the commit, `recover-submission.sh` rebuilds it from the commit's `Job` trailer.
6. **Fault** (a missing install file, a check that can't run): the human is told by `systemMessage`, the stop goes through, and nothing is counted. The agent can't repair an install, so a fault is never a refusal.

## 3. What is proven, and how

| Path | Scripted proof | Real sub-agent (live) |
|---|---|---|
| Refused, repaired, accepted | yes, every kind | **yes**: builder (summary too long), tester (missing mutation gate), reviewer (edge-case without proof). Each real agent read the reason, fixed it, and stopped again; one held stop each (`live/stops.txt`) |
| Every finding addressed (`fixes`) | yes (`list … in fixes`, declined-twice, unknown ID) | build-fix and test-fix accepted with the finding listed; **no live refusal for a missing fix** |
| Missing or misplaced report | yes (repair line row) | **no** |
| Second refusal, gave-up | yes (4b: `job.ended` gave-up, the human told) | **no** |
| Install fault, told to the human | yes (missing submission file, missing rules) | **no** |
| Event lost after commit, recovered | yes (8) | no |
| Parallel stops, unique IDs | yes (review 12-parallel) | no |

Two limits on the live runs:
- **The agents were stand-ins:** a `code-builder.md` recipe on haiku in the sandbox lab, not the real definitions with plugins. The real definitions have never stopped through the hook. That's the planned integration run.
- **The prompt was hand-written:** the lab wrote main's prompt and a stand-in PostToolUse hook wrote `job.assigned`. Neither is the real dispatch yet.

## 4. Gaps

| # | Gap | Why it matters | Proposed fix |
|---|---|---|---|
| G1 | **A fault writes no event.** The human gets a `systemMessage`, but the job stays assigned forever in the log. | Main, or the harvester to come, can't learn from the log that the job is dead. Only the human's eyes do. | Write `job.ended` with `reason: fault` and the fault line. The log is then the one source, as it is for gave-up. |
| G2 | **jq missing means the stop goes through unchecked**, with only a stderr line, which the human doesn't see. | A silent pass with nothing told is exactly what you ruled out. | Print a fixed `systemMessage` JSON without jq (a literal `printf`). install-check already requires jq, so this is the backstop. |
| G3 | **An agent that never reaches its stop** (killed, turn limit, API error, interrupted). Whether SubagentStop fires then is unverified. | The job stays assigned, with no event and no message. | First a probe of what Claude Code does in each case. Then either the hook handles it, or the dispatch-side harvester treats an assigned job whose agent has finished as ended (`reason: no-stop`). |
| G4 | **Gave-up, a missing report and a fault are not proven live**, only scripted. | Your bar is actual executions. | Add three live cases with real sub-agents: a report written to the wrong path (repaired), two bad stops (gave-up event plus message), and a broken install (fault message plus the G1 event). |
| G5 | **No live refusal for a missing fix.** | The coverage rule you named first has been seen only in scripts. | A live build-fix case whose agent first leaves a finding out, then lists it. |
| G6 | **The report path reaches the agent only through a prompt the dispatch will write.** | If the dispatch leaves it out, the agent can't know. The hook still refuses with the path, so the agent learns it at its first stop, but that costs one of its two tries. | The dispatch's job check refuses a prompt without the report path (dispatch talk). Optionally, don't count a refusal for a missing report the first time (owner's call). |

## 5. Recommendation

Do G1 and G2 now: small, script-only, proven by `run.sh`. Do the G3 probe next, then G4 and G5 as one live run once the probe is known. G6 goes to the dispatch talk.
