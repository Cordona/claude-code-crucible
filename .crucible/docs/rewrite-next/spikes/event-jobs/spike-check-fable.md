# Spike spec check: event-driven jobs (2026-11-23)

By Crucible Fable Reviwer, for the owner, as the independent check of `spec.md` (step 2 of the owner's spike rules). I read the spec, my two answers it builds on, the owner's spike rules, and the new probe's hooks and logged inputs. I ran nothing. Nothing here is a go.

## Verdict: the right spike; seven blockers before the go

- **It covers the scenarios.** Every change in `job-model-fable.md` and every correction in `job-model-loop-fable.md` has a case, except the nine in blocker 6.
- **It can prove the first half of the claim** (the events are guaranteed) once the gaps in blockers 3, 5 and 6 are closed.
- **As written it can pass falsely on the second half** (main needs only thin prose). The 25 lines are counted, but three other places can carry the instruction: the scripted human, the agents' `act`, and the hold reasons. Blockers 1 and 2.
- **The new probe settles what I called the open risk:** a hook can refuse and rewrite a SendMessage, the second hook sees the resumed agent's id, and the resumed agent's end reached main. That was headless. The interactive proof is run C2, and the spec has it.

## 1. Does it prove the owner's claim?

The claim has two halves, and the spec tests them unevenly.

### "The events are guaranteed"

Mostly yes: criteria 1 and 2, Stage A3, Stage B and run C4. Three weak points:

- **"Died" is not guaranteed by anything.** The stop check writes the event for a good end and for giving up. For a death, `job-end.sh` is run by main, and nothing in the 25 lines tells main to. The scan can't know an agent is gone, so it will say "waiting" for ever. Blocker 3.
- **The stop check commits, then writes the event.** If the events lock is held at that moment, the commit exists and the event doesn't. Three reviewers ending together and main writing at the same time make a held lock ordinary here, not rare. No case covers it. Blocker 6.
- **Main is woken more than once.** Three reviewers end, main may take three turns, and each stop runs the scan. Every owed step must be refused when run a second time, or the merge runs twice. No case covers a repeated step. Blocker 5.

### "Main needs only thin prose"

This is where a false pass is possible.

- **The scripted human can do main's thinking.** If my answer at a gate is "review with three reviewers on these file groups, two hot and one fresh", then the prose is thin because the human is thick. The answers must be what the owner would really type: "yes, review it", "fix high and medium, three rounds", "stop the loop".
- **`act` can do it too.** If main has to pass or choose the `act`, main is being fed. The dispatch script must attach it from the fixture, where main never sees it.
- **A hold reason can be a paragraph of steps.** Then the prose moved from the file into the hook. The spec says the reason "names its script"; make that a checked format, one line.
- **Hot or fresh, and the swarm of the first round,** are main's judgement in the real thing. In the spike something has to decide them. It must be one neutral line in `main.md` or a default in the dispatch script, never the answer script.

With those closed, a pass means what the owner means by it.

## 2. Would it catch a false pass?

Seven ways it could pass wrongly today, and what closes each:

1. **Stage A's events are written by hand,** by the author of the scripts. A shape the real hooks never write would pass. Build every fixture by calling `ev.sh`, so a fixture is always an event the lab can produce.
2. **Stage A's expected outputs come from the same head as the scripts.** Write them before the scripts, from the two answers and the old decisions. I can read the case folders before the build; they are small.
3. **The dry run is too thin.** The owner's rules ask for a dry run with simulated agents, and say it caught real bugs every time. "C1 only" is not that. A shell driver that plays main and the agents through the real lab scripts and hooks, with fed hook input, can walk C1 to C9 with no model. Its event sequence is then the expected sequence for the live run.
4. **Pass or fail by eye.** Compare each run's events with the expected sequence by script, per root.
5. **"Nobody typed" is asserted, not shown.** Log every keystroke the tmux driver sends, with its time. Any send between `fix.chosen` and the end card fails the run.
6. **"Main only did what was named" is not checked.** The lab's PreToolUse hook already sees every tool call main makes. List main's calls inside the loop from that log; anything that is not a named script, the call it printed, or a gate is reported.
7. **A stand-in that doesn't follow its `act`** tests another case than the one named. For each case that depends on bad behaviour (no report, a broken report), show the refusals in the hook log.

One more guard the spec half has: stop rule 4 forbids patching prose to pass. Record the hash of `main.md` before C1 and show it unchanged after C10.

## 3. Coverage against the two answers

Covered: end states, root and unique IDs, the busy rule, rules declared per component, facts against held stops, the round as one event, cold and hot delivery, the type check, accept-or-insist inside the re-review, the arbiter in the round's set, the harvest, the derived swarm, the human's stop, one replacement, a refused step ending the loop, the cap of one first, every kind.

**Missing, each a small case:**

| Missing | Where it belongs |
|---|---|
| The events lock held while an agent stops: one commit, one event, after the release | B |
| A report refused because the tree's tip moved (the tip moved by hand) | B |
| A second Agent call with a `JOB:` line already assigned | B |
| Main writing an event file directly is refused | B |
| A repeated step is refused: a second merge, a second round for one fix, a second choice | A |
| Two builds, then one round covering both: both "no review" facts clear | A1 |
| One `fix.chosen` leading to two fix jobs (production and tests); the next round waits for both | A2 |
| A fix with every finding declined: no commit, the round still made | A2 |
| A deadlocked key is not given to a re-reviewer in its round | A2 |

Two rules from the old decisions are in the spec only loosely:
- **`choose.sh` takes `{ids, cap}`.** D4 says main passes a query and the script resolves the IDs. Test it that way, with one refusal.
- **The fixer sees only the chosen findings.** Check the fix job's file in A5.

Also say which approval covers the gateless second plan job. The refusal list covers only the loop.

**Not tested, and fine for a spike, but say so in the results:** how the facts meet an agreed adaptive flow (the lab has no flow); a real permission mode (the probes ran with permissions bypassed, and in real use a prompt to an absent human would stall the loop).

## 4. The blockers, in one list

1. **Nothing but `main.md` instructs main.** The human's answers are human words, written before the run and kept as evidence. `act` is attached by the dispatch script. Hot or fresh comes from one neutral line or a script default.
2. **Measure all the prose main reads:** `main.md`, every hold reason, every fact line, every `--help` main opened. A hold reason is one line in a fixed form. `main.md`'s hash is recorded before C1.
3. **"Died", honestly.** Say who writes `job.ended` in each case. Add the one neutral line main needs, or show in Stage B what the harness reports when an agent is stopped. Make C10 the real death (section 5).
4. **Fixtures through `ev.sh`; expected outputs first; the dry run as a scripted driver for every run.**
5. **Repeated steps are refused,** as cases.
6. **The nine missing cases** in section 3.
7. **Pass or fail by script:** the sequence compare, the driver's keystroke log, main's tool calls from the hook log.

## 5. Section 8's open points

- **"70%" for hot reuse: enough for the spike.** Hot or fresh is not what is being proven. The condition is blocker 1: the choice must not come from the answer script. C1's "one fresh reviewer" should come from the fixture (that reviewer's earlier job ended badly, so it can't be reused), not from an instruction.

- **"Died": TaskStop is a fair stand-in for a cancel, not for a death.** Main calls it, so main knows. Two better stand-ins, both cheap:
  - **Close the session while an agent is working.** That is the death that really happens. After the reopen the job is assigned, has no end, and its agent is gone. C10 should close at that moment, and once more while nothing runs. Reopening needs one human message; say so, and count it as the only input.
  - **In Stage B, log what fires when an agent is stopped:** whether the stop hook runs, with what input, and what main is told. If the hook runs, it can write the end event itself and main needs no line for it.

  A crash inside the harness can't be staged. Record it in the results as shown by simulation only, as the owner's rules ask.

- **The 25-line cap: keep the number, but it is not the measure.** Report the total from blocker 2, and beside it the size of what the old rewrite needed for the same ground (the build, test and review flow skills and the seat-run references). The owner's claim is about that ratio. In the real framework the lines will be spread over several skills, so a single cap won't carry over anyway.

- **C2 twice: three times, and C1 twice.** One pass of a model-driven loop shows it can work, not that it does. Report n of n. Any run where main asks the human or does a step nobody named is a fail to report, even if the loop then finishes: the design recovers from a dropped step by holding the stop again, so the events alone would hide it. Record how many holds came in a row, and the model and effort main ran with.

## 6. Size and order

The spike is close to the real build with stand-ins: seventeen scripts, five agents, ten live runs. That is what "every scenario" costs, and Stage A carries most of the proof cheaply. Two suggestions, not blockers:

- **Run order in Stage C:** C1 to C6 and C10 decide the claim. C7 to C9 show kinds whose rows Stage A already proved, on the same mechanism. Run them last; if time is short they are the ones to cut, and the results should say what stayed offline only.
- **Keep the stop rule sharp.** A failure in Stage A is a failure of the model's logic and should stop everything. A failure in C7 to C9 is a missing row.

## 7. What I can do after

Read the Stage A case folders before the build, and judge `results.md` against the evidence once the runs are done. Both are reading only, on the owner's word.
