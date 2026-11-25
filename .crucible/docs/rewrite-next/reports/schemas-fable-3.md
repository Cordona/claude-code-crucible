# Report schemas, round 3: the owner's six proposals (2026-11-24)

By Crucible Fable Reviwer, for the owner. Talking only; the owner's go is the only go.

**What I read:** `round-3-proposals.md`, `event-timeline.md`, the five round-3 worker answers, and Dev Beta's positions in `schemas-fable-3-brief.md`.

## Verdict

**I approve all six proposals.** Each makes the spec smaller or plainer, and the workers found nothing that breaks them.

**I don't approve everything that was hung on them.** The workers' conditions and Dev Beta's positions would add back two event types, a digest, a scanner in the stop check, a seventh judgement and two more field values. Most of those don't pass the reader test, or already have a home.

| # | Proposal | My view |
|---|---|---|
| 1 | One `noticed` field | **Yes,** with a kind in place of the boolean, and under another name than `security`. `for` only in reviews. No scan. |
| 2 | Test-plan event names | **Yes to the first three. `test-plan.approved` should stay the gate's own answer.** No `amended` event, no digest. |
| 3 | No `files` in the event | **Yes. The owner is right, and I disagree with Dev Beta here.** |
| 4 | The report path in the event | **Yes.** |
| 5 | The finding inside its item | **Yes.** The agent splits an item that holds two defects. |
| 6 | `answers` keeps its name | **Yes.** |

## 1. One `noticed` field

**The merge is right.** To the agent these were always one act: I saw something that isn't my task.

- **A kind, not a boolean: yes** (five of five). A leak and a planted instruction get different treatment on the card, so the value has a reader.
- **Don't call the flag `security`.** Three of five workers read `security: true` and `for: "security"` as the same thing, and an agent will too. They are different: one says "this must not be here, or it tries to steer us"; the other says "a possible defect for the security reviewer". Dev Beta is right to keep them apart, and the name is what blurs them. Draft 2's word does it: `kind: "secret" | "instruction"`, absent on an ordinary entry.
- **The scan in the stop check: no.** Scanning the cited lines for secret shapes is a secret scanner inside a hook. Projects have a `scan` gate for that. KPI's worry (an agent forgets the flag) was just as true of the separate `found` field: an agent that doesn't recognise a leak writes it nowhere. The floor rests on the agent's prose either way; say so plainly.
- **`for` belongs in review reports only.** Every real case the workers gave was a reviewer handing something to another lens. A builder's `for` would need a new kind of offer (Gamma's condition), with no case behind it. A builder's notices go to the card, as today.
- **A handoff never seats a reviewer.** It reaches the named lens if that lens is already in the round. Otherwise the card shows it and the human decides. That keeps the owner's rule that a lens runs only when asked for.
- **A stamped key on a `for` entry: yes.** A script stamps it, and without it the receiving reviewer can't say what it did with the handoff. Keep what it may answer to two outcomes: it is real (and becomes that reviewer's own finding), or it isn't (with proof). The exact shape belongs to the loop's spec.
- **`for: "human"`: no.** A reviewer's notice with no `for` already goes to the human. Nothing would treat the two differently.
- **`@where` in `at`: yes.**

## 2. Test-plan event names

**`submitted`, `challenged`, `updated`: yes.** Each has a different next step, which is the rule the spec already uses.

**`test-plan.approved`: keep it as the gate's answer.** Every other human yes is the core gate's `gate.answered`, written by the gate's own hook, and the lab decided on purpose that nothing writes a second approval event. A special name for this one gate means the core gate learns about test plans, or a second writer appears. The gate's answer already names what was approved: its subject carries the seq of the plan event the human saw.

**The human's change at the gate** (five of five, real): no new event.
- Main doesn't edit a plan. The human's words go to the planner as a rework, and the planner hands in a `test-plan.updated`. Its next step is the same as any update: the gate.
- A change after approval needs no rule either. The approval names the old plan event. The tester's dispatch asks for an approval of the latest one, finds none, and is refused.
- **Challenged again? Not by itself.** The owner decided the challenge has no loop and the human's gate is the loop. Main may offer a second challenge.

**The digest: no.** The seq pins the plan as long as an update is always a new report and never an edit of the old file. Say that instead.

## 3. No `files` in `build.submitted`

**Drop it.** Dev Beta would keep it because it costs the agent nothing. That isn't the cost. The cost is a second home for a fact.

- The event already rests on the commit: the review round reads `base..head` from it. If the commit is gone the round can't run, file list or not. So the list protects nothing.
- Epsilon's objections (rebased merges, re-made landing commits, ports) are all about commits that land. Working commits don't.

**The workers' three conditions are right, but they are rules of the working commit, wanted with or without `files`:**
- the effort's branch is never rebased or rewritten; main is merged in;
- a ref keeps the effort's commits until the effort is pruned on purpose;
- the worktree starts clean and the commit respects the project's ignore rules. A generated file that isn't ignored will be committed, and the reviewer will see it. Don't build more than that.

**One thing only Dev Beta knows:** if a rule that reads nothing but events needs the file list (a busy tree, for instance), that is a reason to keep it. A script that can call git isn't one.

## 4. The report path

**Yes.** Stamped, relative to the effort so it survives a move, and never in the job's tree. Epsilon's second condition (never in a commit, an MR or a ticket) is the landing step's rule.

## 5. The finding inside its item

**Yes.** It removes a linking rule.

- **Two defects in one item:** the triage agent splits it (`F-03a`, `F-03b`). No list inside an item.
- **Who labels items:** the agent, using the bot's own labels where they exist. A fetch script can't divide a paragraph into points.
- **`same_as`: not yet.** One worker. Without it the same defect gets two IDs and the fixer answers both. That is clumsy, not wrong. Add it when it bites.
- **A `valid` item's reply after the fix** (four of five): real. A script drafts it from the fixer's note and the landed commit, and the human edits it at the gate. It belongs with the landing step.
- **Don't move the whole replies gate after the landing.** A rejection or an answer to a reviewer's question doesn't depend on the fix. Make them two offers: the replies that are ready, and later the replies to what was fixed. The human posts at once or waits and posts together. That is the human's choice, not the flow's.
- **`discuss`** (question 3): I'd still hold at six, by folding. `deferred` was already defined as "a proposal the human sees at the gate". `discuss` is the same thing without a proposal. One judgement for "yours to decide", with a note saying what the triage suggests (a follow-up, or the options). It also covers KPI's release question.

## 6. `answers`

**Yes.** The job's kind says which values are allowed.

## The timelines (question 4)

**They show the flows as the spec defines them,** with these corrections:

1. **Timeline 3, step 10:** the human's yes is `gate.answered` (section 2 above).
2. **Timeline 4, steps 6 to 8:** two reply offers, not one gate moved (section 5 above).
3. **Timeline 2, "send it back":** say what carries it. It is a new choice by the human, so it should be a new `fix.chosen` with its own cap, as any fix choice is.
4. **Say once that nothing lands in any timeline.** Landing is its own step, with its own consent. Epsilon's point belongs there too: a project that requires a review before landing gets it by the landing step refusing an unreviewed build, not by making the review owed.
5. **`pr.posted` and `pr.review-requested`:** the workers are on GitLab. Pick a name that isn't one host's word.

## What I'd ask Dev Beta to keep in mind for draft 3

The round added more than it removed, and almost all of it came as conditions. A condition from five workers is a real case to answer. It isn't always a field. Three times here the answer was already in the design: the gate's answer, the planner's rework, the dispatch that refuses.
