# `jobs/assign/SKILL.md`: Fable's prose review (2026-11-27)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `jobs/assign/SKILL.md`, `job-assign.sh`'s `--help` and the lines it prints, the end of `evidence/jobs-2/run.out`, the changed lines of `specs/jobs-structure.md`.

**Not done:** nothing was run. I did not read the hooks or the 54 cases one by one.

## Verdict

**Passes as thin: four sentences and no rule about what follows.** Three cuts make it leaner, and none is needed for it to work.

## The three cuts

1. **"One per message, the next as soon as this one returns, in the same turn" is said three times:** in the skill, in `--help`, and printed with every call. We settled that this line lives in the script's own words so main's prose needs none. Keep it where it is printed (and in the hook's refusal). Drop it from the skill; in `--help`, "send it exactly as printed" is enough.
2. **"The door" is our word from the spikes, not main's.** The skill uses it five times and never says what it is; main has to work out that the door is `job-assign.sh`. Say "the script" or name it. One term less to learn.
3. **The description carries plumbing.** "Writes no event itself; its hooks write job.assigned when the agent starts or the message is sent" sits in main's list in every session, and main can do nothing with it. Enough: what it does and when to use it. The same fact is already in `--help` under "Writes", where it belongs.

**What the body would then say,** in substance: run `job-assign.sh` for a defined job and send exactly what it prints; a job that cuts its tree needs the tree first, and the script says how; `--hot` gives the job to an agent that already ran one, and the script says when a fresh agent is needed.

**Nothing is missing.** When to choose hot is main's judgment, and the checks are the script's. What to do with a job that never starts belongs to `track`.

## One thing to confirm, not a prose fault

"The door says how": check that the refusal for a cut job with no `--tree` names `worktree-cut.sh` and `--tree SEQ` in one line. I saw the agent-file refusal do exactly that ("run agent-init's agent-files.sh on the proposal, then start it from the next turn"); I did not see this one.

## The rest of the message

- **One start hook writing both events, `agent-init` with no hook:** agreed; it is the honest shape, and the spec now says why.
- **The new finding (a fresh cut that another job already uses is refused):** right. A tree someone already works in is not a fresh cut.
- **"A tree start no job claimed: refused."** This is the point from my structure review, and as built it is the case to worry about: installed at user level, it would refuse tree starts in the owner's other sessions. It is marked "to probe before a real install"; keep it a blocker for any real install, not a follow-up.
