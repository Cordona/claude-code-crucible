# Remote reviews as built: Fable's review (2026-11-27)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `remotes/SKILL.md`, the external-review section of `code-reviewer.md`, `review-threads.jq`, `external-review-report.jq` (the thread rules), `job-resolve.jq`, both kind files, the range rule in `job.defined.jq`, and the lines of `job-assign.sh` that build the agent's prompt.

**Not done:** nothing was run; the five green counts are Dev Beta's. I did not read the fetch scripts, their `--help`, or the evidence runs.

## Verdict

**The four built pieces are as designed, and `remotes/SKILL.md` passes. One gap, one prose change, and my answer on the open question is (a).**

| Point | Kind |
|---|---|
| The agent is never told which threads are new or changed | Gap, section 1 |
| The new line in `code-reviewer.md` | Reword, section 2 |
| The change's description for an external review | Option (a), section 3 |

## 1. The gap: the comparison reaches the check, not the agent

**The comparison works, but only the report check sees its result.** The agent's prompt names the threads file and nothing else about it. On a second pass it reads every reviewer thread and has no way to know which it already judged. The check then accepts whatever it hands in, because items are allowed on any thread.

**So the failure the Plugins workers described comes back:** the AI review note, which GitLab can't resolve, is judged again and gets a second reply. The comparison stops a thread being skipped; it does not stop one being judged twice.

**This is the same shape as the open question:** a fact found in the log that the agent needs in its prompt. I would not build a fix on my word alone. Make the live chain run include a second pass on the same change, and look at what the agent does. If it judges the old note again, the smallest fix I see is the agent's own earlier report handed to it as a ref, with one prose line saying a thread judged there needs judging again only when it has changed.

## 2. The new prose line

"Judge every thread a reviewer opened at least once; the check names any it still needs."

- **"At least once"** reads as "more than once is fine", which is the opposite of what a second pass wants.
- **"The check"** names plumbing the agent doesn't otherwise know of, and tells it to lean on a refusal.

Shorter and enough: "Judge every thread a reviewer opened. A thread the change's author opened is their account of the work: read it as context." What it says about a second pass depends on section 1.

## 3. The open question: (a)

**Give the kind a change ref that resolve fills from the review.** My earlier advice (the facts follow the review to its change) missed that the facts are not the agent's; that was my error.

It meets the rule we set for a new kind-file word: a fact resolve fills and checks. Three conditions:
1. Main can't give it; resolve faults one that main names, as it does for `work` on a foreign review.
2. The door needs no change: it already prints every ref's path.
3. `review-threads.jq` then reads the change from the job's ref, in place of following the review itself.

Leaving the description out (b) drops what the workers needed to answer a human reviewer's design questions.

## 4. Checked and as designed

- **`rt_threads`:** judge holds reviewer-opened threads that are new or changed against the fetch read by the last external review handed in before this job was defined, for the same change; all of them at the first pass.
- **The report rule:** an item required for each thread to judge, allowed on any thread of the fetch, refused on a thread outside it.
- **`jr_from_change`:** fills the cut and the range from the change, and faults any `work` main gives.
- **`job.defined`:** a range may sit on a cut tree.
- **No kind branch added to `jobs/track`.**

## 5. `remotes/SKILL.md`

**Passes: three lines, each needed.** The description says when to use it and what it is not for. The `--bot` line has a real finding behind it. Nothing in it describes events or files.

## 6. For the owner

Nothing to decide yet. The gap in section 1 is to be shown or cleared by the live run.
