# Report schemas, draft 2: Fable's check (2026-11-24)

By Crucible Fable Reviwer, for the owner. Talking only; the owner's go is the only go.

**What I read:** draft 2 of `report-schemas.md` and `decisions.md`, against my round 1 answer and the workers' points. I went through every field and every enum value with the reader test.

## Verdict

**Draft 2 is sound and close to ready for the owner.** Round 1 is applied faithfully, the owner's three decisions are in, and nothing the workers showed a real case for was lost. It is also smaller than draft 1 in the places that matter (commits, arbiter, judgements by what follows).

Seven things remain. Two are gaps the decline decision opened, three are fields without a clear reader, two are wording that would refuse real work.

## Gaps

1. **What a fixer may answer after the human sends a decline back.** Decision 2 says the human waives it or sends it back to be fixed. The fix report's rules still allow `declined` on that finding, so it could be declined a second time and come round again. After the human insists, `declined` should be refused for that ID. A fixer that truly can't do it has a blocker to say so.
2. **The arbiter's event still has a review's type.** The draft's own rule is one event type per different next step, and it gave the challenge its own type for that reason. A ruling has no merge after it; it is a view on the end card. As `review.submitted` it would make every reader look inside the body to tell it from a review. Give it its own type. The triage can stay a review, since a merge does follow it.

## Fields without a clear reader

3. **`untested[].category`** (carried over from draft 1). Nothing in the table reads it. Drop it, or name what treats a "concurrency" case differently.
4. **`impact` and `not_run` in the build event.** The card shows both from the report. They belong in the event only if `next.sh` says something different because of them. For `found` and `red` it does. For these two the draft doesn't say what.
5. **The arbiter is offered "on a decline where the reviewer disagrees".** That is a rule nobody needs. The human can want a third view on any decline. Leave when to offer it to main and the human.

## Wording that would refuse real work

6. **"Every target exists" in the plan challenge.** A challenge on a planned support file (a new golden, a new helper) names a file that doesn't exist yet. Backoffice's base-class case and Gamma's goldens are exactly this. A target may also be a `support` file the plan names.
7. **"Every item in the job is judged once" in the triage.** The job can list threads; it can't list the fourteen points inside a bot's note. The agent splits them. So: every thread is judged at least once, and items within a thread are the agent's own split, each judged once.

## Small

- **Rule 0.4** says a next step never opens a report, yet the next review job carries the fixer's reasons to the reviewer, and the end card shows them. Say what is meant: a step that decides never opens a report; a script that carries text to an agent or onto a card may.
- **The test plan has `blocker`, the build report `blockers`.** One name.
- **The 55-character summary** was sized for a prefix that no longer lands. Harmless; keep it or say one line.
- **"Report text never holds customer data"** can't be checked by the stop check. It is right to state, and it will need its line in each agent's prose.

## What I checked and found right

- Every enum that remains is treated differently by something: gate results, the three fix answers, the four reviewer answers, the six judgements, `found.kind`, `blockers.kind`, test actions, `recommend`.
- Known failures come from the job, never from the agent, and the baseline shares the gate's shape and rule.
- A job that fails its check keeps its tree.
- The working commit carries only what recovery needs, and the landing step is named as the home of everything else.
- Dropped as agreed: `deferred` from the fixer, the foreign `comment`, `checks`, `repairs`, `extend`, `move`, the `ci` place, the reason kind on `not_run`, the questions cap, the extra trailers.
