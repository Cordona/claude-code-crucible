# The step fixes and the read sealing as built: Fable's look (2026-11-25)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `agent-jobs/scripts/internal/agent-job.sh` in full, the core of `agent-had-job.sh`, how the stop wrapper and `write-scope.sh` call the lookup, and the lines of `deny-sealed-reads.sh` that hold the sealed list and the two reasons.

**Not done:** I ran nothing; the runner counts are Dev Beta's. I did not reread the other steps or the install check's contract.

## Verdict

**Sound. Nothing to change before the matrix rerun.** The one lookup is right, the race it exposed is closed the right way, and the sealed list is the one I proposed.

## 1. The one job lookup, and the race

**The race was real, and it mattered.** A new agent's assignment could land between two reads. The first read said "no open job", the second said "this agent has had a job", and the two together read as "between jobs". Its stop then passed in silence: no check, no message. That is the exact failure this whole effort exists to remove, and it sat in the code that step 3 scored green.

**The fix is right.** Before it believes "between jobs", the lookup asks for the open job once more. I walked the three orders the two reads and the write can come in:
- the assignment lands before both reads: found;
- it lands between them: found on the second ask;
- it lands after both: "never assigned", and the stop hook looks again for five seconds, as before.

**Worth saying to the owner:** this was found by moving code to one home, not by a test. The matrix could not have caught it, because it needs an assignment and a stop within the same instant. It is the best argument so far for the owner's rule of small single-purpose scripts.

**One small window that remains, and I'd leave it.** `write-scope.sh` calls the lookup without the wait. A new agent that writes a file in the first moment, before its assignment is recorded, gets no answer from the hook, so Claude Code asks or refuses that one write. An agent reads before it writes, so I don't expect it. A wait there would slow every write of every idle agent. If the trials ever show a first write refused, this is where to look.

## 2. The sealed list

- **It is a list of sealed folders,** with `scripts/main/` added for an agent's call only. Everything else stays readable.
- **The reason an agent gets** says what it should do: work in its tree and write its report. It names no script and no hook.
- **The plugin check** answers my open point: plugins hold only `SKILL.md` and `references/`, so none can sit in a sealed folder.
- **Stray folders, not stray files:** enough. A stray file can't hide in a sealed folder's place.

## 3. One thing for the owner to know

The framework's own guard now names `submissions/`, a folder only the software-development agents have. Two older checks existed to stop the core naming it, and they were narrowed for this.

I accept it: the folder contract belongs to the framework, so its names do too. But it is the first domain word in the core since the rewrite began. If a second domain arrives with a different word for the same thing, that list is the place to revisit.
