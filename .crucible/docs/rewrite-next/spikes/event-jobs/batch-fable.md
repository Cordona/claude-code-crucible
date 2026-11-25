# The live batch on main.md v5: verification (2026-11-24)

By Crucible Fable Reviwer, for the owner, on `batch-brief.md`. Not a go; the owner's go is the only go.

**What I did:** listed every tool call of main in all ten runs from the scope logs, in time order; read each `compare.json`, `sends.log`, the gate answers in the events, the C10 and C4 drive logs, and `lab/c/compare.sh`; compared the live and expected sequences of C4 and C10 line by line. I ran no lab script. I did not read the agents' calls.

## Verdict

- **The measuring fix is sound.**
- **Findings 1 and 2 are right. Finding 2 is larger than the brief says,** and there are two more doors of the same kind.
- **Findings 3, 4 and 5 have one cause the brief misses: the driver types a request into an open question,** and the question takes it as its answer. C4, C5 and C6 are driver faults, not main's. C10's difference is the lab's too.
- **Where the driver stayed in step, the sequence was right every time:** C1 twice, C2 three times, C3. Nobody typed in a loop, and no hold was dropped. On what the owner asked, C2 shows the unattended loop three times out of three. The runs fail on main's looking around, not on what it did.

## 1. The measuring fix

**Sound.** I checked it in seven runs: the end card's file time is 2 to 7 seconds after the human's answer in every one, so the old window always swallowed that answer.

- Ending the window at main's first `show-card.sh` call for the end card is right: once the card is shown, what the human types is the card's answer.
- It can't hide a real slip. The end card's file doesn't exist until the loop has ended, so main can't show it early to close the window.
- One small thing: the time comes from the log written before the call runs, so a refused call would count too. The gate's own record that the card was shown is the better source. Not needed before the next runs.

**What the window does hide, by design:** unnamed steps and event reads are counted only inside a loop. Over the whole run, main touched the events folder in every run, 4 to 13 calls each. The table's "events read" column is the in-loop part only. Say so in the results.

## 2. Finding 1: chains with separators and project looks

**Right.** The `echo ---` and `echo "exit $?"` lines are in C1-13, C2-2, C6-1; the project looks (`git log`, `cat a.sh b.sh`) are in seven runs.

**My answer to question 3:** count them, forwards only, and stop judging by the shape of the shell line. This is the second time a batch has failed on shape, and a third rule about shapes will not be the last. Judge by what the line does:

- **fails:** a write, a dispatch, a question, an internal script, or a read of the events or the cards folder, that no printed line named;
- **reported:** anything read-only on the project;
- **nothing:** an `echo` of a literal or of `$?`.

These ten runs keep the scores they have. The rule was set before they ran, and they failed it.

## 3. Finding 2: main reads the merged result from the events

**Right, and wider than the four runs named.** Main goes to the events at three moments, and only one of them falls inside a loop:

1. **After a merge,** to tell the human what was found and to word the fix's hand-over (C2-1, C2-3, C3-1, C10-1, C5-1). Also before the fix choice, outside the loop, so not counted (C2-1, C5-1, C10-1).
2. **When a job ends badly,** to see who ended and why, before the replacement (C1-13, C2-3, C4-1, C10-1, C6-1). Not in the brief. In C2-2 and C2-3 main then tried the replacement hot to a reviewer of the same round, was refused, and ran it again without. That refusal is the code doing its job.
3. **Before a choice,** main reads the card's follow file, `CARD.follow.json`, to learn what answers the choice takes (seven runs, 15 reads). Not in the brief, and not counted by the check. After change 2 the commands are off the card, but they sit in a file beside it with an obvious name.

**My answer to question 4: yes, with the same idea applied to all three.** Each script prints what main needs about the thing it just did, so main never has a reason to open an event:

- `merge.sh` prints the totals and the path of the merged report: verdict, counts by severity, what is still open. Totals and a path, as on the cards.
- The owed replacement line says why the job ended ("job 9 ended: gave up").
- A choice card's line from `next.sh` or `gate.sh` says what the choice takes. Then the follow file can move out of the cards folder, or stay and be counted as an internal.

No general door to the events. Three scripts each saying a little more is smaller than one script that shows everything.

## 4. Findings 3, 4, 5: the driver, not main

**The cause, from `sends.log` and the gate answers:** the driver sends a request by its place in the script, whatever is on screen. When a question is open, the typed request is lost and Enter picks the first option.

| Run | What was sent | What was on screen | What the gate recorded |
|---|---|---|---|
| C6-1 | "also build the installer in the same tree" | the review question | "Review it (Recommended)" |
| C6-1 | "yes, build it" | the fix choice | "Fix SHELL-01 (Recommended)" |
| C6-1 | "then put it in repo-b" | the end card | "Close the loop (Recommended)" |
| C5-1 | "stop the loop" | the end card | "Close the loop (Recommended)" |
| C4-1 | "stop the security reviewer, it is taking too long" | the fix choice | "Fix both (Recommended)" |
| C4-1 | "fix high, two rounds" | the end card of loop 1 | typed in as the end card's answer |

- **C6 (finding 4):** main never diverged. It never saw the second request; the review question took it. Everything after is the script and the session out of step.
- **C5 (finding 3):** the brief is right that the loop ended before the request. But the run didn't only stall: the human's "stop the loop" was recorded as a yes to closing a clean loop.
- **C4 (finding 5):** not the order of concurrent events. The cancel request became the fix choice, and the next answer started a second loop. The sequence check is not at fault here.
- **C10 (finding 5):** two differences, both the lab's:
  - the stand-in can't hang live (the drive log says so at the start), so "died" became "gave up";
  - the dry run expects cold dispatches after reopening, because "the agents are gone". Live, after two `--continue` restarts, the hot send to the first session's builder worked: assigned in 6 seconds, built in 11. That is a real finding for the design, and a good one: a continued session still reaches its agents.

  What C10 did show: after each restart main ran `next.sh` and showed the same pending card again. The place was recovered from the events alone. What it did not show: a death written by the second session, or an owed merge after reopening.

**Answer to question 5: all four are lab faults.** Before re-running:

1. **The driver sends by what is on screen.** A request goes out only at an idle prompt; an answer only to the question it is meant for (match the open gate's record, not just "a question is there").
2. **A new fail rule, the mirror of (b):** a request sent while a question was on screen fails the run as a driver fault.
3. **A stand-in that can really wait,** for C4, C5 and C10. Without it those three can't be run live as specified, and should be reported as not run, not as failed.
4. **C10's expectation:** leave `delivery` free after a reopening, and state the new finding.

## 5. What else I saw

- **The request is still unclear in C2 to C5** ("please write the two lab scripts"). Only C1 was made plain. In C5 main told the human so in its question. It didn't stall anything this time.
- **Main reads the code and puts its own view in the gate's question** ("b.sh loops over an unquoted `$*`", and in C5 "the finding probably names the wrong file"). The question's text is main's, and it is stored in the answer event. Not a fault of this spike, but the review piece will have to say whether main forms a view of the code or only carries the reviewers'.
- **Holds:** 0 to 4 per run, none dropped. C2-3's four are two rounds and two merges, each caught by the net. That is the net working.
- **The first question for a choice was refused twice** (C1-12, C3-1: a multi-select, then asked again as a single choice). Worth one line in the choice card's instruction.

## 6. Order I'd take

1. The driver and its fail rule (section 4, points 1 and 2).
2. The three script outputs (section 3), and the scoring by effect (section 2). `main.md` doesn't change, so C1's runs still count.
3. Dry runs again, then C2 three times and C3. These are the claim, and they are close.
4. The waiting stand-in, then C4, C5, C10. Then C6.
5. The flow test, the results, and only then the review piece, on the owner's go.
