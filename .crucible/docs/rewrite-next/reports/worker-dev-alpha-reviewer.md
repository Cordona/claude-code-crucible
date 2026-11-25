# Dev Alpha: the reviewer's spec vs real review work

Checked against `review-agent.md` (draft 1). The evidence is ecosystem-api (PHP/Laravel, GitLab):
- internal reviews on PSWS-1313 and 1813;
- MRs !10, !12, !14, !16 and !19, reviewed by the AI bot and by Ivo.

"GUESS" marks an inference. Read only.

## 1. Can a reviewer say everything? (kind `review`)

Yes, mostly. Several real cases are now answered:
- **Ranges:** PSWS-1313 PHP-001 sat at `ListEditorRequest.php:37-44`, and `path:N-M` covers it.
- **Callers:** callers in core-api take `@core-api:…`.
- **Outside the diff:** PSWS-1813 PHP-013 takes `relates_to`.

Two gaps:
- **`suggestion` as one line of 200 characters is too short for code.** Our PHP-001 suggestion was a validation snippet. Give `suggestion` the `reply` limit (1,000 characters, several lines). That matters most in a foreign review, where it's the product.
- **The same defect across iterations.** PSWS-1813 PHP-011 (a restore/destroy race) was set aside, then came back from the bot on !14 as F-05, judged REAL/HIGH. IDs reset per iteration, so `reopens` can't name it.
  - Free text in `claim` is enough, unless a card should show "set aside before, came back". If it should, let `reopens` take `<iteration>:<ID>`.

## 2. External review

**The six verdicts cover every thread I've had:**
- the bot's 14-point note on !10;
- the two-claim F-03 on !14, which this spec's F-03a/F-03b split now matches;
- Ivo's !16 note (one finding, plus "checked, no change" items as `noted`);
- a release-window question (PSWS-1834) as `deferred` with a `note`.

**Item splitting and per-item replies** match how we worked: !10 got 14 replies, one per point, in one discussion. **The two reply offers** match too: we fixed first, then replied.

Four gaps:
- **The commit to name.** A valid item's script-drafted reply says "fixed in `<commit>`", but working commits never land. After a rebase (!12, force-with-lease) or a squash-merge (!19), only the pushed or landed SHA means anything to the reviewer. The script must cite that one, and `already-fixed` too.
- **The SHA the review was made at.** Judging `already-fixed` needs it. On !14 we diffed from the reviewed SHA to the head. Have the threads file carry it, or name it in the job (§12).
- **Relayed comments.** Ivo's !16 points came through chat, not as threads. This is the third time I've raised it. A threads file built from the human's paste (`relayed-1`, `source: human`) would fit, so it belongs in the remote's spec.
- **No second opinion on a rejected human point.** One triager now judges everything. Legacy put an arbiter on contested points, and that's how F-05 got its REAL/HIGH. Offer the arbiter (§14 q9) on a `rejected` human point before its reply is posted.

## 3. Foreign review

I have no real evidence: I've never reviewed someone else's MR. Two GUESSES:
- **GitLab inline comments need a position in the MR's diff.** A finding with `relates_to`, `out_of_scope` or no `at` must post as a general comment. The remote's spec should say so.
- **The overall comment.** Use `notes` as the summary comment to the author (what held), so no new field is needed.

## 4. The re-review statuses

`fixed`, `open`, `agree` and `disagree` cover what I saw: "partly" becomes `open` with a reason, and a fix that broke something is a new finding. Two cases need a word in the spec, with no new value:
- **Moot:** the finding's code was removed by another fix. Use `fixed` with an optional `reason`. Say that `reason` is allowed on `fixed`.
- **Not checkable by reading the code:** the PSWS-1834 Helm env var could only be proven by a deploy, and `open` would loop it to the cap. Say it is `fixed` with a reason naming the live check, which the end card shows.

## 5. The plan challenge

It fits. `change` covering a wrong fact, a merge and a shrink answers my r1 point: PSWS-1813's challenge had about 9 plan-fact fixes (a wrong run command, wrong line numbers). A wrong `run` takes the target `plan`.

## 6. Rules that would refuse a good review

- **`suggestion` length:** see 1.
- **The tree check:** if a lens ever runs the suite, phpunit's result cache (git-ignored) mustn't count as "the tree has changes". Ignore git-ignored files. GUESS: reviewers have no shell today.
- **No other rule bites.** `-path:N` covers a deleted check, and `@where` covers vendor and cross-repo files.

## 7. The open questions

- **q6, the external finding's prefix:** the triager's lens is fine. But a security-class point the PHP triager rates valid must still get the security floor, not only a `PHP-NN` ID.
- **q9:** a separate `code-arbiter`, yes. Also offer it after the external triage (see 2).
- **q10:** yes to one agent type with the lens in the job.
- **q11:** an MR stays open over several iterations. Any card that cites an earlier finding should show the iteration with the ID.
- **q12:** yes to holding the lock from stamp to event.
- **q4:** yes to no iteration on a foreign review, with IDs numbered per job.
