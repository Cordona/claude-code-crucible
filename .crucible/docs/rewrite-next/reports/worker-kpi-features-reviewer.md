# Worker answer: the reviewer (core-api, KPI features)

Real work behind this: our GitLab MRs get an AI-review bot (triggered by a label) plus a human reviewer. We also do internal PHP reviews with re-reviews, and the PSWS-2236 Helm-values MR (merged after a server-side rebase). Mostly the spec fits. These are the cases where it doesn't.

## 1. Can a reviewer say everything?

**`review`: yes.** `out_of_scope` matters most to us: "fix only the reported bug" is a standing rule, and most of our real findings outside the diff land there. `relates_to` and `@repo:` cover our cross-repo case (code in core-api, its env var in a Helm values repo).

Two small gaps:
- **`reason` on `fixed` should be optional.** "Fixed, but differently than suggested" is common, and the human wants to see it.
- **An `out_of_scope` security finding** must still reach the card in full, not only the follow-up list. The spec doesn't say it does.

## 2. External review

**The six verdicts cover our threads.** Real mapping:
- The bot flags a missing tenant filter on a query: `rejected` ("one DB per tenant, scoped by the connection"). This is our most frequent bot false positive, and the verdict fits.
- The human approves and writes "merge it, warn QA, prod tonight or preprod first?": three points in one note. Split into items: `deferred` + `note` for the release call, and `answered` or `deferred` for "merge" and "warn QA". The spec covers it.
- A reply in the reviewer's own language (ours are often Bulgarian): free text in `reply`, already covered.

**What doesn't fit:**
- **The bot re-posts on every push.** A point we rejected last pass comes back as a new thread. The reviewer judges it again from nothing and may answer differently. The threads file (the remote's spec) should mark a thread that repeats an already-judged one, with the earlier verdict and reply, so the reviewer can keep or change it knowingly. No new report field is needed.
- **Thread positions are on an older commit.** GitLab diff notes point at the line as of the SHA the reviewer saw. After a push the line has moved, and a `valid` finding's `at` at the job's head is a remap the reviewer must do. Say so in the job (the thread's original position next to the head), or the `at` rule refuses good findings or, worse, accepts the wrong line.
- **"Fixed in `<commit>`" must name the landed commit, not a working commit.** Working commits never land, and our MRs are squashed or rebased server-side (our Helm MR's SHA changed at merge). A reply naming the working SHA points at nothing. `already-fixed` replies and the drafted replies to `valid` items need the commit after landing (the second reply offer should come after landing, not after the fix).

**The two reply offers match how we work.** Rejections and answers go out early. Fix replies go after the merge.

## 3. Foreign review

The shape fits, but the commonest real comment on a colleague's MR is a **question** ("why not reuse the existing guard?"), not a defect. Today that has to become a low `hypothetical` finding, which reads like an accusation. Simplest generic fix: allow an optional `at` on `notes` in a foreign review and post notes as non-blocking comments. Praise fits `notes` already.

## 4. Re-review statuses

`fixed` / `open` / `agree` / `disagree` cover what we see. One real case is covered but should be said: a fix that introduces a new defect is a new finding, not `open` on the old ID. A line in the lens prose is enough.

## 5. Plan challenge

Fits. The `path::helper` target is exactly the challenge we'd raise on a shared test helper (`tests/Fixtures/*Helpers.php`). I'd add a missing CI suite registration (CI only runs files listed in `tests/ParallelGroups/suite-N.txt`) as a target example: a support file the plan should name and didn't.

## 6. Rules that would refuse a good review

- **`at` must exist at the job's head:** see the moved-thread case above.
- **"A finding on another verdict" refused:** a `rejected` point that hides a *different* real defect is real (the bot is wrong about X, but its line shows Y). That's two items, and the spec allows splitting, so fine. Say it in the prose.
- Nothing else would bite in our work.

## 7. Open questions (§14), where our experience bears

- **Q6, ID prefix of a valid external finding:** the lens alone loses routing. A triage lens (PHP) meets security and persistence points. Our current external-review flow routes each finding to the seat that owns it. Keep the job's lens prefix, but let a `valid` finding carry `for` (as `noticed` does), so the fix choice and the re-review go to the right lens.
- **Q9, the arbiter as a separate agent:** yes. Ours is separate today, and that's what makes its ruling credible.
- **Q12, parallel reviewers of one lens:** hold the lock from stamp to event. Readable IDs matter. We quote them in Jira and MR replies.
- **Q1, slim bodies:** fine for us.
