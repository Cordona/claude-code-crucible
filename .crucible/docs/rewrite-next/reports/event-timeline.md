# Event timelines: what happens, in order

By Dev Beta, for the owner. The flows of `report-schemas.md` as timelines, using the names proposed on 2026-11-24 (not yet applied to the spec or verified):
- `noticed`, with `security` and `for`;
- the test-plan event names.

**Legend:**
- **who:** `human`, `main`, `script` (a lab or framework script main runs), `hook` (it runs by itself), `agent`.
- `→` means "which makes".
- `[owed]` means main must do it, unasked.
- `[offer]` means main asks the human.

## 1. Build, then a review loop, then the end card

```text
 #  who     event                    what it means / what follows
 1  human   "build the retry limit"
 2  main    gate card: Build it?      → human answers yes
 3  hook    gate.answered            the human's yes, recorded; it approves the dispatch
 4  script  job.dispatched (build)   everything the builder needs: task, tree, report path, plugins
 5  hook    job.assigned             the builder is running: build-kotlin-af6bac
 6  agent   (works, writes its report, tries to stop)
 7  hook    (stop check: validates the report, makes the working commit)
 8  hook    build.submitted          commit, red?, blocked?, report path
            → [offer] "build 8 has no review: review it?"
 9  human   yes                      → gate.answered
10  script  round.made               the review round: 3 reviewers, base..head, who covers what
11  script  job.dispatched ×3        one per reviewer
12  hook    job.assigned ×3
13  hook    review.submitted ×3      each reviewer's findings (IDs stamped: SHELL-01, SECURITY-01, …)
            → [owed] merge, once all three are in
14  script  review.merged            all findings with status; verdict: changes; targets
            → [offer] fix choice card
15  human   "fix high and medium, three rounds"
16  script  fix.chosen               the IDs and the cap (3): from here the loop runs on its own
17  script  job.dispatched (fix)     hot, to the same builder, with the chosen findings
18  hook    build.submitted          the fix: answers per finding (done / partly / declined)
            → [owed] the next round
19  script  round.made               re-review: each reviewer gets its earlier IDs and the fixer's answers
20  hook    review.submitted ×n      answers: fixed / open; on a decline: agree / disagree
            → [owed] merge
21  script  review.merged            nothing open → verdict: pass (or open → back to 17, up to the cap)
            → [owed] end card
22  main    end card                 what was fixed; each decline with the fixer's reason and
                                     the reviewer's view
23  human   close / waive a decline / send it back
24  script  loop.ended (clean, cap, stopped, …)
```

Nobody types between 16 and 22.

## 2. A decline, in that loop

```text
18  hook    build.submitted          CLEAN-CODE-01: declined, "the word input is b.sh's contract"
            the finding is set aside: no new fix job takes it
20  hook    review.submitted         the reviewer's view on CLEAN-CODE-01: agree or disagree, with why
         (optional) [offer] the arbiter; its ruling.submitted is a third view
22  main    end card                 CLEAN-CODE-01: declined, fixer says …, reviewer says …
23  human   waive it                 → it is closed
     or     send it back             → a fix job takes it again; this time it can't be declined
```

## 3. A test plan, challenged once

```text
 1  human   "plan the tests for build 8"
 2  main    gate card                → human: yes → gate.answered
 3  script  job.dispatched (test-plan)
 4  hook    test-plan.submitted      the draft: behaviours, tests, untested, baseline
            → [owed] the challenge (it was approved with the plan step)
 5  script  job.dispatched (challenge)
 6  hook    test-plan.challenged     challenges C-1, C-2 (or none)
            none → straight to 9
            → [owed] the rework
 7  script  job.dispatched (test-plan, rework), to the planner, with C-1 and C-2
 8  hook    test-plan.updated        answers: C-1 applied, C-2 cannot (why)
            every challenge answered → the plan is done
 9  main    plan gate card           the plan, with anything it couldn't apply
10  human   approve                  → test-plan.approved
            → [offer] write the tests
11  script  job.dispatched (test)    the tester writes exactly the approved plan
12  hook    test.submitted           → [offer] review the tests (a review loop as in 1)
```

## 4. Someone reviews our MR (external review)

```text
 1  script  external-review.received   the MR's new threads (human and bot), fetched
            → [offer] triage it
 2  human   yes                        → gate.answered
 3  script  round.made + job.dispatched (external-review)
 4  hook    review.submitted           per item: valid (with its finding), rejected, already-fixed,
                                       deferred, answered, noted
 5  script  review.merged              the valid items' findings
            → [offer] fix choice (as in 1, 14 to 22, for the valid ones)
 6  main    replies gate card          each reply, human threads first
 7  human   post them
 8  script  pr.posted                  the replies, per thread and item
```

## 5. We review someone else's MR (foreign review)

```text
 1  human   "review MR !42 in core-api"
 2  script  pr.review-requested        the MR's base, head and tree
            → [offer] review it
 3  human   yes → round.made + job.dispatched (review, foreign)
 4  hook    review.submitted           findings written for the MR's author; no answers
 5  script  review.merged
            → [offer] comments gate card
 6  human   edit and post
 7  script  pr.posted                  the comments
            no fix loop: it isn't our code
```

## 6. When a job goes wrong

```text
 a  an agent's report won't validate twice   → job.ended (gave-up); its tree is kept
                                               → [owed] a fresh agent replaces it
 b  the human cancels a working agent        → job.ended (cancelled)
 c  the session closes while an agent works  → at the reopen: job.ended (died)
                                               → [owed] a replacement
```
