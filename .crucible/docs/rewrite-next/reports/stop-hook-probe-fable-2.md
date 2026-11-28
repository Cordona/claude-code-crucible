# The four extra probes and the new break: Fable's check (2026-11-25)

By Crucible Fable Reviwer, for the owner. Talking only; the owner's go is the only go.

**What I read:** the new rows P9 to P12 in `evidence/stop-hook-probe/results.md`, and the last three sections of `stop-hook-probe-implications.md`.

**Not done:** I ran nothing, and this time I didn't open the raw logs. The two Claude Code settings I name in section 1 are from memory and must be probed before anyone relies on them.

## Verdict

**Yes, step 2 is settled enough to draft, with one slot left open: how B6 is closed.** The probes confirm the one-writer design for `no-stop` and the refusal of background shells. For B6 I'd try a setting before a hook. One finding in P12 reaches further than the hot agent, and the draft should take it in.

| Point | View |
|---|---|
| P9a, P9b: refuse background shells | **Settled** |
| P10a, P10b: the one writer at main's turn end | **Settled** |
| P12: assign a hot agent at PreToolUse(SendMessage) | **Agree, with two notes** |
| B6: Claude Code backgrounds a command after 120 s | **Real. Try a setting first, then a rewrite, then a deny** |

## 1. B6: the command Claude Code backgrounds by itself

**The proposal works, and I'd rank three ways to do it.**

1. **A setting, if it exists.** As I remember it, Claude Code reads a default and a maximum Bash time limit from its environment settings (`BASH_DEFAULT_TIMEOUT_MS`, `BASH_MAX_TIMEOUT_MS`). If the default can be raised, no hook is needed. If the maximum can be raised too, the ten-minute limit on a test suite goes away with it. The cost: it applies to the whole Claude Code install, not only to job agents, so it is the owner's call.
2. **The hook rewrites the call** to add the time limit (P13). The agent sees nothing, which fits the rule that agents don't know the plumbing.
3. **The hook denies the call** with "add `timeout: 600000`". It works, and it is the worst of the three: every job agent is refused once on its first command, and from then on carries a plumbing habit in every call.

**One more probe, whichever way is chosen.** What happens to a command that runs past an explicit time limit: is it ended, or moved to the background as at 120 s? If it is moved, a ten-minute suite parks the agent again, and no setting or hook prevents it.

**How the hook knows a job agent.** By its type having a `submissions` folder, the same test as A0. Not by looking the job up in the log: that would read every effort's events on every Bash call of every sub-agent.

**What remains after this, said plainly.** A parked stop is a class, and we are closing its doors one at a time: background shells (B3), the 120-second move (B6). A Claude Code update can open another. If one slips through, the result is visible, not silent: the hook refuses "write your report", and at worst the job ends gave-up with its tree kept. Rerunning the probe kit after each update is what finds a new door.

## 2. P12: when a job is assigned

**Agree: a hot agent is assigned at PreToolUse(SendMessage).** Two notes.

1. **The id.** The stop hook finds a job by the agent's id. SendMessage can address an agent by name. For the dispatch talk: a hot job addresses its agent by id.
2. **A send that fails after the hook ran** leaves a job assigned to an agent that never started. The one writer ends it at main's turn end, since the agent isn't in the list. No extra case.

**What P12 also says about a new agent.** It showed that PostToolUse runs alongside the agent, not before it. A new background agent is assigned at PostToolUse(Agent), so the same holds there: nothing orders the assignment before the stop. P5 saw three seconds between them; with twelve launches writing to one log that gap can close.

- **The effect:** the stop finds no job, A0 tells the human, and the report is never checked.
- **The repair, small:** when A0's case arises (a job-taking type, no job found), the stop hook looks again for a few seconds before it tells the human. The wait happens only on that rare path.
- **Whose call:** the owner's. It is cheap, and without it A0 fires for a reason that isn't a fault.

## 3. What the draft of step 2 holds

So the draft is whole, by where each piece lives:

| Piece | Holds |
|---|---|
| The stop hook | A0 by the agent's type, skipping the empty type; `job.refused`, counted from the events; the stop still held when that event can't be written; faults as events naming the step; its own waits shorter than its timeout; the outcome note in the exit trap, if the owner wants it |
| The job model (`agent-jobs`) | the one writer of `no-stop` at main's turn end, for this session's jobs only; the script that ends a stale job |
| A hook on a job agent's Bash calls | refuse background shells; the time limit, by whichever way B6 is closed |
| The installer | the stop hook's explicit timeout |

**What must wait for the dispatch talk.** The owner said the dispatch isn't to be built before that talk. These pieces are the dispatch's, so the draft should name them and leave them to it:
- where `job.assigned` is written, for a new agent and for a hot one;
- refusing a job in the foreground;
- refusing a new job on a tree with an open one.

Until then the assurance runs use stand-ins for them, as the probes did.

**Still owed to me before anything is built:** the review of the event shapes, with the open question from my last reply on whether a job that faulted after acceptance has ended.
