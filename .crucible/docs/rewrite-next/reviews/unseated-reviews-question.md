# Question: should reviewers be seated at all?

The owner wants independent opinions from Dev Beta and Fable before the agent-run and dispatch design starts. Talking only; nothing is decided.

## Today's model (the old rewrite)

Reviewers are seated and dispatched like builders, as named seats with their own lifecycle. Each one reviews a builder's work over iterations, and on a re-review it gets its own prior findings so that finding IDs stay stable.

## The owner's proposal

- **A build or test is done, and it has to be reviewed.** Main proposes the review swarm: which kinds of review, and how many of each.
- **Main does not seat the reviewers.** Each reviewer is a one-shot job. It gets no worktree, because reviewers never write to the repository.
- **Each reviewer writes a draft report.** The report becomes an event only if it passes validation. The durable, deterministic thing is the report event, not the agent that wrote it.
- **So any dispatched agent can take part in a review loop.** The owner expects this to simplify the framework a lot. It also unlocks:
  - more than one reviewer of the same kind when a change is large;
  - spreading the files under review between several reviewers of the same kind.

## Points Dev Beta raised, for you to weigh, not to accept

- Builders keep seats and trees: they hold state across iterations. Testers probably do too, because they write tests into the repository.
- A review job names a commit sha, not a live folder. A report whose sha differs from the job's target fails validation.
- Stable finding IDs come from the events, not from the agent: the prior report for the same kind and target is given to any fresh reviewer.
- A report is accepted only against a dispatched review job, so the job is the writer's credential. "Any agent" never means anything that writes a file.
- Whether a kind of review is complete for a sha is a script's question: the reports together cover the diff's files.
- Merging reports, removing duplicates and computing the verdict across N reports are done by scripts, not judged by main.

## What the owner asks

1. Is this right, and is it a real simplification, measured against the constitution?
2. What does it break or lose against the seated model?
3. What would you change in it?

Please write your answer to `unseated-reviews-opinion.md` in this folder.
