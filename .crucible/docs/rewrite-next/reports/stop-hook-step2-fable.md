# The step 2 build: Fable's review (2026-11-25)

By Crucible Fable Reviwer, for the owner. Design level. The owner's go is the only go.

**What I read:** `stop-hook-step2-build.md`, and the code as built: all of `agent-jobs` (event rules, `jobs.jq`, `iteration.jq`, `job-of.sh`, `end-gone-jobs.sh`, `end-job.sh`), and in `agent-submission` the stop hook, `held-stop.sh`, the two fault writers, `recover-submission.sh`, `job-agent-bash.sh`, `stop-lock.sh`, the stamping step, plus the installer's diff.

**Not done:** I ran nothing. The runner counts (258, 109, 109, 59) are Dev Beta's; I didn't rerun them. Two facts about Claude Code below are read from the saved probe logs (P1, P12), on 2.1.332.

## Verdict

**The build matches the agreed design, and my five changes to the event shapes are all in. I'd take it to step 3 after one fix (item 2), and I'd change two things before the owner relies on it (items 3 and 6).**

| # | Dev Beta's point | My view |
|---|---|---|
| 1 | The Bash hook rewrites without "allow" | **Right as built.** What to do if P15 says no is the owner's call |
| 2 | `recover-submission.sh` sits where main can't run it | **Move it to `scripts/main/`. Must be fixed before step 3** |
| 3 | An unrecorded refusal holds the stop every time | **Bound it to one hold,** with a field the hook already gets |
| 4 | `iteration.jq`: every unaccepted end reuses the number | **Agree** |
| 5 | `end-job.sh` turns a pinned report into stalled | **Agree,** with two small wording fixes |
| 6 | The installer greps agent prose for "longer than N minutes" | **I'd drop the number from the prose, and the check with it** |

## 1. What I checked and found sound

- **The states.** `job.refused` and `job.stalled` don't end a job; a stalled job isn't matched to its agent again; a hot agent between jobs passes in silence; a stalled job can be submitted or ended `fault`, and nothing else.
- **The exit trap.** Every exit path notes an outcome, and one that doesn't becomes `job.ended` or `job.stalled` at step `hook`, by whether the report was accepted. A kill signal goes the same way.
- **The count of tries** comes from the events, and the rule refuses a `try` that isn't the next one. A job refused twice whose end couldn't be written is ended at its next stop with no third refusal.
- **The one writer of `no-stop`** touches only this session's jobs, and turns a pinned report into `job.stalled`.
- **A resumed agent is in main's list.** I checked this because the writer would otherwise end a hot job the moment it was assigned. In the P12 logs every main Stop during a resume lists the resumed agent as running.

## 2. Dev Beta's six points

### 2.1 The Bash hook without "allow" (item 1)

**Right.** A hook whose job is timing shouldn't change what the human is asked to approve. With "allow" every job agent's command that names no time limit would skip the human's permission rules.

**If P15 shows the rewrite is ignored outside bypass mode,** don't fall back to "allow". The two ways left are both worse, and choosing is the owner's:
- raise `BASH_DEFAULT_TIMEOUT_MS` for the whole install. No hook then, but a hung command in the owner's own sessions also waits 45 minutes before Claude Code backgrounds it;
- deny with "add a timeout", which teaches every job agent a plumbing habit.

### 2.2 `recover-submission.sh` (item 2)

**Move it to `scripts/main/`. As built this is a dead end:**
- the stop hook tells the human to run it;
- `end-job.sh` refuses a stalled job and points at it;
- main is denied `scripts/internal/`, and its help says "not for main to call".

So a stalled job can be neither finished nor ended by anyone. The design always had main finish the hand-in.

**Skipping the check on `--finish`:** I had asked for the whole hand-in to run again from the check. The build's reason for not doing it is good: a stamped report is no longer the one the agent wrote, so the agent's rules would refuse it. I accept it.

**One thing it leans on:** stamping a stamped report must change nothing. That is a property of each agent's own stamp rules, not of the plumbing. Say it where the stamp rules are described, and keep one proof case per agent that has them.

### 2.3 The unrecorded refusal (item 3)

**Holding is right. Holding without end isn't needed.** The hook's input carries `stop_hook_active`, which the P1 logs show as true on a stop that follows a block. So:
- a refusal that can't be recorded, on a first stop: hold, tell the human (as built);
- the same on a stop that already follows a block: let it through, tell the human.

That bounds the loop at one extra hold, with no file and no count. The job stays assigned, and main's turn end ends it or says it couldn't.

### 2.4 `iteration.jq` (item 4)

**Agree.** A build that ended before acceptance made no commit, whatever the reason, so its number is free. A build that stalled and was given up may have made its commit, so it keeps its number. The cost is a number with no commit when it stalled before the commit step, which harms nothing.

### 2.5 `end-job.sh` and the pinned report (item 5)

**Agree: it is the same promise as the no-stop writer's.** Two small fixes:
- when it writes `job.stalled` instead of ending the job, main should be told so in a line, since it asked for an end and only gets an event path back;
- its help says `--other-session` "records" the human's call. Nothing in the event records it. Reword the help; the event's writer already implies it.

`pinned()` is written twice, in `end-job.sh` and `end-gone-jobs.sh`. Give it one home in the component's lib.

### 2.6 The 45 minutes, in three places (item 6)

The number now lives in the framework's installer, in two agents' prose, and in a check that greps the prose for a phrase.

**What is wrong with that:**
- the framework's installer holds a number that belongs to one domain's job agents, and knows a phrase from their prose;
- the check passes in silence the day someone rewords the line, for example to "more than 45 minutes";
- an agent can rarely know that a command will take 45 minutes before it runs it.

**What I'd do:**
1. **The prose keeps only what an agent can act on:** "Don't start a command that never ends (a watch mode, a server in the foreground)." No number, so no check.
2. **The number gets one home in `agent-submission`,** beside `matchers.json`, as an env need the installer collects the way it collects hooks. The installer then knows no domain's number.

**What that gives up:** an agent that reads in the project's docs that the full suite takes an hour no longer knows there is a limit. It finds out when the command is backgrounded and its stop is refused once. I think that is the cheaper side; the owner approved the line, so it is the owner's call.

## 3. For the dispatch talk, noted only

- A fix needs its iteration's build to have been submitted. Today the newest build's number is the tree's current one even when that build ended.
- Who decides `--give-up` on a stalled job: it discards an accepted report, so it may deserve the human's word, as ending another session's job does.
