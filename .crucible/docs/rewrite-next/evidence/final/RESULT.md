# Final verification: result

2026-11-25. Run on the frozen framework, hash `e9e6a1d2…`, the same at the start and end of every run. Signed off by Fable from the raw results (`reports/final-verification-signoff-fable.md`).

**Verdict: your five criteria are met.** Round 2 closed two of the three open items, and the third isn't needed in practice. See "Round 2" below.

## What was validated (concise)

1. **Agents produce the right JSON, holding real work.** Your real builder, tester and reviewer ran on Opus, unsteered, 33 runs across all 11 report kinds:
   - **33 handed in, 0 gave up:** 17 accepted first time, 16 after one refusal.
   - **Planted facts 21/21:** reviews found the planted bug; fixes touched the right code; test commits add tests that run and pass.
   - **Allowed checks run 18/18.**
2. **Reports are validated by script, coverage included.** In 86 matrix cells, every kind's own rule refused a bad report:
   - a finding left out;
   - a fix without a status;
   - a skipped thread;
   - an unanswered challenge;
   - a wrong path or location;
   - not one JSON object;
   - a forbidden change.

   Each was refused, then accepted.
3. **The agent is told the exact error, automatically, and fixes it itself.**
   - **Delivery** proven on all 86 cells, while the control run, with every hook removed, failed all 86, each for its scenario's reason.
   - **Self-repair from the error lines alone** proven with your real agents: 16 of 16.
   - **Main never stepped in:** no message from main between a refusal and the fix, in any cell.
4. **An event trail of every outcome:** refused, accepted, gave up, fault, stalled, finished later, agent vanished. The audit passed on every run: each job ends exactly once, every refusal is an event, no job has more than two refusals, every pin matches its report, and every commit has its event.
5. **The rest of "rock solid":**
   - **No silent pass:** no job found, a hook error, or a refusal that can't be recorded is always told to you.
   - **No vanished job:** a killed agent's job is ended automatically at main's turn end.
   - **No lost work:** a failure after acceptance stalls the job and keeps the report; the finish script completes it.
   - **Tamper evidence:** a handed-in report is read-only and hashed.
   - **Agents stay in their lane:** writes only to their job folder and report, never your checkout; no background shells; no reading of hooks or internals.
   - **Parallel safety:** 12 agents refused at once each got their own lines, with unique IDs.
   - **Resumed agents** are checked by their new job's rules.
   - **Every event type is rule-checked.**
   - **No length ever fails an agent:** 0 of 33 refusals mention a length.
   - **Combined commands:** 64 were refused with "run plain single commands", and no agent stopped using the shell after one.
   - **Speed:** about 0.27 s per write, 0.13 s per shell call.
   - **Nothing called GitHub or GitLab;** stubs were in place.
   - **Every job agent ran on Opus 5.5,** verified per run.
6. **Your interactive mode:**
   - a build refused once and repaired, with its checks run;
   - a review accepted first time;
   - combined commands refused unseen by you, and plain commands reached you as prompts.

## Round 2: the three open items (frozen hash `f71a0054…`)

Round 2 replaces round 1 for the three open items only, and everything else above stands. F1 and F2 were re-run in full, the matrix with its control, all green. Signed off by Fable (`reports/final2-signoff-fable.md`).

1. **Locations: closed.** Two changes: the exact form now sits at each field, and the repair line now says what to write.
   - **Location refusals:** 28 lines in round 1, 0 in round 2.
   - **Accepted at the first stop:** 13 of 15 runs (build, test, outside review, test plan, plan rework), with 0 gave up.
2. **Long test suites: closed.** The hook now always sets the full 45-minute limit, and the prose says a check may take what it needs. The real builder and tester both ran a 150 s suite, passed, and the tester ran it five times for its mutation checks.
3. **A real agent pausing mid-command: not needed in practice.** In 5 + 2 attempts, real agents waited for a moved-aside command to finish, then reported honestly. The recovery, a "write your report" refusal then the hand-in, is proven with stand-ins in three matrix cells. Fable advises no further attempts.

**For the dispatch talk:** 33 plain commands were denied headless, mostly a builder running its changed script by hand or making a temp folder, so the manual check was often "not run". That's a matter for the allow-list.

## Not covered

- How main acts on the events: the dispatch talk.
- The quality of the plugins' content.
- Whether a review or fix is good, beyond the planted facts.
- **Scripted only, never live:**
  - an unrecorded refusal;
  - the hook error fallback;
  - stalls at the stamp, pin, event and lock steps;
  - pinned-to-stalled;
  - an idle resumed agent;
  - ending a job by hand;
  - a second session leaving another's jobs alone.

## Evidence

- Round 2: `evidence/final2/`, with F1.txt, F2/ and F3/.
- `evidence/final/F1.txt`: the scripted runners.
- `evidence/final/F2/`: the matrix and its control.
- `evidence/final/F3/`: your real agents, with the parked and interactive cases.
- Every cell's raw output is saved.
- Nothing was committed or pushed.
