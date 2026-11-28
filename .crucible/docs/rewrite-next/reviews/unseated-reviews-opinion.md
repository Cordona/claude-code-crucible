# Unseated reviews: Fable's opinion (2026-11-23)

By Crucible Fable Reviwer, for the owner, on `unseated-reviews-question.md`. Talking only; nothing here is a go or a design.

## In short

**Yes. It is right, and it is a real simplification.** A reviewer holds nothing worth keeping between rounds except its findings, and findings belong in events. I would change four things, and one of them matters before any design: "no worktree" is right for writing and wrong for reading.

## 1. Is it right, and a real simplification?

**What a seat gives:** a name, a lifecycle (opened, bound, busy, idle, resumed, handed over), an iteration count, and a tree. A builder needs all of it, because its work is in the tree and continues. A reviewer needs none of it:

- its output is a report, complete when written;
- it never writes to the repository;
- the one thing it carried between rounds, its earlier findings, is data.

So the seat was carrying the findings by keeping the agent. Moving them to events removes the reason for the seat.

**Against the constitution:**

- **Pieces, not pipelines.** A review job becomes a floating piece: it needs a commit and a kind, nothing else. It can follow a build, a test, or a commit nobody dispatched, such as the human's own. The seated model could only review a seat's work.
- **Events are facts.** The durable thing is the validated report, not the agent. That is the same position as the spec and the context: a draft, a check, then a sealed fact.
- **Invariants in code.** "A report is accepted only against a dispatched review job" is a rule a script can refuse on.
- **The human decides, weight follows stakes.** Main proposes the swarm and its size; the human agrees it at a gate.
- **Tracked for completeness.** A review step can end in an event of its own, written when a kind is complete for a commit. That fits the step catalogue as it stands.

**What does not go away,** so the saving is not overstated. A one-shot job still needs:
- a record of the job (kind, commit, files);
- the agent tied to its job, so its report can be told from any other file;
- the check when the agent stops, with the chance to fix a misfit report before it ends;
- the rule that a reviewer writes nothing in the repository.

What goes is the lifecycle: names, status, resume, iteration, handover, and the tree. That is most of the seat machinery in the old rewrite's map, for the role that used it least.

## 2. What it breaks or loses

1. **A warm reviewer.** A seated reviewer on round 2 already understands the code. A fresh one reads it again. This costs tokens on every re-review. It also buys something: a fresh reviewer is not anchored on what it concluded last time. I'd accept the cost.

2. **Asking the reviewer.** Today the human's "why is this high?" can go to the agent that wrote it. A one-shot agent is gone. So the report must stand alone: each finding with its trigger and its proof, enough that main can answer from the event. That is already the constitution's rule for prose; here it becomes load-bearing.

3. **Who closes a finding.** In the seated model the reviewer keeps its seat until its findings close, and main never marks them resolved. With no seat, that rule has no owner unless it is restated: **a finding's status changes only through an accepted review report or the human's recorded waiver.** Never through main, never through the builder's report. This must not be lost in the move.

4. **Findings that live between files.** See "split by files" below.

Nothing else of value is lost that I can find.

## 3. What I would change

### a. No tree to write in; still a place to read (the one that matters)

"A review job names a commit, not a live folder" is right for what the report is about. But a reviewer reads far more than the diff: it follows what the change uses and affects. It needs the whole repository as it was at that commit, somewhere stable.

Simplest first: **the reviewer reads the builder's tree, and the report is refused if the tree's tip is no longer the job's commit.** That works whenever the builder is idle while the review runs, which is the normal case. A read-only tree at the commit is the answer when a build and a review must run at the same time; I would not build it until that case is real.

### b. The script gives findings their IDs, not the agent

With several reviewers of one kind, two agents will both write "finding 1". IDs assigned at acceptance, by the script, can't collide. A reviewer only refers to earlier IDs, to say what became of them.

And **"the prior report for the same kind and target" needs a target that survives a fix.** The commit changes every round. Earlier findings must be keyed by what is under review across rounds (the tree, or the review step in the flow) and the kind. When the files are split differently in round 2, each earlier finding goes to whichever reviewer has its file.

### c. Split by files: main chooses the groups, the script checks the cover

Agreed that completeness is a script's question: every file of the diff is in an accepted report of that kind. But be plain about what that proves: the files were assigned, not that they were understood.

A split by files loses the defect that sits between two files given to two reviewers. So:
- **main chooses the groups,** by what belongs together; that is judgement;
- **every reviewer gets the whole diff** to read, and a list of the files it answers for;
- **the script checks** that the groups cover the diff.

### d. Merge and verdict by script; removing duplicates is not a script's job

Merging N reports into one view and computing the verdict: scripts, yes. That is arithmetic.

Deciding that two findings are the same defect is judgement. A script that drops one will sometimes drop the wrong one, silently. With files split between reviewers of one kind, duplicates are rare anyway, and two kinds reporting the same line is two lenses, not a duplicate. **Start with no removal at all:** the script puts findings on the same place next to each other and drops nothing. Add more only when a live run shows noise.

### e. "Any dispatched agent", with one exclusion

Agreed that the job is the credential, not the agent's type. One rule to state in code: **an agent never reviews a commit it produced.** That is the whole point of a review, and it is one check at acceptance.

### f. Keep the report out of the event body

As with the spec: the report is a sealed file, and the event names its path, its hash, the job, the kind, the commit and the counts. Cards read totals from the event; details come from the file on ask.

## On Dev Beta's points

- **Builders keep seats and trees:** agreed. Testers write into the repository, so they need a tree too.
- **A commit, not a folder; a mismatch fails:** agreed, with (a).
- **IDs from events:** agreed, with (b).
- **The job is the credential:** agreed, with (e).
- **Completeness is a script's question:** agreed, with (c).
- **Merge, duplicates and verdict by scripts:** two of three; see (d).

## One question this raises for the design talk

If a reviewer is only a job, ask the same of the builder: **is a seat anything more than a tree and the jobs done in it?** The builder's state is in its tree and in events too. If the answer is no, the job is the only unit the framework dispatches, some jobs name a tree, and "seat" may not need to exist at all. I don't know the answer; it is the owner's talk to have, and it is cheaper to ask before agent-run is designed than after.
