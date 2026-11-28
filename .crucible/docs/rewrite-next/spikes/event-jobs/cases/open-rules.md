# Stage A: open rules

One line each: the case(s), the question, the reading the cases take.

## Script interfaces

- all: does every script take the effort? Every command passes `--effort "$EFFORT"`, harvest.sh and busy.sh too.
- all owes cases: owed-step args beyond `merge` are undefined. Readings: `make-round {kind, targets}`, `merge {round}`, `choose {merge}`, `fix {merge, side}`, `replace {job}`, `end-card {loop, reason}`, `plan-rework {round}`, `plan-gate {plan}`, `replies {review}`, `comments {merge}`. Root, loop and approval are left out, since the scripts derive them (contract 1.4).
- a5, a10, a2-14, a7-12: how do args reach a step script? Each arg becomes `--name value`, arrays comma-joined (`--targets 12`).
- a3-04, a4, a5, a2-14, a7-12, a11: merge.sh, round.sh, choose.sh, job-dispatch.sh (not check) and orphans.sh have no defined stdout. The cases discard it and read the events they wrote with jq.
- a10: does a step script refuse a repeated step outside `--check`? Yes: it prints the same `done-already` object and writes nothing.
- a9, a5-03: job-dispatch.sh flags are body fields as flags (`--kind --tree --target --round --slot --replaces --delivery --hot-agent`), plus `--merge --side` for a fix. Root, approval and agent type are derived; `--tree` is given only for a build or test.
- a9-01, a9-02, a9-03, a9-08: a hot or cold agent for a round slot is checked on a replacement (`--round --slot --replaces`), since round.sh writes every slot's first job with the round.
- a9-02: own-commit and type-misfit both hold for a hot builder offered a review of its own commit. Reading: own-commit is checked first.
- a9-06, a9-10: a gate.answered covers one step. A build or test gate is used by the job that names it; a review gate by the round whose jobs name it; the test-plan gate by the first plan job, its challenge and the rework. A later dispatch of that step needs a new gate.
- a5-04, a5-05: choose.sh flags are `--merge --severity --plus --minus --cap`. `query` records only the keys given, in D4's form, and `ids` are sorted.
- a5-05: the refusal key for a query that resolves to no key is not in the contract. Reading: `no-match`.
- a7-12: how does main give round.sh the agreed swarm of a gated round? Reading: `--kinds shell,security`, one reviewer per kind, no file split.
- a11: orphans.sh takes `--session ID` (the running session); its `job.ended` carries that session and no agent.

## owes.sh

- all: every printed object has all five fields; empty lists are `[]`, absent values `null`.
- a2-17: a root with nothing to print gives empty output; its expect.json is empty.
- waiting cases: `since` is the seq of the job's `job.assigned`, or the job's own seq if it was never assigned.
- loop cases: `loop.rounds` counts the `round.made` events whose `loop` is that `fix.chosen`. `loop` is shown until `loop.ended`, including after `loop.stopped`.
- a2-01: at the cap's last round with no targets left, the reason is `clean`, not `cap`.
- a2-16, a2-17: after `loop.ended` with reason `cap`, the choice gate is owed again on the last merge; after `clean`, nothing.
- fact cases: fact words are given only for `no-review` of a build. Readings: "build N has no review", "test N has no review", "fix N has no review", "external review N has no judging round", "review request N has no review", "head move N has no re-review".
- a1-05, a8-01: a later build on the same tree continues that tree's chain; it is not a new root.
- a7-10: a `range.imported` root has no starting fact, and its review gate comes before the import, with no root.

## Rounds, merges and the harvest

- a4-02, a2-02: IDs are `<KIND>-NN`, numbered per kind across the effort, in `review.submitted` seq order, then report order.
- a4-02, a2-02: a `review.merged` lists every finding of the root with its latest status, including earlier rounds' findings and skipped ones.
- merge cases: `verdict` is `changes` exactly when `targets` is non-empty. Outside a loop, `targets` holds the open, realistic critical, high and medium findings that are not skipped or rejected.
- a2-02: "carry over" applies to keys the last fix was given; "new" means first listed in this merge.
- a2-21: a waived key is never a target, carried or new.
- a2-04, a2-14: `harvest.sh --merge M` reports `deadlocked` as the keys insisted in M that a fix submitted after M declined again. Before such a fix, the list is empty.
- a2-14: in a derived swarm, the reviewers come first by kind and the arbiter last; the lab's tech reviewer kind is `shell`.
- a2-05, a2-06: a round where every key was declined again is the arbiter alone.
- a5-06: a re-review's cover is the fix's `files` plus the chosen findings' files, sorted.
- job cases: `target` is the round for a job in a round (review, external-review, challenge, arbiter), the merge for a fix, and the build for a test or a first plan job. A plan rework's target is the challenge round, and a build's is `null`.

## End states

- a3-01, a3-02, a2-08, a2-19: a reviewer slot or a fix job that gave up or died owes `replace`, inside or outside a loop. The replacement takes the replaced job's approval.
- a3-03: a cancelled slot is not replaced: the round closes with the gap, so the merge is owed.
- a2-09, a2-20: when a replacement also ends, a reviewer's round is merged with the gap and then the end card is owed with `replacement-failed`; for a fix, the end card is owed at once.
- a2-10, a2-18: after `loop.stopped`, a complete round's merge is still owed and then `end-card` with reason `stopped`. With no round to merge, the end card is owed at once.

## Kinds

- a2-12, a2-15: which fix side does a finding go to? Kind `test` goes to `tests`, any other kind to `production`. The chosen keys' sides give the expected set of fix jobs, production first (O2).
- a7-03: a challenge round has no merge; `plan-rework` is owed once its job submits.
- a7-04: a `plan.submitted` whose job carries `challenges` owes the plan gate (ended by `plan.approved`); one without owes a challenge round.
- a7-06, a7-11: an external chain's replies are owed after its `loop.ended`, or after `fix.none`, and a later `pr.posted` clears them.
- a7-11: an external merge whose threads were all rejected has `targets: []`.
- a7-07, a7-09: a foreign root's merge owes `comments`, never `choose`, and a later `pr.posted` clears it. The delta re-review takes a new review gate.
- a7-08: `pr.posted.items` name a thread or a finding as `id`.
- a7-01: a test job continues the build's root; its `test.submitted` gives the fact `no-review:<seq>`.
