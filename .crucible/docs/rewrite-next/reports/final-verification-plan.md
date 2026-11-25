# The final verification: plan

By Dev Beta, 2026-11-25. The owner's instruction: align this plan with Fable; when Fable approves, verify, then give the owner the results, with no approval asked in between. The bar is `final-verification-acceptance.md` (v2), the owner's five criteria.

## 1. Freeze

- Every build is in: the step 4 fixes, the command hook, no length checks, the commit summary shape, the prose lines and `noticed.at` optional.
- **Fingerprint** `new-rewrite/` (a sha256 over every file), written to `evidence/final/framework-hash.txt`.
- Every run below records the hash at its setup and at its collect. **A run whose hash differs doesn't count.**
- No one edits `new-rewrite/` during the verification.

## 2. Run everything once, on the frozen code

| # | What | Proves |
|---|---|---|
| F1 | All scripted runners: build, test, review, agent-jobs, the four git runners, internals-guard, installed-run, plus help-check | every repair line; every event rule; every step callable alone (14 of 14); the scripted-only list in the bar |
| F2 | The step 3 matrix, real layout (main in the repo, default mode, the narrow allow-list, no Write/Edit rules), **control run first** (all framework hooks removed) | R2, R3 delivery, R4, R5.1 to R5.7, now including the PermissionRequest hook's live cell in place of S15 |
| F3 | Step 4: the real definitions on Opus, unsteered, 3 runs per kind × 11 kinds; the 2 parked cases (real builder, real tester); and the full interactive set in tmux (one build refused and repaired, one review, one parked case) | R1 (planted facts, allowed checks run), R3 self-repair from the lines alone, the owner's interactive mode |

## 3. Scoring

The scorers read only events, report files, git, saved hook outputs and agent transcripts (only for the model and main's messages).

- **R1:** for every job, submitted or gave up, planted facts met, and allowed checks run. **The bar: zero gave up.** Reported beside it:
  - accepted at the first stop;
  - repaired after one refusal;
  - the spread of text lengths per field.
- **R2:** each scenario refused with its own line, then accepted.
- **R3:**
  - delivery, with the control run red on every cell;
  - self-repair, in F3;
  - no message from main between a refusal and its submission.
- **R4:** the audit over every run:
  - one ending or a submission per job;
  - every refusal an event;
  - no job with more than two refusals;
  - every pin matching its report;
  - every working commit with its event.
- **R5:** each row as the bar names it. The model is checked as Opus per run.

## 4. Two tries

Kept, as Fable decided. Go to three only if, in F3, more than about a third of the jobs need a refusal, or any job ends on a second different slip. Then the result goes to the owner as a finding; three tries isn't switched on silently.

## 5. If something fails

- **A lab or stand-in bug:** fix the lab, rerun that cell in both modes, and say so.
- **A framework bug** (a script): fix it, get Fable's look, **re-freeze, and rerun F1 to F3 in full**, never only the failed cell.
- **A prose problem** (agents slipping the same way in 2 of 3 runs): the fix goes to Fable first. Then re-freeze and rerun all three runs of that kind plus F1. If Fable judges the change wide, rerun F3 in full.
- **The cap:** at most two fix rounds. After that, report to the owner what still fails, with evidence, rather than loop.

## 6. Sign-off and report

- **Fable reads the raw results:** the score files, the counts, a sample of cells, and the control. Not my summary.
- **The owner gets one page,** `evidence/final/RESULT.md`:
  - each criterion, R1 to R5, pass or fail, with its evidence path;
  - the counts;
  - the hook timings;
  - the honest limits and the scripted-only list.
- Nothing is committed or pushed without the owner.

## Rules throughout

- The sandbox only, under `/Users/Shared/crucible-sandbox/final/`, with the logged-in sandbox config.
- Never `~/.claude`.
- Never bypass.
- Never sign with a real key: no global git config, `gpgsign` false.
- Kill processes by PID only.
- Each blocking wait is 2 minutes or less.
- Job agents run on Opus; stand-ins on haiku.

## Corrections from Fable (`final-verification-plan-fable.md`), applied

1. **No tracker call with the owner's login.**
   - F1 leaves out the live GitHub issue read in installed-run and doesn't run tracker-run.
   - Stub `gh` and `glab` go first on PATH for every runner and agent run.
2. **Fingerprint what runs.** Each run records the hash of the installed copy in the sandbox, as well as `new-rewrite/`, and proves at setup that it came from the frozen source.
3. **After a prose fix,** earlier runs still count when the difference between the two hashes is only the named definition's prose file. That difference is saved beside the result.
4. **One more ask in the interactive build:** a compound command refused with its message by the real hook, and a plain command that reaches the human.
5. **Every cell's raw output is saved,** not only the red ones, so Fable can pick a sample.

Fable will check:
- zero gave up, and the larger part accepted at the first stop;
- no refusal about a length anywhere;
- the control red on every cell for the reason the cell names;
- the parked cases with real agents.
