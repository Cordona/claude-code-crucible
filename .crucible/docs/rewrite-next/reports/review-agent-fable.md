# The review agent's spec and the workers' fit checks: Fable's judgement (2026-11-24)

By Crucible Fable Reviwer, for the owner. Talking only; the owner's go is the only go.

**What I read:** `review-agent.md` in full, `worker-reviewer-brief.md`, and the five workers' answers. I ran nothing. I didn't reopen what the owner has decided.

## Verdict

**The spec is sound and fits real review work.** All five workers say their real reviews fit, and most of what they raise is about the remote (threads, replies, commits), which is another spec.

**One new field, one widened field, and six rules to loosen.** The rest is answered by the design or belongs elsewhere.

**Three things I'd settle before building:**

1. **Which lens owns a finding from an external review** (4 of 5 workers, question 6).
2. **A tree that moved under a reviewer is not the reviewer's fault,** yet the spec hands it a repair line it can't act on.
3. **Parallel reviewers of one lens** (question 12): one lock around the stop hook's work, not the core's events lock.

## 1. What changes the spec (question 1)

| Point | Workers | Change |
|---|---|---|
| A valid external finding belongs to another lens | 4 | **A field:** `for: <lens>` on the valid item's finding, the word `noticed` already uses. Section 2 below |
| A question or remark at a line, in a foreign review | 1 | **Widen:** `notes[]` may take `at`. The comments gate posts it at that line. The spec's own example note already names a line in its text |
| `suggestion` and `proof` at 200 characters, one line | 2 | **Loosen:** both take the reply's limit. `claim` stays one line; it is what cards and lists show |
| `relates_to` on a removed line | 2 | **Loosen:** it accepts `-path:N`; a deleted line is a changed line |
| A reason on `fixed` | 3 | **Loosen:** optional. It covers "the code is gone", "fixed another way", and "right by reading, proven only by a deploy" |
| A reply on `noted` | 1 | **Loosen:** optional. Some projects answer every bot note |
| The tree check and ignored files | 1 | **Say it:** "the tree has changes" follows the project's ignore rules, as the builder's commit does |
| A challenge's target | 1 | **Say it:** any plan ID is a target, the untested entries too; `plan` covers the run and the baseline. Fix the repair line, which names only behaviours and tests |

## 2. The lens of an external finding (question 6)

**The recommendation in the spec is the job's lens. I'd change it.** One bot note on a real MR held points for four lenses. With one lens per job, a PHP reviewer's security finding is stamped `PHP-NN`, the security count misses it, and its re-review goes to the wrong lens.

**So:** a valid item's finding may say `for: <lens>`. Without it, the job's lens.
- **It has script readers:** the stamp takes its prefix from it, the security count reads it, and the re-review goes to that lens.
- **It never seats a reviewer.** If that lens isn't in the round, the card shows it and the human decides, as for a routed `noticed`.

## 3. Answered by the design

| Point | The answer already there |
|---|---|
| The same point in two threads (`same_as`) | judge the repeat `answered`, with a reply saying it is handled under the other label. One finding, no field |
| A location in an installed dependency | `@vendor:path:N`. The `@<where>` form is not checked for existence |
| A fix that broke something else | a new finding; its `claim` says which fix it came from |
| The same defect back in a later iteration | a new finding that says so in words. `reopens` is for IDs of the same iteration |
| A valid point about the MR's description | not a code defect, so not `valid`: `deferred` with a note. Editing the description is main's step |
| A rejected point that hides a different real defect | two items |
| A fix only checkable by a deploy or in CI | `fixed` with the reason naming the check, once the reason is allowed |
| Replies in the reviewer's own language | free text |

**One case I'd answer with what exists, and it is the owner's call:** a point that is real but not this MR's, which the human then wants fixed anyway.
- Today it is `deferred` with a reply, and `deferred` never reaches the fix choice.
- Our own reviews already have the same case: a finding marked `out_of_scope`, true but not this change, listed as a follow-up.
- So I'd make it `valid`, with a finding that carries `out_of_scope`. The human can then choose it like any finding. `deferred` keeps one meaning: only the human can decide.

## 4. The open questions (question 2)

| # | Question | My view |
|---|---|---|
| 1 | Slim event bodies | **Yes.** The report is the one source |
| 2 | `test-plan-challenge` and `foreign-review` as kinds | **Yes** |
| 3 | `external-review.submitted` | **Yes.** One kind, one event |
| 4 | No iteration on a foreign review | **Yes** |
| 5 | A re-review's fix round | **The loop's spec,** copied from its round. One caution: a re-review must carry its earlier findings under its own name (`earlier`), never `findings`. A fix is told by carrying the findings the human chose |
| 6 | The external finding's prefix | **Change:** section 2 |
| 7 | The stamp step | **Accept as plumbing.** It runs the agent's own named rules, as the check step does, and it writes into the report before the pin |
| 8 | `test-plan.challenged` | **Keep** |
| 9 | The arbiter | **A separate agent, later.** Two workers want it offered on a rejected human point too; that is main's offer |
| 10 | One agent type, the lens in the job | **Yes** |
| 11 | A foreign review's IDs | **Per job.** The key is then the job and the ID |
| 12 | Parallel reviewers of one lens | **A lock, but not the core's.** Below |
| 13 | Findings into fix targets | **The loop's spec** |

**Question 12.** Holding the core's events lock from the stamp to the event means the hook takes a lock the event writer also takes, so the writer must learn that it is already held. That is machinery in the core for one agent's need.

**Simpler:** the stop hook takes its own lock, one per effort, around its work from the stamp to the event. It names no agent, IDs stay readable (all five workers quote them in replies and tickets), and it closes something still unproven: the lab lost an event when two agents stopped at once.

## 5. Two things in the spec itself

1. **The tree check blames the reviewer for what it didn't do.** "The tree's tip isn't the job's head" gets the line "undo your changes". A reviewer reads the builder's tree. If a fix lands there while it reads, the reviewer can't repair that, is held twice, and the job ends as "gave up". Split the rule:
   - uncommitted changes in the tree: a repair line, as now;
   - a moved tip: told to main, no refusal counted, as for a missing install file.
2. **The event example in section 4.6** has no `body`, and its `agent` holds the agent type where the others hold the agent's id. An example only, but it is the one a builder copies.

## 6. What belongs to another spec (question 3)

| Spec | What |
|---|---|
| **The remote** | the threads file: the SHA the review was made at and each thread's original line; our own notes left out of a new fetch; a re-posted point shown with its earlier verdict; a follow-up in an answered thread as a new item; comments the human relays by hand; a new fetch as a new file, never an edit. Also: the commit a reply names is the pushed or landed one, never a working commit; inline comments only on the MR's diff, the rest as general notes; severity words not posted as they are; whether posting resolves a thread; a push resetting the approval |
| **The review loop** | a drafted reply for a valid item the human didn't choose; an `out_of_scope` security finding shown in full; the iteration shown beside an ID when a card spans two; the arbiter's offer |
| **The dispatch** | the job's fields (the lens, the cover, the earlier findings, the threads); mapping a moved line is the lens's prose |

## 7. The constitution (question 4)

**Nothing against it.** The reviewer keeps everything of its own, the plumbing stays blind, and no field was added without a script that reads it.

**One thing to watch when it is built:** `reviewer-facts.sh` gathers the facts of four kinds (the cover, the IDs, the earlier findings, the plan, the threads). If it grows a branch per kind, split it by kind.
