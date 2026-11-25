# The step 3 matrix: Fable's review (2026-11-25)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `evidence/stop-hook-matrix/README.md`, all of `score.sh`, the last lines of `score.txt` and `control-score.txt`, and the raw events and saved hook calls of four cells: `S2-build`, `S11-build`, `S12-build`, and the control table.

**Not done:** I ran nothing and did not rerun the scorer. I did not read `run.sh`, `lab/cells.sh` or the recipes, so what I say about how the stand-ins were steered is from the README.

## Verdict

**Step 3 meets the plan's exit bar.** The scorer checks what the README says it checks, the control run is red on every cell's own checks, and the raw cells I opened match the scores. Nothing in how it was run weakens what step 3 is meant to prove. It does leave one assurance to step 4, and one cell showed something step 4 must look at.

| Question | Answer |
|---|---|
| Does it meet the step 3 bar? | **Yes** |
| Prepared reports through `act.sh` | **Fine for step 3.** They leave A3 unproven, which is step 4's job |
| The S5a and S5b fault injection | **Sound.** Both are real faults on the real path |
| S12 with TaskStop only | **Enough** |
| A framework bug? | None found, and I agree. One design point surfaced, section 3 |

## 1. What I checked

- **The scorer can fail.** Each scenario asks for exact events in order (the try number, the repair line's wording, the writer), the pin's hash and read-only bit, and the commit's `Job` trailer. An unknown scenario fails. A scorer error fails the cell.
- **The control is real.** It ends "cells whose own scenario checks all pass without the hooks: 0", and the table has no cell with zero failed scenario checks. The 450 passing lines in it are audit lines that hold trivially with no events.
- **Raw against score:**
  - `S2-build`: `job.refused` try 1 with the summary line, then `build.submitted`.
  - `S12-build`: the killed agent's job ended `no-stop` by `end-gone-jobs.sh` five seconds after it was assigned. The two turn ends around it list the running agent and the hot one, and both jobs were later submitted.
  - `S11-build`: the stop after the block carries `stop_hook_active: true`. That is the field the bound on an unrecorded refusal relies on, now seen in the real flow.

## 2. Does the way it was run weaken it?

**Prepared reports.** Step 3 is about the mechanism: the hook refuses, Claude Code delivers the block, the events are right. For that the agent's words don't matter, and scripted ones make the run repeatable. What they can't show is A3 in its real sense: that an agent, reading only the repair lines, repairs its own report. The stand-in's repair was written before it ran. The README says so, and step 4 exists for it.

**S5a and S5b.** Removing a rules module, and leaving an `index.lock` in the tree, are faults a real install and a real repo can have. Neither touches the hook.

**S12.** TaskStop is one of five ways an agent ends without a stop. The writer's rule doesn't look at the cause, only at the list, and the probes covered the others. One live cause is enough.

**What stayed scripted, and why I accept it.** These paths were proven only by the scripted runners, not with live agents:
- a refusal that can't be recorded;
- the exit trap;
- a stall at the stamp, pin, event or lock step;
- a pinned report turned into `job.stalled` by the no-stop writer;
- an idle hot agent stopping in silence;
- `end-job.sh`.

None of them depends on anything Claude Code does beyond what the live cells already showed. The owner should know the list all the same.

## 3. What S11 showed

The README calls it a harmless quirk. For the stand-in it is. For a real agent it is two things to look at:

1. **A parked agent is told to write its report while its command is still running.** A real builder then reports on a check that hasn't finished. The honest report says `narrowed` or `not_run`. Whether the real definitions produce that is not known yet.
2. **After its report is accepted, the command finishes and the agent wakes up again.** The stand-in tried to rewrite its report and the pin stopped it. A real builder could instead edit code. That work comes after the working commit, belongs to no job, and nobody reviews it.

The second is covered by a rule already on the list for the dispatch talk: the dispatch refuses a new job on a tree that isn't clean. This is a second way to reach that state, so the rule has now been needed twice.

## 4. What step 4 needs

1. **The real definitions, unsteered.** `code-builder`, `code-tester` and `code-reviewer` with their skills and plugins. No recipes, no prepared reports, no `act.sh`. The agent writes its own report.
2. **The model is the owner's choice,** and it must be the one the framework will run on. Haiku results don't carry over.
3. **Prompts that carry only what the real dispatch would.** The dispatch isn't built, so the prompts are stand-ins. They hold the task and the report path, and no hint about report rules. Otherwise step 4 measures the lab's prompt. Keep each prompt in the evidence.
4. **No tracker calls.** The external review must read prepared threads, or stub `gh` and `glab` first on the PATH. Nothing may call GitHub or GitLab with the owner's login.
5. **Three runs per kind on small real tasks,** shaped so natural mistakes are likely, as the plan says. Real fixtures behind them: an approved plan for a test job, chosen findings for a fix, an earlier review for a re-review.
6. **The same scorer and audit,** plus the three counts per kind: accepted at the first stop, repaired after one refusal, gave up. The bar is zero gave up.
7. **For every refusal, keep its lines.** They are in `job.refused`, so no transcript is read. A line that refuses the same kind in two runs of three points at the prose or at the line's wording. That list is step 4's real product.
8. **One parked case with the real builder and the real tester:** a check that runs longer than the shortened limit. Expected: one refusal, then the submission. Then read the report: it must not claim a check passed that hadn't finished. Also record whether the agent changed the tree after its submission.
9. **When a job gives up,** keep its two refusals and its last report. A prose change that follows comes to me before the rerun, and the rerun is all three runs of that kind.

**The owner's go is needed before it starts,** with the model named: this is thirty or more runs on a real model.
