# The final verification: Fable's sign-off (2026-11-25)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read, raw:**
- the frozen hash, which I recomputed over `new-rewrite/` myself: it is still `e9e6a1d2…`;
- F2: `score.txt`, `control-score.txt`, the four hash files, and the events, git log and hook calls of nine cells I picked (S2-build, S4-test-fix, S5b-build and its give-up, S9, S11-test, S12-review, S14-build, S15-review);
- F3: `score.txt` with every FAIL line, and the events of all 45 cells, from which I counted refusals, submissions and endings myself and listed every refusal line; one working commit, one test commit's test run, the parked build's report, and every saved call of the permission hook.

**Not done:** I reran nothing. For F1 I read the summary and the runner counts, not the 22 output files. I read no agent transcript.

## Verdict

**I sign off: the verification meets the acceptance bar (v2), on the frozen framework.** My own counts from the raw events match Dev Beta's: 33 submitted, 0 gave up, 17 accepted at the first stop, 16 repaired after one refusal, and no refusal about a length.

**Three things should be fixed or decided before the first real use.** None is a fault in the mechanism. They are in section 3, and the owner's page should carry them.

## 1. Against the bar

| # | Requirement | Result | What I saw myself |
|---|---|---|---|
| R1 | Agents produce the JSON, holding real work | **Met** | 33 of 33 submitted; a test commit's tests ran and passed from the commit |
| R2 | Reports validated, coverage included | **Met** | S4-test-fix: "list TEST-01 in fixes" twice, then ended; S9: twelve reviewers refused on their own line |
| R3 | The agent is told the exact error and corrects itself | **Met** | 16 of 16 real agents repaired from the lines alone; the control is red on 86 of 86 |
| R4 | An audit trail of every failure | **Met** | every cell ends in a submission or one ending; the stall and the give-up after it are events |
| R5 | The rest of "rock solid" | **Met, with the scripted-only list as the bar names it** | the Write into the repo refused and redirected; the compound command refused with its message; the hashes equal at every setup and collect |

**The new commit shape works:** the subject is cut at a word with "…", the whole summary is in the body, and the trailers follow.

## 2. One number to correct

The F3 README says the permission hook refused **99** compound commands in the counted runs. No scorer line gives that number. From the saved hook calls I count **64** in the 33 counted cells and 95 over all 45. The claim itself holds: the refusals happened, and every builder and tester went on to run its checks. Correct the number, or have the scorer print it, before the owner's page.

## 3. Before the first real use

### 3.1 The location prose I approved did not work

| Kind | Accepted at the first stop | The slip |
|---|---|---|
| build | 0 of 3, and 0 of 7 in the extra runs | `at` as a file plus words: "bin/prune-backups.sh option loop" |
| test | 0 of 3 | `at` as a file and a test's name |
| external-review | 0 of 3 | `at: description`, for something with no file |
| test-plan and its update | 2 of 6 | `at` as a comma list in one string |

The lines are in the shared skill, and the agents don't apply them. Each field in the definitions still says "`at`: where you made it", which reads as words.

**Why it matters:** a builder spends its first try on this every time. With two tries, it really has one, and the next slip ends the job. That is where step 4 stood before the fixes, for these three kinds.

**The fix I'd try:** say the form where the field is, for example "`at`: the line where you made it, as `path:N`", in the definitions. Dev Beta drafts, the lines come to me, and those kinds rerun, three runs each. If that doesn't hold, the question is whether a decision needs a checked location at all.

### 3.2 A test suite longer than two minutes is not run

In the last parked attempt, both agents judged a 150-second suite "longer than the 120 s foreground limit" and reported the test gate `not_run`. That is honest, and it was accepted. But many real projects have a suite over two minutes, and there the builder and tester would hand in work with its tests unrun.

The framework's timeout step leaves a call alone when the agent sets its own timeout, and the agents always set one, at 120 seconds. **This needs one probe with the real limit of 45 minutes,** then a decision: the step raises an agent's timeout on a check command, or the prose says a check may take as long as it needs.

### 3.3 The parked stop stays proven with a stand-in only

Five attempts, and no real agent parked. I accept it as a limit, said plainly: the recovery is proven by the matrix with a stand-in, and real agents avoided the situation. 3.2 is the other side of the same behaviour.

## 4. For the dispatch talk

Headless, 33 plain commands were denied outright. Most were a builder running the script it had just changed by hand, or making a temp folder for a check. So the `manual` gate was often `not_run`. That is the allow-list's matter, which main and the human set per job, not the framework's hooks.

## 5. Smaller

- **The write guard:** 274 ms at the median with real agents, 725 ms in the matrix with about thirty-six at once. Fine for real use; no index needed.
- **`sh -c '…'` with a chain inside quotes** counts as one plain command, so it reaches the human. That follows from ignoring quoted text, and I'd leave it: the human sees the whole command.
