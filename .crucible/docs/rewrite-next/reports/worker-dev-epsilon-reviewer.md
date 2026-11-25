# Dev Epsilon (Auth API): the reviewer spec vs real review work

**Source:** auth-api (PHP 8.1 / Laravel 9, GitLab MRs). It covers:
- **Internal:** PHP-reviewer passes, lens passes on the partner API epic, re-reviews after fix rounds.
- **External:** the human reviewer's notes, and the AI review bot that the `ai-review-please` label triggers.
- **Foreign:** none, so §3 below is a judgement, not experience.

## 1. Can a reviewer say everything? (kind `review`)

Yes, almost. Real cases fit:
- an edge-case HIGH fixed on the human's pick (`proof` + realism);
- "can't occur" dismissals with a proof line;
- a defect in a caller (`relates_to`);
- ">1000 query params gives a 500 on every route" as `out_of_scope` (PSWS-1792);
- "what held up" (`notes`).

Two gaps:
- **A location in an installed dependency.** One real proof was "Guzzle always sets request_size" at a vendor file and line. Our worktrees have no `vendor/`, since it's ignored and lives in the image. As `proof` text that's fine. As an `at` it's refused ("doesn't exist at the head"). Allow `@vendor:path:N`, or say that dependency locations go in text only.
- **`proof` at 200 characters, one line, is tight.** A real reachability proof chains two or three facts. For example: Laravel 9's `Http::fake` answers with the first matching stub, so a stub in `setUp` hides the per-test one. Let `proof` (and `out_of_scope`) take about 400 characters, like a short `reply`.

## 2. External review

The six verdicts fit the threads we really got:
- **The human's note 11370:** one real point (`valid`) plus four "checked, no change needed" (`noted`, no reply).
- **AI-bot notes:** several points in one note. Splitting them into items with the bot's own labels is exactly what we did by hand.
- **A point only a stakeholder can decide** (the key format was "still needing his yes"): `deferred` with a `note`.

Gaps:
- **A `valid` point whose fix isn't in the tree.** The human reviewer's real finding was about the merge note in the **MR description**. Its fix is an edit to the description (or the commit body), not a code fix. The fix loop sends findings to the builder. Say that a `valid` finding whose `at` is `description` goes to main's landing/MR-edit step, not to a fix job.
- **A `valid` point the human chooses not to fix.** A bot's real-but-minor nit is common. It has no fix commit, so the "drafted from the fix" reply never comes, and the thread is left without an answer. The second reply offer should also draft "acknowledged, not changing: <the human's reason>" for valid items left out of the fix choice.
- **A new note in a thread we already answered.** A follow-up in the same discussion: say that the next `external-review.received` carries it as a new item in the old thread, and that earlier items aren't judged again.
- **Remote's spec, for the record:**
  - On GitLab a fix push resets the MR's approval (seen on !32). The second reply offer should say so.
  - Say whether posting also resolves the thread. The convention varies.

The two reply offers match how we worked. The ready replies went out first, and the "fixed in <sha>" replies went out after the push.

## 3. Foreign review

The shape fits as far as I can judge: findings written for the author, edited at the comments gate, no fix loop. Two small points:
- **GitLab diff notes need the old line on a removed line,** so `-path:N` covers that. Say that a finding with no `at` becomes a general MR comment.
- **Severity and realism words posted to an outside author read harshly.** Leave it to the comments gate (the human edits them), but don't post the labels by default.

## 4. The re-review statuses

`fixed` / `open` / `agree` / `disagree` cover what we saw after fix rounds:
- `partly` became `open` with a reason;
- a fix done differently from the suggestion is still `fixed`;
- a fix that broke something else is a new finding.

One case is missing: **the code was removed.** A finding on code the change later deleted is neither fixed nor open. In PSWS-1951 a restore deleted whole blocks of the epic's code. Allow `fixed` with a `reason` ("the code is gone") rather than adding a status.

## 5. The plan challenge

It fits, and it now covers what round 2 asked for. Mapped to real challenges:

| Real challenge | `target` | `ask` |
|---|---|---|
| The run scope (PSWS-1793) | `plan` | `change` |
| The shared setup (PSWS-1793) | the support file or `path::helper` | `change` |
| The editor guard at a code line, with no behaviour ID (PSWS-1793 test 7) | a code location | `add` |
| Two drafts merged into one renamed test (PSWS-2294) | the test | `change` |

One check: `prove` targets an untested entry (`N-`), but the repair line says "not a behaviour or test in the plan". Make sure `N-` IDs (and `baseline`, `run`) are valid targets.

## 6. Would a rule refuse a real, good review?

- **`at` must exist at the head:** this refuses dependency locations (point 1).
- **The 200-character, one-line limit:** this refuses a real proof chain (point 1).
- **No `reply` on `valid`:** right as a rule, but it leaves an unfixed valid point with no reply (point 2).
- **"Every thread judged at least once":** this is right. Bots post "review started" or summary notes: those are `noted`, so nothing is refused.

## 7. The open questions (§14)

1. **Slim bodies:** agree.
2. **Kind names:** agree.
3. **The external review's event:** agree.
4. **The foreign review's iteration:** agree.
6. **The external finding's prefix:** the lens, agree. The stamped `source` plus the thread already show where it came from.
9. **The arbiter:** a separate agent, agree.
10. **The lens:** one agent type, with the lens in the job, agree.
11. **IDs reset per iteration:** fine. The cards must then show the iteration whenever two iterations are on one card. These IDs never reach an MR or a ticket here.
12. **Parallel reviewers of one lens:** hold the lock from the stamp to the event, agree. An ID that carries the job seq would be hard to talk about at the fix choice.
