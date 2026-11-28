# Remote reviews, the real output: Fable's review of the shapes (2026-11-27)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** the gate preview with the scripts' real output (kept outside the repo, as it holds real merge request text), and the "Third read" in `spikes/remotes/gitlab-findings.md`.

**Not done:** nothing was run. I did not read the scripts, `evidence/remotes/run.sh` or its output; the 33/33 and the GitLab counts are Dev Beta's.

## Verdict

**The three shapes are right as the output shows them: approve, with one fix before the rules and two things to confirm.** No field is missing a reader and none is extra. The output also confirms the point I took back: on the bot's review note, the commit worked out from the push history is the same commit the note names in its own text.

| Point | Kind |
|---|---|
| GitHub's `base.sha` is not the merge base | Fix, section 1 |
| Every comment of a resolved GitLab thread carries the same `updated` | Confirm, section 2 |
| `state` is each host's own word | Decide, section 3 |
| The spec's fetch steps are older than the runs | Text, section 4 |

## 1. The base on GitHub

**The runs replaced the merge base with the base the host recorded.** On GitLab that is right and proven: `diff_refs.base_sha` is the merge base, on five changes.

**On GitHub it is not the same thing.** As I know the API, a pull request's `base.sha` is the base branch's tip as GitHub last recorded it, not the commit the change forked from. When the base branch has moved on since the fork, the two differ, which is the ordinary case for any pull request open more than a day. A range from `base.sha` to the head then shows the base branch's newer commits as if the change undid them.

**The fix keeps what the runs found:** fetch `base.sha` by sha, then take the merge base of it and the head. On GitLab the result is unchanged. The stubs can't show this either way, so it joins the not-proven list, and the one public read-only call would settle it.

## 2. `updated` on a resolved GitLab thread

In the output with line threads, all comments of one thread carry the same `updated` to the millisecond, though their ids are far apart and one body dates itself a day earlier. The three threads differ from each other by about a second.

**Two readings.** GitLab may touch every note when a discussion is resolved, and these were resolved in one sweep. Or the mapping copies one value to every comment. Check one thread against the raw reply.

**If it is GitLab's doing, the shape holds:** the thread is `changed` anyway because `resolved` flipped. The field's line should then say that on GitLab `updated` also moves when the thread is resolved, so no reader takes it for an edit.

## 3. `state`

The pinned change file gives GitLab's word, `opened`. GitHub says `open`, and tells a merge by a separate flag. Either map both to one set (`open`, `merged`, `closed`), or say it is the host's own word and nothing may branch on it. I lean to the mapping: one shape from both hosts is the point of the file, and the runs now fetch merged changes.

## 4. The spec's text

Section 1 of `specs/jobs-remote-reviews.md` still describes the fetch before the runs: the base from the base branch's tip, no fallback to the head's sha, no `--refmap=`. Bring steps 3 and 4 in line with the third read, with the base as in section 1 above.

## 5. Read from the output, no change asked

- **Stacked changes work:** one change's base is the head of the change below it.
- **A reply posted as its own note** becomes a thread with role `author`, on the commit after the fix push. That is the fixer's account, as designed.
- **An AI review reads as `human` when no `--bot` named its account.** That is the default working as written; the human names the account.
- **One note, ten points:** the reply in the output speaks of ten items in a single note. The live chain run should show whether each gets its own item.
- **The preview's own slip:** the review event names change 17, which in the preview is another merge request than the one its threads came from. Only the hand-filled wrapper; the real write takes it from `--change`.

## 6. Not proven, to keep in the results

- GitHub's real query and paging.
- The link from a GitHub line thread to its review, synthetic in the stub.
- The GitHub base (section 1).

## 7. For the owner

1. **The three shapes:** yours to approve; I see nothing against them once section 1 is fixed.
2. **The one public read-only GitHub call:** it would now settle three things, not one.
3. **`state`:** one set of words, or the host's own.
