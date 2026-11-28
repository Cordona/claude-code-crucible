# wt2: twelve starts and the real agents in their trees. Fable's review (2026-11-26)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `spikes/dispatch/wt2-results.md`; in `kit-wt2/`, `give-tree.sh` with its two steps, `job-note.sh`, `dispatch-guard.sh` and `swap-prompt.sh`; the start and end times of all 24 guard and tree-hook calls in `evidence/wt2/run1/r1-twelve/hooks/`; `evidence/wt2/run2/asks.tsv` line by line; the Write, Edit and shell-write calls of the three builders and `test-3` in their hook files; arm A's `asks.tsv` from probes 2 for the comparison.

**Not done:** I ran nothing and read no transcripts. I did not open r1-shared, r1-fail or r1-outside beyond their turn ids, nor the six `git.txt` files; those rows are Dev Beta's reading.

## Verdict

**Run 1: the basis is sound enough for the spec, because of the refusal, not because of the margin.** Two things to state with it, and one small hole.

**Run 2: the allow-list plus a line on shell writes does not reach zero.** A third cause is in the data and neither covers it: the builder's manual trial. It needs the owner's decision.

| Question | Answer |
|---|---|
| Is the note as the guard's last act sound enough | **Yes, with the refusal as the guarantee** and both ends stated, section 1 |
| Is the route to zero the allow-list plus prose | **Two of three causes.** The third is a scratch folder, section 2 |

## 1. Run 1: the note and the order

### 1.1 What the times say

My read of the 24 calls agrees with the results: guard, its tree hook, the next guard, twelve times, with no start refused.

**The margin is the guard's own running time.** The next guard starts 1 to 250 ms after the tree hook starts, and writes its note about 0.3 s later, when its work is done. The tree hook lists the notes within its first few tens of milliseconds. So the margin exists because the guard is slow, and it shrinks if the guard is ever made faster.

**That is acceptable, for one reason:** when the margin is lost, both starts are refused and main is told. Nothing is paired by guess. The margin decides how often a start is refused. The refusal decides whether the design is correct.

### 1.2 What the spec should state

1. **Both ends.** The guard writes the note after all its other work. The tree hook lists the notes before any other work. The results name only the first.
2. **The order is observed, not promised.** Claude Code ran the twelve calls one after another. Nothing in its documents says it always will. The spec says so, and says the refusal is what the design rests on.
3. **The second refusal's reason.** When two notes meet, the first tree hook clears both, so the second start is refused with "Inside an effort, worktrees come only from a dispatched job". That is the wrong reason for a job that was dispatched. One reason for both, or the first refusal leaves a mark the second reads.

### 1.3 One hole: a note nobody took

**How:** a guard writes its note and the start never reaches the tree hook (the human interrupts, or Claude Code fails in between). The note stays.

**What follows:**
- the next start of another job meets two notes and is refused once, with a reason that blames a parallel start that didn't happen;
- inside an effort, an agent with no job that asks for isolation finds one note, takes it, and is given that job and its tree. This is the only silent mispairing I can find. It needs two rare things at once.

**The fix takes no guess.** Both hook calls carry the same turn id (`prompt_id`): 24 of 24 in r1-twelve, 6 of 6 in r1-shared, 4 of 4 in r1-fail. The note records it, and the tree hook drops any note from another turn. I would add it, as one field and one comparison, and not go further.

### 1.4 Claims and gaps

- **Closed since my last review:** a start that fails after its assignment is ended by the gone-agents step; the tree is intact after real work (six trees, each at its job's commit).
- **"Never silently mispaired"** holds for two job starts. Section 1.3 is the exception.
- **Still not run:** a hot message to an agent started this way, and an interactive session.
- **The cost of the order:** each guard takes 0.3 to 0.6 s and they run one after another, so twelve reviewers take about 7 s to start. Fine today. It belongs with the measurement of reading every effort, for the parked log discussion.

### 1.5 The owner's decision, now measured

- **"Inside an effort"** is tested as "this session appears in any effort's events", so a session stays inside after its effort ends. The spec should say an open effort.
- **Outside an effort,** the hook's own worktree and its branch are never removed, and Claude Code gives no moment to remove them (the removal hook didn't fire). Claude Code's own default removes a clean one. So each isolated agent in any other project leaves a folder and a branch behind.

  I would not build a cleaner. The owner chooses between refusing outside an effort too, which is simple and switches the feature off, and accepting the leftovers with a line that says where they are.

## 2. Run 2: three causes, not two

### 2.1 What the table shows

**The start folder did its part:** `cd <tree> && git …` went from 6 to 0. The total stayed, 16 to 17, as the results say.

**The mix changed, and that is not noise:**

| Form refused | Arm A | wt2 |
|---|---|---|
| File written through the shell | 0 | 4 |
| Checks chained with `; echo x=$?` | 0 | 5 |
| Trial in a temp folder | 3 | 3 |

All three builders wrote the production file through the shell first. Each was refused and then used Write, which was allowed. In arm A none did. Starting in the tree makes a relative shell write the natural first move.

### 2.2 The causes

| Cause | Refused | Unanswered | Route |
|---|---|---|---|
| Checks, chained or on the tree's own files | 10 | 5 | the allow-list |
| The manual trial | 3 | 3, and 2 Writes denied | a scratch folder; the owner's decision |
| Files written through the shell | 4 | 0 | wait for the allow-list run, then prose if still needed |

**Checks.** The allow-list, as Dev Beta proposes, with one run to measure. Two things for that run:
- `build-3` used the tree's full path in every command, and two testers ran `cd <own tree>; …`. The prompt's "Tree:" line causes both. A rule written for relative paths won't match them, so the prompt line changes first. That line comes to me before it runs.
- The rule must cover the tree's own files: `sh tests/test_prune.sh`, and the changed script's `--help`.

**The manual trial.** Two builders did the same thing: Write a trial script to `/tmp`, then run it with `sh`. The Write was denied and the run got no answer. The other form is `d=$(mktemp -d) && for …`, which no allow-list can hold. This is why builders report the manual check as not run.

What the agents reach for is a place to put a throwaway script and a rule that lets them run it. The smallest answer is a scratch folder per job, outside the tree so nothing in it can be handed in, where Write is allowed and `sh` of its files runs. I advised against a scratch folder for the tester's mutation check. That one was caused by prose and guarded by the stop check. This need is different, and it is in six of six builder runs across both arms.

It changes the job's folders and the allow-list, so it is the owner's decision. Without it, zero is out of reach for a builder, or the builder's prose must say that the manual check is not its job.

**Shell writes.** Don't write the prose yet. In the allow-list run, watch one thing: with `cat` allowed and the tree as the agent's own folder, `cat > file <<EOF` may pass with no ask. Then the refusal is gone without prose, and writes pass beside the write step. The stop check still refuses a wrong file at hand-in, so I'd accept it, but the record should say which it is. If the form is still refused, one clause in each definition, and it comes to me first.

### 2.3 Claims

- **"The total is unchanged"** is honest. Three builds and three tests; a difference of one means nothing.
- **"An allow-list would likely let most chains through"** is marked untested, correctly.
- **All six accepted at the first stop** is the result that matters most, and it held.

## 3. Before the spec

1. The owner's two decisions: the scratch folder, and what the hook does outside an effort given the leftovers.
2. One run: the changed prompt line and the allow-list, three builds and three tests, counted by the three causes above.
3. Then the dispatch spec, with sections 1.2 and 1.3 in it.
