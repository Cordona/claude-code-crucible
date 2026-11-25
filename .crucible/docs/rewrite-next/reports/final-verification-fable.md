# The final verification bar: Fable's review (2026-11-25)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `final-verification-acceptance.md`, against what I know of the build, the probes, the step 3 matrix and the two step 4 trials from my earlier reviews. I ran nothing and opened no code for this one, so where I say "I don't know of a check", Dev Beta should correct me if one exists.

## Verdict

**The bar covers the right ground, and it is not yet honest in four places and not complete in five.** None of this needs new machinery. Most of it is saying plainly what a row does and doesn't prove, and adding a few cells to runs that are already planned.

## 1. Where a row claims more than its proof

| Row | The problem | What to do |
|---|---|---|
| R1 | Its check is circular. "Each accepted report passes the kind's rules" is what accepted means. An empty review and a build with no check run both pass it, and both happened in the trials | Add a check that the report isn't empty of work, section 2.1 |
| R3 | "No main involvement" has no check behind it, and "corrects itself" was scripted in advance in step 3 | Score it: no message from main to the agent between the refusal and the submission. Say that self-repair is proven by step 4 alone |
| R5.2 | "A dead session's job is refused new work until ended" isn't built. It is the dispatch's | Move it to "out of scope". What exists is the script that ends such a job on the human's word |
| R5.5 | "Never in the owner's checkout" holds for the Write and Edit tools only. A shell command can still write anywhere Claude Code's own permissions let it. And I don't know of a check behind "no commit by the agent" | Word it as what the hook covers. For the commit: name its check, or take it off the list |

**Two limits that should be written into the document, since its heading says "so nothing hides":**
- **When the event log can't be written,** the human's message is the only record. That is the agreed limit of R4.
- **When `jq` is missing, or the hooks aren't installed at all,** every stop passes unchecked and nothing says so. The owner dropped the first as unrealistic. The second is what the control run looks like, and section 2.4 is about it.

**One more for R5.1:** a hook that Claude Code kills outright leaves nothing at that moment. It is caught later, at main's turn end. The row should say "caught by the end of main's turn", not "never".

## 2. What is missing

### 2.1 A report that holds real work

The fixtures already have planted facts, so a script can check them without judging quality:
- a review of the build with the planted bug has a finding in the file that holds it;
- a fix job's commit touches the code its chosen findings point at;
- a test job's commit adds tests, and they run;
- a builder and tester ran their allowed checks (already planned).

This doesn't say a review is good. It says the agent did the job and not only the paperwork.

### 2.2 The mode the owner really uses

Every run so far is headless. The owner works in an interactive session, where a question reaches the human and the agent waits. Add a small interactive set, in tmux as the probes did:
- one build that is refused once and repairs;
- one review;
- one parked case.

Same scorer. Without it the bar proves a mode the owner doesn't use.

### 2.3 The real hooks, live, after the rework

The matrix was scored before the write scope existed. For its rerun, add:
- **a job agent that writes into the repo:** refused by the real hook, it writes in its tree, the repo stays clean, the job is submitted. So far only a probe's stand-in gate showed this;
- **the `cd` before git case,** if that refusal is built;
- **the layout of real use** for the whole matrix: main started in the repo, the trees and the space elsewhere, permission mode `default`.

### 2.4 Knowing the hooks are there

Everything in this bar assumes the hooks are installed and unchanged. If an entry is lost from the settings, the framework goes quiet and looks healthy. `install-check.sh` can tell. What is missing is the rule for when it runs. The smallest answer is the owner's to pick: by hand after each change, or at the start of each session.

The same goes for R5.9. "Rechecked after each update" is a promise with nobody behind it. One cheap way to make it visible: the install check compares the Claude Code version with the one the probes last ran on, and says so when they differ.

### 2.5 What the numbers mean

- **33 runs with zero gave up** is strong evidence, not a guarantee. It says the give-up rate is low, roughly under one in ten at worst. The document should say so.
- **Report beside it** how many of the 33 were accepted at the first stop. A job has two tries; a kind that always spends one on a length limit is one slip away from giving up. That number is the health of the prose.
- **The step 4 parked cases** (`parked-build`, `parked-test`) are built and not in the table. Add them: the report must not claim a check that hadn't finished, and the tree must be unchanged after the submission.

## 3. Proven by script only, to be listed as such

These paths have scripted proofs and no live run. I accept that; the document should list them so the owner sees the line:
- a refusal that can't be recorded;
- the exit trap;
- a stall at the stamp, pin, event or lock step;
- a pinned report turned into a stalled job by the no-stop writer;
- an idle hot agent stopping in silence;
- ending a job by hand;
- a second session leaving another session's jobs alone.

## 4. What I'd leave as it is

- **R2, R5.3, R5.4, R5.6, R5.7, R5.8:** right, and their proofs match.
- **The three items out of scope:** right. I'd add the dispatch's refusals there (a new job on a tree with an open job, or on a tree that isn't clean), since two findings now lean on them.
