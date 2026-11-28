# Baseline C1 runs 6 and 7: verification (2026-11-24)

By Crucible Fable Reviwer, for the owner, on `baseline-brief.md`. Not a go; the owner's go is the only go.

**What I did:** listed every tool call of main in both runs from `effort/hook-log/scope-*`, in order; read both `compare.json` files and `effort/stops/main-stop.out`; read `lab/deny-internals.sh` and the matching lines of the real `deny-internals-read.sh`; ran `--help` on seven lab scripts (no effort given, nothing written). I did not read the agents' calls or the events themselves.

## Verdict

- **Finding 1 is right, and larger than the brief says.**
- **Finding 3 is right,** in the lab and in the real guard.
- **Fix A is sound but won't be enough alone,** and one cause of the stray steps is missing from the brief: **`--help` is broken on every lab script.** Fix that first.
- **Finding 4: leave the classifier.**

## 1. Finding 1: main works out the next step itself

Confirmed, with three additions from the logs.

- **It is the whole run, not the moment after the fix.** Main ran `owes.sh` seven times in run 6 and eight in run 7: after the build, after the reviewers, after the merge, after the choice, after the fix, after the second merge, after the end.
- **The stop hook held only twice per run, of twelve stops.** The dry run expects seven holds. The two that fired were the replacement and the first merge. Every other step main found by itself. So the baseline shows the sequence holds, but it says little about held stops driving the loop: main mostly got there first.
- **The hand-built round was refused by the script** (`round.sh … --kinds shell,security,clean-code` in run 6, then the correct call without kinds). That is the design working: main guessed, the code refused, nothing wrong was written.

Two details in the brief check out exactly: `gate.sh --owed make-round` in run 6 (main also tried `gate.sh --owed merge`), and `merge.sh` chained with `owes.sh` in run 7. Main was using `gate.sh --owed` as a way to turn the raw answer into a command. It was looking for a ready line and had no door to one.

**Main also read event files directly:** `cat $E/events/000019-*.json` and `jq -c .body $E/events/000035-*.json` in run 6, `ls $E/events | tail -15` and `view.sh --help` in run 7. This matters for fix A, below.

## 2. Not in the brief: `--help` doesn't work

`main.md` tells main every script has `--help`. Run with `--help` alone, all seven I tried (`gate`, `job-dispatch`, `round`, `merge`, `choose`, `loop-end`, `owes`) print "`--effort is required`" and nothing else.

- Both runs open the same way: `./gate.sh --help`, then `sed -n 1,80p gate.sh`.
- Run 6 later: `job-dispatch.sh --help`, then `sed -n 1,30p job-dispatch.sh`.
- Every `sed` of a script in the unnamed lists (`round.sh`, `job-dispatch.sh`, `merge.sh`) follows from this. Main was told to read the help, the help gave nothing, so it read the source.

That accounts for two of run 6's four unnamed steps and two of run 7's five. It is a lab fault, not main's judgement, and it must be fixed before another run is scored. Otherwise the next baseline counts the same fault again.

## 3. Finding 3: the guard gap

Confirmed by the code. The guard splits the command into words and resolves only words that start with `/`, `~` or `$HOME`. `$L/*.jq` starts with `$L`, is taken as a path under the working folder, and falls outside the lab. The real guard has the same split and handles only `~`, `$HOME` and `${HOME}` (its lines 51 to 52 and 86 to 87).

I agree: note it for the real build, don't fix it in the spike. One line for that note: a guard that parses shell text will always have a gap like this, so it should be counted as a fence against wandering, not as a wall.

## 4. Fix A

**Sound, and in line with my change 3.** Raw `owes.sh` output is a contract between scripts. Main misread it twice (the kinds, `gate.sh --owed merge`), so it should not be main's to read. That holds for the real framework too.

**But hiding `owes.sh` alone leaves the roads main already used:**
- `view.sh` is on the guard's main-facing list;
- so are `harvest.sh`, `busy.sh` and `orphans.sh`, which nothing in `main.md` or a printed line names;
- the events folder is outside the lab, so the guard doesn't cover it at all.

A main that wants to know what is next, and finds the scan closed, will read the events and rebuild the answer by hand. That is worse than what we have now.

**What I'd do, in this order:**

1. **Fix `--help`.**
2. **Fix A, made whole:** the main-facing list is only what `main.md` or a printed line names (`gate`, `job-dispatch`, `round`, `merge`, `choose`, `loop-end`, `remote`, `import`). The owed line carries its instruction.
3. **Run C1 twice and watch one thing:** does main end its turn and take the held line, or does it go to the event files? Say before the run that reading events to work out a step fails it.
4. **If it goes to the events: give it the door instead of taking away more.** One main-facing way to ask "what is owed now" that prints the same ready lines the stop hook prints, from the same code. Main asks, gets the exact line, runs it; the held stop stays as the net for when it forgets. I expect this is where it ends up: asking a script is a natural act for a model, and ending a turn in order to be stopped is not. But steps 1 to 3 are smaller, so they go first.

Either way the claim under test is the same: the events decide the next step, and main needs only thin prose. Whether the line reaches main by a held stop or by a script it asks is a delivery choice, and the baseline suggests main prefers to ask.

## 5. Finding 4: the classifier

**Leave it.** After fix A the `owes.sh` chains are gone. What remains is the `c=$(gate.sh …); eval "$c"` shape, which is two named steps in one line. If a later run fails on nothing but such a chain, list it in the results and say so; don't widen the classifier to make it pass.

## 6. One correction to my own earlier note

I asked for "reads reported, not failed". Both `compare.json` files have `reads: null`, and the `sed` and `grep` lines are still in `unnamed_steps`. So reads are neither reported apart nor excused yet. It changes nothing here, since both runs fail on the `owes.sh` calls anyway, but the scoring doesn't yet do what the brief says it does.

## 7. Follow-up: runs 10 and 11 with `next.sh` (2026-11-24)

**What I did:** listed every tool call of main in both runs from the scope logs, read both `compare.json` files, read `lab/c/main.md` v4 (hash `5fcb808e…`), and ran `gate.sh --help`, which now prints the help.

### Do they count as C1's two runs?

**Yes.** Both logs are clean and almost identical, call for call:

- no read of an event file, no read of a script's source, no `owes.sh`, no hand-built command;
- every step main took came from `next.sh`, a card, or a printed call;
- the one ToolSearch is the select of SendMessage before the first hot send;
- run 10 has a single extra call, `round.sh --help`, which is what `main.md` tells it to do.

Compared with runs 6 and 7, the wandering is gone. The door did what hiding could not.

**How to report them:** as they are scored. `compare.json` says `passed: false` in both, on the one chained line. The results should say "2 of 2 with the expected sequence; each fails the script's check on one line that chains two named scripts", and not turn that into a pass by hand.

Three notes on the evidence:
- `C1-11/effort/stops/main-stop.out` is missing, so I could confirm the count of holds only for run 10: one hold in ten stops.
- The last call of both runs, `loop-end.sh …; next.sh …`, is the same chained shape and is not listed. I take it that it falls after the loop's end; say so in the results.
- The chain is the same line at the same place in both runs. It is a habit, not an accident.

**So I change my answer on the classifier, forwards only.** Because the chain is stable, judging it by eye in every later run is worse than a stated rule. Before C2 runs, declare: a Bash line whose every command is a named script counts as those named steps. Runs 10 and 11 keep the score they have.

**One thing the door changes in the spec.** C2 was to show "about four held stops per round". With `next.sh`, main asks first and the hold is the net: one hold in run 10. Change the expectation before C2 runs: record how many holds fired and what each caught, and fail only a hold that was dropped.

### What next

Beta's order is right in its parts. I'd put the remaining runs in it, since C2 and C10 decide the owner's claim and the review piece is the real build:

1. **Change 2, and let `next.sh` carry it.** After a gate's answer, the answered gate is itself a fact in the events: a yes with nothing dispatched yet. So `next.sh` can print the follow-up as an owed line, and for a choice, the line that takes the human's words. Then the cards carry no commands at all, and `main.md`'s line about `on yes:` goes away. One door for everything, and the text gets shorter, not longer.
2. **C1 twice on that text.** By the lab's own rule, runs count from zero when `main.md` changes. It is two short runs.
3. **C2 three times, then C10.** These decide the unattended loop and the reopened session.
4. **C3 to C6.**
5. **The flow test.**
6. **The results, judged against the evidence.**
7. **Then the review piece,** first of the pieces, on the owner's go for the build.
