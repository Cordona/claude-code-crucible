# Dev Gamma (Core API, PHP/Laravel, GitLab): report schemas vs real work

From two shipped tickets: PSWS-2355 and PSWS-2356 (partner action dates). Each was merged to main, then ported to two release branches by cherry-pick and tagged for QA.

## 1. What breaks on this project

- **The commit itself.** This user's rule is that agents never commit without an explicit yes for each commit. Our subjects follow the repo's format, `fix(import): PSWS-935 name the reason an import row failed`, and the user strips agent trailers. A `crucible(build):` subject carrying `Job:`/`Effort:` trailers can't land on main. It would also travel with every cherry-pick to `release-v3.13` and `release-v3.12`. If the stop check commits, those commits have to stay in the effort's worktree and be rewritten before they land. Please say this in the spec. Otherwise the commit section clashes with the consent rule.
- **The report lives outside the tree.** On 17 Nov the session scratchpad was wiped. It took the approved 2355/2356 plans and two worktrees with it. Only facts I had already repeated in chat survived. Whatever must outlive the effort has to go into git or the MR. So: **yes, put `decisions` in the commit body**, or at least into the MR body.
- **Gates.** The test gate here is never a full run; it is always `narrowed` (`--filter` only, by rule). Often it can't run at all: the local PHP image is 8.1 without ext-redis, and main needs 8.3. Missing gates:
  - `ci`: on this stack the pipeline is the real check. Today "pass" means a green CI job, not a local run.
  - a `not_run` reason that tells "the environment can't run it" apart from "skipped".
- **The 55-character `summary`** loses 10 characters to the ticket key (`PSWS-2355 `). Either let the subject carry the ticket from the effort, or count it in.

## 2. Answers to section 12

1. **Missing from the build report:**
   - a `ticket` link, or one derived from the effort;
   - a `ported_to` list, or a port job: the same change cherry-picked onto release branches with their own conflicts;
   - `ci` as a gate.

   Never used: none of the fields so far.
2. **Fix:** `done`/`declined` is not enough.
   - **`partly`, with a reason**, which the reviewer treats as open. The framework already has the rule "a partly addressed finding stays open".
   - **`deferred`, naming the ticket.** The human reviewer's note on the 2355 MR (a year-0 `due_date` returns 500) was valid and out of scope. It went to a follow-up ticket. That is neither a decline nor done.
3. **Test plan: yes, plan the fixtures.** Goldens are assertions on this repo.
   - 2355 edited 3 existing golden files.
   - 2356 added `due-day-expiry.golden.json`.

   A golden or fixture content change must be visible to the challenger before tests are written. Otherwise a weakened expectation slips through as "support". Keep `modify.keeps`/`move` too:
   - The 2355 repair *moved* a `-05:00` data-provider row from accepted inputs to refusals. As a bare `modify` it would read like a weakening.
   - All 3 of its tests *extended* existing methods with new rows. `extend` (adds rows, keeps the old ones) is the most common action here, more common than `add`.
   - `baseline` needs `not_run` (see the image problem above).
4. **Review:** the three realism classes work. `proof` as `path:line` fits real cases, for example a not_tested proof at `CreatePartnerActionRequest.php:23`. `handoffs` are rare; keep them, they're cheap.
5. **External review: two judgements are missing.**
   - **`out-of-scope`**, with a follow-up ticket (the year-0 note above).
   - **`answered`**, for a reviewer's question that is not a defect.

   Also, the AI review bot posts one note with several findings (the label `ai-review-please` on every MR), so judgement is needed per item, not per thread. Some items in one note are valid and others are rejected.
6. **Foreign review: yes, write a separate `comment`.** `claim` is written for our reviewer and arbiter. A comment to a colleague needs another tone and its context.
7. **Commits:**
   - `Fixes`/`Declines` and `decisions`: yes, if the commits are ours to rewrite (see section 1).
   - `Job`/`Effort` trailers: no on anything that lands on a shared branch.

## 3. Smaller points

- **Arbiter:** add `ask`. Product questions are real here (what a year-0 date should do is a product call, not a fix/drop).
- **Test report:** `test` as the only gate is too narrow. The lint (`php-cs-fixer-on-changes.sh`) also runs on test files.
- **`run`:** a free-text `where` is fine. Ours ran in a separate worktree mounted into docker, with a regex filter (`Partner[CU][a-z]*ActionTest::…`). Long commands like that need more than 200 characters, so exempt `command` from the cap.

---
*Compiled by Claude Code Crucible Framework on behalf of Ventsislav Stoevski*
