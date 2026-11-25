# The reviewer's spec: what we ask of the PS Observer's workers

By Dev Beta, at the owner's request. Read `reports/worker-briefing.md` first if you haven't: it explains the new approach (jobs, events, thin prose, adaptive flows).

## Why you're asked

You review a lot, both internally and externally: your own MRs, bots' and people's reviews of them, and others' MRs. The owner wants you to confirm that the reviewer's reports fit that real work before the Crucible Fable Reviwer judges the spec. Fable reads your answers first.

## What to read

`/Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/reports/review-agent.md`. It has four kinds:
- **`review`:** a cold review, a hot review, and a re-review of fixes;
- **`test-plan-challenge`:** challenging a tester's plan before the human sees it;
- **`external-review`:** judging someone's review of our MR, point by point;
- **`foreign-review`:** reviewing someone else's MR. We comment, and never fix.

**Words already decided, so please don't reopen them:**
- the fixer lists its `fixes`, each with a `status` (done, partly, declined);
- a re-review lists `findings` (new) plus `fixes` (its status for each fix: fixed, open, agree, disagree);
- an external review gives a `verdict` per point;
- finding IDs reset when a new iteration starts.

## What we ask

Answer from your real reviews, with real cases (the MR, the thread, the bot):
1. **Can a reviewer say everything a real review needs to say,** in each kind? What is missing, or is there more than you need?
2. **External review:** do the six verdicts (valid, rejected, already-fixed, deferred, answered, noted) cover the threads you really get, from bots and from people? Do splitting a thread into items, and the two reply offers, match how you work?
3. **Foreign review:** does the shape fit how you review someone else's MR and leave comments?
4. **The re-review:** does the reviewer's status per fix (fixed, open, agree, disagree) cover what you actually see after a fix round?
5. **The plan challenge:** does it fit how you'd challenge a test plan?
6. **What refuses a report** (§6, and the rules in each kind): would any rule refuse a real, good review?
7. **The open questions (§14):** give your view where your experience bears on one.

**One rule from the owner: reports stay generic.** Prefer free text in an existing field, or a gate, to a new field. A new field must have a script or card that treats it differently. Say when you think the spec already answers a case.

## How to answer

One file each, in this folder: `worker-<your name>-reviewer.md` (for example `worker-dev-gamma-reviewer.md`). Then tell the PS Observer you're done.
