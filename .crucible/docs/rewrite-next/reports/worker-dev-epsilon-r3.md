# Dev Epsilon (Auth API): round 3 proposals vs real work

Source: auth-api (PHP/Laravel, GitLab MRs, fast-forward merges, shared release branches), the partner API epic.

## 1. `noticed` replaces `found` and `handoffs`: fits, with three gaps

- **Fits:** in practice a security concern and a cross-lens handoff were both just "seen, not mine". The `security` rule (name the kind, never the value) matches our rule. Add "and never its length".
- **Gap 1: the kind is lost.** `found.kind` separated `secret` from `instruction`, which is text that tries to steer an agent. We hit the second kind for real: untrusted kits and relayed peer content that carried instructions. The card has to say which one it is, so keep `kind` when `security: true`.
- **Gap 2: no ID, so the handoff can't be answered.**
  - A handoff needs the receiver's ruling, with proof.
  - With `for` alone, the next round gets the claim but has nothing to name in its `answers`.
  - Have the stop check stamp an ID (e.g. `N-n`), and require the routed lens to answer it.
- **Gap 3: `for` must allow `human`, not only a lens.** In PSWS-1951 the security lens flagged a DB header carried over a redirect. Its owner was the human's restore decision, not another lens.
- **Also:** allow `@<where>:path` in `noticed[].at`. Our "outside this task" items were often in core-api.

## 2. Test-plan event names: fit

- `submitted` / `challenged` / `updated` / `approved` read well and match what happened on 1793, 1792 and 2294.
- **Missing: changes after approval.** On 1951 the human trimmed and restored tests at the gate, and after approval. Each change sent the plan back to unapproved, and tests that were added or rewritten got re-challenged.
  - Say that a `test-plan.updated` after `approved` voids the approval.
  - Say that only the new or rewritten tests are re-challenged.
- **`test-plan.approved` should carry the digest of the plan the human saw.** Then a plan that changes between the card and the yes is refused.

## 3. No `files` in `build.submitted`: breaks here

"Working commits are never rewritten" isn't true in this repo's lifecycle:
- **Fast-forward-only MRs:** the branch is rebased onto the target before merge, with the merge pinned to the head SHA. Every commit gets a new SHA.
- **Release ports:** these are new `-x` cherry-picks on shared release branches.
- **Landing re-makes commits:** the gated landing step, from round 2, writes new commits. The working commits are left behind.
- **Cleanup:** a worktree and its branch are deleted after merge. The old commits become unreachable, and git's garbage collection deletes them.

So a cover read later from the commit can fail, or come out of a different diff. Draft 2's reason for `files` still holds. The agent never writes it anyway (the hook stamps it), so dropping it saves the agent nothing. **Keep `files` in the event, stamped by the hook.**

## 4. Report path in every submission: fits

Two conditions:
- **The report must live in the Crucible space, never in the job's tree.** Our worktrees' `.crucible/` must never be committed, and worktrees get removed after merge, which would leave the path dangling.
- **The path is local.** It must never reach a commit, an MR body or a ticket. Our rule there: no local paths or register ids.

## 5. The finding inside its item: fits

- It matches Ivo's note 11370 exactly: one note, five items, one `valid` with a finding, four `noted`.
- It also covers "valid, but a follow-up" (`deferred`) and the MR description thread.
- **Missing: the reply on a `valid` item after the fix.** A fixed item still needs a reply that names the fix commit. On !32 the fix push (`79edd92`) also reset the approval.
  - Say where that reply comes from: the fix answers plus the landed SHA.
  - Order the replies gate after the fix loop for `valid` items. The timeline's step 6 sits before the fix is done.

## 6. `answers` keeps its name: fits

There are three answer sets, from the fixer, the reviewer and the plan rework. They're kept apart by their key (`id` vs `challenge`). No confusion in practice.

## The timeline, against our flows

- **§1 step 7 (the hook makes the working commit):** fine, as long as nothing pushes or lands without the human's go (round 2, commits).
- **§1 step 8, the review as an `[offer]`:** in this repo a correctness review is mandatory before anything lands. An offer is fine only if landing refuses an unreviewed build.
- **§2 decline → end card → "send it back, can't decline again":** matches our rule that what the human chose is mandatory.
- **§4:** see point 5. Replies to `valid` items belong after the fix. Posting them is an outward write and needs the replies gate, which it has.
- **§5:** our side is GitLab, so `pr.*` names read oddly, but that's cosmetic.
