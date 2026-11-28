# Plan: the repair loop, refused reports reaching the human, and `source`

Three findings from the fourth live run (`evidence/jobs-live/results.md`). The plan goes to Fable first; nothing is built before her approval.

## 1. The repair loop never runs for a backgrounded agent (task #86)

**What the run showed.** Claude Code runs job agents in the background. An agent ends its work by calling `SubagentHandback`, which delivers its report message to main. The report check runs in the SubagentStop hook (`agent-submission`), after the handback. Its refusal is recorded (`job.refused`), but the agent has already handed back and ended, and the job ends `no-stop`. Jobs 17, 24, 42 and 48 each ended after one refusal.

**Probe first** (sandbox config, stand-in agent, haiku, no framework), four questions:
1. Does PreToolUse fire for `SubagentHandback` inside a subagent, and does its input carry `agent_id` and `agent_type`?
2. When that hook denies, does the agent get the reason and keep working in the same run (then hand back again)?
3. Does a SubagentStop block, after a handback, ever restart a backgrounded agent? (Expected: no.)
4. Does an agent that is denied twice end without handing back, and what does main see then, and when? Is anything before main's own stop able to carry a line to main?
5. A control: the same stand-in started in the foreground. Does it hand back or just stop, and does a SubagentStop block restart it? This says which path build-agent's "8-recovered" repair took, when each door applies, and whether the stop hook backstop is live or dead code.
6. Is `SubagentHandback` documented by Claude Code, or an internal we observed? The answer goes in the results. If it's internal, the design must fall back to exactly today's behaviour when it changes, and nothing may depend on its name beyond the one hook matcher.

**The doors (probe, 2026-11-28):** in auto mode the handback is the door; in every other mode, and for an agent that stops without handing back, the stop hook is. The owner's sessions are always in auto mode, so before this the repair loop never ran live for them.

**The fix, if questions 1 and 2 are yes:** run the report check at the handback. A PreToolUse hook on `SubagentHandback` for job agents runs the same check the stop hook runs, and denies with the same repair lines.
- **One check, two doors:** it calls agent-submission's existing check step and duplicates nothing. The SubagentStop hook stays as the backstop, for an agent that stops without handing back.
- **Same limits:** the same lock, and the same two tries before the job is stalled.
- **Report only:** a handback that passes the check writes the submission, as the stop hook does today. The stop hook then finds the job already handed in and passes.
- **A handback that doesn't complete after the check passed:** the submission stands. The stop hook finds the job handed in and passes, and never writes a second submission. agent-submission's runs get this case.

**If the answer is no:** I stop and bring what the harness does to Fable and the owner, with nothing built around it.

**Evidence:**
- agent-submission's runs get the handback cases: refused, then repaired, then accepted, and refused twice, then stalled.
- **Live:** a job whose first report is refused, repaired and accepted in one agent run. That closes the changed case of the remote kinds green.

## 2. Main relayed refused reports as verdicts (task #85)

**Mostly closed by 1.** With the check at the handback, a refused report never reaches main as a message: the agent can't hand back until its report is accepted.

**What is left, script side:** an agent that ends without an accepted hand-in, after a second refusal, an interrupt or its turn limit. `end-gone-jobs.sh` already writes `job.ended` or `job.stalled` for it.
- **Timing:** it runs at main's own stop, after main has written its turn to the human. A line from it corrects; it can't prevent.
- **The probe answered it (question 4):** with the check at the handback a refused report is never delivered, and Claude Code itself tells main an agent "ended without sending its report". So no `systemMessage` is added. Kept as a check for the live run: a twice-refused job, and what main does when it resumes that agent on its own.
**Was:** the probe's question 4 says what main is handed, and when. If something earlier than main's stop can carry the line, it goes there. If not, `end-gone-jobs.sh` prints one `systemMessage`, `job N ended without an accepted report; it has no verdicts`, and the spec says plainly that it comes after the fact. No prose line to main.

**Evidence:** the jobs-track (agent-jobs) run gets the case, and the same live run covers it.

## 3. `source` on an external-review item

Fable's simplification, which I agree with: `source` is not the agent's to write. The report rule stops refusing over it. The stamp sets every item's `source` from the thread's opener, overwriting whatever the agent wrote. One branch less, and no job fails over a field it doesn't own.

**Evidence:** the review-agent run's two `source` rows become one: a written source, right or wrong, is replaced by the thread's.

## Order

Probe 1, then the fix, then 3, then 2, then one live run covering all of it. Every evidence run stays green throughout.
